"""ULID (48 bits de tempo + 80 bits aleatórios, Crockford): mesmos ids do reqlog do egress."""
from __future__ import annotations

import os
import time

_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def new_ulid(now_ms: int | None = None, rand: bytes | None = None) -> str:
    ts = int(time.time() * 1000) if now_ms is None else now_ms
    value = (ts << 80) | int.from_bytes(rand if rand is not None else os.urandom(10), "big")
    out = []
    for _ in range(26):
        out.append(_ALPHABET[value & 31])
        value >>= 5
    return "".join(reversed(out))
