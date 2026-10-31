import os
import socket
import sys
import threading
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from racky_supervisor import vsock  # noqa: E402


def echo_server() -> tuple[socket.socket, int]:
    """Servidor TCP em loopback que responde `echo:` + o que recebeu, até o EOF do cliente."""
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.bind(("127.0.0.1", 0))
    server.listen(1)

    def serve() -> None:
        conn, _ = server.accept()
        data = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            data += chunk
        conn.sendall(b"echo:" + data)
        conn.close()

    threading.Thread(target=serve, daemon=True).start()
    return server, server.getsockname()[1]


class VsockForwarder(unittest.TestCase):
    def test_bytes_flow_both_ways_and_half_close_keeps_the_reply(self):
        server, port = echo_server()
        client, inner = socket.socketpair()  # `inner` faz o papel da conexão vsock aceita
        worker = threading.Thread(target=vsock.handle, args=(inner, ("127.0.0.1", port)), daemon=True)
        worker.start()
        client.sendall(b"GET /v1/health HTTP/1.1\r\n\r\n")
        client.shutdown(socket.SHUT_WR)  # o cliente terminou de enviar, mas ainda lê a resposta
        reply = b""
        while True:
            chunk = client.recv(4096)
            if not chunk:
                break
            reply += chunk
        self.assertEqual(reply, b"echo:GET /v1/health HTTP/1.1\r\n\r\n")
        worker.join(timeout=5)
        client.close()
        server.close()

    def test_a_dead_target_closes_the_client(self):
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()  # ninguém escuta nessa porta
        client, inner = socket.socketpair()
        vsock.handle(inner, ("127.0.0.1", port))
        self.assertEqual(client.recv(10), b"")
        client.close()

    def test_without_a_port_there_is_nothing_to_forward(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("RACKY_VSOCK_PORT", None)
            self.assertEqual(vsock.main(), 0)


class SupervisorWiring(unittest.TestCase):
    def test_vsock_service_runs_unprivileged_and_the_env_reaches_only_egress_services(self):
        from racky_supervisor import __main__ as supervisor

        with mock.patch.dict(os.environ, {"RACKY_VSOCK_PORT": "8791", "RACKY_ADMIN_BIND": "127.0.0.1"}):
            self.assertEqual(supervisor.service_env("vsock")["RACKY_VSOCK_PORT"], "8791")
            self.assertEqual(supervisor.service_env("egress")["RACKY_ADMIN_BIND"], "127.0.0.1")
            self.assertNotIn("RACKY_VSOCK_PORT", supervisor.service_env("runtime"))
        # Sem a variável (modo Docker), nada muda no ambiente dos serviços.
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("RACKY_VSOCK_PORT", None)
            os.environ.pop("RACKY_ADMIN_BIND", None)
            self.assertNotIn("RACKY_VSOCK_PORT", supervisor.service_env("egress"))

    def test_vsock_command_drops_every_capability(self):
        from racky_supervisor import __main__ as supervisor

        with mock.patch.object(supervisor.pwd, "getpwnam", return_value=mock.Mock(pw_uid=10003, pw_gid=10003)):
            cmd = supervisor.command("vsock")
        self.assertIn("--reuid=10003", cmd)
        self.assertIn("--ambient-caps=-all", cmd)
        self.assertEqual(cmd[-3:], ["python", "-m", "racky_supervisor.vsock"])


if __name__ == "__main__":
    unittest.main()
