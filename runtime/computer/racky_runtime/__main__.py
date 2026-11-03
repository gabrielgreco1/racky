"""Ponto de entrada do papel `runtime`: API de ações em :8765 (07 CS-190). Tela (Xvfb), VNC e Chromium sobem sob demanda
(backlog 20): o computador nasce só com o proxy e esta API; o primeiro comando de navegador liga a tela e o Chromium, e o VNC só
sobe quando alguém abre a tela ao vivo. Crawler que só faz HTTP nunca paga o navegador."""
from __future__ import annotations

import asyncio
import os
import signal
import subprocess
import sys
from pathlib import Path

from .browser import BrowserSession, OpError
from .ingest import Ingestor, load_token
from .server import RuntimeServer

DISPLAY = os.environ.get("DISPLAY", ":99")
# P24: tela, VNC e gerenciador de janelas pertencem ao usuário `agent` (o mesmo do Chromium e dos comandos do agente).
AGENT_USER = os.environ.get("RACKY_AGENT_USER", "agent")


def as_agent() -> dict:
    """Argumentos de `Popen` para largar o privilégio de `egress` e virar `agent` (precisa de CAP_SETUID/SETGID ambiente).
    Fora do container (testes) o usuário não existe e nada muda."""
    import pwd

    try:
        pw = pwd.getpwnam(AGENT_USER)
    except KeyError:
        return {}
    if os.getuid() == pw.pw_uid:
        return {}
    return {"user": pw.pw_uid, "group": pw.pw_gid, "extra_groups": []}
PORT = int(os.environ.get("RACKY_RUNTIME_PORT", "8765"))


class Display:
    """Xvfb sempre ligado. `desktop` liga o Openbox (gerenciador de janelas) sem tocar no Chromium: a troca nunca recarrega a
    página (CS-191/192). Redimensionar o display exigiria reiniciar o Xvfb e fica fora desta tarefa."""

    def __init__(self) -> None:
        self.xvfb: subprocess.Popen | None = None
        self.openbox: subprocess.Popen | None = None
        self.vnc: subprocess.Popen | None = None
        self.mode = "headless"

    async def start_xvfb(self) -> None:
        if self.xvfb is not None and self.xvfb.poll() is None:
            return
        self.xvfb = subprocess.Popen(["Xvfb", DISPLAY, "-screen", "0", "1440x900x24", "-nolisten", "tcp", "-ac"],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **as_agent())
        socket = Path(f"/tmp/.X11-unix/X{DISPLAY.lstrip(':')}")
        for _ in range(100):
            if socket.exists():
                return
            if self.xvfb.poll() is not None:
                raise RuntimeError("Xvfb exited during startup")
            await asyncio.sleep(0.1)
        raise RuntimeError("Xvfb did not become ready")

    async def ensure_vnc(self) -> None:
        """Só para a tela ao vivo: sem viewer aberto, ninguém precisa do x11vnc. Espera ele aceitar conexão: o app conecta logo
        depois de receber o ticket."""
        if self.vnc is not None and self.vnc.poll() is None:
            return
        self.start_vnc()
        for _ in range(100):
            try:
                _, writer = await asyncio.open_connection("127.0.0.1", 5900)
                writer.close()
                return
            except OSError:
                if self.vnc.poll() is not None:
                    raise RuntimeError("x11vnc exited during startup")
                await asyncio.sleep(0.05)
        raise RuntimeError("x11vnc did not start listening")

    def start_vnc(self) -> None:
        """x11vnc só em 127.0.0.1 (ninguém fora deste container o alcança); a ponte do servidor de controle faz o upgrade
        WebSocket com ticket e filtra input conforme o lease (T3-05, CS-401/402). Sem troca de seleção X: clipboard só por
        ação explícita do humano (CS-422)."""
        self.vnc = subprocess.Popen(
            ["x11vnc", "-display", DISPLAY, "-localhost", "-rfbport", "5900", "-nopw", "-forever", "-shared", "-nosel", "-noipv6",
             "-nobell", "-noxrecord", "-wait", "10", "-defer", "10", "-ncache", "0", "-quiet"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **as_agent())

    async def set_mode(self, display) -> dict:
        if display not in ("headless", "desktop"):
            raise OpError("invalid_argument", "display must be headless or desktop")
        if display == "desktop" and self.openbox is None:
            self.openbox = subprocess.Popen(["openbox"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **as_agent())
        if display == "headless" and self.openbox is not None:
            self.openbox.terminate()
            self.openbox = None
        self.mode = display
        return {"display": display, "reloaded": False}

    def stop(self) -> None:
        for proc in (self.vnc, self.openbox, self.xvfb):
            if proc and proc.poll() is None:
                proc.terminate()


async def main() -> int:
    # P24: o token chega por `docker exec` (abx-provision) depois do start; sem ele o runtime não sobe (fail closed).
    token = load_token()
    while not token:
        await asyncio.sleep(0.2)
        token = load_token()
    display = Display()
    browser = BrowserSession(Ingestor(token))
    server = RuntimeServer(browser, token, display)
    listener = await asyncio.start_server(server.handle, "127.0.0.1", PORT, limit=1 << 20)  # P24: só loopback do container
    if os.environ.get("RACKY_BROWSER_EAGER") == "1":  # comportamento antigo, para comparar nas medições
        await server.ensure_browser()
    print(f"runtime: API em :{PORT}, display {DISPLAY}, browser sob demanda", flush=True)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    await stop.wait()
    listener.close()
    await browser.stop()
    display.stop()
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
