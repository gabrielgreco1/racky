"""PID 1 lógico do computador (o `docker --init` é o PID 1 real). Roda como root com poucas capacidades (NET_ADMIN, SETUID,
SETGID, SETPCAP, KILL) e faz, nesta ordem:

1. instala as regras de rede por uid (firewall.py). Falhou = o container sai (fail closed: sem regra não há computador);
2. sobe os serviços já sem privilégio e com o conjunto de capacidades REDUZIDO por `setpriv`:
   - `egress` (uid 10003): proxy + reqlog + contadores + admin API, sem nenhuma capacidade;
   - `vsock` (uid 10003, só no runtime sem Docker, quando `RACKY_VSOCK_PORT` existe): encaminha vsock -> admin API em loopback;
   - `runtime` (uid 10003): servidor de controle do browser; só mantém CAP_SETUID/SETGID (ambiente) para largar o privilégio
     e iniciar Xvfb, x11vnc, openbox e o Chromium como `agent`, que é quem os possui;
3. supervisiona: reinicia o serviço que cair (com espera crescente) e repassa SIGTERM/SIGINT.

Depois do passo 2 o próprio supervisor não executa nada do agente. Os comandos do agente (`docker exec -u agent`) rodam com
`no-new-privileges` e sem capacidades efetivas.
"""
from __future__ import annotations

import os
import pwd
import shutil
import signal
import subprocess
import sys
import time

from . import firewall

AGENT = os.environ.get("RACKY_AGENT_USER", "agent")
EGRESS = os.environ.get("RACKY_EGRESS_USER", "egress")
SECRETS = "/run/racky"
DROP_ALL = ["--bounding-set=-all", "--inh-caps=-all", "--ambient-caps=-all"]


def install_firewall() -> None:
    uid = pwd.getpwnam(AGENT).pw_uid
    for binary, v6 in (("iptables", False), ("ip6tables", True)):
        exe = shutil.which(binary)
        if exe is None:
            if v6:
                continue  # sem ip6tables o container também não tem IPv6 útil
            raise SystemExit("firewall: iptables ausente; recusando subir")
        for rule in firewall.rules(uid, ipv6=v6):
            result = subprocess.run([exe, *rule], capture_output=True, text=True)
            if result.returncode != 0:
                if v6:
                    print(f"firewall: ip6tables falhou ({result.stderr.strip()}); IPv6 desabilitado no container", flush=True)
                    break
                raise SystemExit(f"firewall: {binary} {' '.join(rule)} falhou: {result.stderr.strip()}")


def service_env(name: str) -> dict[str, str]:
    """Ambiente explícito de cada serviço: SEM as variáveis de proxy do agente (o egress não pode sair por si mesmo)."""
    env = {"PATH": "/opt/racky/bin:/usr/local/bin:/usr/bin:/bin", "PYTHONPATH": "/opt/racky", "PYTHONUNBUFFERED": "1",
           "PYTHONDONTWRITEBYTECODE": "1", "HOME": SECRETS, "DISPLAY": os.environ.get("DISPLAY", ":99"),
           "PLAYWRIGHT_BROWSERS_PATH": os.environ.get("PLAYWRIGHT_BROWSERS_PATH", "/ms-playwright")}
    # Fuso e idioma do Mac (F42): o Chromium herda `TZ` e lê `RACKY_LOCALE`; um navegador em UTC/en-US num IP do Brasil é
    # um sinal de bot.
    for key in ("TZ", "RACKY_LOCALE"):
        if os.environ.get(key):
            env[key] = os.environ[key]
    if name == "runtime":
        env["RACKY_PROFILE_DIR"] = "/profile"
    # Runtime sem Docker (VM): admin API só em loopback e o encaminhador vsock (o app chega nela pelo vsock, não pelo IP da VM).
    for key in ("RACKY_ADMIN_BIND", "RACKY_VSOCK_PORT", "RACKY_ADMIN_PORT"):
        if os.environ.get(key) and name in ("egress", "vsock"):
            env[key] = os.environ[key]
    return env


def command(name: str) -> list[str]:
    egress = pwd.getpwnam(EGRESS)
    base = ["setpriv", f"--reuid={egress.pw_uid}", f"--regid={egress.pw_gid}", "--clear-groups", "--no-new-privs"]
    if name == "egress":
        return base + DROP_ALL + ["python", "-m", "racky_egress"]
    if name == "vsock":
        return base + DROP_ALL + ["python", "-m", "racky_supervisor.vsock"]
    keep = "+setuid,+setgid,+setpcap,+kill"  # kill: encerrar o Openbox do `agent` ao voltar para headless
    return base + [f"--bounding-set=-all,{keep}", f"--inh-caps=-all,{keep}", f"--ambient-caps=-all,{keep}", "python", "-m", "racky_runtime"]


def main() -> int:
    os.makedirs("/tmp/.X11-unix", exist_ok=True)
    os.chmod("/tmp/.X11-unix", 0o1777)
    install_firewall()
    names = ["egress"] + (["vsock"] if os.environ.get("RACKY_VSOCK_PORT") else []) + (
        ["runtime"] if os.environ.get("RACKY_DISPLAY", "headless") != "http" else [])
    procs: dict[str, subprocess.Popen] = {}
    backoff = {n: 0.5 for n in names}
    started: dict[str, float] = {}
    stopping = False

    def stop(_signum, _frame) -> None:
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    def launch(name: str) -> None:
        procs[name] = subprocess.Popen(command(name), env=service_env(name), cwd="/")
        started[name] = time.monotonic()

    for name in names:
        launch(name)
    print(f"supervisor: {', '.join(names)} no ar, firewall por uid ativo", flush=True)
    while not stopping:
        time.sleep(0.5)
        for name, proc in list(procs.items()):
            if proc.poll() is None:
                continue
            if stopping:
                break
            lived = time.monotonic() - started[name]
            backoff[name] = 0.5 if lived > 30 else min(backoff[name] * 2, 10)
            print(f"supervisor: {name} saiu ({proc.returncode}); reiniciando em {backoff[name]:.1f}s", flush=True)
            time.sleep(backoff[name])
            launch(name)
    for proc in procs.values():
        if proc.poll() is None:
            proc.terminate()
    deadline = time.monotonic() + 4
    for proc in procs.values():
        try:
            proc.wait(max(0.1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            proc.kill()
    return 0


if __name__ == "__main__":
    sys.exit(main())
