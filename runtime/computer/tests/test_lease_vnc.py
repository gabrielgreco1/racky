"""Lease humano (CS-410..414), ticket e ponte VNC (CS-401/402) sem Docker: x11vnc é um servidor falso que grava o que recebe."""
import asyncio
import base64
import json
import os
import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from racky_runtime.browser import OpError  # noqa: E402
from racky_runtime.lease import Lease  # noqa: E402
from racky_runtime.server import RuntimeServer  # noqa: E402
from racky_runtime.vnc import RfbClientFilter, Reject, Tickets, VncBridge, accept_key, encode_frame, read_frame  # noqa: E402

TOKEN = "runtime-token-0123456789abcdef"


def key(down, keysym):
    return struct.pack(">BBHI", 4, down, 0, keysym)


def pointer(mask, x, y):
    return struct.pack(">BBHH", 5, mask, x, y)


def cut_text(text: bytes):
    return struct.pack(">BxxxI", 6, len(text)) + text


def update_request():
    return struct.pack(">BBHHHH", 3, 1, 0, 0, 100, 100)


HANDSHAKE = b"RFB 003.008\n" + b"\x01" + b"\x01"


class LeaseTests(unittest.IsolatedAsyncioTestCase):
    async def test_agent_by_default_and_gate_refuses_when_not_agent(self):
        lease = Lease(asyncio.Lock())
        lease.gate()
        await lease.take()
        with self.assertRaises(OpError) as ctx:
            lease.gate()
        self.assertEqual((ctx.exception.code, ctx.exception.status), ("human_in_control", 409))
        self.assertEqual(ctx.exception.details["retry_after_s"], 5)

    async def test_take_over_waits_for_the_write_in_flight_then_acks(self):
        lock = asyncio.Lock()
        lease = Lease(lock)
        finished = []

        async def slow(a):
            await asyncio.sleep(0.3)
            finished.append(True)
            return {"ok": True}

        write = asyncio.ensure_future(lease.run_write(slow, {}))
        await asyncio.sleep(0.05)
        started = asyncio.get_running_loop().time()
        result = await lease.take(wait_s=5)
        waited = asyncio.get_running_loop().time() - started
        self.assertTrue(result["ack"] and result["lease"] == "human")
        self.assertTrue(finished, "the write in progress had to finish first")
        self.assertGreaterEqual(waited, 0.2)
        with self.assertRaises(OpError) as ctx:  # CA-402: a chamada em curso termina e o agente recebe human_in_control
            await write
        self.assertEqual(ctx.exception.code, "human_in_control")
        self.assertEqual(ctx.exception.details["completed_result"], {"ok": True})  # nada se perde
        self.assertEqual(lease.state, "human")  # e o lease não volta para o agente

    async def test_take_over_without_ack_stays_revoking_and_refuses_new_writes(self):
        lease = Lease(asyncio.Lock())

        async def very_slow(a):
            await asyncio.sleep(2)

        write = asyncio.ensure_future(lease.run_write(very_slow, {}))
        await asyncio.sleep(0.05)
        result = await lease.take(wait_s=0.1)
        self.assertFalse(result["ack"])
        self.assertEqual(lease.state, "revoking")
        with self.assertRaises(OpError):
            await lease.run_write(very_slow, {})
        forced = await lease.take(wait_s=2, force=True)  # Force Take Over cancela a escrita em curso
        self.assertTrue(forced["ack"] and lease.state == "human")
        with self.assertRaises(OpError) as ctx:
            await write
        self.assertEqual(ctx.exception.code, "human_in_control")

    async def test_queued_writes_do_not_run_after_the_human_took_over(self):
        lease = Lease(asyncio.Lock())
        ran = []

        async def first(a):
            await asyncio.sleep(0.2)

        async def queued(a):
            ran.append(True)

        w1 = asyncio.ensure_future(lease.run_write(first, {}))
        await asyncio.sleep(0.02)
        w2 = asyncio.ensure_future(lease.run_write(queued, {}))
        await asyncio.sleep(0.02)
        await lease.take(wait_s=3)
        with self.assertRaises(OpError):  # a que estava em curso termina, mas o agente recebe human_in_control (CA-402)
            await w1
        with self.assertRaises(OpError):
            await w2
        self.assertEqual(ran, [])

    async def test_a_failing_agent_write_does_not_change_the_lease(self):
        lease = Lease(asyncio.Lock())

        async def bad(a):
            raise OpError("timeout", "selector not found", 408)

        with self.assertRaises(OpError):
            await lease.run_write(bad, {})
        self.assertEqual(lease.state, "agent")
        await lease.take()
        with self.assertRaises(OpError):
            await lease.run_write(bad, {})  # com o humano no controle, o erro continua sendo o do lease
        self.assertEqual(lease.state, "human")

    async def test_hand_back_keeps_the_note_until_consumed_and_notifies_listeners(self):
        lease = Lease(asyncio.Lock())
        seen = []
        lease.listeners.append(seen.append)
        await lease.take()
        lease.give("  Signed in, continue from page 3  ")
        self.assertEqual(lease.state, "agent")
        self.assertEqual(seen, ["revoking", "human", "agent"])
        self.assertEqual(lease.snapshot()["note"], "Signed in, continue from page 3")
        self.assertEqual(lease.consume_note()["note"], "Signed in, continue from page 3")
        self.assertIsNone(lease.consume_note()["note"])

    async def test_a_new_take_over_clears_the_previous_note(self):
        lease = Lease(asyncio.Lock())
        await lease.take()
        lease.give("old")
        await lease.take()
        self.assertIsNone(lease.snapshot()["note"])


