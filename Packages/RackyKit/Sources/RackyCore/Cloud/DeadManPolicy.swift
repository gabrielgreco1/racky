import RackyProtocol
import Foundation

/// Decisão da chave morta (estudo 6.1, camadas 1 a 3). O Mac é o controlador (P27.2): se ele some, a VM se apaga sozinha, sem papel
/// IAM e sem controlador na nuvem. `DeadManScript` roda a MESMA lógica no host; os testes executam o script e comparam com esta.
public enum DeadManDecision: Sendable, Equatable {
    case keep
    case shutdown(reason: DeadManShutdownReason)
}

public enum DeadManShutdownReason: String, Sendable, Equatable {
    case maxLifetime = "max-lifetime"
    case leaseExpired = "lease-expired"
    case bootGraceExpired = "boot-grace-expired"
    case idle
}

public struct DeadManPolicy: Sendable, Equatable {
    /// De quanto em quanto o app renova o lease (e a VM confere).
    public var heartbeatInterval: Duration
    /// Heartbeats perdidos seguidos até a VM se apagar.
    public var missedLimit: Int
    /// Tempo para o app se conectar depois do boot (antes do primeiro heartbeat).
    public var bootGrace: Duration
    /// Vida máxima dura da VM, com ou sem heartbeat.
    public var maxLifetime: Duration
    /// Sem nenhum container de computador por tanto tempo, a VM se apaga.
    public var idleShutdown: Duration

    public init(
        heartbeatInterval: Duration = .seconds(60), missedLimit: Int = 20, bootGrace: Duration = .seconds(900),
        maxLifetime: Duration = .seconds(8 * 3600), idleShutdown: Duration = .seconds(900)
    ) {
        self.heartbeatInterval = heartbeatInterval; self.missedLimit = max(missedLimit, 1); self.bootGrace = bootGrace
        self.maxLifetime = maxLifetime; self.idleShutdown = idleShutdown
    }

    /// Prazo do lease: `interval x missed` (padrão 20 min, como no estudo).
    public var leaseTimeout: Duration { heartbeatInterval * missedLimit }

    public static let heartbeatFile = "/var/lib/racky/heartbeat"
    public static let stateDirectory = "/var/lib/racky"
    /// Rótulo dos containers que contam como "computador" para o teste de ociosidade.
    public static let computerLabel = "racky.computer"

    /// Comando fixo do app pelo SSH: grava a hora DA VM (sem depender do relógio do Mac) de forma atômica.
    public static let heartbeatCommand =
        "date +%s > \(heartbeatFile).tmp && mv -f \(heartbeatFile).tmp \(heartbeatFile)"

    static func seconds(_ duration: Duration) -> Int { Int(duration.components.seconds) }

    /// Mesma regra do script. `lastHeartbeat == nil`: nunca recebeu. `idleSince`: desde quando não há computador (ou o boot).
    public func decision(now: Date, booted: Date, lastHeartbeat: Date?, idleSince: Date?, computers: Int) -> DeadManDecision {
        let t = now.timeIntervalSince1970
        if t - booted.timeIntervalSince1970 >= Double(Self.seconds(maxLifetime)) { return .shutdown(reason: .maxLifetime) }
        if var beat = lastHeartbeat?.timeIntervalSince1970 {
            beat = min(beat, t)  // heartbeat "do futuro" não estende o lease
            if t - beat >= Double(Self.seconds(leaseTimeout)) { return .shutdown(reason: .leaseExpired) }
        } else if t - booted.timeIntervalSince1970 >= Double(Self.seconds(bootGrace)) {
            return .shutdown(reason: .bootGraceExpired)
        }
        if computers == 0, let idleSince, t - idleSince.timeIntervalSince1970 >= Double(Self.seconds(idleShutdown)) { return .shutdown(reason: .idle) }
        return .keep
    }
}

