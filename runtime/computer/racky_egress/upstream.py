"""Encadeamento para o proxy upstream configurado (07 CS-140): HTTP/HTTPS com Proxy-Authorization ou SOCKS5 com usuário e senha."""
from __future__ import annotations

import asyncio
import base64
import ipaddress
import ssl
from typing import Optional

from .config import Upstream

CONNECT_TIMEOUT = 20.0


class UpstreamError(Exception):
    """Falha do proxy upstream (407, 403, handshake...). `status` é o status HTTP do upstream, quando existe."""

    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


def basic_auth(user: str, password: str | None) -> str:
    return "Basic " + base64.b64encode(f"{user}:{password or ''}".encode()).decode()


def proxy_auth_header(up: Upstream) -> Optional[str]:
    user = up.effective_username()
    return basic_auth(user, up.password) if user is not None else None


def _ssl_context(up: Upstream) -> ssl.SSLContext:
    ctx = ssl.create_default_context(cafile=up.ca_file) if up.ca_file else ssl.create_default_context()
    return ctx


async def connect_to_upstream(up: Upstream) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
    kwargs = {}
    if up.scheme == "https":
        kwargs["ssl"] = _ssl_context(up)
        kwargs["server_hostname"] = up.host
    try:
        return await asyncio.wait_for(asyncio.open_connection(up.effective_host(), up.port, **kwargs), CONNECT_TIMEOUT)
    except (OSError, asyncio.TimeoutError, ssl.SSLError) as exc:
        raise UpstreamError(f"upstream unreachable: {type(exc).__name__}: {exc}") from exc


async def _read_head(reader: asyncio.StreamReader, limit: int = 65536) -> bytes:
    try:
        return await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), CONNECT_TIMEOUT)
    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError) as exc:
        raise UpstreamError(f"upstream closed during handshake: {type(exc).__name__}") from exc


async def open_tunnel(up: Upstream, host: str, port: int) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
    """Túnel TCP até `host:port` através do upstream (nome, não IP: o upstream resolve)."""
    reader, writer = await connect_to_upstream(up)
    try:
        if up.scheme == "socks5":
            await _socks5_connect(reader, writer, up, host, port)
        else:
            target = f"[{host}]:{port}" if ":" in host else f"{host}:{port}"
            lines = [f"CONNECT {target} HTTP/1.1", f"Host: {target}"]
            auth = proxy_auth_header(up)
            if auth:
                lines.append(f"Proxy-Authorization: {auth}")
            if up.geo_country and up.geo_mode == "header":
                lines.append(f"{up.geo_header}: {up.geo_country}")
            writer.write(("\r\n".join(lines) + "\r\n\r\n").encode())
            await writer.drain()
            head = await _read_head(reader)
            status = int(head.split(b"\r\n", 1)[0].split()[1])
            if status != 200:
                raise UpstreamError(f"upstream CONNECT refused with {status}", status)
    except BaseException:
        writer.close()
        raise
    return reader, writer


async def _socks5_connect(reader, writer, up: Upstream, host: str, port: int) -> None:
    methods = [0x00] if up.effective_username() is None else [0x02, 0x00]
    writer.write(bytes([5, len(methods), *methods]))
    await writer.drain()
    try:
        ver, method = await asyncio.wait_for(reader.readexactly(2), CONNECT_TIMEOUT)
    except (asyncio.IncompleteReadError, asyncio.TimeoutError) as exc:
        raise UpstreamError("socks5 handshake failed") from exc
    if ver != 5 or method == 0xFF:
        raise UpstreamError("socks5: no acceptable authentication method", 407)
    if method == 0x02:
        user = (up.effective_username() or "").encode()
        pw = (up.password or "").encode()
        if len(user) > 255 or len(pw) > 255:
            raise UpstreamError("socks5: credentials too long")
        writer.write(bytes([1, len(user)]) + user + bytes([len(pw)]) + pw)
        await writer.drain()
        try:
            _v, status = await asyncio.wait_for(reader.readexactly(2), CONNECT_TIMEOUT)
        except (asyncio.IncompleteReadError, asyncio.TimeoutError) as exc:
            raise UpstreamError("socks5 auth failed") from exc
        if status != 0:
            raise UpstreamError("socks5: authentication rejected", 407)
    try:
        ip = ipaddress.ip_address(host)
        addr = bytes([1]) + ip.packed if ip.version == 4 else bytes([4]) + ip.packed
    except ValueError:
        encoded = host.encode("idna")
        addr = bytes([3, len(encoded)]) + encoded
    writer.write(bytes([5, 1, 0]) + addr + port.to_bytes(2, "big"))
    await writer.drain()
    try:
        ver, rep, _rsv, atyp = await asyncio.wait_for(reader.readexactly(4), CONNECT_TIMEOUT)
        skip = {1: 4, 4: 16}.get(atyp)
        if atyp == 3:
            skip = (await reader.readexactly(1))[0]
        await reader.readexactly((skip or 0) + 2)
    except (asyncio.IncompleteReadError, asyncio.TimeoutError) as exc:
        raise UpstreamError("socks5 connect failed") from exc
    if rep != 0:
        names = {1: "general failure", 2: "not allowed", 3: "network unreachable", 4: "host unreachable", 5: "connection refused",
                 6: "ttl expired", 7: "command not supported", 8: "address type not supported"}
        raise UpstreamError(f"socks5 connect refused: {names.get(rep, rep)}", 403 if rep == 2 else None)