class FilterTests(unittest.TestCase):
    def make(self, human=False):
        state = {"human": human}
        return RfbClientFilter(lambda: state["human"]), state

    def test_handshake_passes_and_view_only_drops_key_and_pointer(self):
        f, _ = self.make()
        out = f.feed(HANDSHAKE + update_request() + key(1, 0x61) + pointer(1, 5, 5) + key(0, 0x61))
        self.assertEqual(out, HANDSHAKE + update_request())
        self.assertEqual((f.dropped_inputs, f.forwarded_inputs), (3, 0))

    def test_human_lease_forwards_input_and_tracks_pressed_keys(self):
        f, state = self.make(human=True)
        out = f.feed(HANDSHAKE + key(1, 0xE7) + pointer(1, 10, 20))  # ç
        self.assertEqual(out, HANDSHAKE + key(1, 0xE7) + pointer(1, 10, 20))
        self.assertEqual(f.pressed, {0xE7})
        release = f.release_all()
        self.assertEqual(release, key(0, 0xE7) + pointer(0, 10, 20))
        self.assertFalse(f.pressed or f.buttons)

    def test_lease_is_read_at_forward_time(self):
        f, state = self.make(human=True)
        f.feed(HANDSHAKE)
        self.assertEqual(f.feed(key(1, 0x61)), key(1, 0x61))
        state["human"] = False
        self.assertEqual(f.feed(key(0, 0x61)), b"")

    def test_clipboard_and_resize_never_pass_even_for_the_human(self):
        f, _ = self.make(human=True)
        f.feed(HANDSHAKE)
        self.assertEqual(f.feed(cut_text(b"secret from the mac")), b"")
        self.assertEqual(f.feed(struct.pack(">BxHHBx", 251, 800, 600, 0)), b"")

    def test_extended_clipboard_with_negative_length_is_consumed_and_dropped(self):
        # o noVNC manda, ao conectar, um ClientCutText com comprimento negativo (Extended Clipboard); travar nele paralisava o stream
        f, _ = self.make(human=True)
        f.feed(HANDSHAKE)
        body = struct.pack(">II", 0x01000003, 0x000000F0)  # flags + capacidades
        extended = struct.pack(">Bxxxi", 6, -len(body)) + body
        self.assertEqual(f.feed(extended[:5]), b"")  # parcial: espera
        self.assertEqual(f.feed(extended[5:] + key(1, 0x61)), key(1, 0x61))  # engole a mensagem e segue para a próxima
        self.assertEqual(f.feed(update_request()), update_request())

    def test_messages_split_across_frames_are_reassembled(self):
        f, _ = self.make(human=True)
        data = HANDSHAKE + key(1, 0x41) + struct.pack(">BxH", 2, 2) + struct.pack(">ii", 0, 7)
        out = b"".join(f.feed(data[i:i + 3]) for i in range(0, len(data), 3))
        self.assertEqual(out, data)

    def test_unknown_message_closes_the_connection(self):
        f, _ = self.make(human=True)
        f.feed(HANDSHAKE)
        with self.assertRaises(Reject):
            f.feed(bytes([99, 0, 0, 0]))
        g, _ = self.make()
        with self.assertRaises(Reject):
            g.feed(b"GET / HTTP/1.1")


