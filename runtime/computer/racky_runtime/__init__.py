"""Servidor de controle do papel `runtime` de um computador (07 §2.2, CS-190..193, CS-210..214).

Roda como uid 10001 dentro da rede interna do computador. Não publica porta: o app fala com ele pelo reverse proxy
autenticado do egress (`/runtime/v1/<op>`). Dirige o Chromium headed em Xvfb com Playwright; o CDP nunca sai do processo.
"""
API_VERSION = "2"
