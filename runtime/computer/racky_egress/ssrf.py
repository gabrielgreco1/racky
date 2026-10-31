"""Filtro SSRF do egress (07 CS-143).

O egress resolve o DNS ele mesmo, confere TODOS os endereços devolvidos e fixa um deles para a conexão direta. Recusa
loopback, RFC 1918, CGNAT, link-local (inclui 169.254.169.254), multicast, reservados, ULA IPv6, metadata de nuvem, os nomes
internos do Docker e as formas "criativas" de escrever um IPv4 (decimal, hexadecimal, octal, abreviado). A regra vale com ou
sem proxy upstream. Exceções são explícitas (`allow_cidrs`) e quem decide é o app, nunca o agente.
"""
from __future__ import annotations

import ipaddress
import socket
from dataclasses import dataclass, field
from typing import Callable, Iterable, Sequence

BLOCKED_NAMES = (
    "host.docker.internal",
    "gateway.docker.internal",
    "docker.for.mac.host.internal",
    "docker.for.mac.localhost",
    "host.lima.internal",
    "host.containers.internal",
    "metadata.google.internal",
    "metadata",
    "instance-data",
    "kubernetes.default.svc",
    "localhost",
)
BLOCKED_SUFFIXES = (".localhost", ".local", ".internal", ".localdomain", ".home.arpa", ".lan")

# Além de `not is_global`: faixas que o Python às vezes classifica como globais ou que merecem nome no motivo.
_EXTRA_NETS = {
    "cgnat": ipaddress.ip_network("100.64.0.0/10"),
    "metadata": ipaddress.ip_network("169.254.169.254/32"),
    "metadata-v6": ipaddress.ip_network("fd00:ec2::254/128"),
    "alibaba-metadata": ipaddress.ip_network("100.100.100.200/32"),
    "ipv4-broadcast": ipaddress.ip_network("255.255.255.255/32"),
    "benchmark": ipaddress.ip_network("198.18.0.0/15"),
    "ula": ipaddress.ip_network("fc00::/7"),
    "link-local-v6": ipaddress.ip_network("fe80::/10"),
    "documentation": ipaddress.ip_network("2001:db8::/32"),
}
_NAT64 = ipaddress.ip_network("64:ff9b::/96")
_SIXTOFOUR = ipaddress.ip_network("2002::/16")
_TEREDO = ipaddress.ip_network("2001::/32")


class Blocked(Exception):
    """Destino recusado. `reason` é curto, estável e vai para o reqlog."""

    def __init__(self, reason: str, detail: str = ""):
        super().__init__(reason if not detail else f"{reason}: {detail}")
        self.reason = reason
        self.detail = detail


def parse_ip_literal(host: str) -> ipaddress.IPv4Address | ipaddress.IPv6Address | None:
    """Interpreta `host` como IP se (e só se) algum parser de URL/`connect()` o trataria como IP.

    Inclui as formas que `inet_aton` aceita: `2130706433`, `0x7f.1`, `017700000001`, `127.1`.
    """
    h = host.strip("[]")
    if "%" in h:  # zone id do IPv6 (fe80::1%eth0)
        h = h.split("%", 1)[0]
    try:
        return ipaddress.ip_address(h)
    except ValueError:
        pass
    if ":" in h:
        return None
    try:
        packed = socket.inet_aton(h)  # decimal, hex, octal, abreviado
    except OSError:
        return None
    if not h or h.endswith("."):
        # `inet_aton("1.")` é inválido; evita falso positivo em nomes
        return None
    if not all(c in "0123456789abcdefxABCDEFX." for c in h):
        return None
    return ipaddress.IPv4Address(packed)


def _embedded_v4(ip: ipaddress.IPv6Address) -> ipaddress.IPv4Address | None:
    if ip.ipv4_mapped is not None:
        return ip.ipv4_mapped
    if ip in _NAT64:
        return ipaddress.IPv4Address(int(ip) & 0xFFFFFFFF)
    if ip in _SIXTOFOUR:
        return ipaddress.IPv4Address((int(ip) >> 80) & 0xFFFFFFFF)
    if ip in _TEREDO:
        return ipaddress.IPv4Address((int(ip) & 0xFFFFFFFF) ^ 0xFFFFFFFF)
    return None


def ip_block_reason(ip: ipaddress.IPv4Address | ipaddress.IPv6Address) -> str | None:
    """Motivo para recusar `ip`, ou `None` se ele é um destino público."""
    if isinstance(ip, ipaddress.IPv6Address):
        inner = _embedded_v4(ip)
        if inner is not None:
            reason = ip_block_reason(inner)
            if reason:
                return f"{reason} (embutido em IPv6)"
    if ip.is_loopback:
        return "loopback"
    if ip.is_unspecified:
        return "unspecified"
    if ip.is_multicast:
        return "multicast"
    if ip.is_link_local:
        return "link-local"
    for name, net in _EXTRA_NETS.items():
        if ip.version == net.version and ip in net:
            return name
    if ip.is_private:
        return "private"
    if ip.is_reserved:
        return "reserved"
    if not ip.is_global:
        return "not-global"
    return None


