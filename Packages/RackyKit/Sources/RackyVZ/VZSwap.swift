import Foundation

/// Swap em arquivo dentro da VM (backlog 20). Sem swap, um computador que passa da memória (pytest + Chromium, 02/11) não mata
/// nada: o kernel fica sem página para o virtio-fs, a pasta de trabalho para e a VM gira a 200% de CPU. Com swap ela só fica mais
/// lenta. O arquivo nasce com `fallocate` no disco da própria VM (um clone APFS esparso no Mac): só ocupa espaço quando é usado.
/// O kernel desta imagem não tem zram, por isso arquivo.
enum VZSwap {
    static let path = "/swapfile"

    static func script(bytes: Int64) -> String {
        "set -e; [ -e \(path) ] || { fallocate -l \(bytes) \(path); chmod 600 \(path); mkswap \(path) >/dev/null; }; "
            + "swapon \(path) 2>/dev/null || swapon --show | grep -q \(path); "
            // Usa o swap só quando precisa: páginas de arquivo (cache) saem antes das do programa.
            + "echo 30 > /proc/sys/vm/swappiness 2>/dev/null || true; echo ok"
    }

    /// Liga o swap. Falhar não impede o computador de subir: só fica sem a rede de segurança (e o motivo vai para o log).
    @discardableResult
    static func enable(on vm: any RunningVM, bytes: Int64) async -> String? {
        do {
            let result = try await vm.run(
                VZExecRequest(command: ["sh", "-c", script(bytes: bytes)], user: "root", systemAdmin: true), timeout: .seconds(30))
            return result.exitCode == 0 && result.stdoutString.contains("ok") ? nil : "swap: exit \(result.exitCode) \(result.stderrString.prefix(200))"
        } catch {
            return "swap: \(error)"
        }
    }
}
