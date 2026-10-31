import Foundation
import ServiceManagement

// Auxiliar de scripts/e2e-launchd.sh: consulta e desregistra o LaunchAgent de TESTE da cópia do app.
// Compilado dentro da cópia (Contents/MacOS), onde Bundle.main é a cópia do app e o SMAppService encontra o plist.
// Uso: registrar status|unregister <plist-name>
let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: registrar status|unregister <plist-name>")
    exit(64)
}
let plistName = arguments[2]
guard plistName.hasPrefix("app.racky.ptyd.test-") else {
    print("refusing: only test labels (app.racky.ptyd.test-*)")
    exit(65)
}
let service = SMAppService.agent(plistName: plistName)
func name(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: "notRegistered"
    case .enabled: "enabled"
    case .requiresApproval: "requiresApproval"
    case .notFound: "notFound"
    @unknown default: "unknown"
    }
}
print("before: \(name(service.status))")
if arguments[1] == "unregister" {
    do {
        try service.unregister()
        print("unregister: ok")
    } catch {
        print("unregister: \(error)")
    }
    print("after: \(name(service.status))")
}
