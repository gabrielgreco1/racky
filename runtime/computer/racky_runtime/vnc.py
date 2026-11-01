"""Ponte VNC do runtime (07 CS-401, CS-402): WebSocket (RFC 6455) <-> x11vnc em 127.0.0.1:5900, com ticket de uso único.

- O ticket (`/v1/vnc_ticket`, token do computador) vale 60 s e é consumido no handshake. O egress só repassa o upgrade.
- O sentido cliente -> servidor passa por um filtro de mensagens RFB: sem o lease humano, KeyEvent e PointerEvent são
  descartados (view-only) e ClientCutText/SetDesktopSize nunca passam (o clipboard é ação explícita, CS-422). Mensagem
  desconhecida derruba a conexão (fail closed).
- Teclas e botões pressionados são soltos quando a conexão cai ou o lease sai do humano (CS-420).
"""
from __future__ import annotations

import asyncio
import base64
import hashlib
import secrets
import struct
import time

GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
TICKET_TTL_S = 60.0
VNC_ADDRESS = ("127.0.0.1", 5900)


class Tickets:
    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self._items: dict[str, float] = {}

    def issue(self) -> dict:
        now = self.clock()
        self._items = {t: exp for t, exp in self._items.items() if exp > now}
        ticket = secrets.token_urlsafe(24)
        self._items[ticket] = now + TICKET_TTL_S
        return {"ticket": ticket, "expires_in": int(TICKET_TTL_S)}

    def redeem(self, ticket: str | None) -> bool:
        exp = self._items.pop(ticket or "", None)
        return exp is not None and exp > self.clock()


# ----- WebSocket ---------------------------------------------------------------------------------------------------------
def accept_key(key: str) -> str:
    return base64.b64encode(hashlib.sha1(key.encode() + GUID).digest()).decode()


def encode_frame(payload: bytes, opcode: int = 2) -> bytes:
    n = len(payload)
    head = bytes([0x80 | opcode])
    if n < 126:
        head += bytes([n])
    elif n < 65536:
        head += bytes([126]) + struct.pack(">H", n)
    else:
        head += bytes([127]) + struct.pack(">Q", n)
    return head + payload


