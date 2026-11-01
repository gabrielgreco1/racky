import RackyDocker
import RackyPlatform
import Foundation

/// Computador de verdade só para evidência e desenvolvimento (`RACKY_DEMO_COMPUTER=1`): sobe a imagem do contexto do repositório
/// (`RACKY_REPO_ROOT`), uma bridge e um computador headless, tudo com os labels `racky.test=1` e `racky.test_run=<id>`.
/// `cleanup()` remove só o que tem esses labels. Nunca roda em uso normal.
public struct DemoComputerRig: Sendable {
    public let computer: ManagedComputer
    public let runID: String
    public let labelFilter: [String]
    private let client: DockerClient
    private let home: URL

    public static var defaultHome: URL { FileManager.default.temporaryDirectory.appendingPathComponent("abx-demo", isDirectory: true) }

    public static let animationHTML = """
    <body style="margin:0;background:#fff"><canvas id=c width=900 height=500></canvas><div id=n style="font:20px monospace;padding:8px">demo-a is working</div><script>
    const c=document.getElementById('c'),x=c.getContext('2d');let n=0;
    function f(){n++;for(let i=0;i<10;i++){x.fillStyle='hsl('+((n*4+i*36)%360)+',80%,50%)';x.fillRect(i*90,(n*3)%460,90,40)}
    x.fillStyle='#000';x.fillRect(0,0,220,30);x.fillStyle='#fff';x.font='20px monospace';x.fillText('frame '+n,10,22);requestAnimationFrame(f)}f()
    </script></body>
    """

    public static let inputHTML = """
    <body style="margin:0"><input id=t style="font-size:24px;width:600px;margin:10px" placeholder="type here"><div id=box style="width:900px;height:500px;background:#00f"></div><script>
    let m=0;document.body.dataset.moves=0;
    document.addEventListener('mousemove',()=>{m++;document.getElementById('box').style.background=m%2?'#f00':'#00f';document.body.dataset.moves=m});
    </script></body>
    """

    public static let captchaHTML = """
    <body style="margin:0;font-family:-apple-system,sans-serif;background:#f4f4f5"><div style="padding:32px"><h1>Listing search</h1>
    <p>Please verify you are human to continue.</p><label style="font-size:22px"><input type=checkbox id=ok style="width:28px;height:28px"> I am not a robot</label>
    <p><input id=t style="font-size:22px;width:420px" placeholder="type the code here"></p></div></body>
    """

    public static func installScript(_ html: String) -> JSON {
        let quoted = String(decoding: (try? JSONSerialization.data(withJSONObject: [html])) ?? Data(), as: UTF8.self).dropFirst().dropLast()
        return ["js": .string("document.open();document.write(\(quoted));document.close();1")]
    }

    public static func provision(repoRoot: URL, home: URL, name: String = "demo-a") async throws -> DemoComputerRig {
        let runID = String(UUID().uuidString.lowercased().prefix(8))
        let detected = try await RuntimeDetector().detect()
        let client = DockerClient(runtime: detected.runtime, defaultTimeout: .seconds(60))
        let testLabels = [RackyLabel.test: "1", "racky.test_run": runID]
        let rig = DemoComputerRigPieces(runID: runID, client: client, home: home)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let images = ImageManager(client: client)
        let image = try await images.ensure(ImageSource(repository: "racky-computer-test-\(runID)", contextDirectory: repoRoot.appendingPathComponent("runtime/computer"), extraLabels: testLabels))
        let labels = ComputerLabels(owner: "test-\(runID)", computerID: UUID().uuidString.lowercased(), computerName: name, ephemeral: true, isTest: true)
        let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let secrets = BoxSecretFiles(root: home)
        let config = EgressConfigFile.make(profile: nil, secret: nil)
        let runDirectory = home.appendingPathComponent("runs/demo/\(name)", isDirectory: true)
        do {
            let provisioned = try await ComputerProvisioner(client: client).provision(ComputerProvisionRequest(
                labels: labels, image: image.tag, display: .headless, token: token, config: config, secrets: secrets,
                runDirectory: runDirectory, extraLabels: testLabels))
            let backend = DockerComputerBackend(client: client, computer: provisioned, secrets: secrets, baseConfig: config)
            let computer = try ManagedComputer(name: name, display: .headless, run: RunFolder(root: runDirectory), backend: backend)
            return DemoComputerRig(computer: computer, runID: runID, labelFilter: rig.labelFilter, client: client, home: home)
        } catch {
            await rig.cleanup()
            throw error
        }
    }

    /// Remove containers, rede, volume e imagens do teste (só `racky.test=1` + `racky.test_run=<id>`).
    public func cleanup() async {
        await DemoComputerRigPieces(runID: runID, client: client, home: home).cleanup()
    }
}

struct DemoComputerRigPieces {
    let runID: String
    let client: DockerClient
    let home: URL
    var labelFilter: [String] { ["\(RackyLabel.test)=1", "racky.test_run=\(runID)"] }

    func cleanup() async {
        let gc = GarbageCollector(client: client)
        if let items = try? await gc.inventory(labels: labelFilter) { await gc.remove(items) }
        if let images = try? await client.listImages(filters: ["label": labelFilter]) { for image in images { try? await client.removeImage(image.id, force: true) } }
    }
}
