"""Admin API do egress (publicada só em 127.0.0.1 pelo app; 07 CS-111, CS-603, 08 AR-107).

Autenticada pelo token do computador (arquivo montado, nunca env): `Authorization: Bearer <token>`. Só `/v1/health` é aberto
e não devolve nada além de "ok". Quem tem o token é o app e o `runtime`; o `work` nunca o recebe.

Rotas autenticadas (T3-03 acrescenta as três últimas):
- leitura: `/v1/usage`, `/v1/proxy`, `/v1/reqlog`, `/v1/reqlog/<id>/body`, `POST /v1/proxy/reload`;
- `POST /v1/reqlog/ingest`: registro `observed` entregue pelo app (http_request, render) ou pelo runtime (browser);
- `POST /v1/render`: render pelo modo API do proxy selecionado (`not_supported` se ele não tem);
- `/runtime/v1/<op>`: reverse proxy para o servidor de controle do runtime (o app só fala com o egress);
- `GET /vnc?ticket=...` (WebSocket): túnel para a ponte VNC do runtime (T3-05, CS-401). Sem `Authorization` (o WebView não
  consegue mandar cabeçalho): o ticket de uso único, emitido por `/runtime/v1/vnc_ticket` com o token, vale 60 s e é conferido
  pelo runtime. Qualquer outra coisa nesse caminho é recusada aqui.
- `GET /v1/tcp?port=<n>` (com o token e `Upgrade: racky-tcp`): túnel de bytes para `127.0.0.1:<n>` dentro do computador, para o app
  ler um serviço que o agente subiu (o Postgres do smoke aparece no Data). Só loopback, só portas >= 1024 e nunca as de controle.
"""
from __future__ import annotations

import asyncio
import base64
import hmac
import json
from urllib.parse import parse_qs, urlsplit

from . import render as rd
from .config import load_config
from .proxy import EgressProxy, header_value, parse_head
from .ssrf import Blocked

RUNTIME_ADDRESS = ("127.0.0.1", 8765)  # P24: mesmo container
MAX_BODY = 48 * 1024 * 1024
# Portas do próprio computador que o túnel nunca abre: proxy, admin, ponte vsock, runtime, VNC.
CONTROL_PORTS = frozenset({3128, 8790, 8791, 8765, 5900})


def tunnel_port(query) -> int | None:
    """Porta pedida para `/v1/tcp`, ou None se não vale (fora de 1024-65535 ou de controle)."""
    try:
        port = int((query.get("port") or [""])[0])
    except ValueError:
        return None
    return port if 1024 <= port <= 65535 and port not in CONTROL_PORTS else None