def host_block_reason(host: str) -> str | None:
    """Recusa por nome, antes de qualquer DNS."""
    name = host.strip("[]").rstrip(".").lower()
    if not name:
        return "empty-host"
    if name in BLOCKED_NAMES:
        return "internal-name"
    if name.endswith(BLOCKED_SUFFIXES):
        return "internal-suffix"
    return None


@dataclass
class SSRFPolicy:
    """Política de destinos de um computador."""

    allow_cidrs: Sequence[str] = ()  # exceção explícita ("Allow Local Network for This Computer")
    allow_hosts: Sequence[str] = ()  # CS-144: se não vazia, só estes padrões (fnmatch) passam
    resolver: Callable[[str, int], Sequence[str]] | None = None
    _nets: list = field(default_factory=list, init=False)

    def __post_init__(self) -> None:
        self._nets = [ipaddress.ip_network(c, strict=False) for c in self.allow_cidrs]

    def _allowed_exception(self, ip) -> bool:
        return any(ip.version == n.version and ip in n for n in self._nets)

    def host_allowed(self, host: str) -> bool:
        if not self.allow_hosts:
            return True
        import fnmatch

        name = host.strip("[]").rstrip(".").lower()
        return any(fnmatch.fnmatchcase(name, p.lower()) for p in self.allow_hosts)

    def resolve(self, host: str, port: int) -> list[str]:
        if self.resolver is not None:
            return list(self.resolver(host, port))
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
        seen: list[str] = []
        for family, _t, _p, _c, sockaddr in infos:
            addr = sockaddr[0]
            if addr not in seen:
                seen.append(addr)
        return seen

    def check(self, host: str, port: int) -> str:
        """Devolve o IP a conectar (fixado) ou lança `Blocked`. Bloqueia se QUALQUER resposta do DNS for proibida."""
        return self.check_all(host, port)[0]

    def check_all(self, host: str, port: int) -> list[str]:
        """Todos os IPs permitidos, IPv4 primeiro (F29: o container não tem rota IPv6; um AAAA na frente fazia o CONNECT
        estourar o tempo). Quem conecta tenta em ordem. Bloqueia se QUALQUER resposta do DNS for proibida."""
        if not self.host_allowed(host):
            raise Blocked("not-in-allowlist", host)
        literal = parse_ip_literal(host)
        if literal is None:
            reason = host_block_reason(host)
            if reason:
                raise Blocked(reason, host)
            try:
                addrs = self.resolve(host, port)
            except OSError as exc:
                raise Blocked("dns-failure", f"{host}: {exc}") from exc
            if not addrs:
                raise Blocked("dns-failure", host)
        else:
            addrs = [str(literal)]
        pinned: list[str] = []
        for text in addrs:
            ip = ipaddress.ip_address(text.split("%", 1)[0])
            reason = ip_block_reason(ip)
            if reason and not self._allowed_exception(ip):
                raise Blocked(reason, f"{host} -> {ip}")
            pinned.append(str(ip))
        pinned.sort(key=lambda a: ":" in a)  # estável: IPv4 antes de IPv6
        return pinned

    def check_name_only(self, host: str, port: int) -> str:
        """Para o caminho com proxy upstream: o upstream resolve o nome, mas o egress confere o que ele mesmo resolve."""
        return self.check(host, port)


def split_host_port(authority: str, default_port: int) -> tuple[str, int]:
    """`host:port`, `[v6]:port`, `host`."""
    a = authority.strip()
    if a.startswith("["):
        end = a.find("]")
        if end < 0:
            raise Blocked("bad-authority", authority)
        host = a[1:end]
        rest = a[end + 1:]
        if rest.startswith(":") and rest[1:].isdigit():
            return host, int(rest[1:])
        if rest == "":
            return host, default_port
        raise Blocked("bad-authority", authority)
    if a.count(":") == 1:
        host, _, port = a.partition(":")
        if not port.isdigit() or not (0 < int(port) < 65536):
            raise Blocked("bad-port", authority)
        return host, int(port)
    if a.count(":") > 1:  # IPv6 sem colchetes: sem porta
        return a, default_port
    return a, default_port


def strip_userinfo(authority: str) -> str:
    """`user:pass@host` -> `host`: o host de verdade é o que vem depois do último `@` (truque clássico de SSRF)."""
    return authority.rsplit("@", 1)[-1]


def noise_host(host: str, patterns: Iterable[str]) -> bool:
    name = host.strip("[]").rstrip(".").lower()
    return any(name == p or name.endswith("." + p) for p in (x.lower() for x in patterns))
