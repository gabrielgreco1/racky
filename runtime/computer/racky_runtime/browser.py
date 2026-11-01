"""Browser persistente do computador: Chromium HEADED em Xvfb, dirigido por Playwright (07 CS-190, CS-210, CS-211).

- Sempre headed, mesmo sem viewer: a troca headless <-> desktop nunca reabre o browser (CS-191/192).
- Sai pelo egress (`--proxy-server`); loopback também passa pelo proxy (Playwright usa `<-loopback>`), então o filtro SSRF
  do egress vale para o `browser_open` (CS-143).
- Observa as requisições (listener passivo, como o antigo `netlog.py`) e envia os registros ao egress, que os grava no
  reqlog `observed` (CS-148a). Ignora image, font, stylesheet e media.
- Escritas serializadas por um lock; leituras não o disputam (CS-193).
"""
from __future__ import annotations

import asyncio
import base64
import json
import os
import time
import uuid
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from .ingest import Ingestor
from .ulid import new_ulid

SKIP_TYPES = {"image", "font", "stylesheet", "media"}
REQUEST_BODY_LIMIT = 64 * 1024
RESPONSE_BODY_LIMIT = 2 * 1024 * 1024
TEXTUAL = ("text/", "json", "xml", "javascript", "x-www-form-urlencoded", "graphql", "csv")
PROFILE_DIR = Path(os.environ.get("RACKY_PROFILE_DIR", "/profile"))
PROXY_SERVER = os.environ.get("RACKY_PROXY_URL", "http://127.0.0.1:3128")
# P24: o Chromium roda como `agent` (sem privilégio) por este wrapper (setpriv); o servidor de controle roda como `egress`.
CHROMIUM_WRAPPER = os.environ.get("RACKY_CHROMIUM_WRAPPER", "/opt/racky/bin/abx-chromium")
MAX_DOWNLOAD_BYTES = 24 * 1024 * 1024



SCREEN = (1440, 900)  # o mesmo `-screen` do Xvfb (__main__.py)


def launch_args(env: dict[str, str]) -> list[str]:
    """Flags do Chromium que não denunciam automação (F42): sem `--disable-gpu` (WebGL some e isso marca bot), WebGL por
    SwiftShader, janela do tamanho da tela, idioma do Mac (`RACKY_LOCALE`). O fuso vem de `TZ` no ambiente do processo, não de
    emulação por CDP (que os web workers não veem)."""
    lang = env.get("RACKY_LOCALE") or "en-US"
    base = lang.split("-")[0]
    accept = ",".join(dict.fromkeys([lang, base, "en-US", "en"]))
    return ["--no-sandbox", "--disable-dev-shm-usage", "--no-first-run", "--no-default-browser-check",
            "--disable-background-networking", "--disable-component-update", "--disable-sync", "--disable-default-apps",
            "--disable-domain-reliability", "--no-pings", "--disable-features=Translate",
            "--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader",
            f"--window-size={SCREEN[0]},{SCREEN[1]}", "--window-position=0,0", f"--lang={lang}", f"--accept-lang={accept}"]

class OpError(Exception):
    def __init__(self, code: str, message: str, status: int = 400, details: dict | None = None):
        super().__init__(message)
        self.code, self.message, self.status, self.details = code, message, status, details or {}


def _is_textual(content_type: str | None) -> bool:
    ct = (content_type or "").lower()
    return any(t in ct for t in TEXTUAL)


