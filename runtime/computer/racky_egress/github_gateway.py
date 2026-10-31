"""Gateway do GitHub dentro do egress: o agente faz git e PR sem nunca ver o token.

O egress não abre túneis HTTPS (CONNECT passa cifrado), então não dá para "pôr a credencial" num `https://github.com` que o agente
chama. Em vez disso, dois hosts locais em HTTP simples chegam ao proxy:

- `http://github.racky/<dono>/<repo>.git`  -> `https://github.com/...` (git smart HTTP: clone, fetch, push)
- `http://api.github.racky/<caminho>`        -> `https://api.github.com/...` (REST: ler o repo, abrir PR)

O egress (uid `egress`, segredos em /run/racky 0700) acrescenta a autenticação e aplica a política do arquivo de config:
só os repositórios listados; push só para refs com os prefixos permitidos (padrão `refs/heads/feat/`), nunca apagar ref; na API,
leitura dos repositórios listados e `POST /repos/<dono>/<repo>/pulls`. Tudo fora disso responde 403 com o motivo.
"""
from __future__ import annotations

import asyncio
import base64
import json
import re
import ssl
from dataclasses import dataclass, field
from typing import Any

GIT_HOST = "github.racky"
API_HOST = "api.github.racky"
UPSTREAM = {GIT_HOST: "github.com", API_HOST: "api.github.com"}
MAX_BODY = 512 * 1024 * 1024  # um push grande (packfile) cabe; acima disso é recusado
ZERO = "0" * 40


@dataclass
class GitHubAccess:
    token: str
    repos: list[str] = field(default_factory=list)  # "dono/repo", sem diferença de caixa
    push_prefixes: list[str] = field(default_factory=lambda: ["refs/heads/feat/"])

    @staticmethod
    def parse(data: dict[str, Any] | None) -> "GitHubAccess | None":
        if not data or not data.get("token"):
            return None
        repos = [r.strip().lower().removesuffix(".git") for r in data.get("repos", []) if r and "/" in r]
        prefixes = [p for p in data.get("push_prefixes", ["refs/heads/feat/"]) if p.startswith("refs/")]
        return GitHubAccess(token=data["token"], repos=repos, push_prefixes=prefixes or ["refs/heads/feat/"])

    def allows_repo(self, owner: str, repo: str) -> bool:
        return f"{owner}/{repo}".lower().removesuffix(".git") in self.repos


class Denied(Exception):
    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


class PushRefused(Denied):
    """Push recusado pela política: responde no protocolo do git, que mostra `! [remote rejected] <ref> (<motivo>)`."""

    def __init__(self, reason: str, body: bytes):
        super().__init__(reason)
        self.body = body


def handles(host: str) -> bool:
    return host.lower() in UPSTREAM


_GIT_PATH = re.compile(r"^/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/(info/refs|git-upload-pack|git-receive-pack)$")
_API_REPO = re.compile(r"^/repos/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)(/.*)?$")


def pkt_ref_updates(body: bytes) -> list[tuple[str, str, str]]:
    """Comandos de um `git-receive-pack` (pkt-lines antes do flush `0000`): (antigo, novo, ref)."""
    out: list[tuple[str, str, str]] = []
    i = 0
    while i + 4 <= len(body):
        try:
            size = int(body[i:i + 4], 16)
        except ValueError:
            break
        if size == 0:
            break
        if size < 4 or i + size > len(body):
            break
        line = body[i + 4:i + size].split(b"\0", 1)[0].decode("latin-1").strip()
        parts = line.split(" ")
        if len(parts) >= 3 and len(parts[0]) == 40 and len(parts[1]) == 40:
            out.append((parts[0], parts[1], parts[2]))
        i += size
    return out


_TRICKY = re.compile(r"%2e|%2f|%5c|%00|\\", re.IGNORECASE)


def _reject_tricky_path(path: str) -> None:
    """A allowlist olha o caminho cru e o caminho cru segue adiante: segmento de ponto, `//` ou ponto/barra codificados poderiam
    levar o GitHub para outro repositório que o conferido. Recusa antes da allowlist."""
    if _TRICKY.search(path) or "//" in path or any(seg in (".", "..") for seg in path.split("/")):
        raise Denied("path with dot segments, empty segments or encoded dots/slashes is not allowed")


def check(access: GitHubAccess, host: str, method: str, path: str, query: str, body: bytes) -> None:
    """Política do gateway. Levanta `Denied` com o motivo legível."""
    host = host.lower()
    _reject_tricky_path(path)
    if host == GIT_HOST:
        m = _GIT_PATH.match(path)
        if not m:
            raise Denied("only git smart-HTTP paths (/<owner>/<repo>.git/info/refs, git-upload-pack, git-receive-pack)")
        owner, repo, op = m.groups()
        if not access.allows_repo(owner, repo):
            raise Denied(f"repository {owner}/{repo} is not allowed for this computer")
        if op == "git-receive-pack":
            updates = pkt_ref_updates(body)
            if not updates:
                raise Denied("push without ref updates")
            for old, new, ref in updates:
                if new == ZERO:
                    raise PushRefused(f"deleting {ref} is not allowed", body)
                if not any(ref.startswith(p) for p in access.push_prefixes):
                    raise PushRefused(f"push to {ref} is not allowed (allowed: {', '.join(access.push_prefixes)})", body)
        return
    if host == API_HOST:
        m = _API_REPO.match(path)
        if not m:
            raise Denied("only /repos/<owner>/<repo>/... is allowed on the GitHub API")
        owner, repo, rest = m.group(1), m.group(2), m.group(3) or ""
        if not access.allows_repo(owner, repo):
            raise Denied(f"repository {owner}/{repo} is not allowed for this computer")
        if method in ("GET", "HEAD"):
            return
        if method == "POST" and rest.rstrip("/") == "/pulls":
            return
        raise Denied(f"{method} {path} is not allowed (read the repository, or POST /repos/{owner}/{repo}/pulls)")
    raise Denied("not a GitHub gateway host")


