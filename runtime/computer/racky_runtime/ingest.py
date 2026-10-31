"""Envio de registros do browser ao reqlog do egress (CS-148a). O runtime só ENVIA: quem escreve (e encadeia o hash) é o
egress. O token do computador vem de arquivo montado, nunca de env."""
from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path

EGRESS_ADMIN = (os.environ.get("RACKY_EGRESS_HOST", "127.0.0.1"), int(os.environ.get("RACKY_EGRESS_ADMIN_PORT", "8790")))
SECRETS_DIR = Path(os.environ.get("RACKY_RUNTIME_DIR", "/run/racky"))


def load_token() -> str | None:
    path = SECRETS_DIR / "token"
    return path.read_text().strip() if path.exists() else None


async def post_json(path: str, payload: dict, token: str, timeout: float = 10.0, host: str | None = None,
                    port: int | None = None) -> tuple[int, bytes]:
    data = json.dumps(payload, ensure_ascii=False).encode()
    reader, writer = await asyncio.wait_for(asyncio.open_connection(host or EGRESS_ADMIN[0], port or EGRESS_ADMIN[1]), timeout)
    try:
        writer.write((f"POST {path} HTTP/1.1\r\nHost: egress\r\nAuthorization: Bearer {token}\r\nContent-Type: application/json\r\n"
                      f"Content-Length: {len(data)}\r\nConnection: close\r\n\r\n").encode() + data)
        await writer.drain()
        raw = await asyncio.wait_for(reader.read(), timeout)
    finally:
        writer.close()
    head, _, body = raw.partition(b"\r\n\r\n")
    status = int(head.split(b" ", 2)[1])
    return status, body


class Ingestor:
    """Fila de registros pendentes. `flush()` espera os envios em andamento (a ferramenta devolve o `request_id` já gravado)."""

    def __init__(self, token: str | None, host: str | None = None, port: int | None = None):
        self.token = token
        self.host, self.port = host, port
        self.pending: set[asyncio.Task] = set()
        self.dropped = 0

    def submit(self, record: dict, request_body: str | None = None, response_body: str | None = None) -> None:
        if not self.token:
            self.dropped += 1
            return
        task = asyncio.ensure_future(self._send({"record": record, "request_body": request_body, "response_body": response_body}))
        self.pending.add(task)
        task.add_done_callback(self.pending.discard)

    async def _send(self, payload: dict) -> None:
        try:
            status, _ = await post_json("/v1/reqlog/ingest", payload, self.token or "", host=self.host, port=self.port)
            if status != 200:
                self.dropped += 1
        except Exception:
            self.dropped += 1

    async def flush(self, timeout: float = 5.0) -> None:
        if self.pending:
            await asyncio.wait(set(self.pending), timeout=timeout)