class AdminServer:
    def __init__(self, proxy: EgressProxy, token: str | None, config_loader=lambda: load_config(required=True),
                 runtime_address: tuple[str, int] = RUNTIME_ADDRESS):
        self.proxy = proxy
        self.token = token
        self.config_loader = config_loader
        self.runtime_address = runtime_address

    def _authorized(self, headers) -> bool:
        if not self.token:
            return False  # sem token configurado, nada além do health
        supplied = header_value(headers, "authorization") or ""
        if not supplied.lower().startswith("bearer "):
            return False
        return hmac.compare_digest(supplied[7:].strip().encode(), self.token.encode())

    async def handle(self, reader, writer) -> None:
        try:
            try:
                head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 10)
            except Exception:
                return
            request_line, headers = parse_head(head)
            method, _, rest = request_line.partition(" ")
            target = rest.rpartition(" ")[0]
            url = urlsplit(target)
            query = parse_qs(url.query)
            if method == "GET" and url.path == "/vnc":
                await self.tunnel_vnc(reader, writer, target, headers)
                return
            if method == "GET" and url.path == "/v1/tcp":
                await self.tunnel_tcp(reader, writer, query, headers)
                return
            request_body = b""
            bad_body = False
            try:
                length = int(header_value(headers, "content-length") or 0)
                if length > MAX_BODY:
                    raise ValueError("body too large")
                if length > 0:
                    request_body = await asyncio.wait_for(reader.readexactly(length), 60)
            except Exception:
                bad_body = True
            try:
                if bad_body:
                    status, ctype, body = 400, "application/json", {"error": "bad_request"}
                else:
                    status, ctype, body = await self.route(method, url.path, query, headers, request_body)
            except Exception as exc:  # config inválida etc.: o estado anterior fica; nunca devolve valores de segredo
                status, ctype, body = 500, "application/json", {"error": "internal", "type": type(exc).__name__}
            data = body if isinstance(body, bytes) else json.dumps(body, sort_keys=True).encode()
            writer.write(f"HTTP/1.1 {status} X\r\nContent-Type: {ctype}\r\nContent-Length: {len(data)}\r\nConnection: close\r\n\r\n".encode() + data)
            await writer.drain()
        except ConnectionError:
            pass
        finally:
            try:
                writer.close()
            except Exception:
                pass

    async def route(self, method: str, path: str, query, headers, request_body: bytes = b""):
        if method == "GET" and path == "/v1/health":
            return 200, "application/json", {"ok": True}
        if not self._authorized(headers):
            return 401, "application/json", {"error": "unauthorized"}
        p = self.proxy
        if method == "GET" and path == "/v1/usage":
            return 200, "application/json", p.usage_snapshot()
        if method == "GET" and path == "/v1/proxy":
            up = p.config.upstream
            return 200, "application/json", {
                "via": p.config.via, "scheme": up.scheme if up else None, "host": up.host if up else None,
                "port": up.port if up else None, "geo": up.geo_country if up else None,
                "allow_cidrs": p.config.allow_cidrs, "allow_hosts": p.config.allow_hosts,
                "render_supported": p.config.render is not None,
            }
        if method == "GET" and path == "/v1/reqlog":
            since = (query.get("since") or [None])[0]
            limit = int((query.get("limit") or ["200"])[0])
            return 200, "application/json", {"records": p.reqlog.read(since, max(1, min(limit, 1000)))}
        if method == "GET" and path.startswith("/v1/reqlog/") and path.endswith("/body"):
            rid = path[len("/v1/reqlog/"):-len("/body")]
            kind = (query.get("kind") or ["response"])[0]
            rec = next((r for r in p.reqlog.read(None, 100000) if r["id"] == rid), None)
            rel = rec.get(f"{kind}_body_file") if rec else None
            file = p.reqlog.body_path(rel) if rel else None
            if file is None:
                return 404, "application/json", {"error": "not_found"}
            return 200, "text/plain; charset=utf-8", file.read_bytes()
        if method == "POST" and path == "/v1/reqlog/ingest":
            try:
                written = p.ingest(json.loads(request_body))
            except (ValueError, TypeError, KeyError, AttributeError, FileExistsError) as exc:
                return 400, "application/json", {"error": "invalid_argument", "message": str(exc)[:200]}
            return 200, "application/json", {"id": written["id"]}
        if method == "POST" and path == "/v1/render":
            return await self.render(request_body)
        if path.startswith("/runtime/"):
            return await self.forward_to_runtime(method, path[len("/runtime"):], headers, request_body)
        if method == "POST" and path == "/v1/proxy/reload":
            cfg = await asyncio.to_thread(self.config_loader)  # pode esperar o bind do host enxergar o arquivo novo
            closed = p.apply_config(cfg)
            p.flush_usage()
            return 200, "application/json", {"applied": True, "via": cfg.via, "closed_tunnels": closed,
                                             "render_supported": cfg.render is not None}
        return 404, "application/json", {"error": "not_found"}

    # ----- reverse proxy do runtime (07 §2.2: o app só fala com o egress) ----------------------------------------------------
    async def forward_to_runtime(self, method: str, path: str, headers, body: bytes):
        """`/runtime/v1/<op>` -> `runtime:8765/v1/<op>`, repassando o token do computador. O runtime confere o mesmo token."""
        auth = header_value(headers, "authorization") or ""
        host, port = self.runtime_address
        try:
            reader, writer = await asyncio.wait_for(asyncio.open_connection(host, port), 5)
        except (OSError, asyncio.TimeoutError):
            return 503, "application/json", {"error": "box_restarted", "message": "runtime is not reachable"}
        try:
            writer.write((f"{method} {path} HTTP/1.1\r\nHost: runtime\r\nAuthorization: {auth}\r\nContent-Type: application/json\r\n"
                          f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n").encode() + body)
            await writer.drain()
            raw = await asyncio.wait_for(reader.read(), 125)
        except (OSError, asyncio.TimeoutError):
            return 504, "application/json", {"error": "timeout", "message": "runtime did not answer in time"}
        finally:
            writer.close()
        head, _, payload = raw.partition(b"\r\n\r\n")
        try:
            status = int(head.split(b" ", 2)[1])
        except (IndexError, ValueError):
            return 502, "application/json", {"error": "box_restarted", "message": "bad answer from runtime"}
        return status, "application/json", payload

    async def tunnel_tcp(self, reader, writer, query, headers) -> None:
        """`/v1/tcp?port=<n>`: depois do 101, bytes crus entre o app e `127.0.0.1:<n>` do computador."""
        def refuse(status: int, error: str) -> bytes:
            body = json.dumps({"error": error}).encode()
            return f"HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode() + body

        if not self._authorized(headers):
            writer.write(refuse(401, "unauthorized"))
            await writer.drain()
            return
        port = tunnel_port(query)
        if port is None or (header_value(headers, "upgrade") or "").lower() != "racky-tcp":
            writer.write(refuse(400, "invalid_argument"))
            await writer.drain()
            return
        try:
            ur, uw = await asyncio.wait_for(asyncio.open_connection("127.0.0.1", port), 5)
        except (OSError, asyncio.TimeoutError):
            writer.write(refuse(502, "nothing_listening"))
            await writer.drain()
            return
        writer.write(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: racky-tcp\r\nConnection: Upgrade\r\n\r\n")
        await writer.drain()

        async def pump(src, dst) -> None:
            try:
                while True:
                    data = await src.read(65536)
                    if not data:
                        break
                    dst.write(data)
                    await dst.drain()
            except (ConnectionError, OSError):
                pass
            finally:
                try:
                    dst.write_eof()
                except (OSError, RuntimeError, AttributeError):
                    pass

        tasks = [asyncio.ensure_future(pump(reader, uw)), asyncio.ensure_future(pump(ur, writer))]
        try:
            await asyncio.wait(tasks, return_when=asyncio.ALL_COMPLETED)
        finally:
            for t in tasks:
                t.cancel()
            uw.close()

    async def tunnel_vnc(self, reader, writer, target: str, headers) -> None:
        """Repassa o upgrade WebSocket ao runtime (`/vnc` -> `/v1/vnc`) e vira um túnel de bytes. Não interpreta nada."""
        if "websocket" not in (header_value(headers, "upgrade") or "").lower() or not header_value(headers, "sec-websocket-key"):
            writer.write(b"HTTP/1.1 400 X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            await writer.drain()
            return
        host, port = self.runtime_address
        try:
            ur, uw = await asyncio.wait_for(asyncio.open_connection(host, port), 5)
        except (OSError, asyncio.TimeoutError):
            writer.write(b"HTTP/1.1 503 X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            await writer.drain()
            return
        forwarded = ["Host: runtime", "Upgrade: websocket", "Connection: Upgrade"]
        for name in ("sec-websocket-key", "sec-websocket-version", "sec-websocket-protocol"):
            value = header_value(headers, name)
            if value:
                forwarded.append(f"{name}: {value}")
        uw.write((f"GET /v1/vnc{target[len('/vnc'):]} HTTP/1.1\r\n" + "\r\n".join(forwarded) + "\r\n\r\n").encode())
        await uw.drain()

        async def pump(src, dst) -> None:
            try:
                while True:
                    data = await src.read(65536)
                    if not data:
                        break
                    dst.write(data)
                    await dst.drain()
            except (ConnectionError, OSError):
                pass

        tasks = [asyncio.ensure_future(pump(reader, uw)), asyncio.ensure_future(pump(ur, writer))]
        try:
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for t in tasks:
                t.cancel()
            uw.close()

    # ----- render (CS-146) ----------------------------------------------------------------------------------------------------
    async def render(self, request_body: bytes):
        p = self.proxy
        cfg = p.config.render
        if cfg is None:
            return 501, "application/json", {"error": "not_supported", "message": "the selected proxy has no render capability"}
        try:
            req = json.loads(request_body)
            url = req["url"]
            parts = urlsplit(url)
            if parts.scheme not in ("http", "https") or not parts.hostname:
                raise ValueError("url must be absolute http(s)")
        except (ValueError, KeyError, TypeError) as exc:
            return 400, "application/json", {"error": "invalid_argument", "message": str(exc)[:200]}
        host, port = parts.hostname, parts.port or (443 if parts.scheme == "https" else 80)
        try:
            await p._check_destination(host, port)
        except Blocked as exc:
            return 403, "application/json", {"error": "blocked_by_policy", "message": f"blocked: {exc.reason}",
                                             "details": {"reason": exc.reason}}
        started = p.clock()
        try:
            status, out = await asyncio.to_thread(rd.call_provider, cfg, rd.build_body(req))
        except rd.RenderError as exc:
            p.usage_for_via().errors += 1
            return exc.status, "application/json", {"error": exc.code, "message": exc.message}
        red = p.reqlog.redactor
        html = out.get("browserHtml", "") if isinstance(out, dict) else ""
        rid = rd.new_id(p)
        record = {"id": rid, "source": "render-api", "kind": "render", "method": "RENDER", "url": url, "status": status,
                  "duration_ms": round((p.clock() - started) * 1000)}
        wall = rd.detect_wall(html)
        if wall:
            record["blocked"] = True
            record["blocked_reason"] = f"anti-bot page in rendered HTML ({wall})"
        if status != 200:
            record["error"] = "proxy_error"
            record["error_detail"] = json.dumps(out)[:600]
        captures = []
        capture_ids = []
        for item in (out.get("networkCapture") or []) if isinstance(out, dict) else []:
            text = base64.b64decode(item.get("httpResponseBody", "") or "").decode("utf-8", "replace")
            cid = rd.new_id(p)
            p.ingest({"record": {"id": cid, "source": "render-api:capture", "method": item.get("method", "GET"),
                                 "url": item.get("url"), "status": item.get("statusCode"), "parent": rid},
                      "response_body": text})
            capture_ids.append(cid)
            captures.append({"id": cid, "url": item.get("url"), "status": item.get("statusCode"), "snippet": red.text(text[:500])})
        record["captures"] = capture_ids
        written = p.ingest({"record": record, "response_body": html})
        usage = p.usage_for_via()
        if status == 200:
            usage.renders += 1
        p.dirty = True
        content = rd.visible_text(html) if req.get("output") == "text" else html
        reply: dict = {"request_id": written["id"], "status": status, "content": red.text(content[:rd.INLINE_LIMIT]),
                       "truncated": len(content) > rd.INLINE_LIMIT, "body_file": written.get("response_body_file"),
                       "captures": captures, "usage": {"renders": usage.renders}}
        if wall:
            reply["blocked"] = record["blocked_reason"]
        if status != 200:
            reply["error"] = "proxy_error"
            reply["message"] = f"render provider answered {status}"
            reply["details"] = {"upstream_status": status}
        return 200, "application/json", reply
