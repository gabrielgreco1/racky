import Foundation
import Testing
@testable import RackyPlatform

/// Redação de log (08 AR-602): um teste por padrão da spec.
@Suite struct LogRedactorTests {
    private static let cases: [(name: String, input: String, secret: String)] = [
        ("sk-ant", "key sk-ant-api03-AbCdEfGhIjKlMnOp1234 used", "sk-ant-api03-AbCdEfGhIjKlMnOp1234"),
        ("sk-", "OPENAI sk-proj1234567890abcdefghijkl here", "sk-proj1234567890abcdefghijkl"),
        ("ghp_", "token ghp_abcdefghijklmnopqrstuvwxyz0123456789 end", "ghp_abcdefghijklmnopqrstuvwxyz0123456789"),
        ("github_pat_", "pat github_pat_11ABCDEFG0abcdefghijklmnop_qrstuvwxyz end", "github_pat_11ABCDEFG0abcdefghijklmnop_qrstuvwxyz"),
        ("gho_", "oauth gho_abcdefghijklmnopqrstuvwxyz0123456789", "gho_abcdefghijklmnopqrstuvwxyz0123456789"),
        ("Bearer", "Authorization: Bearer abc.def-123_XYZ=", "abc.def-123_XYZ="),
        ("bearer sozinho", "got bearer 0123456789abcdef from server", "0123456789abcdef"),
        ("proxy url", "using http://proxyuser:s3cr3tPass@proxy.example.com:8080/x", "s3cr3tPass"),
        ("proxy user", "using socks5://proxyuser:s3cr3tPass@proxy.example.com:1080", "proxyuser"),
        ("zyte key", "proxy http://0123456789abcdef0123456789abcdef:@api.zyte.com:8011", "0123456789abcdef0123456789abcdef"),
        ("api key", "x-api-key: sekret-value-123", "sekret-value-123"),
        ("password", "password=hunter2&user=bob", "hunter2"),
        ("jwt", "jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c ok", "eyJhbGciOiJIUzI1NiJ9"),
        ("slack", "slack xoxb-1234567890-abcdefghij end", "xoxb-1234567890-abcdefghij"),
        ("aws", "aws AKIAIOSFODNN7EXAMPLE end", "AKIAIOSFODNN7EXAMPLE"),
        ("aws sts", "temp ASIAIOSFODNN7EXAMPLE end", "ASIAIOSFODNN7EXAMPLE"),
        ("google", "key AIzaSyA1234567890abcdefghijklmnopqrstuv end", "AIzaSyA1234567890abcdefghijklmnopqrstuv"),
        ("stripe sk_live", "stripe sk_live_abcdefghijklmnop1234 end", "sk_live_abcdefghijklmnop1234"),
        ("stripe rk_live", "stripe rk_live_abcdefghijklmnop1234 end", "rk_live_abcdefghijklmnop1234"),
        ("pem inline", #"{"k":"-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\n-----END PRIVATE KEY-----"}"#, "MIIEvQIBADANBgkqhkiG9w0BAQEFAASC"),
    ]

    @Test(arguments: cases) func removesEveryPattern(_ item: (name: String, input: String, secret: String)) {
        let out = LogRedactor.redact(item.input)
        #expect(!out.contains(item.secret), "\(item.name): \(out)")
        #expect(out.contains(LogRedactor.marker), "\(item.name): marcador ausente em \(out)")
    }

    @Test func multiLinePrivateKeyBlockIsRedactedAndNeighboursSurvive() {
        let text = "before\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmU\nAAAAB3NzaC1lZDI1NTE5\n-----END OPENSSH PRIVATE KEY-----\nafter"
        let out = LogRedactor.redact(text)
        #expect(!out.contains("b3BlbnNzaC1rZXktdjE") && !out.contains("AAAAB3NzaC1lZDI1NTE5"))
        #expect(out == "before\n\(LogRedactor.marker)\nafter")
        // Corte do log antes do END: o corpo base64 também sai.
        let cut = LogRedactor.redact("-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA1234567890abcdef")
        #expect(!cut.contains("MIIEowIBAAKCAQEA"))
    }

    @Test func homeFolderBecomesTilde() {
        #expect(LogRedactor.redact("opened /Users/me/code/work/file.txt") == "opened ~/code/work/file.txt")
        #expect(LogRedactor.redact("two /Users/ana/a and /Users/bob/b") == "two ~/a and ~/b")
        #expect(LogRedactor.redact(#"{"path":"/Users/me/x"}"#) == #"{"path":"~/x"}"#)
    }

    @Test func keepsOrdinaryText() {
        let text = "session abc started pid 123 in /tmp/work; sk-short; https://github.com/org/repo"
        #expect(LogRedactor.redact(text) == text)
    }

    @Test func isIdempotentAndCleanDetectsLeaks() {
        let once = LogRedactor.redact("Bearer abcdef123456 password=x /Users/me/a http://u:p@h/")
        #expect(LogRedactor.redact(once) == once)
        #expect(LogRedactor.isClean(once))
        #expect(!LogRedactor.isClean("ghp_abcdefghijklmnopqrstuvwxyz0123"))
    }
}