class TicketTests(unittest.TestCase):
    def test_single_use_and_expiry(self):
        now = [100.0]
        tickets = Tickets(clock=lambda: now[0])
        issued = tickets.issue()
        self.assertEqual(issued["expires_in"], 60)
        self.assertTrue(tickets.redeem(issued["ticket"]))
        self.assertFalse(tickets.redeem(issued["ticket"]))  # uso único
        late = tickets.issue()["ticket"]
        now[0] += 61
        self.assertFalse(tickets.redeem(late))
        self.assertFalse(tickets.redeem(None))
        self.assertFalse(tickets.redeem("made-up"))

    def test_rfc6455_accept_key(self):
        self.assertEqual(accept_key("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")


class FakeVnc:
    """Servidor RFB falso: manda a versão, aceita o handshake e grava tudo o que o cliente manda depois."""

    def __init__(self):
        self.received = bytearray()
        self.connections = 0
        self.server = None
        self.writers = []

    async def start(self):
        self.server = await asyncio.start_server(self.handle, "127.0.0.1", 0)
        return self.server.sockets[0].getsockname()[1]

    async def handle(self, reader, writer):
        self.connections += 1
        self.writers.append(writer)
        writer.write(b"RFB 003.008\n")
        await writer.drain()
        try:
            while True:
                data = await reader.read(4096)
                if not data:
                    return
                self.received += data
                if len(self.received) == len(HANDSHAKE):  # responde ao handshake com um "frame" qualquer
                    writer.write(b"\x00\x00\x00\x00frame-1")
                    await writer.drain()
        except ConnectionError:
            pass


class BrokenBrowser:
    ready = True

    def __init__(self):
        self.write_lock = asyncio.Lock()

    async def open(self, a):
        await asyncio.sleep(a.get("sleep", 0))
        return {"ok": True}

    async def status(self, a):
        return {"ready": True}


class Display:
    mode = "headless"


async def ws_connect(port, ticket, protocols="binary"):
    r, w = await asyncio.open_connection("127.0.0.1", port)
    k = base64.b64encode(os.urandom(16)).decode()
    w.write((f"GET /v1/vnc?ticket={ticket} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
             f"Sec-WebSocket-Key: {k}\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: {protocols}\r\n\r\n").encode())
    await w.drain()
    head = await asyncio.wait_for(r.readuntil(b"\r\n\r\n"), 5)
    return r, w, head, k


def client_frame(payload: bytes) -> bytes:
    mask = os.urandom(4)
    n = len(payload)
    head = bytes([0x82]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n))
    return head + mask + bytes(b ^ mask[i & 3] for i, b in enumerate(payload))


async def http_post(port, path, payload):
    r, w = await asyncio.open_connection("127.0.0.1", port)
    body = json.dumps(payload).encode()
    w.write(f"POST {path} HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer {TOKEN}\r\nContent-Length: {len(body)}\r\n\r\n".encode() + body)
    await w.drain()
    data = await asyncio.wait_for(r.read(), 10)
    w.close()
    head, _, rest = data.partition(b"\r\n\r\n")
    return int(head.split()[1]), json.loads(rest)


class BridgeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.vnc = FakeVnc()
        vnc_port = await self.vnc.start()
        self.browser = BrokenBrowser()
        self.server = RuntimeServer(self.browser, TOKEN, Display())
        self.server.bridge.vnc_address = ("127.0.0.1", vnc_port)
        self.listener = await asyncio.start_server(self.server.handle, "127.0.0.1", 0)
        self.port = self.listener.sockets[0].getsockname()[1]

    async def asyncTearDown(self):
        self.listener.close()
        self.vnc.server.close()

    async def ticket(self):
        status, payload = await http_post(self.port, "/v1/vnc_ticket", {})
        self.assertEqual(status, 200)
        return payload["ticket"]

    async def test_ticket_is_required_and_single_use(self):
        r, w, head, _ = await ws_connect(self.port, "nope")
        self.assertIn(b"401", head.split(b"\r\n")[0])
        w.close()
        ticket = await self.ticket()
        r, w, head, _ = await ws_connect(self.port, ticket)
        self.assertIn(b"101", head.split(b"\r\n")[0])
        self.assertIn(b"Sec-WebSocket-Protocol: binary", head)
        w.close()
        r2, w2, head2, _ = await ws_connect(self.port, ticket)
        self.assertIn(b"401", head2.split(b"\r\n")[0])
        w2.close()

    async def test_vnc_ticket_needs_the_token(self):
        r, w = await asyncio.open_connection("127.0.0.1", self.port)
        w.write(b"POST /v1/vnc_ticket HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n")
        await w.drain()
        self.assertIn(b"401", (await r.read())[:20])
        w.close()

    async def test_view_only_until_take_over_then_input_flows_and_keys_are_released_on_close(self):
        r, w, head, _ = await ws_connect(self.port, await self.ticket())
        opcode, _, data = await read_frame_server(r)
        self.assertEqual(data, b"RFB 003.008\n")  # a versão do servidor chega ao cliente por frames binários
        w.write(client_frame(HANDSHAKE))
        opcode, _, data = await read_frame_server(r)
        self.assertEqual(data, b"\x00\x00\x00\x00frame-1")
        # agente no controle: view-only
        w.write(client_frame(update_request() + key(1, 0x61) + pointer(1, 3, 4)))
        await w.drain()
        await asyncio.sleep(0.2)
        self.assertEqual(bytes(self.vnc.received), HANDSHAKE + update_request())
        # Take Over (pelo mesmo caminho HTTP do app) libera o input
        status, payload = await http_post(self.port, "/v1/lease", {"action": "take"})
        self.assertEqual((status, payload["lease"], payload["ack"]), (200, "human", True))
        w.write(client_frame(key(1, 0xE7) + key(0, 0xE7) + key(1, 0xE3)))  # ç ã (ã fica pressionada)
        await w.drain()
        await asyncio.sleep(0.2)
        self.assertEqual(bytes(self.vnc.received), HANDSHAKE + update_request() + key(1, 0xE7) + key(0, 0xE7) + key(1, 0xE3))
        # Hand Back com a tecla ainda pressionada: o runtime a solta no x11vnc
        status, payload = await http_post(self.port, "/v1/lease", {"action": "give", "note": "done"})
        self.assertEqual(payload["lease"], "agent")
        await asyncio.sleep(0.2)
        self.assertTrue(bytes(self.vnc.received).endswith(key(0, 0xE3)))
        w.close()

    async def test_agent_writes_get_human_in_control_while_the_human_drives(self):
        await http_post(self.port, "/v1/lease", {"action": "take"})
        status, payload = await http_post(self.port, "/v1/open", {"url": "http://x/"})
        self.assertEqual((status, payload["error"]), (409, "human_in_control"))
        self.assertEqual(payload["details"]["retry_after_s"], 5)
        status, payload = await http_post(self.port, "/v1/status", {})  # leituras continuam
        self.assertEqual((status, payload["lease"]), (200, "human"))
        await http_post(self.port, "/v1/lease", {"action": "give", "note": "hi"})
        self.assertEqual((await http_post(self.port, "/v1/open", {"url": "http://x/"}))[0], 200)
        self.assertEqual((await http_post(self.port, "/v1/lease", {"action": "consume_note"}))[1]["note"], "hi")

    async def test_take_over_during_a_long_write_acks_after_it_and_the_write_completes(self):
        write = asyncio.ensure_future(http_post(self.port, "/v1/open", {"url": "http://x/", "sleep": 0.5}))
        await asyncio.sleep(0.1)
        started = asyncio.get_running_loop().time()
        status, payload = await http_post(self.port, "/v1/lease", {"action": "take"})
        self.assertTrue(payload["ack"])
        self.assertGreaterEqual(asyncio.get_running_loop().time() - started, 0.3)
        status, payload = await write  # CA-402: a chamada do agente termina com human_in_control e o lease não volta para ele
        self.assertEqual((status, payload["error"], payload["details"]["completed"]), (409, "human_in_control", True))
        self.assertEqual((await http_post(self.port, "/v1/lease", {"action": "status"}))[1]["lease"], "human")

    async def test_invalid_lease_action(self):
        status, payload = await http_post(self.port, "/v1/lease", {"action": "steal"})
        self.assertEqual((status, payload["error"]), (400, "invalid_argument"))


async def read_frame_server(reader):
    """Lê um frame do servidor (sem máscara)."""
    b1, b2 = await asyncio.wait_for(reader.readexactly(2), 5)
    n = b2 & 0x7F
    if n == 126:
        n = struct.unpack(">H", await reader.readexactly(2))[0]
    elif n == 127:
        n = struct.unpack(">Q", await reader.readexactly(8))[0]
    return b1 & 0x0F, bool(b1 & 0x80), await reader.readexactly(n)


if __name__ == "__main__":
    unittest.main()
