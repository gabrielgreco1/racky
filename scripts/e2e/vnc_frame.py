#!/usr/bin/env python3
"""vnc_frame.py - um quadro de verdade pelo VNC do computador (e2e passo 4).

Roda DENTRO do container (`docker exec -i <c> python3 - < vnc_frame.py`): o x11vnc só escuta em loopback. Faz o handshake RFB
(sem senha: o x11vnc é `-nopw` e nunca sai do container), pede um FramebufferUpdate completo em Raw e escreve um PNG em stdout;
largura, altura e nome do desktop vão em JSON no stderr. Sai com 1 se o quadro vier vazio (um preto liso conta como falha).
"""
import json
import socket
import struct
import sys
import zlib


def read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("VNC closed")
        buf += chunk
    return buf


def png(width, height, rgb):
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + rgb[y * width * 3:(y + 1) * width * 3] for y in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def main():
    s = socket.create_connection(("127.0.0.1", 5900), timeout=20)
    banner = read_exact(s, 12)
    s.sendall(b"RFB 003.008\n")
    count = read_exact(s, 1)[0]
    types = list(read_exact(s, count))
    if 1 not in types:
        raise SystemExit(f"VNC pede autenticação (tipos {types})")
    s.sendall(b"\x01")
    if struct.unpack(">I", read_exact(s, 4))[0] != 0:
        raise SystemExit("VNC recusou o handshake")
    s.sendall(b"\x01")  # ClientInit: shared
    width, height = struct.unpack(">HH", read_exact(s, 4))
    read_exact(s, 16)  # pixel format do servidor (a gente impõe o nosso)
    name = read_exact(s, struct.unpack(">I", read_exact(s, 4))[0]).decode("utf-8", "replace")
    # 32 bpp, little-endian, true colour, R<<16 G<<8 B
    s.sendall(struct.pack(">BxxxBBBBHHHBBBxxx", 0, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0))
    s.sendall(struct.pack(">BxHi", 2, 1, 0))  # SetEncodings: Raw
    s.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, width, height))
    rgb = bytearray(width * height * 3)
    filled = 0
    while filled < width * height:
        mtype = read_exact(s, 1)[0]
        if mtype != 0:
            raise SystemExit(f"mensagem VNC inesperada {mtype}")
        read_exact(s, 1)
        for _ in range(struct.unpack(">H", read_exact(s, 2))[0]):
            x, y, w, h, enc = struct.unpack(">HHHHi", read_exact(s, 12))
            if enc != 0:
                raise SystemExit(f"encoding {enc} inesperado")
            data = read_exact(s, w * h * 4)
            for row in range(h):
                base = row * w * 4
                out = ((y + row) * width + x) * 3
                line = data[base:base + w * 4]
                rgb[out:out + w * 3:3] = line[2::4]
                rgb[out + 1:out + w * 3:3] = line[1::4]
                rgb[out + 2:out + w * 3:3] = line[0::4]
            filled += w * h
    distinct = len(set(bytes(rgb[i:i + 3]) for i in range(0, len(rgb) - 2, 3 * 997)))
    sys.stderr.write(json.dumps({"width": width, "height": height, "name": name, "rfb": banner.decode().strip(), "sampled_colors": distinct}) + "\n")
    sys.stdout.buffer.write(png(width, height, bytes(rgb)))
    sys.stdout.buffer.flush()
    if distinct < 2:
        raise SystemExit("quadro liso (nenhuma variação de cor)")


main()
