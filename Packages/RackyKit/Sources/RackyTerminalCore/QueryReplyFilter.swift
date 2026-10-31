import Foundation

/// Política de respostas do emulador headless (08 AR-105, 06 §1.1).
/// O headless responde DA/DSR/tamanho; **nunca** OSC 52 (leitura), OSC 4/10/11/12 (cores) nem DECRQSS.
public enum QueryReplyFilter {
    public static func allows(_ reply: [UInt8]) -> Bool {
        let osc: [UInt8] = [0x1b, 0x5d]
        if reply.starts(with: osc) || (reply.first == 0x9d) { return false }
        // DCS (DECRQSS responde `ESC P 1 $ r ... ST` ou `ESC P 0 $ r ST`).
        if reply.starts(with: [0x1b, 0x50]) || reply.first == 0x90 { return false }
        return true
    }
}
