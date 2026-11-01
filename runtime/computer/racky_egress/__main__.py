"""Ponto de entrada: sobe o proxy (só na interface da rede interna) e a admin API."""
from __future__ import annotations

import asyncio
import os
import signal
import sys

from .admin import AdminServer
from .config import load_config, load_token, secrets_dir
from .proxy import EgressProxy


async def wait_for_provisioning():
    """O app entrega `token` e `egress.json` por `docker exec` (abx-provision) depois que o container sobe. Até lá, espera
    (sem config não há proxy: fail closed)."""
    while True:
        token = load_token()
        try:
            if token and (secrets_dir() / "egress.json").exists():
                return load_config(), token
        except OSError:
            pass
        await asyncio.sleep(0.2)


async def main() -> int:
    config, token = await wait_for_provisioning()
    proxy = EgressProxy(config)
    # P24: o proxy escuta SÓ em loopback do próprio container (o agente chega nele por regra de uid no iptables).
    bind = config.bind or "127.0.0.1"
    proxy_server = await asyncio.start_server(proxy.handle, bind, config.proxy_port, limit=1 << 17, backlog=256)
    admin = AdminServer(proxy, token)
    # `RACKY_ADMIN_BIND=127.0.0.1` no runtime sem Docker (VM): a admin API só chega pelo encaminhador vsock, nunca pela rede da vmnet.
    admin_bind = os.environ.get("RACKY_ADMIN_BIND") or "0.0.0.0"
    admin_server = await asyncio.start_server(admin.handle, admin_bind, config.admin_port)
    print(f"egress: proxy em {bind}:{config.proxy_port}, admin em {admin_bind}:{config.admin_port}, via={config.via}", flush=True)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)

    async def flusher() -> None:
        while True:
            await asyncio.sleep(1)
            proxy.flush_usage()

    task = asyncio.ensure_future(flusher())
    await stop.wait()
    task.cancel()
    proxy_server.close()
    admin_server.close()
    proxy.close_all("shutdown")
    proxy.dirty = True
    proxy.flush_usage()
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
