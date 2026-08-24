import AppKit
import SwiftUI

@main
struct EngineConfigPreview {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let engine = StockfishService()
        engine.loadOptions()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, engine.state != .ready {
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        }

        let view = EngineConfigurationView()
            .environmentObject(engine)
            .preferredColorScheme(.dark)
            .frame(width: 720, height: 790)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 790)
        let window = NSWindow(
            contentRect: NSRect(x: -2_000, y: -2_000, width: 720, height: 790),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "EngineConfigPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not render engine configuration"])
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "EngineConfigPreview", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode engine configuration"])
        }
        try png.write(to: output, options: .atomic)
        window.orderOut(nil)
        engine.stopEngine()
        print(output.path)
    }
}
