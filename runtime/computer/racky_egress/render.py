"""Render via o modo API do proxy selecionado (07 CS-146, CS-256, T12/P13).

Só roda se o `ProxyProfile` selecionado declara a capacidade (`config.render`). Adaptador da v1: Zyte API (`/v1/extract`,
`browserHtml`, `networkCapture` opcional, `actions` opcional). Proxy sem render: `not_supported`. A chave existe só no
arquivo 0400 do egress (CS-145). O alvo passa pelo mesmo filtro SSRF do tráfego normal. Marca `blocked` quando o HTML
renderizado ainda é página anti-bot.
"""
from __future__ import annotations

import base64
import json
import re
import urllib.error
import urllib.request
from typing import Any

from . import reqlog as rl
from .config import Render

WALLS = ("Just a moment...", "cf-chl", "Incapsula incident", "captcha-delivery.com", "Attention Required! | Cloudflare")
INLINE_LIMIT = 60000


class RenderError(Exception):
    def __init__(self, code: str, message: str, status: int = 502, details: dict | None = None):
        super().__init__(message)
        self.code, self.message, self.status, self.details = code, message, status, details or {}


def build_body(request: dict[str, Any]) -> dict[str, Any]:
    body: dict[str, Any] = {"url": request["url"], "browserHtml": True}
    capture = request.get("capture") or []
    if capture:
        body["networkCapture"] = [
            {"filterType": "url", "matchType": "contains", "value": str(needle), "httpResponseBody": True} for needle in capture]
    if request.get("actions"):
        body["actions"] = request["actions"]
    if request.get("geolocation"):
        body["geolocation"] = request["geolocation"]
    return body


def call_provider(render: Render, body: dict[str, Any], timeout: float = 120.0) -> tuple[int, dict[str, Any]]:
    """Bloqueante (o admin roda em thread). A chave vai como usuário Basic, como no CLI antigo."""
    token = base64.b64encode(f"{render.api_key}:".encode()).decode()
    req = urllib.request.Request(render.endpoint, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": f"Basic {token}", "Accept-Encoding": "identity"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw, status = response.read(), response.status
    except urllib.error.HTTPError as exc:
        raw, status = exc.read(), exc.code
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise RenderError("proxy_error", f"render provider unreachable: {type(exc).__name__}", 502)
    try:
        return status, json.loads(raw)
    except ValueError:
        return status, {"raw": raw[:2000].decode("utf-8", "replace")}


def visible_text(html: str) -> str:
    html = re.sub(r"(?s)<(script|style)[^>]*>.*?</\1>", "", html)
    return re.sub(r"\n\s*\n+", "\n", re.sub(r"<[^>]+>", " ", html)).strip()


def detect_wall(html: str) -> str | None:
    return next((w for w in WALLS if w in html), None)


def new_id(proxy) -> str:
    return rl.new_ulid(int(proxy.clock() * 1000))