def auth_header(access: GitHubAccess, host: str) -> str:
    if host.lower() == GIT_HOST:
        raw = base64.b64encode(f"x-access-token:{access.token}".encode()).decode()
        return f"Basic {raw}"
    return f"Bearer {access.token}"


async def read_body(reader: asyncio.StreamReader, headers: list[tuple[str, str]]) -> bytes:
    """Corpo da requisição do cliente: Content-Length ou chunked (o git manda chunked em pushes grandes)."""
    lower = {k.lower(): v for k, v in headers}
    if "chunked" in lower.get("transfer-encoding", "").lower():
        out = bytearray()
        while True:
            line = await reader.readline()
            size = int(line.split(b";", 1)[0].strip() or b"0", 16)
            if size == 0:
                await reader.readline()
                break
            out += await reader.readexactly(size)
            await reader.readexactly(2)
            if len(out) > MAX_BODY:
                raise Denied("request body too large")
        return bytes(out)
    length = int(lower.get("content-length", "0") or 0)
    if length > MAX_BODY:
        raise Denied("request body too large")
    return await reader.readexactly(length) if length else b""


HOP = {"connection", "proxy-connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade", "proxy-authorization",
       "authorization", "host", "content-length"}


async def forward(access: GitHubAccess, host: str, method: str, path_query: str, headers: list[tuple[str, str]], body: bytes,
                  connect=None) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
    """Abre TLS para o GitHub de verdade e manda a requisição com a autenticação. Devolve o leitor da resposta."""
    target = UPSTREAM[host.lower()]
    if connect is None:
        ctx = ssl.create_default_context()
        reader, writer = await asyncio.wait_for(asyncio.open_connection(target, 443, ssl=ctx, server_hostname=target), 20)
    else:
        reader, writer = await connect(target)
    out = [(k, v) for k, v in headers if k.lower() not in HOP]
    out += [("Host", target), ("Authorization", auth_header(access, host)), ("Content-Length", str(len(body))),
            ("Connection", "close")]
    if host.lower() == API_HOST and not any(k.lower() == "user-agent" for k, _ in out):
        out.append(("User-Agent", "racky-computer"))
    head = f"{method} {path_query} HTTP/1.1\r\n" + "".join(f"{k}: {v}\r\n" for k, v in out) + "\r\n"
    writer.write(head.encode("latin-1") + body)
    await writer.drain()
    return reader, writer


def _pkt(data: bytes) -> bytes:
    return f"{len(data) + 4:04x}".encode() + data


def receive_pack_caps(body: bytes) -> set[str]:
    """Capacidades pedidas pelo cliente: depois do NUL da primeira linha de comando (um clone raso manda `shallow <sha>` antes)."""
    i = 0
    while i + 4 <= len(body):
        try:
            size = int(body[i:i + 4], 16)
        except ValueError:
            return set()
        if size < 4 or i + size > len(body):
            return set()
        line = body[i + 4:i + size]
        if b"\0" in line:
            return set(line.split(b"\0", 1)[1].decode("latin-1").split())
        i += size
    return set()


def push_rejection(body: bytes, reason: str) -> bytes:
    """Resposta 200 de `git-receive-pack` com `ng <ref> <motivo>` para cada ref: o git mostra o motivo e sai com erro."""
    reason = reason.replace("\n", " ")
    status = _pkt(b"unpack ok\n") + b"".join(_pkt(f"ng {ref} {reason}\n".encode()) for _, _, ref in pkt_ref_updates(body)) + b"0000"
    caps = receive_pack_caps(body)
    if "side-band-64k" in caps or "side-band" in caps:
        limit = 65515 if "side-band-64k" in caps else 995
        payload = b"".join(_pkt(b"\x01" + status[i:i + limit]) for i in range(0, len(status), limit)) + b"0000"
    else:
        payload = status
    return (b"HTTP/1.1 200 OK\r\nContent-Type: application/x-git-receive-pack-result\r\nX-Racky-Blocked: github_policy\r\n"
            + f"Content-Length: {len(payload)}\r\nConnection: close\r\n\r\n".encode() + payload)


def denial_response(reason: str) -> bytes:
    payload = json.dumps({"error": "blocked_by_racky", "reason": reason}).encode()
    return (b"HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nX-Racky-Blocked: github_policy\r\n"
            + f"Content-Length: {len(payload)}\r\nConnection: close\r\n\r\n".encode() + payload)
