import RackyCore
import RackyDesignSystem
import RackyProtocol
import AppKit
import SnapshotTesting
import SwiftUI
import Testing

@testable import RackyUI

/// Snapshots do painel direito com fixture fixa em `/tmp` (caminho estável). Referências em `__Snapshots__/`;
/// gravar com `RACKY_RECORD_SNAPSHOTS=1`. Nenhuma janela: só `NSHostingView` fora da tela.
@MainActor
@Suite(.serialized) struct RightPanelSnapshotTests {
    static let fixtureRoot = "/tmp/racky-rp-fixture"

    static func buildFixture() throws -> String {
        let root = URL(fileURLWithPath: fixtureRoot, isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let files: [String: String] = [
            "README.md": "# Fixture\n\nA small project.\n",
            "Package.swift": "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"App\")\n",
            ".gitignore": "build/\n",
            "Sources/App/main.swift": "import Foundation\n\n// Entry point\nstruct App {\n    let name = \"agent\"\n    func run() -> Int {\n        print(\"hello \\(name)\")\n        return 42\n    }\n}\n\nApp().run()\n",
            "Sources/App/Model.swift": "struct Model { var id: Int }\n",
            "Tests/AppTests/AppTests.swift": "import Testing\n",
            "docs/guide.md": "# Guide\n",
            "build/out.o": "binary-ish\n",
            "notes.md": "todo\n",
        ]
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return FileTreeLoader.canonical(fixtureRoot)
    }

    /// Controlador com a árvore carregada, três pastas expandidas e marcas de git.
    func loadedFiles(root: String) async -> FilesController {
        let box = FilesSourceBox()
        box.sessionRoot = root
        box.focused = FilesFixture.claude(UUID(), cwd: root)
        let porcelain = " M Sources/App/main.swift\0A  Package.swift\0?? notes.md\0"
        let diff = "@@ -6,0 +7,2 @@\n+        print(\"hello\")\n+        return 42\n@@ -3 +3 @@\n-// Entry\n+// Entry point\n"
        let files = FilesFixture.controller(box: box, porcelain: porcelain, diff: diff)
        files.recompute()
        files.toggleFolder(root + "/Sources")
        files.toggleFolder(root + "/Sources/App")
        _ = await FilesFixture.wait { files.tree?.rows.contains { $0.entry.name == "main.swift" } == true && files.changes.count == 3 }
        return files
    }

    func panel(files: FilesController, size: CGSize, hide: PanelModuleID? = nil) -> NSHostingView<some View> {
        let controller = RightPanelController()
        controller.register(FilesModule(controller: files))
        controller.register(InsightsModule(model: InsightsPreviewData.model()))
        controller.isContentVisible = true
        controller.updateWindow(width: 1440, sidebarWidth: 280)
        if let hide { controller.hide(hide) }
        let elements = UIElementStore()
        let flags = SliceFlags()
        let registry = ActionRegistry(flags: flags, surface: WindowAutomation(store: elements, flags: flags, fixture: nil, automationEnabled: false))
        try? controller.register(in: registry)
        try? files.register(in: registry, openIn: nil, overlays: OverlayRouter(), elements: elements)
        let root = RightPanelView(controller: controller)
            .environment(\.actionRegistry, registry)
            .environment(\.elementStore, elements)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        return host
    }

    func snap<V: View>(_ host: NSHostingView<V>, _ name: String, line: UInt = #line) {
        withSnapshotTesting(record: ComponentSnapshotTests.recording) {
            assertSnapshot(of: host, as: .image(precision: 0.98, perceptualPrecision: 0.97), named: name, testName: "rightPanel", line: line)
        }
    }

    @Test func filesAndInsights() async throws {
        DSFonts.registerIfNeeded()
        let previous = MotionPolicy.shared.preference
        MotionPolicy.shared.preference = .on
        defer { MotionPolicy.shared.preference = previous }
        let root = try Self.buildFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let files = await loadedFiles(root: root)
        snap(panel(files: files, size: CGSize(width: 380, height: 760)), "filesAndInsights")
    }

    @Test func compactAndMinimized() async throws {
        DSFonts.registerIfNeeded()
        let previous = MotionPolicy.shared.preference
        MotionPolicy.shared.preference = .on
        defer { MotionPolicy.shared.preference = previous }
        let root = try Self.buildFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let files = await loadedFiles(root: root)
        snap(panel(files: files, size: CGSize(width: 280, height: 480), hide: .insights), "compactFilesOnly")
    }

    @Test func viewerWithSearchAndGutter() async throws {
        DSFonts.registerIfNeeded()
        let previous = MotionPolicy.shared.preference
        MotionPolicy.shared.preference = .on
        defer { MotionPolicy.shared.preference = previous }
        let root = try Self.buildFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let files = await loadedFiles(root: root)
        files.open(root + "/Sources/App/main.swift")
        _ = await FilesFixture.wait { files.viewer?.content != nil && files.viewer?.marks.marks.isEmpty == false }
        files.setSearchActive(true)
        files.setSearchQuery("name")
        let host = panel(files: files, size: CGSize(width: 380, height: 520), hide: .insights)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        snap(host, "viewerSearch")
    }
}
