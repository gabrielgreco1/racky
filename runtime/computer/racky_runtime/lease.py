"""Lease de controle do computador (07 CS-410..415): `agent` (padrão), `revoking` (Take Over pedido, esperando a escrita em
curso) e `human`. Vive SÓ aqui; o app consulta e comanda por `/v1/lease`. Erro de escrita do agente não mexe no lease (CS-411)."""
from __future__ import annotations

import asyncio
import time

from .browser import OpError

AGENT, REVOKING, HUMAN = "agent", "revoking", "human"
RETRY_AFTER_S = 5


class Lease:
    def __init__(self, write_lock: asyncio.Lock, clock=time.time):
        self.write_lock = write_lock
        self.clock = clock
        self.state = AGENT
        self.since = clock()
        self.note: str | None = None  # nota do último Hand Back (consumida pelo app)
        self.handed_back_at: float | None = None
        self.inflight: set[asyncio.Task] = set()
        self.revoked: set[asyncio.Task] = set()  # escritas que estavam em curso quando o humano pediu o controle
        self.listeners: list = []  # chamados com o novo estado (a ponte VNC solta teclas ao voltar para o agente)

    def snapshot(self) -> dict:
        return {"lease": self.state, "since": self.since, "note": self.note, "handed_back_at": self.handed_back_at,
                "inflight_writes": len([t for t in self.inflight if not t.done()])}

    def _set(self, state: str) -> None:
        if state != self.state:
            self.state = state
            self.since = self.clock()
            for fn in list(self.listeners):
                fn(state)

    @property
    def human_may_input(self) -> bool:
        return self.state == HUMAN

    def gate(self) -> None:
        """Escritas do agente: recusadas enquanto o humano (ou o pedido dele) manda."""
        if self.state != AGENT:
            raise OpError("human_in_control", "a human is controlling this computer; wait for Hand Back", 409,
                          {"retry_after_s": RETRY_AFTER_S, "lease": self.state})

    async def run_write(self, fn, args: dict):
        """Executa uma escrita serializada. Cancelável por `force_take`; relê o lease ao pegar o lock (uma escrita que esperava
        na fila quando o humano assumiu não executa)."""
        self.gate()
        task = asyncio.ensure_future(self._locked(fn, args))
        self.inflight.add(task)
        task.add_done_callback(self.inflight.discard)
        try:
            result = await asyncio.shield(task)
            if task in self.revoked and self.state != AGENT:
                # CA-402: a chamada que estava em curso termina, mas o agente é avisado de que o humano assumiu. O que ela
                # produziu vai em `details.completed_result` (nada se perde) e o lease NÃO volta para o agente.
                raise OpError("human_in_control", "a human took over while this call was running", 409,
                              {"retry_after_s": RETRY_AFTER_S, "lease": self.state, "completed": True, "completed_result": result})
            return result
        except asyncio.CancelledError:
            if task.cancelled():
                raise OpError("human_in_control", "the write was cancelled by a forced Take Over", 409,
                              {"retry_after_s": RETRY_AFTER_S, "lease": self.state})
            task.cancel()
            raise
        finally:
            self.revoked.discard(task)

    async def _locked(self, fn, args: dict):
        async with self.write_lock:
            self.gate()
            return await fn(args)

    async def take(self, wait_s: float = 10.0, force: bool = False) -> dict:
        """`Take Over`: `revoking` até a escrita em curso terminar (ACK = pegar o lock); `force` cancela a escrita em curso."""
        if self.state == HUMAN:
            return {**self.snapshot(), "ack": True}
        self._set(REVOKING)
        self.revoked |= {t for t in self.inflight if not t.done()}
        if force:
            # Take Over do app: o humano assume na hora. A escrita em curso é cancelada (o agente recebe `human_in_control`)
            # e nenhuma nova passa do `gate()`; não espera o lock.
            for task in list(self.inflight):
                task.cancel()
            self._set(HUMAN)
            self.note = None
            return {**self.snapshot(), "ack": True}
        try:
            await asyncio.wait_for(self.write_lock.acquire(), max(0.0, wait_s))
        except asyncio.TimeoutError:
            return {**self.snapshot(), "ack": False}
        self.write_lock.release()
        self._set(HUMAN)
        self.note = None
        return {**self.snapshot(), "ack": True}

    def give(self, note: str | None) -> dict:
        """`Hand Back`: o agente volta a escrever; a nota segue para a próxima chamada do filho."""
        if self.state == AGENT:
            return {**self.snapshot(), "ack": True}
        self.note = (note or "").strip()[:2000] or None
        self.handed_back_at = self.clock()
        self._set(AGENT)
        return {**self.snapshot(), "ack": True}

    def consume_note(self) -> dict:
        out = {"note": self.note, "handed_back_at": self.handed_back_at}
        self.note = None
        return out
