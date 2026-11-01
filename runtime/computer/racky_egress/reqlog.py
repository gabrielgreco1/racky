"""Reqlog append-only do egress (07 CS-147, CS-149, CS-151, CS-608).

- `requests.jsonl`: uma linha por registro, com `prev_sha256` (hash da linha anterior, em bytes) encadeando o arquivo.
- `bodies/<id>.bin`: corpos limitados (requisição 64 KiB, resposta 2 MiB), só de conteúdo textual; quota por computador.
- Redação ANTES de gravar: headers sensíveis, parâmetros de query sensíveis, padrões de token e os valores secretos
  configurados (senha do proxy etc.). O log nunca contém o valor.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import threading
import time
from pathlib import Path
from typing import Any, Iterable, Mapping

REQUEST_BODY_LIMIT = 64 * 1024
RESPONSE_BODY_LIMIT = 2 * 1024 * 1024
DEFAULT_BODY_QUOTA = 500 * 1024 * 1024
REDACTED = "[redacted]"
GENESIS = "0" * 64

SENSITIVE_HEADERS = {
    "authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "x-auth-token",
    "x-csrf-token", "x-xsrf-token", "x-amz-security-token", "x-goog-api-key", "api-key", "apikey",
}
SENSITIVE_QUERY = re.compile(
    r"(?i)([?&;](?:[a-z0-9_.\-]*(?:token|secret|password|passwd|pwd|api[_-]?key|apikey|access[_-]?key|signature|sig|auth|session|key)"
    r"[a-z0-9_.\-]*)=)([^&#\s]*)"
)
TOKEN_PATTERNS = [
    re.compile(r"sk-ant-[A-Za-z0-9_\-]{8,}"),
    re.compile(r"sk-[A-Za-z0-9_\-]{16,}"),
    re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(r"github_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"xox[baprs]-[A-Za-z0-9\-]{10,}"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    # Bearer só com dígito ou 24+ caracteres: evita apagar prosa ("Bearer authentication"). Basic só vale em header (por nome).
    re.compile(r"(?i)\bBearer\s+(?:(?=[A-Za-z0-9._~+/=\-]*[0-9])[A-Za-z0-9._~+/=\-]{8,}|[A-Za-z0-9._~+/=\-]{24,})"),
    re.compile(r"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"),
]
TEXTUAL = ("text/", "application/json", "application/xml", "application/javascript", "application/x-www-form-urlencoded",
           "application/graphql", "application/ld+json", "application/xhtml", "+json", "+xml")

_ULID_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def new_ulid(now_ms: int | None = None, rand: bytes | None = None) -> str:
    """ULID: 48 bits de tempo + 80 bits aleatórios, 26 caracteres Crockford."""
    ts = int(time.time() * 1000) if now_ms is None else now_ms
    value = (ts << 80) | int.from_bytes(rand if rand is not None else os.urandom(10), "big")
    out = []
    for _ in range(26):
        out.append(_ULID_ALPHABET[value & 31])
        value >>= 5
    return "".join(reversed(out))


class Redactor:
    def __init__(self, secrets: Iterable[str] = (), extra_headers: Iterable[str] = ()):
        # valores curtos demais gerariam falso positivo em tudo
        self._secrets = sorted({s for s in secrets if s and len(s) >= 4}, key=len, reverse=True)
        self._headers = SENSITIVE_HEADERS | {h.lower() for h in extra_headers}

    def text(self, value: str) -> str:
        for secret in self._secrets:
            value = value.replace(secret, REDACTED)
        value = SENSITIVE_QUERY.sub(lambda m: m.group(1) + REDACTED, value)
        for pattern in TOKEN_PATTERNS:
            value = pattern.sub(REDACTED, value)
        return value

    def url(self, value: str) -> str:
        if "@" in value.split("?", 1)[0].split("//", 1)[-1].split("/", 1)[0]:  # user:pass@host
            scheme, sep, rest = value.partition("://")
            if sep:
                authority, slash, tail = rest.partition("/")
                value = f"{scheme}://{REDACTED}@{authority.rsplit('@', 1)[-1]}{slash}{tail}"
        return self.text(value)

    def headers(self, items: Iterable[tuple[str, str]]) -> list[list[str]]:
        out = []
        for name, value in items:
            out.append([name, REDACTED if name.lower() in self._headers else self.text(value)])
        return out

    def body(self, data: bytes) -> bytes:
        try:
            decoded = data.decode("utf-8")
        except UnicodeDecodeError:
            decoded = data.decode("latin-1")
        return self.text(decoded).encode("utf-8")


def is_textual(content_type: str | None) -> bool:
    if not content_type:
        return False
    ct = content_type.lower().split(";", 1)[0].strip()
    return any(ct.startswith(t) if t.endswith("/") else (t in ct) for t in TEXTUAL)


def sniff_text(data: bytes) -> bool:
    """Sem Content-Type: trata como texto se parece texto (UTF-8 válido, sem NUL, quase sem controle)."""
    sample = data[:4096]
    if not sample or b"\x00" in sample:
        return False
    try:
        text = sample.decode("utf-8")
    except UnicodeDecodeError as exc:
        if exc.start < len(sample) - 4:  # corte no meio de um caractere multibyte no fim da amostra é normal
            return False
        text = sample[: exc.start].decode("utf-8")
    controls = sum(1 for c in text if ord(c) < 32 and c not in "\r\n\t")
    return controls <= len(text) // 50


class ReqLog:
    """Escritor append-only. Uma instância por computador; thread-safe (o egress também grava de threads)."""

    def __init__(self, directory: Path, redactor: Redactor, body_quota: int = DEFAULT_BODY_QUOTA, clock=time.time):
        self.directory = Path(directory)
        self.bodies = self.directory / "bodies"
        self.bodies.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.file = self.directory / "requests.jsonl"
        self.redactor = redactor
        self.body_quota = body_quota
        self._clock = clock
        self._lock = threading.Lock()
        self._prev, self._count, self._body_bytes = self._recover()

    def _recover(self) -> tuple[str, int, int]:
        prev, count = GENESIS, 0
        if self.file.exists():
            with self.file.open("rb") as handle:
                for raw in handle:
                    if raw.strip():
                        prev = hashlib.sha256(raw.rstrip(b"\n")).hexdigest()
                        count += 1
        used = sum(p.stat().st_size for p in self.bodies.glob("*") if p.is_file())
        return prev, count, used

    @property
    def count(self) -> int:
        return self._count

    def write_body(self, record_id: str, kind: str, data: bytes, limit: int) -> dict[str, Any]:
        """Grava o corpo (redigido, truncado). Devolve campos a mesclar no registro."""
        if not data:
            return {}
        truncated = len(data) > limit
        clipped = self.redactor.body(data[:limit])
        with self._lock:
            if self._body_bytes + len(clipped) > self.body_quota:
                return {f"{kind}_body_dropped": "quota"}
            name = f"{record_id}.{kind}.txt"
            path = self.bodies / name
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as out:
                out.write(clipped)
            self._body_bytes += len(clipped)
        result: dict[str, Any] = {f"{kind}_body_file": f"bodies/{name}", f"{kind}_body_bytes": len(clipped)}
        if truncated:
            result[f"{kind}_body_truncated"] = True
        return result

    def append(self, record: Mapping[str, Any]) -> dict[str, Any]:
        rec = dict(record)
        rec.setdefault("id", new_ulid())
        rec.setdefault("ts", round(self._clock(), 3))
        with self._lock:
            rec["prev_sha256"] = self._prev
            line = json.dumps(rec, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
            fd = os.open(self.file, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            try:
                os.write(fd, line + b"\n")
            finally:
                os.close(fd)
            self._prev = hashlib.sha256(line).hexdigest()
            self._count += 1
        return rec

    def read(self, since_id: str | None = None, limit: int = 200) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        if not self.file.exists():
            return out
        everything: list[dict[str, Any]] = []
        with self.file.open("rb") as handle:
            for raw in handle:
                if raw.strip():
                    everything.append(json.loads(raw))
        if since_id is None:
            return everything[-limit:]
        # Ordem do ARQUIVO (não do id): registros do browser chegam ao fim da requisição com o ULID do começo dela.
        position = next((i for i, rec in enumerate(everything) if rec["id"] == since_id), None)
        if position is None:
            out = [rec for rec in everything if rec["id"] > since_id]
        else:
            out = everything[position + 1:]
        return out[:limit]

    def body_path(self, relative: str) -> Path | None:
        path = (self.directory / relative).resolve()
        if self.bodies.resolve() not in path.parents or not path.is_file():
            return None
        return path


def verify_chain(file: Path) -> tuple[bool, int | None]:
    """`(True, None)` se a cadeia está íntegra; `(False, n)` com a linha (1-based) onde ela quebra."""
    prev = GENESIS
    with Path(file).open("rb") as handle:
        for number, raw in enumerate(handle, start=1):
            line = raw.rstrip(b"\n")
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                return False, number
            if rec.get("prev_sha256") != prev:
                return False, number
            prev = hashlib.sha256(line).hexdigest()
    return True, None
