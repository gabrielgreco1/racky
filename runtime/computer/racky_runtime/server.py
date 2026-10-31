"""API de ações do runtime: HTTP/1.1 mínimo sobre asyncio, `POST /v1/<op>` com JSON, autenticada por token de arquivo.

Contrato `X-Racky-Runtime: 2` (07 CS-125). Erros: `{"error": <code>, "message": ..., "details": {...}}`. Só `/v1/health`
é aberto. Escritas (open, click, type, ...) são serializadas; leituras (read, screenshot, status, tabs list, cookies get,
eval) não disputam o lock (CS-193).
"""
from __future__ import annotations

import asyncio
import hmac
import json
from typing import Any

from . import API_VERSION
from .browser import BrowserSession, OpError
from .lease import Lease
from .vnc import Tickets, VncBridge

READS = {"read", "screenshot", "status", "eval", "frame", "selection"}
MAX_BODY = 48 * 1024 * 1024
OPS = ("open", "read", "screenshot", "click", "type", "press", "select", "scroll", "wait", "eval", "cookies", "tabs", "back",
       "forward", "reload", "download", "upload", "status", "mode", "lease", "vnc_ticket", "frame", "selection")


class RuntimeServer:
    def __init__(self, browser: BrowserSession, token: str | None, display):
        self.browser = browser
        self.token = token
        self.display = display  # objeto com `.mode` e `set_mode(m)` (Openbox liga/desliga)
        self.lease = Lease(browser.write_lock)
        self.tickets = Tickets()
        self.bridge = VncBridge(self.lease, self.tickets)

    def _authorized(self, headers: dict[str, str]) -> bool:
        supplied = headers.get("authorization", "")
        if not self.token or not supplied.lower().startswith("bearer "):
            return False
        return hmac.compare_digest(supplied[7:].strip().encode(), self.token.encode())

    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            try:
                head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 15)
            except Exception:
                return
            lines = head.decode("latin-1").split("\r\n")
            method, target, _ = (lines[0].split(" ") + ["", ""])[:3]
            headers = {}
            for line in lines[1:]:
                if ":" in line:
                    k, _, v = line.partition(":")
                    headers[k.strip().lower()] = v.strip()
            if method == "GET" and target.split("?")[0] == "/v1/vnc":
                await self.bridge.serve(reader, writer, target, headers)  # autenticado pelo ticket, não pelo token
                return
            length = int(headers.get("content-length", "0") or 0)
            if length > MAX_BODY:
                await self._send(writer, 413, {"error": "invalid_argument", "message": "body too large"})
                return
            body = await asyncio.wait_for(reader.readexactly(length), 60) if length else b""
            status, payload = await self.route(method, target.split("?")[0], headers, body)
            await self._send(writer, status, payload)
        except (ConnectionError, asyncio.IncompleteReadError):
            pass
        finally:
            try:
                writer.close()
            except Exception:
                pass

    async def _send(self, writer, status: int, payload: Any) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode()
        writer.write((f"HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {len(data)}\r\n"
                      f"X-Racky-Runtime: {API_VERSION}\r\nConnection: close\r\n\r\n").encode() + data)
        await writer.drain()

    async def _lease(self, args: dict) -> dict:
        action = args.get("action", "status")
        if action == "status":
            return self.lease.snapshot()
        if action in ("take", "force_take"):
            return await self.lease.take(min(float(args.get("wait_s", 10)), 30.0), force=action == "force_take")
        if action == "give":
            return self.lease.give(args.get("note"))
        if action == "consume_note":
            return self.lease.consume_note()
        raise OpError("invalid_argument", "action must be status, take, force_take, give or consume_note")

    async def route(self, method: str, path: str, headers: dict[str, str], body: bytes) -> tuple[int, Any]:
        if method == "GET" and path == "/v1/health":
            return 200, {"ok": True, "ready": self.browser.ready, "display": self.display.mode, "api": API_VERSION}
        if not self._authorized(headers):
            return 401, {"error": "unauthorized", "message": "missing or invalid token"}
        if method != "POST" or not path.startswith("/v1/"):
            return 404, {"error": "not_found", "message": "unknown route"}
        op = path[len("/v1/"):]
        if op not in OPS:
            return 404, {"error": "not_found", "message": f"unknown operation {op}"}
        try:
            args = json.loads(body) if body else {}
            if not isinstance(args, dict):
                raise ValueError("JSON object required")
        except ValueError as exc:
            return 400, {"error": "invalid_argument", "message": str(exc)}
        try:
            if op == "mode":
                return 200, await self.display.set_mode(args.get("display"))
            if op == "vnc_ticket":
                return 200, self.tickets.issue()
            if op == "lease":
                return 200, await self._lease(args)
            fn = getattr(self.browser, op)
            if op in READS or (op == "tabs" and args.get("action") == "list") or (op == "cookies" and args.get("action") in ("get", "export")):
                result = await fn(args)
                if op == "status" and isinstance(result, dict):
                    result = {**result, "lease": self.lease.state}
                return 200, result
            return 200, await self.lease.run_write(fn, args)
        except OpError as exc:
            return exc.status, {"error": exc.code, "message": exc.message, "details": exc.details}
        except Exception as exc:
            name = type(exc).__name__
            if "Timeout" in name:
                return 408, {"error": "timeout", "message": str(exc).split("\n")[0][:300]}
            # Playwright: seletor inválido, elemento não encontrado etc. Sem stack nem valores internos.
            return 400, {"error": "invalid_argument", "message": f"{name}: {str(exc).splitlines()[0][:300] if str(exc) else ''}"}
