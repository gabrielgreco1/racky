"""Proxy HTTP/CONNECT do egress (07 CS-140..143, CS-147, CS-162, CS-163).

- `CONNECT`: túnel TCP sem descriptografar TLS (os fingerprints chegam intactos). Um registro por túnel, ao fechar.
- HTTP simples (URI absoluta): o egress lê cabeçalhos, guarda corpos limitados (redigidos) e repassa. Uma requisição por
  conexão (`Connection: close`), o que mantém o parsing do corpo trivial e o registro fiel.
- Antes de tudo: lista de ruído (403), allowlist, filtro SSRF (resolve o DNS aqui, confere todos os IPs, fixa um).
- Com `upstream`, encadeia (HTTP/HTTPS CONNECT ou SOCKS5). Erros do upstream voltam como 502 `proxy_error` com o status dele.
"""
from __future__ import annotations

import asyncio
import ssl
import json
import os
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from . import github_gateway as gh
from . import reqlog as rl
from .config import Config
from .ssrf import Blocked, SSRFPolicy, noise_host, split_host_port, strip_userinfo
from .upstream import UpstreamError, connect_to_upstream, open_tunnel, proxy_auth_header

IDLE_TIMEOUT = 300.0
HOP_BY_HOP = {"proxy-authorization", "proxy-connection", "connection", "keep-alive", "te", "trailer", "upgrade"}


@dataclass
class Usage:
    requests: int = 0
    tunnels: int = 0
    bytes_up: int = 0
    bytes_down: int = 0
    blocked: int = 0
    errors: int = 0
    renders: int = 0


@dataclass
class Tunnel:
    via: str
    host: str
    writers: list = field(default_factory=list)
    closed_by: str | None = None


def parse_head(head: bytes) -> tuple[str, list[tuple[str, str]]]:
    text = head.decode("latin-1")
    lines = text.split("\r\n")
    headers: list[tuple[str, str]] = []
    for line in lines[1:]:
        if not line:
            break
        name, sep, value = line.partition(":")
        if sep:
            headers.append((name.strip(), value.strip()))
    return lines[0], headers


def header_value(headers: list[tuple[str, str]], name: str) -> str | None:
    for key, value in headers:
        if key.lower() == name:
            return value
    return None