class BrowserSession:
    def __init__(self, ingestor: Ingestor, proxy_server: str | None = PROXY_SERVER, profile: Path = PROFILE_DIR,
                 headless: bool = False, extra_args: list[str] | None = None):
        self.ingestor = ingestor
        self.proxy_server = proxy_server
        self.profile = profile
        self.headless = headless
        self.extra_args = extra_args or []
        self.pw = None
        self.ctx = None
        self.page = None
        self.write_lock = asyncio.Lock()
        self.observers: set[asyncio.Task] = set()
        self.request_ids: dict[int, str] = {}
        self.started: dict[int, float] = {}
        self.last_main_request_id: str | None = None
        self.downloads_dir = Path("/tmp/abx-downloads")
        self.display = "headless"

    # ----- ciclo de vida ------------------------------------------------------------------------------------------------
    async def start(self) -> None:
        # Patchright (Playwright corrigido): sem `--enable-automation`/`navigator.webdriver`, sem `Runtime.enable` do CDP e sem os
        # vazamentos em web workers que o Cloudflare e o DataDome usam para marcar bot (F42). Import tardio: os testes de unidade não
        # precisam de nenhum dos dois; sem o Patchright (imagem antiga), cai no Playwright.
        try:
            from patchright.async_api import async_playwright
        except ImportError:  # pragma: no cover
            from playwright.async_api import async_playwright

        self.profile.mkdir(parents=True, exist_ok=True)
        self.downloads_dir.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(self.downloads_dir, 0o1777)  # o Chromium (uid agent) grava aqui; o servidor (uid egress) lê
        except OSError:
            pass
        self.pw = await async_playwright().start()
        options: dict[str, Any] = dict(
            user_data_dir=str(self.profile), headless=self.headless, args=launch_args(os.environ) + self.extra_args,
            # Sem viewport emulada: a janela ocupa a tela do Xvfb e inner/outer/screen batem como num desktop de verdade.
            no_viewport=True,
            accept_downloads=True, downloads_path=str(self.downloads_dir), env={**os.environ, "DISPLAY": os.environ.get("DISPLAY", ":99")})
        if self.proxy_server:
            options["proxy"] = {"server": self.proxy_server}
        if CHROMIUM_WRAPPER and Path(CHROMIUM_WRAPPER).exists():
            options["executable_path"] = CHROMIUM_WRAPPER
        self.ctx = await self.pw.chromium.launch_persistent_context(**options)
        self.ctx.on("request", self._on_request)
        self.ctx.on("requestfinished", lambda r: self._spawn(self._on_finished(r)))
        self.ctx.on("requestfailed", lambda r: self._spawn(self._on_failed(r)))
        self.ctx.on("page", self._on_page)
        for page in self.ctx.pages:
            self._on_page(page)
        self.page = self.ctx.pages[0] if self.ctx.pages else await self.ctx.new_page()

    async def stop(self) -> None:
        try:
            if self.ctx:
                await asyncio.wait_for(self.ctx.close(), 10)
        except Exception:
            pass
        try:
            if self.pw:
                await asyncio.wait_for(self.pw.stop(), 5)
        except Exception:
            pass

    def _spawn(self, coroutine) -> None:
        task = asyncio.ensure_future(coroutine)
        self.observers.add(task)
        task.add_done_callback(self.observers.discard)

    async def settled(self, timeout: float = 3.0) -> None:
        """Espera os observadores de rede em andamento e os envios ao egress: quando a ferramenta devolve, o que ela fez já
        está no reqlog (o agente consulta `reqlog_query` logo em seguida)."""
        if self.observers:
            await asyncio.wait(set(self.observers), timeout=timeout)
        await self.ingestor.flush(timeout)

    def _on_page(self, page) -> None:
        self.page = page
        page.set_default_timeout(15000)

    @property
    def ready(self) -> bool:
        return self.ctx is not None and self.page is not None

    # ----- observador de rede (reqlog `observed`) -----------------------------------------------------------------------
    def _on_request(self, request) -> None:
        key = id(request)
        self.request_ids[key] = new_ulid()
        self.started[key] = time.monotonic()
        if request.is_navigation_request() and request.frame == (self.page.main_frame if self.page else None):
            self.last_main_request_id = self.request_ids[key]

    def _skip(self, request) -> bool:
        return request.resource_type in SKIP_TYPES or request.url.startswith(("data:", "blob:", "about:"))

    async def _on_finished(self, request) -> None:
        key = id(request)
        rid = self.request_ids.pop(key, None) or new_ulid()
        started = self.started.pop(key, time.monotonic())
        if self._skip(request):
            return
        record: dict[str, Any] = {
            "id": rid, "source": "browser", "kind": "http", "method": request.method, "url": request.url,
            "host": urlsplit(request.url).hostname, "type": request.resource_type,
            "duration_ms": round((time.monotonic() - started) * 1000)}
        response_body = None
        try:
            record["request_headers"] = [[k, v] for k, v in (await request.all_headers()).items()]
            response = await request.response()
            if response is not None:
                record["status"] = response.status
                ctype = response.headers.get("content-type")
                record["content_type"] = ctype
                record["response_headers"] = [[k, v] for k, v in (await response.all_headers()).items()]
                if _is_textual(ctype):
                    try:
                        raw = await response.body()
                        response_body = raw[:RESPONSE_BODY_LIMIT].decode("utf-8", "replace")
                    except Exception:
                        record["body_error"] = "unavailable"  # redirect ou navegação já descartou o corpo
        except Exception as exc:  # observar nunca muda a navegação
            record["observe_error"] = type(exc).__name__
        post = request.post_data
        self.ingestor.submit(record, request_body=post[:REQUEST_BODY_LIMIT] if post else None, response_body=response_body)

    async def _on_failed(self, request) -> None:
        key = id(request)
        rid = self.request_ids.pop(key, None) or new_ulid()
        started = self.started.pop(key, time.monotonic())
        if self._skip(request):
            return
        record = {"id": rid, "source": "browser", "kind": "http", "method": request.method, "url": request.url,
                  "host": urlsplit(request.url).hostname, "type": request.resource_type, "error": request.failure or "failed",
                  "duration_ms": round((time.monotonic() - started) * 1000)}
        post = request.post_data
        self.ingestor.submit(record, request_body=post[:REQUEST_BODY_LIMIT] if post else None)

    # ----- helpers ------------------------------------------------------------------------------------------------------
    def _page(self):
        if not self.ready:
            raise OpError("box_restarted", "the browser is not running", 409)
        return self.page

    def _locator(self, selector: str):
        if not isinstance(selector, str) or not selector.strip():
            raise OpError("invalid_argument", "selector must be a non-empty string")
        return self._page().locator(selector).first

    async def _title(self) -> str:
        try:
            return await self._page().title()
        except Exception:
            return ""

    # ----- operações ----------------------------------------------------------------------------------------------------
    async def open(self, a: dict) -> dict:
        page = self._page()
        url = a.get("url")
        if not isinstance(url, str) or not url.startswith(("http://", "https://")):
            raise OpError("invalid_argument", "url must be an absolute http(s) URL")
        wait_until = a.get("wait_until", "domcontentloaded")
        timeout = float(a.get("timeout_s", 45))
        self.last_main_request_id = None
        response = None
        try:
            response = await page.goto(url, wait_until=wait_until, timeout=timeout * 1000)
        except Exception as exc:
            text = str(exc)
            if "Timeout" in type(exc).__name__ or "Timeout" in text.split("\n")[0]:
                raise OpError("timeout", f"navigation did not finish in {timeout:g}s", 408)
            await self.settled(2)
            raise OpError("navigation_failed", text.split("\n")[0][:400], 502, {"request_id": self.last_main_request_id})
        wait_s = float(a.get("wait_s", 4))
        if wait_s > 0:
            await page.wait_for_timeout(min(wait_s, 30) * 1000)
        await self.settled()
        return {"url": page.url, "title": await self._title(), "status": response.status if response else None,
                "request_id": self.last_main_request_id}

    async def read(self, a: dict) -> dict:
        page = self._page()
        what = a.get("what")
        selector = a.get("selector")
        max_chars = int(a.get("max_chars", 60000))
        offset = int(a.get("offset", 0))
        if what == "text":
            content = await (self._locator(selector).inner_text() if selector else page.inner_text("body"))
        elif what == "html":
            content = await (self._locator(selector).evaluate("e => e.outerHTML") if selector else page.content())
        elif what == "links":
            links = await page.evaluate("""() => Array.from(document.querySelectorAll('a[href]')).map(a => ({
                text: (a.innerText || a.getAttribute('aria-label') || '').trim().slice(0, 200), href: a.href}))""")
            content = json.dumps(links, ensure_ascii=False)
        elif what == "forms":
            forms = await page.evaluate("""() => Array.from(document.forms).map((f, i) => ({
                index: i, action: f.action, method: (f.method || 'get').toUpperCase(),
                fields: Array.from(f.elements).filter(e => e.name || e.id).map(e => ({
                    name: e.name || e.id, tag: e.tagName.toLowerCase(), type: e.type || null,
                    value: e.type === 'password' ? (e.value ? '********' : '') : (e.type === 'checkbox' || e.type === 'radio' ? String(e.checked) : e.value)}))}))""")
            content = json.dumps(forms, ensure_ascii=False)
        elif what == "accessibility":
            content = await (self._locator(selector) if selector else page.locator("body")).aria_snapshot()
        else:
            raise OpError("invalid_argument", "what must be text, html, links, forms or accessibility")
        await self.settled()
        total = len(content)
        chunk = content[offset:offset + max_chars]
        truncated = offset + max_chars < total
        out = {"url": page.url, "title": await self._title(), "content": chunk, "truncated": truncated}
        if truncated:
            out["next_offset"] = offset + max_chars
        return out

    async def screenshot(self, a: dict) -> dict:
        page = self._page()
        if a.get("selector"):
            png = await self._locator(a["selector"]).screenshot(type="png")
        else:
            png = await page.screenshot(type="png", full_page=bool(a.get("full_page", False)))
        return {"png_b64": base64.b64encode(png).decode(), "bytes": len(png), "url": page.url}

    async def frame(self, a: dict) -> dict:
        """Miniatura para a aba Computers (CS-403): JPEG da página, qualidade baixa. O app pede no máximo 1 por segundo."""
        page = self._page()
        quality = max(10, min(int(a.get("quality", 45)), 90))
        jpeg = await page.screenshot(type="jpeg", quality=quality, scale="css", animations="allow", caret="initial")
        return {"jpeg_b64": base64.b64encode(jpeg).decode(), "bytes": len(jpeg), "url": page.url, "title": await page.title()}

    async def selection(self, a: dict) -> dict:
        """`Copy Selection from Computer` (CS-422): só a seleção da página, só por ação explícita do humano."""
        text = await self._page().evaluate("() => String(window.getSelection ? window.getSelection() : '')")
        return {"text": text[:100000]}

    async def _settle(self, before: str, wait_s: float) -> dict:
        page = self._page()
        if wait_s > 0:
            try:
                await page.wait_for_load_state("domcontentloaded", timeout=wait_s * 1000)
            except Exception:
                pass
        await self.settled()
        return {"url": page.url, "navigated": page.url != before}

    async def click(self, a: dict) -> dict:
        page = self._page()
        before = page.url
        button = a.get("button", "left")
        count = int(a.get("count", 1))
        selector, x, y = a.get("selector"), a.get("x"), a.get("y")
        if bool(selector) == (x is not None and y is not None):
            raise OpError("invalid_argument", "give selector XOR (x, y)")
        if selector:
            await self._locator(selector).click(button=button, click_count=count, timeout=15000)
        else:
            await page.mouse.click(float(x), float(y), button=button, click_count=count)
        return await self._settle(before, float(a.get("wait_s", 2)))

    async def type(self, a: dict) -> dict:
        page = self._page()
        before = page.url
        text = a.get("text")
        if not isinstance(text, str):
            raise OpError("invalid_argument", "text is required")
        if a.get("selector"):
            loc = self._locator(a["selector"])
            if a.get("clear", True):
                await loc.fill(text, timeout=15000)
            else:
                await loc.press_sequentially(text, timeout=15000)
            if a.get("submit"):
                await loc.press("Enter")
        else:
            await page.keyboard.type(text)
            if a.get("submit"):
                await page.keyboard.press("Enter")
        return await self._settle(before, 2.0 if a.get("submit") else 0)

    async def press(self, a: dict) -> dict:
        page = self._page()
        before = page.url
        keys = a.get("keys")
        if not isinstance(keys, str) or not keys:
            raise OpError("invalid_argument", "keys is required")
        await page.keyboard.press(keys)
        return await self._settle(before, 1.0)

    async def select(self, a: dict) -> dict:
        values = a.get("values")
        if not isinstance(values, list) or not all(isinstance(v, str) for v in values):
            raise OpError("invalid_argument", "values must be an array of strings")
        selected = await self._locator(a.get("selector")).select_option(values, timeout=15000)
        return {"selected": selected}

    async def scroll(self, a: dict) -> dict:
        page = self._page()
        if a.get("selector"):
            await self._locator(a["selector"]).scroll_into_view_if_needed(timeout=15000)
        dx, dy = float(a.get("dx", 0)), float(a.get("dy", 0))
        if dx or dy:
            await page.mouse.wheel(dx, dy)
            await page.wait_for_timeout(100)
        sx, sy = await page.evaluate("[window.scrollX, window.scrollY]")
        return {"scroll_x": sx, "scroll_y": sy}

    async def wait(self, a: dict) -> dict:
        page = self._page()
        cond = a.get("for") or {}
        timeout = float(a.get("timeout_s", 30)) * 1000
        try:
            if cond.get("selector"):
                await page.wait_for_selector(cond["selector"], state="visible", timeout=timeout)
            if cond.get("url_contains"):
                needle = cond["url_contains"]
                await page.wait_for_function("n => location.href.includes(n)", arg=needle, timeout=timeout)
            if cond.get("text"):
                await page.wait_for_function("t => document.body && document.body.innerText.includes(t)", arg=cond["text"], timeout=timeout)
            if cond.get("network_idle"):
                await page.wait_for_load_state("networkidle", timeout=timeout)
        except Exception as exc:
            if "Timeout" in type(exc).__name__:
                return {"matched": False, "url": page.url}
            raise
        await self.settled()
        return {"matched": True, "url": page.url}

    async def eval(self, a: dict) -> dict:
        js = a.get("js")
        if not isinstance(js, str) or not js.strip():
            raise OpError("invalid_argument", "js is required")
        try:
            # O `eval` do agente lê variáveis da página (`window.__NEXT_DATA__`...): mundo principal, não o isolado do Patchright.
            try:
                result = await self._page().evaluate(js, isolated_context=False)
            except TypeError:  # Playwright puro não tem o parâmetro
                result = await self._page().evaluate(js)
        except Exception as exc:
            raise OpError("invalid_argument", str(exc).split("\n")[0][:400])
        text = json.dumps(result, ensure_ascii=False, default=str)
        limit = int(a.get("max_chars", 20000))
        return {"result_json": text[:limit], "truncated": len(text) > limit}

    async def cookies(self, a: dict) -> dict:
        action = a.get("action")
        domain = a.get("domain")
        if action in ("get", "export"):
            cookies = await self.ctx.cookies()
            if domain:
                bare = domain.lstrip(".")
                cookies = [c for c in cookies if c["domain"].lstrip(".").endswith(bare)]
            return {"cookies": cookies}
        if action == "set":
            cookies = a.get("cookies")
            if not isinstance(cookies, list) or not cookies:
                raise OpError("invalid_argument", "cookies is required for set")
            await self.ctx.add_cookies(cookies)
            return {"cookies": await self.ctx.cookies()}
        if action == "clear":
            if domain:
                await self.ctx.clear_cookies(domain=domain)
            else:
                await self.ctx.clear_cookies()
            return {"cookies": []}
        raise OpError("invalid_argument", "action must be get, set, clear or export")

    async def tabs(self, a: dict) -> dict:
        action = a.get("action")
        pages = self.ctx.pages
        if action == "new":
            page = await self.ctx.new_page()
            if a.get("url"):
                await page.goto(a["url"], wait_until="domcontentloaded", timeout=45000)
            self.page = page
        elif action in ("switch", "close"):
            index = a.get("index")
            if not isinstance(index, int) or not 0 <= index < len(pages):
                raise OpError("invalid_argument", "index out of range")
            if action == "switch":
                self.page = pages[index]
                await self.page.bring_to_front()
            else:
                await pages[index].close()
                remaining = self.ctx.pages
                self.page = remaining[-1] if remaining else await self.ctx.new_page()
        elif action != "list":
            raise OpError("invalid_argument", "action must be list, switch, new or close")
        out = []
        for i, p in enumerate(self.ctx.pages):
            out.append({"index": i, "url": p.url, "title": await p.title(), "active": p == self.page})
        return {"tabs": out}

    async def back(self, a: dict) -> dict:
        await self._page().go_back(wait_until="domcontentloaded", timeout=30000)
        await self.settled()
        return {"url": self.page.url}

    async def forward(self, a: dict) -> dict:
        await self._page().go_forward(wait_until="domcontentloaded", timeout=30000)
        await self.settled()
        return {"url": self.page.url}

    async def reload(self, a: dict) -> dict:
        response = await self._page().reload(wait_until="domcontentloaded", timeout=45000)
        await self.settled()
        return {"url": self.page.url, "status": response.status if response else None}

    async def download(self, a: dict) -> dict:
        page = self._page()
        timeout = float(a.get("timeout_s", 60)) * 1000
        if a.get("selector"):
            async with page.expect_download(timeout=timeout) as info:
                await self._locator(a["selector"]).click(timeout=15000)
            download = await info.value
            path = await download.path()
            data = Path(path).read_bytes() if path else b""
            name = download.suggested_filename or "download.bin"
        elif a.get("url"):
            response = await self.ctx.request.get(a["url"], timeout=timeout)
            data = await response.body()
            name = Path(urlsplit(a["url"]).path).name or "download.bin"
        else:
            raise OpError("invalid_argument", "give selector or url")
        if len(data) > MAX_DOWNLOAD_BYTES:
            raise OpError("invalid_argument", f"download larger than {MAX_DOWNLOAD_BYTES} bytes")
        return {"name": name, "bytes": len(data), "data_b64": base64.b64encode(data).decode()}

    async def upload(self, a: dict) -> dict:
        data_b64, name = a.get("data_b64"), a.get("name")
        if not isinstance(data_b64, str) or not isinstance(name, str) or "/" in name or name in ("", ".", ".."):
            raise OpError("invalid_argument", "name and data_b64 are required")
        folder = Path("/tmp/uploads") / uuid.uuid4().hex
        folder.mkdir(parents=True, exist_ok=True)
        os.chmod(folder, 0o755)  # o Chromium (uid agent) precisa ler o arquivo
        path = folder / name
        path.write_bytes(base64.b64decode(data_b64))
        os.chmod(path, 0o644)
        await self._locator(a.get("selector")).set_input_files(str(path), timeout=15000)
        return {"uploaded": True}

    async def status(self, a: dict) -> dict:
        if not self.ready:
            return {"ready": False}
        return {"ready": True, "url": self.page.url, "title": await self._title(), "tabs": len(self.ctx.pages)}
