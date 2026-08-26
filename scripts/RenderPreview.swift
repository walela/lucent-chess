import AppKit
import SwiftUI

private struct WorkspacePreviewShell: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var engine: StockfishService
    @ObservedObject var appearance: AppearanceSettings
    @State private var tab: RootView.InspectorTab

    init(
        library: LibraryStore,
        engine: StockfishService,
        appearance: AppearanceSettings,
        tab: RootView.InspectorTab = .analysis
    ) {
        self.library = library
        self.engine = engine
        self.appearance = appearance
        _tab = State(initialValue: tab)
    }

    var body: some View {
        Group {
            if let study = library.selectedStudy {
                StudyWorkspace(study: study, inspectorTab: $tab, showDashboard: {})
            }
        }
        .environmentObject(library)
        .environmentObject(engine)
        .environmentObject(appearance)
        .frame(width: 1_520, height: 930)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@main
struct RenderPreview {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.appearance = NSAppearance(
            named: CommandLine.arguments.contains("--light") ? .aqua : .darkAqua
        )
        let archive = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let selectedTab = CommandLine.arguments.count > 3
            ? (RootView.InspectorTab(rawValue: CommandLine.arguments[3]) ?? .analysis)
            : .analysis
        let library = LibraryStore(archiveURL: archive)
        if CommandLine.arguments.contains("--demo-ratings") {
            let demo = ChessStudy(
                title: "Rated bullet game",
                white: "Gyoegy",
                black: "smeesloff",
                event: "Rated bullet game",
                site: "https://lichess.org/demo",
                whiteElo: "1847",
                blackElo: "1912",
                result: "0-1",
                startFEN: "r5k1/5ppp/p3rq2/2pQ4/1P1B4/4P3/P4PPP/2RR2K1 w - - 0 22"
            )
            demo.sourceName = "Lichess"
            library.studies = [demo]
            library.selectedStudyID = demo.id
        }
        let engine = StockfishService()
        let appearance = AppearanceSettings()
        appearance.boardTheme = BoardThemeOption.find("wood")
        appearance.pieceSet = PieceSetOption.find(selectedTab == .style ? "fritz-inspired" : "cburnett")
        if let study = library.selectedStudy {
            study.goToEnd()
            engine.startAndAnalyze(study.currentPosition)
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline, engine.currentDepth < 12 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.04))
            }
        }
        try render(
            WorkspacePreviewShell(library: library, engine: engine, appearance: appearance, tab: selectedTab),
            size: NSSize(width: 1_520, height: 930),
            to: output
        )
        engine.stopEngine()
        print(output.path)
    }

    @MainActor
    private static func render<V: View>(_ view: V, size: NSSize, to output: URL) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -3_000, y: -3_000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw PreviewError.render }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PreviewError.encode }
        try png.write(to: output, options: .atomic)
        window.orderOut(nil)
    }

    private enum PreviewError: Error { case render, encode }
}