class EgressProxy:
    # Testes trocam a conexão com o GitHub de verdade por um servidor local (assinatura: async (host) -> (reader, writer)).
    github_connect = None

    def __init__(self, config: Config, log_dir: Path | None = None, clock=time.time):
        self.clock = clock
        self.log_dir = Path(log_dir or config.logs_dir)
        self.usage: dict[str, Usage] = {}
        self.open_tunnels: dict[int, Tunnel] = {}
        self._next = 0
        self.dirty = False
        self.apply_config(config)

    # ----- configuração e troca de proxy (CS-141) ---------------------------------------------------------------------
    def apply_config(self, config: Config) -> int:
        """Aplica uma configuração nova. Fecha TODOS os túneis abertos pelo caminho anterior e devolve quantos."""
        closed = 0
        if hasattr(self, "config"):
            closed = self.close_all("proxy_switch")
        self.config = config
        secrets = list(config.upstream.secrets()) if config.upstream else []
        if config.render:
            secrets.append(config.render.api_key)
        if config.github:
            secrets.append(config.github.token)
        redactor = rl.Redactor(secrets, config.extra_redact_headers)
        if hasattr(self, "reqlog"):
            self.reqlog.redactor = redactor
            self.reqlog.body_quota = config.body_quota_bytes
        else:
            self.reqlog = rl.ReqLog(self.log_dir, redactor, config.body_quota_bytes, clock=self.clock)
        self.policy = SSRFPolicy(allow_cidrs=config.allow_cidrs, allow_hosts=config.allow_hosts)
        self.usage.setdefault(config.via, Usage())
        self.dirty = True
        return closed

    def close_all(self, reason: str) -> int:
        count = 0
        for tunnel in list(self.open_tunnels.values()):
            tunnel.closed_by = reason
            for writer in tunnel.writers:
                try:
                    writer.transport.abort()
                except Exception:
                    pass
            count += 1
        return count

    def usage_snapshot(self) -> dict[str, Any]:
        total = Usage()
        for u in self.usage.values():
            for name in vars(total):
                setattr(total, name, getattr(total, name) + getattr(u, name))
        return {"via": self.config.via, "by_via": {k: vars(v) for k, v in self.usage.items()}, "total": vars(total),
                "open_tunnels": len(self.open_tunnels), "reqlog_records": self.reqlog.count}

    def flush_usage(self) -> None:
        if not self.dirty:
            return
        self.dirty = False
        path = self.log_dir / "usage.json"
        tmp = self.log_dir / f".usage.{os.getpid()}.tmp"
        tmp.write_text(json.dumps(self.usage_snapshot(), sort_keys=True))
        os.replace(tmp, path)

    def _u(self) -> Usage:
        return self.usage.setdefault(self.config.via, Usage())

    def usage_for_via(self) -> Usage:
        return self._u()

    # ----- registros enviados por quem tem o token (app e runtime) -------------------------------------------------------
    INGEST_SOURCES = {"browser", "work:python", "work:curl", "work:other", "render-api", "render-api:capture"}
    INGEST_FIELDS = ("id", "source", "kind", "method", "url", "host", "type", "status", "content_type", "request_headers",
                     "response_headers", "duration_ms", "error", "error_detail", "ttfb_ms", "parent", "final_url", "impersonate",
                     "blocked", "blocked_reason", "captures")

    def ingest(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Grava um registro `observed` entregue pelo app (http_request, render) ou pelo runtime (browser). O chamador já
        passou pela autenticação por token: o `work` nunca o tem. O egress redige e encadeia como em qualquer outro registro."""
        rec_in = payload.get("record")
        if not isinstance(rec_in, dict):
            raise ValueError("record must be an object")
        source = rec_in.get("source")
        if source not in self.INGEST_SOURCES:
            raise ValueError(f"source must be one of {sorted(self.INGEST_SOURCES)}")
        red = self.reqlog.redactor
        rid = rec_in.get("id") or rl.new_ulid(int(self.clock() * 1000))
        if not (isinstance(rid, str) and len(rid) == 26 and all(c in rl._ULID_ALPHABET for c in rid)):
            raise ValueError("id must be a ULID")
        record: dict[str, Any] = {k: rec_in[k] for k in self.INGEST_FIELDS if k in rec_in}
        record.update(id=rid, trust="observed", via=self.config.via)
        if isinstance(record.get("url"), str):
            record["url"] = red.url(record["url"])
        if isinstance(record.get("final_url"), str):
            record["final_url"] = red.url(record["final_url"])
        for key in ("request_headers", "response_headers"):
            if key in record:
                record[key] = red.headers([(str(k), str(v)) for k, v in record[key]])
        for key in ("error", "error_detail", "blocked_reason"):
            if isinstance(record.get(key), str):
                record[key] = red.text(record[key])
        for kind, limit in (("request", rl.REQUEST_BODY_LIMIT), ("response", rl.RESPONSE_BODY_LIMIT)):
            body = payload.get(f"{kind}_body")
            if isinstance(body, str) and body:
                record.update(self.reqlog.write_body(rid, kind, body.encode("utf-8"), limit))
        written = self.reqlog.append(record)
        self.dirty = True
        return written

    # ----- servidor -----------------------------------------------------------------------------------------------------
    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        peer = (writer.get_extra_info("peername") or ("?", 0))[0]
        try:
            try:
                head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 30)
            except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError, ConnectionError):
                return
            request_line, headers = parse_head(head)
            parts = request_line.split(" ")
            if len(parts) != 3:
                await self._reply(writer, 400, "bad request")
                return
            method, target, version = parts
            if method.upper() == "CONNECT":
                await self._connect(reader, writer, target, headers, peer)
            elif target.lower().startswith("http://"):
                await self._plain(reader, writer, method, target, version, headers, head, peer)
            else:
                await self._reply(writer, 400, "this is a forward proxy: use an absolute http:// URI or CONNECT")
        except (ConnectionError, asyncio.CancelledError):
            pass
        finally:
            try:
                writer.close()
            except Exception:
                pass

    async def _reply(self, writer, status: int, message: str, extra: dict[str, str] | None = None) -> None:
        reasons = {400: "Bad Request", 403: "Forbidden", 502: "Bad Gateway", 504: "Gateway Timeout"}
        body = (message + "\n").encode()
        hdr = [f"HTTP/1.1 {status} {reasons.get(status, 'Error')}", f"Content-Length: {len(body)}", "Connection: close",
               "Content-Type: text/plain; charset=utf-8"]
        for k, v in (extra or {}).items():
            hdr.append(f"{k}: {v}")
        try:
            writer.write(("\r\n".join(hdr) + "\r\n\r\n").encode() + body)
            await writer.drain()
        except ConnectionError:
            pass

    def _block(self, writer_reply: bool, record: dict[str, Any], reason: str, detail: str, scope: str) -> None:
        u = self._u()
        u.blocked += 1
        record.update(blocked=True, blocked_reason=reason, blocked_detail=self.reqlog.redactor.text(detail), error=f"blocked: {reason}")
        self.reqlog.append(record)
        self.dirty = True

    async def _check_destination(self, host: str, port: int) -> str:
        """Devolve o IP fixado. Lança `Blocked` com o motivo. O DNS bloqueia a thread: roda fora do loop."""
        return (await self._check_destinations(host, port))[0]

    async def _check_destinations(self, host: str, port: int) -> list[str]:
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(None, self.policy.check_all, host, port)

    @staticmethod
    async def _open_direct(ips: list[str], port: int):
        """Conexão direta tentando cada IP aprovado em ordem (IPv4 primeiro); com mais de um candidato, 8 s por tentativa."""
        last: BaseException = OSError("no address")
        per_try = 20 if len(ips) == 1 else 8
        for ip in ips:
            try:
                return await asyncio.wait_for(asyncio.open_connection(ip, port), per_try)
            except (OSError, asyncio.TimeoutError) as exc:
                last = exc
        raise last

    # ----- CONNECT ------------------------------------------------------------------------------------------------------
    async def _connect(self, cr, cw, target: str, headers, peer: str) -> None:
        start = self.clock()
        via = self.config.via
        base: dict[str, Any] = {"source": "egress", "trust": "observed", "via": via, "kind": "tunnel", "method": "CONNECT",
                                "client": peer}
        try:
            host, port = split_host_port(strip_userinfo(target), 443)
        except Blocked as exc:
            base.update(url=self.reqlog.redactor.url(target))
            self._block(True, base, exc.reason, exc.detail, "connect")
            await self._reply(cw, 400, f"bad CONNECT target ({exc.reason})")
            return
        base.update(host=host, port=port, url=f"{host}:{port}")
        if noise_host(host, self.config.noise):
            self._block(True, base, "noise", host, "connect")
            await self._reply(cw, 403, "blocked by racky: background/analytics host", {"X-Racky-Blocked": "noise"})
            return
        try:
            ips = await self._check_destinations(host, port)
            ip = ips[0]
        except Blocked as exc:
            self._block(True, base, exc.reason, exc.detail, "connect")
            await self._reply(cw, 403, f"blocked by racky: {exc.reason}", {"X-Racky-Blocked": exc.reason})
            return
        base["ip"] = ip
        up = self.config.upstream
        try:
            t0 = self.clock()
            if up is None:
                ur, uw = await self._open_direct(ips, port)
            else:
                ur, uw = await open_tunnel(up, host, port)
            base["connect_ms"] = round((self.clock() - t0) * 1000)
        except (UpstreamError, OSError, asyncio.TimeoutError) as exc:
            self._upstream_failure(base, exc, start)
            status = getattr(exc, "status", None)
            await self._reply(cw, 502, f"proxy_error: {exc}", {"X-Racky-Proxy-Error": str(status or "connect")})
            return
        cw.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        await cw.drain()
        u = self._u()
        u.tunnels += 1
        u.requests += 1
        self.dirty = True
        key = self._next = self._next + 1
        tunnel = Tunnel(via=via, host=host, writers=[cw, uw])
        self.open_tunnels[key] = tunnel
        counts = [0, 0]
        try:
            await self._pipe_both(cr, cw, ur, uw, counts)
        finally:
            self.open_tunnels.pop(key, None)
            for w in (cw, uw):
                try:
                    w.close()
                except Exception:
                    pass
            u.bytes_up += counts[0]
            u.bytes_down += counts[1]
            base.update(bytes_up=counts[0], bytes_down=counts[1], duration_ms=round((self.clock() - start) * 1000))
            if tunnel.closed_by:
                base["closed_by"] = tunnel.closed_by
            self.reqlog.append(base)
            self.dirty = True

    async def _pipe_both(self, cr, cw, ur, uw, counts: list[int], cap_up: bytearray | None = None) -> None:
        async def pump(src, dst, idx: int, capture: bytearray | None) -> None:
            try:
                while True:
                    data = await asyncio.wait_for(src.read(65536), IDLE_TIMEOUT)
                    if not data:
                        break
                    counts[idx] += len(data)
                    if capture is not None and len(capture) < rl.REQUEST_BODY_LIMIT + 1:
                        capture.extend(data[: rl.REQUEST_BODY_LIMIT + 1 - len(capture)])
                    dst.write(data)
                    await dst.drain()
            except (ConnectionError, asyncio.TimeoutError, OSError):
                pass

        up_task = asyncio.ensure_future(pump(cr, uw, 0, cap_up))
        down_task = asyncio.ensure_future(pump(ur, cw, 1, None))
        done, pending = await asyncio.wait({up_task, down_task}, return_when=asyncio.FIRST_COMPLETED)
        # Se o cliente fechou o envio mas o upstream ainda responde, deixa o lado da resposta terminar.
        if up_task in done and not down_task.done():
            try:
                await asyncio.wait_for(down_task, IDLE_TIMEOUT)
            except asyncio.TimeoutError:
                pass
        for task in (up_task, down_task):
            if not task.done():
                task.cancel()
        await asyncio.gather(up_task, down_task, return_exceptions=True)

    def _upstream_failure(self, record: dict[str, Any], exc: BaseException, start: float) -> None:
        u = self._u()
        u.errors += 1
        status = getattr(exc, "status", None)
        record.update(error="proxy_error" if self.config.upstream else "connect_error",
                      error_detail=self.reqlog.redactor.text(str(exc)), duration_ms=round((self.clock() - start) * 1000))
        if status is not None:
            record["upstream_status"] = status
        self.reqlog.append(record)
        self.dirty = True

    # ----- HTTP simples -------------------------------------------------------------------------------------------------
    async def _plain(self, cr, cw, method: str, target: str, version: str, headers, head: bytes, peer: str) -> None:
        start = self.clock()
        red = self.reqlog.redactor
        via = self.config.via
        base: dict[str, Any] = {"source": "egress", "trust": "observed", "via": via, "kind": "http", "method": method,
                                "url": red.url(target), "client": peer, "request_headers": red.headers(headers)}
        parts = urlsplit(target)
        try:
            host, port = split_host_port(strip_userinfo(parts.netloc), 80)
        except Blocked as exc:
            self._block(True, base, exc.reason, exc.detail, "http")
            await self._reply(cw, 400, f"bad request target ({exc.reason})")
            return
        base.update(host=host, port=port)
        if gh.handles(host):
            await self._github(cr, cw, method, parts, headers, base, start)
            return
        if noise_host(host, self.config.noise):
            self._block(True, base, "noise", host, "http")
            await self._reply(cw, 403, "blocked by racky: background/analytics host", {"X-Racky-Blocked": "noise"})
            return
        try:
            ips = await self._check_destinations(host, port)
            ip = ips[0]
        except Blocked as exc:
            self._block(True, base, exc.reason, exc.detail, "http")
            await self._reply(cw, 403, f"blocked by racky: {exc.reason}", {"X-Racky-Blocked": exc.reason})
            return
        base["ip"] = ip
        path = parts.path or "/"
        if parts.query:
            path += "?" + parts.query
        up = self.config.upstream
        forward = [(k, v) for k, v in headers if k.lower() not in HOP_BY_HOP]
        try:
            t0 = self.clock()
            if up is None or up.scheme == "socks5":
                if up is None:
                    ur, uw = await self._open_direct(ips, port)
                else:
                    ur, uw = await open_tunnel(up, host, port)
                request_target = path
            else:
                ur, uw = await connect_to_upstream(up)
                request_target = target
                auth = proxy_auth_header(up)
                if auth:
                    forward.append(("Proxy-Authorization", auth))
                if up.geo_country and up.geo_mode == "header":
                    forward.append((up.geo_header, up.geo_country))
            base["connect_ms"] = round((self.clock() - t0) * 1000)
        except (UpstreamError, OSError, asyncio.TimeoutError) as exc:
            self._upstream_failure(base, exc, start)
            await self._reply(cw, 502, f"proxy_error: {exc}", {"X-Racky-Proxy-Error": str(getattr(exc, 'status', None) or 'connect')})
            return
        forward.append(("Connection", "close"))
        raw_head = f"{method} {request_target} HTTP/1.1\r\n" + "".join(f"{k}: {v}\r\n" for k, v in forward) + "\r\n"
        uw.write(raw_head.encode("latin-1"))
        await uw.drain()
        u = self._u()
        u.requests += 1
        self.dirty = True
        key = self._next = self._next + 1
        tunnel = Tunnel(via=via, host=host, writers=[cw, uw])
        self.open_tunnels[key] = tunnel
        counts = [0, 0]
        req_capture = bytearray()
        resp_capture = bytearray()
        status_holder: dict[str, Any] = {}
        try:
            await self._pipe_http(cr, cw, ur, uw, counts, req_capture, resp_capture, status_holder)
        finally:
            self.open_tunnels.pop(key, None)
            for w in (cw, uw):
                try:
                    w.close()
                except Exception:
                    pass
            u.bytes_up += counts[0]
            u.bytes_down += counts[1]
            rec = dict(base)
            rec_id = rl.new_ulid(int(self.clock() * 1000))
            rec["id"] = rec_id
            rec.update(bytes_up=counts[0], bytes_down=counts[1], duration_ms=round((self.clock() - start) * 1000))
            if "status" in status_holder:
                rec["status"] = status_holder["status"]
                rec["response_headers"] = red.headers(status_holder["headers"])
                ctype = header_value(status_holder["headers"], "content-type")
                rec["content_type"] = ctype
                rec["ttfb_ms"] = status_holder["ttfb_ms"]
                # 407 nunca vem de um site: é o upstream recusando as credenciais. 401/403 podem ser do site e passam como estão.
                if self.config.upstream and (status_holder["status"] == 407 or (status_holder["status"] == 403 and header_value(
                        status_holder["headers"], "proxy-authenticate") is not None)):
                    rec["error"] = "proxy_error"
                    rec["upstream_status"] = status_holder["status"]
                    u.errors += 1
                if resp_capture and (rl.is_textual(ctype) or (ctype is None and rl.sniff_text(bytes(resp_capture)))):
                    rec.update(self.reqlog.write_body(rec_id, "response", bytes(resp_capture), rl.RESPONSE_BODY_LIMIT))
            elif tunnel.closed_by:
                rec["error"] = tunnel.closed_by
            else:
                rec["error"] = "no_response"
            req_ctype = header_value(headers, "content-type")
            if req_capture and (rl.is_textual(req_ctype) or (req_ctype is None and rl.sniff_text(bytes(req_capture)))):
                rec.update(self.reqlog.write_body(rec_id, "request", bytes(req_capture), rl.REQUEST_BODY_LIMIT))
            if tunnel.closed_by:
                rec["closed_by"] = tunnel.closed_by
            self.reqlog.append(rec)
            self.dirty = True

    async def _github(self, cr, cw, method: str, parts, headers, base: dict[str, Any], start: float) -> None:
        """Gateway do GitHub: valida pela política, autentica e repassa ao GitHub de verdade (github_gateway.py)."""
        host = (parts.hostname or "").lower()
        path = parts.path or "/"
        path_query = path + ("?" + parts.query if parts.query else "")
        base.update(kind="github", url=f"http://{host}{path}")
        access = self.config.github
        try:
            if access is None:
                raise gh.Denied("GitHub access is off for this computer (the session did not allow it)")
            body = await gh.read_body(cr, headers)
            gh.check(access, host, method, path, parts.query, body)
        except gh.Denied as exc:
            self._block(True, base, "github_policy", exc.reason, "http")
            cw.write(gh.push_rejection(exc.body, exc.reason) if isinstance(exc, gh.PushRefused) else gh.denial_response(exc.reason))
            await cw.drain()
            cw.close()
            return
        u = self._u()
        u.requests += 1
        u.bytes_up += len(body)
        try:
            ur, uw = await gh.forward(access, host, method, path_query, headers, body, connect=self.github_connect)
        except (OSError, asyncio.TimeoutError, ssl.SSLError) as exc:
            self._upstream_failure(base, exc, start)
            await self._reply(cw, 502, f"github_error: {exc}", {"X-Racky-Proxy-Error": "github"})
            return
        status = None
        down = 0
        try:
            first = True
            while True:
                data = await asyncio.wait_for(ur.read(65536), IDLE_TIMEOUT)
                if not data:
                    break
                if first:
                    first = False
                    try:
                        status = int(data.split(b" ", 2)[1])
                    except (IndexError, ValueError):
                        status = None
                down += len(data)
                cw.write(data)
                await cw.drain()
        except (ConnectionError, asyncio.TimeoutError, OSError):
            pass
        finally:
            for w in (cw, uw):
                try:
                    w.close()
                except Exception:
                    pass
            u.bytes_down += down
            rec = dict(base)
            rec["id"] = rl.new_ulid(int(self.clock() * 1000))
            rec.update(status=status, bytes_up=len(body), bytes_down=down, duration_ms=round((self.clock() - start) * 1000))
            self.reqlog.append(rec)
            self.dirty = True

    async def _pipe_http(self, cr, cw, ur, uw, counts, req_capture: bytearray, resp_capture: bytearray, status_holder) -> None:
        async def up_pump() -> None:
            try:
                while True:
                    data = await asyncio.wait_for(cr.read(65536), IDLE_TIMEOUT)
                    if not data:
                        break
                    counts[0] += len(data)
                    if len(req_capture) <= rl.REQUEST_BODY_LIMIT:
                        req_capture.extend(data[: rl.REQUEST_BODY_LIMIT + 1 - len(req_capture)])
                    uw.write(data)
                    await uw.drain()
            except (ConnectionError, asyncio.TimeoutError, OSError):
                pass

        async def down_pump() -> None:
            t0 = self.clock()
            try:
                try:
                    resp_head = await asyncio.wait_for(ur.readuntil(b"\r\n\r\n"), IDLE_TIMEOUT)
                except (asyncio.IncompleteReadError, asyncio.LimitOverrunError):
                    return
                status_line, resp_headers = parse_head(resp_head)
                try:
                    status_holder["status"] = int(status_line.split(" ", 2)[1])
                except (IndexError, ValueError):
                    status_holder["status"] = 0
                status_holder["headers"] = resp_headers
                status_holder["ttfb_ms"] = round((self.clock() - t0) * 1000)
                cw.write(resp_head)
                counts[1] += len(resp_head)
                await cw.drain()
                while True:
                    data = await asyncio.wait_for(ur.read(65536), IDLE_TIMEOUT)
                    if not data:
                        break
                    counts[1] += len(data)
                    if len(resp_capture) <= rl.RESPONSE_BODY_LIMIT:
                        resp_capture.extend(data[: rl.RESPONSE_BODY_LIMIT + 1 - len(resp_capture)])
                    cw.write(data)
                    await cw.drain()
            except (ConnectionError, asyncio.TimeoutError, OSError):
                pass

        up_task = asyncio.ensure_future(up_pump())
        down_task = asyncio.ensure_future(down_pump())
        await down_task  # a resposta termina quando o upstream fecha (Connection: close)
        up_task.cancel()
        await asyncio.gather(up_task, return_exceptions=True)
