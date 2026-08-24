import AppKit
import SwiftUI

private struct PreviewShell: View {
    @ObservedObject var appearance: AppearanceSettings

    var body: some View {
        EngineLineRow(
            line: EngineLine(
                multipv: 1,
                depth: 26,
                score: "+1.07",
                moves: ["e4", "e5", "Nf3", "Nc6", "Bb5", "a6", "Ba4", "Nf6"],
                uciMoves: ["e2e4", "e7e5", "g1f3", "b8c6", "f1b5", "a7a6", "b5a4", "g8f6"]
            ),
            startPosition: .starting,
            isExpanded: true,
            togglePreview: {},
            add: {}
        )
        .environmentObject(appearance)
        .frame(width: 480, height: 580, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@main
struct EngineLinePreviewRender {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let appearance = AppearanceSettings()
        appearance.boardTheme = .find("wood")
        appearance.pieceSet = .find("cardinal")
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let size = NSSize(width: 480, height: 580)
        let hosting = NSHostingView(rootView: PreviewShell(appearance: appearance))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -3_000, y: -3_000), size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw PreviewError.render }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PreviewError.render }
        try png.write(to: output, options: .atomic)
        window.orderOut(nil)
        print(output.path)
    }

    private enum PreviewError: Error { case render }
}
