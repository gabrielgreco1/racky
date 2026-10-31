"""HEALTHCHECK da imagem: a admin API responde. Não lê a config (os segredos são do usuário `egress`); a porta é a padrão."""
import os
import sys
import urllib.request

try:
    port = int(os.environ.get("RACKY_ADMIN_PORT", "8790"))
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/v1/health", timeout=2) as r:
        sys.exit(0 if r.status == 200 else 1)
except Exception:
    sys.exit(1)
