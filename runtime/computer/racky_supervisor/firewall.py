"""Regras de rede do container único (P24): todo tráfego do usuário `agent` sai SÓ pelo proxy local.

Premissa: o agente (comandos do `exec` e o Chromium) roda como o uid `agent`; o proxy/egress e o servidor de controle rodam
como `egress`. As regras `-m owner --uid-owner` valem na cadeia OUTPUT, então não dependem de o agente "cooperar" com
`HTTP_PROXY`: quem ignora o proxy leva REJECT.

- loopback (127.0.0.0/8): permitido para o agente, EXCETO o resolvedor do Docker (127.0.0.11) e as portas de controle (proxy é permitido; admin, runtime e VNC não);
- qualquer outro destino (rede do Docker, host, metadata 169.254.169.254, internet, DNS): REJECT. O DNS do agente também
  fecha: o nome é resolvido pelo proxy, que aplica o filtro SSRF; assim não há túnel por DNS;
- IPv6: tudo do agente rejeitado (o container não tem rota IPv6 útil);
- o uid `egress` (proxy) não recebe regra de uid: o filtro SSRF do proxy decide os destinos dele.
"""
from __future__ import annotations

PROXY_PORT = 3128
CONTROL_PORTS = (8790, 8765, 5900)  # admin/viewer (publicada), servidor de controle do browser, x11vnc


def rules(agent_uid: int, *, proxy_port: int = PROXY_PORT, control_ports: tuple[int, ...] = CONTROL_PORTS, ipv6: bool = False) -> list[list[str]]:
    """Lista de argumentos para `iptables` (ou `ip6tables`). Ordem importa: a primeira regra que casa vale."""
    owner = ["-m", "owner", "--uid-owner", str(agent_uid)]
    if ipv6:
        return [["-A", "OUTPUT", *owner, "-j", "REJECT"]]
    ports = ",".join(str(p) for p in control_ports if p != proxy_port)
    return [
        # portas de controle: nunca para o agente, em qualquer endereço do próprio container
        ["-A", "OUTPUT", *owner, "-p", "tcp", "-m", "multiport", "--dports", ports, "-j", "REJECT", "--reject-with", "tcp-reset"],
        # resolvedor embutido do Docker (redes definidas pelo usuário, 127.0.0.11): o agente não resolve nomes nem faz túnel por DNS
        ["-A", "OUTPUT", "-d", "127.0.0.11/32", *owner, "-j", "REJECT"],
        # loopback: proxy e servidores locais que o próprio agente subir
        ["-A", "OUTPUT", "-o", "lo", "-d", "127.0.0.0/8", *owner, "-j", "ACCEPT"],
        # tudo o mais (outros containers, host, metadata, internet, DNS)
        ["-A", "OUTPUT", *owner, "-j", "REJECT", "--reject-with", "icmp-port-unreachable"],
    ]
