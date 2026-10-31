import RackyCore
import RackyDesignSystem
import AppKit
import SnapshotTesting
import SwiftUI
import Testing

@testable import RackyUI

/// Teste de layout do módulo Files (F21): renderiza em várias combinações de tamanho, o cabeçalho de pasta cola no topo
/// (sem vazio acima, mesmo com poucos arquivos) e nada sai dos limites. Tudo fora da tela (`NSHostingView`, nenhuma janela).
@MainActor
@Suite(.serialized) struct FilesLayoutTests {
    nonisolated static let sizes: [CGSize] = [
        CGSize(width: 260, height: 200), CGSize(width: 320, height: 300), CGSize(width: 380, height: 500), CGSize(width: 520, height: 800),
        CGSize(width: 260, height: 700), CGSize(width: 300, height: 140), CGSize(width: 600, height: 420), CGSize(width: 720, height: 300),
    ]

    func render(_ files: FilesController, size: CGSize) throws -> (NSHostingView<AnyView>, LayoutProbe) {
        DSFonts.registerIfNeeded()
        let probe = LayoutProbe()
        let registry = try FilesFixture.registry(for: files)
        let root = AnyView(
            FilesPanelView(controller: files, compact: false)
                .environment(\.actionRegistry, registry)
                .environment(\.layoutProbe, probe)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            host.layoutSubtreeIfNeeded()
        }
        return (host, probe)
    }

    func loaded(_ names: [String]) async throws -> (FilesController, String) {
        let root = try FilesFixture.makeTree(names, name: "layout-fixture")
        let box = FilesSourceBox()
        box.sessionRoot = root
        box.focused = FilesFixture.claude(UUID(), cwd: root)
        let files = FilesFixture.controller(box: box)
        files.recompute()
        _ = await FilesFixture.wait { (files.tree?.rows.count ?? 0) == names.count }
        return (files, root)
    }

    @Test func folderHeaderHugsTheTopEvenWithFewFiles() async throws {
        let (files, root) = try await loaded(["a.swift", "b.swift"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        for size in Self.sizes {
            let (_, probe) = try render(files, size: size)
            let bar = try #require(probe.frames["rootBar"], "no root bar at \(size)")
            #expect(bar.minY < 0.5, "empty space above the folder header at \(size): \(bar)")
        }
    }

    @Test func nothingLeavesTheBoxAtAnySize() async throws {
        let (files, root) = try await loaded((0..<40).map { "file-\($0).swift" })
        defer { try? FileManager.default.removeItem(atPath: root) }
        for size in Self.sizes {
            let (_, probe) = try render(files, size: size)
            #expect(!probe.frames.isEmpty)
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5)
            for (id, frame) in probe.frames {
                #expect(frame.minX >= bounds.minX && frame.maxX <= bounds.maxX, "\(id) leaves horizontally at \(size): \(frame)")
                #expect(frame.minY >= bounds.minY && frame.maxY <= bounds.maxY, "\(id) leaves vertically at \(size): \(frame)")
            }
        }
    }

    @Test func viewerFitsEveryLayoutAndWideShowsTreeAndViewerTogether() async throws {
        let (files, root) = try await loaded(["main.swift", "util.swift"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        files.open(root + "/main.swift")
        _ = await FilesFixture.wait { files.viewer?.content != nil }
        for size in Self.sizes {
            let (_, probe) = try render(files, size: size)
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5)
            let viewer = try #require(probe.frames["viewer"], "no viewer at \(size)")
            #expect(bounds.contains(viewer), "viewer leaves the box at \(size): \(viewer)")
            if FilesLayout(width: size.width, height: size.height) == .wide {
                let bar = try #require(probe.frames["rootBar"], "wide layout lost the tree at \(size)")
                #expect(bar.maxX <= viewer.minX + 0.5, "tree and viewer overlap at \(size)")
            }
        }
    }

    @Test func snapshotsOfAFewFilesAtThreeSizes() async throws {
        let (files, root) = try await loaded(["README.md", "main.swift", "Sources/"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        for size in [CGSize(width: 260, height: 220), CGSize(width: 380, height: 400), CGSize(width: 600, height: 320)] {
            let (host, _) = try render(files, size: size)
            withSnapshotTesting(record: ComponentSnapshotTests.recording) {
                assertSnapshot(of: host, as: .image(precision: 0.98, perceptualPrecision: 0.97), named: "few-\(Int(size.width))x\(Int(size.height))", testName: "filesLayout")
            }
        }
    }

    @Test func layoutBreakpoints() {
        #expect(FilesLayout(width: 700, height: 500) == .wide)
        #expect(FilesLayout(width: 400, height: 500) == .medium)
        #expect(FilesLayout(width: 260, height: 500) == .compact)
        #expect(FilesLayout(width: 700, height: 100) == .compact)
    }
}
