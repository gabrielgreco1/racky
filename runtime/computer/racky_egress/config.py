"""Configuração do egress, lida de arquivos montados somente leitura (07 CS-145, CS-602). Nada de segredo em env ou argv.

`/run/racky/egress.json` (0400, dono do Mac) traz política e, se houver, o upstream com credenciais.
`/run/racky/token` traz o token do computador (admin API). `RACKY_EGRESS_DIR` troca o diretório (testes unitários).
"""
from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .github_gateway import GitHubAccess

DEFAULT_NOISE = (
    "accounts.google.com", "gvt1.com", "clients2.google.com", "update.googleapis.com", "safebrowsing.googleapis.com",
    "optimizationguide-pa.googleapis.com", "content-autofill.googleapis.com", "google-analytics.com",
    "googletagmanager.com", "doubleclick.net", "clarity.ms", "hotjar.com",
)


@dataclass
class Upstream:
    scheme: str  # http | https | socks5
    host: str
    port: int
    username: str | None = None
    password: str | None = None
    ca_file: str | None = None
    geo_country: str | None = None
    geo_mode: str = "suffix"  # suffix | header | host
    geo_template: str = "-country-{cc}"
    geo_header: str = "X-Country"

    def effective_username(self) -> str | None:
        if self.username is None:
            return None
        if self.geo_country and self.geo_mode == "suffix":
            return self.username + self.geo_template.format(cc=self.geo_country)
        return self.username

    def effective_host(self) -> str:
        if self.geo_country and self.geo_mode == "host":
            return self.geo_template.format(cc=self.geo_country, host=self.host)
        return self.host

    def secrets(self) -> list[str]:
        out = [self.password or "", self.username or "", self.effective_username() or ""]
        return [s for s in out if s]


@dataclass
class Render:
    """Modo API/render do provedor do proxy selecionado (07 CS-146). A chave só existe aqui (arquivo 0400 do egress)."""
    adapter: str  # zyte
    endpoint: str
    api_key: str
    cost_note: str | None = None


@dataclass
class Config:
    via: str = "direct"
    upstream: Upstream | None = None
    render: Render | None = None
    proxy_port: int = 3128
    admin_port: int = 8790
    internal_subnet: str | None = None
    bind: str | None = None  # só para testes/dev: endereço explícito do proxy
    allow_cidrs: list[str] = field(default_factory=list)
    allow_hosts: list[str] = field(default_factory=list)
    noise: list[str] = field(default_factory=lambda: list(DEFAULT_NOISE))
    extra_redact_headers: list[str] = field(default_factory=list)
    body_quota_bytes: int = 500 * 1024 * 1024
    logs_dir: str = "/run/racky/logs"
    # Gateway do GitHub (github_gateway.py): token e política. None = git/PR desligados neste computador.
    github: GitHubAccess | None = None

    @staticmethod
    def parse(data: dict[str, Any]) -> "Config":
        up = data.get("upstream")
        upstream = None
        if up:
            geo = up.get("geo") or {}
            upstream = Upstream(
                scheme=up["scheme"], host=up["host"], port=int(up["port"]), username=up.get("username"),
                password=up.get("password"), ca_file=up.get("ca_file"), geo_country=geo.get("country"),
                geo_mode=geo.get("mode", "suffix"), geo_template=geo.get("template", "-country-{cc}"),
                geo_header=geo.get("header", "X-Country"),
            )
            if upstream.scheme not in ("http", "https", "socks5"):
                raise ValueError(f"scheme de proxy inválido: {upstream.scheme}")
        rd = data.get("render")
        render = None
        if rd:
            render = Render(adapter=rd.get("adapter", "zyte"), endpoint=rd["endpoint"], api_key=rd["api_key"])
            if render.adapter != "zyte":
                raise ValueError(f"adaptador de render inválido: {render.adapter}")
        cfg = Config(
            via=data.get("via", "direct" if upstream is None else "proxy"), upstream=upstream, render=render,
            proxy_port=int(data.get("proxy_port", 3128)), admin_port=int(data.get("admin_port", 8790)),
            internal_subnet=data.get("internal_subnet"), bind=data.get("bind"),
            allow_cidrs=list(data.get("allow_cidrs", [])), allow_hosts=list(data.get("allow_hosts", [])),
            extra_redact_headers=list(data.get("extra_redact_headers", [])),
            body_quota_bytes=int(data.get("body_quota_bytes", 500 * 1024 * 1024)), logs_dir=data.get("logs_dir", "/run/racky/logs"),
        )
        if "noise" in data:
            cfg.noise = list(data["noise"])
        cfg.github = GitHubAccess.parse(data.get("github"))
        return cfg


def secrets_dir() -> Path:
    return Path(os.environ.get("RACKY_EGRESS_DIR", "/run/racky"))


def load_config(directory: Path | None = None, *, required: bool = False, retries: int = 15, delay: float = 0.2) -> Config:
    """Lê `egress.json`. Com `required` (reload), arquivo ausente é ERRO, nunca "config padrão": a troca de proxy não pode
    degradar em silêncio. Retenta porque o bind do host (virtiofs) pode demorar a enxergar o arquivo trocado."""
    base = directory or secrets_dir()
    path = base / "egress.json"
    for attempt in range(retries if required else 1):
        try:
            return Config.parse(json.loads(path.read_text()))
        except FileNotFoundError:
            if attempt + 1 < retries and required:
                time.sleep(delay)
                continue
            if required:
                raise
            return Config()
    return Config()


def load_token(directory: Path | None = None) -> str | None:
    path = (directory or secrets_dir()) / "token"
    if not path.exists():
        return None
    return path.read_text().strip() or None
