# racky-computer: a imagem ÚNICA de um computador (07 §2, decisão P24). Um container por computador:
#   - Xvfb + x11vnc (só loopback) + Chromium headed + servidor de controle (`racky_runtime`)  -> eram o papel `runtime`;
#   - utilitários de trabalho (`abx-http` com curl_cffi, requests, lxml, ...)                    -> eram o papel `work`;
#   - proxy/egress com filtro SSRF, reqlog, contadores e admin API (`racky_egress`)           -> era o sidecar `egress`.
#
# Isolamento interno (o que substitui a separação em três containers):
#   - `agent` (uid 10001): comandos do agente (docker exec -u agent), Chromium, Xvfb, x11vnc, openbox. Sem privilégio.
#   - `egress` (uid 10003): proxy, reqlog, contadores, segredos (/run/racky, tmpfs 0700) e o servidor de controle.
#   - iptables por uid (owner match): todo tráfego do `agent` sai só pelo proxy em 127.0.0.1:3128 (ver racky_supervisor/firewall.py).
#   - o supervisor (root) só tem NET_ADMIN, SETUID, SETGID, SETPCAP e KILL; cada serviço sobe com o conjunto reduzido por `setpriv`.
#
# Reprodutibilidade (08 AR-114): base fixada por DIGEST (a tag é só legenda); pacotes Python com versão exata em requirements.txt;
# nenhum pin de versão de apt (somem dos espelhos): a imagem é identificada pela tag de hash do contexto (racky-computer:ctx-<sha12>).
FROM mcr.microsoft.com/playwright/python:v1.63.0-noble@sha256:72bd171a9ffc2b4b59532aaa6210e21014d07093120dc25528870c0b840da1f0

ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        xvfb openbox tint2 x11vnc xdotool curl jq ca-certificates iptables \
        git postgresql postgresql-contrib \
    && rm -rf /var/lib/apt/lists/* \
    # O pacote sobe um cluster de serviço que o computador não usa: os smokes criam o próprio banco descartável com initdb.
    && rm -rf /var/lib/postgresql/*/main /etc/postgresql/*/main \
    && for b in initdb pg_ctl postgres pg_isready createdb psql; do ln -sf /usr/lib/postgresql/*/bin/$b /usr/local/bin/$b; done \
    && ln -sf /opt/racky/bin/racky-pr /usr/local/bin/racky-pr

COPY requirements.txt /tmp/requirements.txt
# --ignore-installed: o typing_extensions da base veio do apt (sem RECORD) e o pip não consegue desinstalá-lo.
RUN python -m pip install --ignore-installed -r /tmp/requirements.txt && rm -f /tmp/requirements.txt

RUN useradd --uid 10001 --create-home --home-dir /home/agent --shell /bin/bash agent \
    && useradd --uid 10003 --no-create-home --home-dir /run/racky --shell /usr/sbin/nologin egress \
    && mkdir -p /opt/racky/bin /work /profile \
    && chown agent:agent /profile \
    && chmod 0755 /work

# Sem `COPY --chmod`: sintaxe só do BuildKit; o contexto também precisa buildar pelo builder clássico da Engine API.
COPY racky_runtime /opt/racky/racky_runtime
COPY racky_egress /opt/racky/racky_egress
COPY racky_supervisor /opt/racky/racky_supervisor
COPY bin/abx-http bin/abx-chromium bin/abx-provision bin/racky-pr /opt/racky/bin/
# Git dentro do computador: sai pelo proxy do egress e https://github.com/ vira o gateway (github_gateway.py), que põe o token e
# aplica a política (repositórios da sessão, push só em feat/*). O agente nunca vê o token.
COPY gitconfig /etc/gitconfig
RUN chmod 0755 /opt/racky/bin/abx-http /opt/racky/bin/abx-chromium /opt/racky/bin/abx-provision /opt/racky/bin/racky-pr \
    && chmod -R go-w /opt/racky

# initdb/pg_ctl no PATH (o smoke cria o próprio cluster); uv instala no HOME do agente.
ENV PYTHONPATH=/opt/racky PATH=/opt/racky/bin:/usr/lib/postgresql/16/bin:$PATH DISPLAY=:99 HOME=/home/agent \
    HTTP_PROXY=http://127.0.0.1:3128 HTTPS_PROXY=http://127.0.0.1:3128 NO_PROXY=127.0.0.1,localhost
WORKDIR /work

EXPOSE 8790
HEALTHCHECK --interval=5s --timeout=3s --start-period=3s --retries=5 \
    CMD ["python", "-m", "racky_egress.healthcheck"]
ENTRYPOINT ["python", "-m", "racky_supervisor"]