/// O script do host (`/usr/local/bin/racky-deadman`), gerado a partir da política. Só `bash` + coreutils + `docker`.
/// Ganchos de teste por variável de ambiente (`RACKY_*`): em produção nenhum é definido.
public enum DeadManScript {
    public static func render(_ policy: DeadManPolicy) -> String {
        """
        #!/bin/bash
        # Chave morta do Racky (P27.2). Gerado por DeadManScript.render; não editar na VM.
        # Se o app (o Mac) parar de renovar o lease, a VM se apaga: InstanceInitiatedShutdownBehavior=terminate transforma
        # `shutdown -h now` em TerminateInstances. Não usa credencial da nuvem.
        set -u
        STATE_DIR="${RACKY_STATE_DIR:-\(DeadManPolicy.stateDirectory)}"
        HEARTBEAT="$STATE_DIR/heartbeat"
        BOOT_FILE="$STATE_DIR/boot"
        IDLE_FILE="$STATE_DIR/idle-since"
        INTERVAL=\(DeadManPolicy.seconds(policy.heartbeatInterval))
        LEASE=\(DeadManPolicy.seconds(policy.leaseTimeout))
        BOOT_GRACE=\(DeadManPolicy.seconds(policy.bootGrace))
        MAX_LIFETIME=\(DeadManPolicy.seconds(policy.maxLifetime))
        IDLE_LIMIT=\(DeadManPolicy.seconds(policy.idleShutdown))

        read_int() { local v; v=$(cat "$1" 2>/dev/null | tr -dc '0-9'); [ -n "$v" ] && echo "$v"; }

        computers() {
          if [ -n "${RACKY_COMPUTERS:-}" ]; then echo "$RACKY_COMPUTERS"; return; fi
          docker ps -q --filter "label=\(DeadManPolicy.computerLabel)" 2>/dev/null | wc -l | tr -d ' '
        }

        stop_host() {
          if [ "${RACKY_DRY_RUN:-0}" = 1 ]; then echo "shutdown:$1"; return; fi
          logger -t racky-deadman "shutdown: $1" 2>/dev/null
          /usr/sbin/shutdown -h now "racky: $1"
        }

        tick() {
          local now boot beat idle n
          now="${RACKY_NOW:-$(date +%s)}"
          mkdir -p "$STATE_DIR"
          boot=$(read_int "$BOOT_FILE") || { boot=$now; echo "$boot" > "$BOOT_FILE"; }
          if [ $((now - boot)) -ge "$MAX_LIFETIME" ]; then stop_host max-lifetime; return; fi
          if beat=$(read_int "$HEARTBEAT"); then
            [ "$beat" -gt "$now" ] && beat=$now
            if [ $((now - beat)) -ge "$LEASE" ]; then stop_host lease-expired; return; fi
          elif [ $((now - boot)) -ge "$BOOT_GRACE" ]; then
            stop_host boot-grace-expired; return
          fi
          n=$(computers)
          if [ "$n" -gt 0 ]; then
            rm -f "$IDLE_FILE"
          else
            idle=$(read_int "$IDLE_FILE") || { idle=$boot; echo "$idle" > "$IDLE_FILE"; }
            if [ $((now - idle)) -ge "$IDLE_LIMIT" ]; then stop_host idle; return; fi
          fi
          [ "${RACKY_DRY_RUN:-0}" = 1 ] && echo keep
        }

        while true; do
          tick
          [ "${RACKY_ONCE:-0}" = 1 ] && exit 0
          sleep "$INTERVAL"
        done
        """
    }
}

/// cloud-init (`#cloud-config`) do host: usuário `racky` só com chave, sshd restrito, Docker, chave morta como serviço systemd.
/// A chave PRIVADA do host viaja no user-data (o app precisa conhecê-la antes de a VM existir para fixar o `known_hosts`):
/// por isso o IMDS fica com 1 salto e IMDSv2 obrigatório (containers não o alcançam), ver `AWSProvider`.
public enum CloudInit {
    public struct HostKey: Sendable, Equatable {
        /// Conteúdo OpenSSH da chave privada ed25519 do host.
        public var privateKey: String
        /// `ssh-ed25519 AAAA...`
        public var publicKey: String
        public init(privateKey: String, publicKey: String) { self.privateKey = privateKey; self.publicKey = publicKey }
    }

    public static let user = "racky"

    private static func indent(_ text: String, _ spaces: Int) -> String {
        let pad = String(repeating: " ", count: spaces)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : pad + $0 }.joined(separator: "\n")
    }

    public static func userData(policy: DeadManPolicy, authorizedKey: String, hostKey: HostKey) -> String {
        """
        #cloud-config
        # Racky: host de computadores. Gerado por CloudInit.userData.
        users:
          - name: \(user)
            gecos: Racky
            shell: /bin/bash
            groups: [docker]
            lock_passwd: true
            ssh_authorized_keys:
              - \(authorizedKey)
        disable_root: true
        ssh_pwauth: false
        ssh_deletekeys: true
        ssh_keys:
          ed25519_private: |
        \(indent(hostKey.privateKey.trimmingCharacters(in: .newlines), 4))
          ed25519_public: \(hostKey.publicKey)
        packages:
          - docker
        write_files:
          - path: /usr/local/bin/racky-deadman
            permissions: '0755'
            owner: root:root
            content: |
        \(indent(DeadManScript.render(policy), 6))
          - path: /etc/systemd/system/racky-deadman.service
            permissions: '0644'
            content: |
              [Unit]
              Description=Racky dead-man switch
              After=docker.service
              [Service]
              ExecStart=/usr/local/bin/racky-deadman
              Restart=always
              RestartSec=5
              [Install]
              WantedBy=multi-user.target
          - path: /etc/ssh/sshd_config.d/50-racky.conf
            permissions: '0644'
            content: |
              PasswordAuthentication no
              KbdInteractiveAuthentication no
              PermitRootLogin no
              AllowUsers \(user)
              AllowTcpForwarding local
              AllowStreamLocalForwarding local
              AllowAgentForwarding no
              X11Forwarding no
              PermitTunnel no
        runcmd:
          - [install, -d, -o, \(user), -g, \(user), -m, '0755', \(DeadManPolicy.stateDirectory)]
          - [sh, -c, 'date +%s > \(DeadManPolicy.stateDirectory)/boot']
          - [systemctl, daemon-reload]
          - [systemctl, restart, sshd]
          - [systemctl, enable, --now, docker]
          - [systemctl, enable, --now, racky-deadman]
        """
    }
}