def _unmask(data: bytes, mask: bytes) -> bytes:
    if not data:
        return data
    key = int.from_bytes((mask * ((len(data) // 4) + 1))[:len(data)], "big")
    return (int.from_bytes(data, "big") ^ key).to_bytes(len(data), "big")


async def read_frame(reader: asyncio.StreamReader, limit: int = 1 << 20) -> tuple[int, bool, bytes]:
    b1, b2 = await reader.readexactly(2)
    fin, opcode = bool(b1 & 0x80), b1 & 0x0F
    n = b2 & 0x7F
    if n == 126:
        n = struct.unpack(">H", await reader.readexactly(2))[0]
    elif n == 127:
        n = struct.unpack(">Q", await reader.readexactly(8))[0]
    if n > limit:
        raise ValueError("frame too large")
    mask = await reader.readexactly(4) if b2 & 0x80 else b""
    data = await reader.readexactly(n) if n else b""
    return opcode, fin, _unmask(data, mask) if mask else data


# ----- Filtro RFB (cliente -> servidor) ----------------------------------------------------------------------------------
class Reject(Exception):
    pass


class RfbClientFilter:
    """Máquina de estados sobre o fluxo do cliente. `feed(bytes)` devolve os bytes que podem seguir ao x11vnc."""

    def __init__(self, may_input):
        self.may_input = may_input  # callable -> bool (lease humano)
        self.buf = bytearray()
        self.stage = "version"
        self.minor = 8
        self.pressed: set[int] = set()
        self.buttons = 0
        self.pointer = (0, 0)
        self.dropped_inputs = 0
        self.forwarded_inputs = 0
        self.trace: list[tuple[int, int]] | None = None  # (tipo, bytes) das primeiras mensagens, só para diagnóstico

    def feed(self, data: bytes) -> bytes:
        self.buf += data
        out = bytearray()
        while True:
            chunk = self._next()
            if chunk is None:
                break
            out += chunk
        return bytes(out)

    def _take(self, n: int) -> bytes | None:
        if len(self.buf) < n:
            return None
        chunk = bytes(self.buf[:n])
        del self.buf[:n]
        return chunk

    def _next(self) -> bytes | None:
        if self.stage == "version":
            chunk = self._take(12)
            if chunk is None:
                return None
            if not chunk.startswith(b"RFB 003."):
                raise Reject("bad version")
            digits = chunk[8:11]
            self.minor = int(digits) if digits.isdigit() else 8
            self.stage = "security" if self.minor >= 7 else "init"
            return chunk
        if self.stage == "security":
            chunk = self._take(1)
            if chunk is None:
                return None
            self.stage = "init"
            return chunk
        if self.stage == "init":
            chunk = self._take(1)
            if chunk is None:
                return None
            self.stage = "messages"
            return chunk
        if not self.buf:
            return None
        t = self.buf[0]
        size = self._size(t)
        if size is None:
            return None
        msg = self._take(size)
        if msg is None:
            return None
        return self._filter(t, msg)

    def _size(self, t: int) -> int | None:
        b = self.buf
        if t == 0:
            return 20
        if t == 2:
            return 4 + 4 * struct.unpack(">H", bytes(b[2:4]))[0] if len(b) >= 4 else None
        if t == 3:
            return 10
        if t == 4:
            return 8
        if t == 5:
            return 6
        if t == 6:
            # ClientCutText; comprimento negativo = Extended Clipboard (o noVNC o manda ao conectar): o corpo tem |comprimento| bytes
            return 8 + abs(struct.unpack(">i", bytes(b[4:8]))[0]) if len(b) >= 8 else None
        if t == 150:
            return 10
        if t == 248:  # ClientFence: type, pad[3], flags[4], len[1], payload
            return 9 + b[8] if len(b) >= 9 else None
        if t == 251:  # SetDesktopSize: type, pad, w, h, n, pad, n*16
            return 8 + 16 * b[6] if len(b) >= 8 else None
        raise Reject(f"unknown client message {t}")

    def _filter(self, t: int, msg: bytes) -> bytes:
        if self.trace is not None and len(self.trace) < 60:
            self.trace.append((t, len(msg)))
        return self._filter_inner(t, msg)

    def _filter_inner(self, t: int, msg: bytes) -> bytes:
        if t == 4:  # KeyEvent: down-flag, pad[2], keysym[4]
            down, keysym = msg[1], struct.unpack(">I", msg[4:8])[0]
            if not self.may_input():
                self.dropped_inputs += 1
                return b""
            (self.pressed.add if down else self.pressed.discard)(keysym)
            self.forwarded_inputs += 1
            return msg
        if t == 5:  # PointerEvent: mask, x[2], y[2]
            if not self.may_input():
                self.dropped_inputs += 1
                return b""
            self.buttons = msg[1]
            self.pointer = struct.unpack(">HH", msg[2:6])
            self.forwarded_inputs += 1
            return msg
        if t in (6, 251):  # clipboard e redimensionar nunca passam
            return b""
        return msg

    def release_all(self) -> bytes:
        """Mensagens para soltar o que ficou pressionado (teclas e botões do mouse)."""
        out = bytearray()
        for keysym in sorted(self.pressed):
            out += struct.pack(">BBHI", 4, 0, 0, keysym)
        if self.buttons:
            out += struct.pack(">BBHH", 5, 0, *self.pointer)
        self.pressed.clear()
        self.buttons = 0
        return bytes(out)


# ----- Ponte -------------------------------------------------------------------------------------------------------------
class VncBridge:
    def __init__(self, lease, tickets: Tickets, vnc_address=VNC_ADDRESS):
        self.lease = lease
        self.tickets = tickets
        self.vnc_address = vnc_address
        self.active: set[BridgeSession] = set()
        lease.listeners.append(self._lease_changed)

    def _lease_changed(self, state: str) -> None:
        if state != "human":
            for session in list(self.active):
                session.release_inputs()

    async def serve(self, reader, writer, target: str, headers: dict[str, str]) -> None:
        """Chamado pelo servidor HTTP quando `GET /v1/vnc` chega com `Upgrade: websocket`."""
        query = target.partition("?")[2]
        params = dict(p.partition("=")[::2] for p in query.split("&") if p)
        key = headers.get("sec-websocket-key")
        if "websocket" not in headers.get("upgrade", "").lower() or not key:
            await _plain(writer, 400, "websocket upgrade required")
            return
        if not self.tickets.redeem(params.get("ticket")):
            await _plain(writer, 401, "invalid or expired ticket")
            return
        try:
            vr, vw = await asyncio.wait_for(asyncio.open_connection(*self.vnc_address), 5)
        except (OSError, asyncio.TimeoutError):
            await _plain(writer, 503, "vnc server is not reachable")
            return
        protocols = [p.strip() for p in headers.get("sec-websocket-protocol", "").split(",") if p.strip()]
        extra = "Sec-WebSocket-Protocol: binary\r\n" if "binary" in protocols else ""
        writer.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                      f"Sec-WebSocket-Accept: {accept_key(key)}\r\n{extra}\r\n").encode())
        await writer.drain()
        session = BridgeSession(self, reader, writer, vr, vw)
        self.active.add(session)
        try:
            await session.run()
        finally:
            self.active.discard(session)


async def _plain(writer, status: int, message: str) -> None:
    data = message.encode()
    writer.write(f"HTTP/1.1 {status} X\r\nContent-Type: text/plain\r\nContent-Length: {len(data)}\r\nConnection: close\r\n\r\n".encode() + data)
    await writer.drain()


class BridgeSession:
    def __init__(self, bridge: VncBridge, reader, writer, vnc_reader, vnc_writer):
        self.bridge, self.reader, self.writer = bridge, reader, writer
        self.vr, self.vw = vnc_reader, vnc_writer
        self.filter = RfbClientFilter(lambda: bridge.lease.human_may_input)
        self.filter.trace = []  # só conta (os primeiros 60 tipos); nada de conteúdo
        self.bytes_down = 0


    def release_inputs(self) -> None:
        data = self.filter.release_all()
        if data and not self.vw.is_closing():
            self.vw.write(data)

    async def run(self) -> None:
        up = asyncio.ensure_future(self._client_to_vnc())
        down = asyncio.ensure_future(self._vnc_to_client())
        try:
            await asyncio.wait({up, down}, return_when=asyncio.FIRST_COMPLETED)
        finally:
            print(f"vnc: session ended; {self.bytes_down} bytes down; client messages {len(self.filter.trace or [])}+; "
                  f"inputs forwarded {self.filter.forwarded_inputs}, dropped {self.filter.dropped_inputs}", flush=True)
            self.release_inputs()
            for task in (up, down):
                task.cancel()
            for w in (self.vw, self.writer):
                try:
                    w.close()
                except Exception:
                    pass

    async def _client_to_vnc(self) -> None:
        message = bytearray()
        try:
            while True:
                opcode, fin, data = await read_frame(self.reader)
                if opcode == 8:
                    self.writer.write(encode_frame(b"", 8))
                    return
                if opcode == 9:
                    self.writer.write(encode_frame(data, 10))
                    await self.writer.drain()
                    continue
                if opcode == 10:
                    continue
                message += data
                if not fin:
                    continue
                payload, message = bytes(message), bytearray()
                out = self.filter.feed(payload)
                if out:
                    self.vw.write(out)
                    await self.vw.drain()
        except (asyncio.IncompleteReadError, ConnectionError, ValueError, Reject):
            return

    async def _vnc_to_client(self) -> None:
        try:
            while True:
                data = await self.vr.read(65536)
                if not data:
                    return
                self.bytes_down += len(data)
                self.writer.write(encode_frame(data))
                await self.writer.drain()
        except ConnectionError:
            return
