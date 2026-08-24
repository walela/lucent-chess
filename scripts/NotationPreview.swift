import AppKit
import SwiftUI

private struct NotationPreviewShell: View {
    let study: ChessStudy
    @ObservedObject var library: LibraryStore
    @ObservedObject var engine: StockfishService

    var body: some View {
        MoveTreeView(study: study)
            .environmentObject(library)
            .environmentObject(engine)
            .frame(width: 500, height: 440)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

@main
struct NotationPreview {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "dark"
        NSApplication.shared.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
        let pgn = """
        [Event "Nested variations"]
        [Result "*"]

        1. e4 {The main choice.} (1. d4 d5 2. c4 e6 (2... c6 3. Nc3 Nf6)) e5
        (1... c5 2. Nf3 d6 (2... Nc6 3. Bb5 g6) 3. d4 cxd4) 2. Nf3 Nc6 3. Bb5 a6
        4. Ba4 Nf6 5. O-O Be7 *
        """
        let study = try PGNService.parse(pgn)[0]
        study.goToEnd()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("LucentNotationPreview-\(UUID().uuidString).json")
        let library = LibraryStore(archiveURL: temporary)
        library.studies = [study]
        library.selectedStudyID = study.id
        let engine = StockfishService()
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let size = NSSize(width: 500, height: 440)
        let hosting = NSHostingView(rootView: NotationPreviewShell(study: study, library: library, engine: engine))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -3_000, y: -3_000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds),
              let png = { hosting.cacheDisplay(in: hosting.bounds, to: bitmap); return bitmap.representation(using: .png, properties: [:]) }() else {
            throw PreviewError.render
        }
        try png.write(to: output, options: .atomic)
        window.orderOut(nil)
        print(output.path)
    }

    private enum PreviewError: Error { case render }
}
