"""Encaminhador vsock -> admin API (só no runtime sem Docker, onde o computador é uma VM).

O app (no Mac) abre uma conexão vsock para a porta `RACKY_VSOCK_PORT` da VM; este processo a liga ao TCP `127.0.0.1:<admin>` do
próprio computador (a admin API, que também serve o reverse proxy do runtime e o túnel VNC). Assim a admin API pode escutar só em
loopback dentro da VM: nada na rede compartilhada da vmnet a alcança, e o Mac não precisa do IP da VM (nem da permissão de rede local).

Roda como `egress` (uid 10003), sem capacidades: AF_VSOCK não exige nenhuma. Cada conexão vira duas threads de cópia.
"""
from __future__ import annotations

import os
import socket
import sys
import threading

CHUNK = 64 * 1024


def pipe(source: socket.socket, sink: socket.socket) -> None:
    """Copia até o EOF de `source`; depois meio-fecha `sink` (a resposta do outro sentido continua)."""
    try:
        while True:
            data = source.recv(CHUNK)
            if not data:
                break
            sink.sendall(data)
    except OSError:
        pass
    finally:
        try:
            sink.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def handle(client: socket.socket, target: tuple[str, int]) -> None:
    try:
        upstream = socket.create_connection(target, timeout=5)
        upstream.settimeout(None)
    except OSError:
        client.close()
        return
    forward = threading.Thread(target=pipe, args=(client, upstream), daemon=True)
    forward.start()
    pipe(upstream, client)
    forward.join(timeout=2)
    client.close()
    upstream.close()


def serve(port: int, target_port: int) -> None:
    server = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    server.bind((socket.VMADDR_CID_ANY, port))
    server.listen(32)
    target = ("127.0.0.1", target_port)
    while True:
        client, _ = server.accept()
        threading.Thread(target=handle, args=(client, target), daemon=True).start()


def main() -> int:
    port = int(os.environ.get("RACKY_VSOCK_PORT", "0"))
    if not port:
        print("vsock: RACKY_VSOCK_PORT ausente; nada a encaminhar", file=sys.stderr, flush=True)
        return 0
    if not hasattr(socket, "AF_VSOCK"):
        print("vsock: este Python não tem AF_VSOCK", file=sys.stderr, flush=True)
        return 1
    serve(port, int(os.environ.get("RACKY_ADMIN_PORT", "8790")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
