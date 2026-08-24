import AppKit
import SwiftUI

private struct DashboardPreviewShell: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var appearance: AppearanceSettings

    var body: some View {
        GameDashboard(openGame: { _ in }, newGame: { _ in }, importPGN: { _ in })
            .environmentObject(library)
            .environmentObject(appearance)
            .preferredColorScheme(appearance.interfaceAppearance.colorScheme)
            .frame(width: 1_420, height: 880)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

@main
struct DashboardPreview {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let mode = CommandLine.arguments.count > 3
            ? (InterfaceAppearance(rawValue: CommandLine.arguments[3]) ?? .dark)
            : .dark
        NSApplication.shared.appearance = NSAppearance(named: mode == .light ? .aqua : .darkAqua)
        let archive = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let library = LibraryStore(archiveURL: archive)
        let suiteName = "LucentDashboardPreview-\(UUID().uuidString)"
        let previewDefaults = UserDefaults(suiteName: suiteName)!
        let appearance = AppearanceSettings(defaults: previewDefaults)
        appearance.interfaceAppearance = mode
        if CommandLine.arguments.count > 4, CommandLine.arguments[4] == "empty" {
            library.studies = []
            library.folders = []
            library.selectedStudyID = nil
        } else {
            enrich(library)
        }
        let size = NSSize(width: 1_420, height: 880)
        let hosting = NSHostingView(rootView: DashboardPreviewShell(library: library, appearance: appearance))
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
        previewDefaults.removePersistentDomain(forName: suiteName)
        print(output.path)
    }

    @MainActor
    private static func enrich(_ library: LibraryStore) {
        let samples = [
            ("World Championship, Game 6", "Carlsen, Magnus", "Nepomniachtchi, Ian", "World Championship", "1-0"),
            ("Candidates preparation", "Gukesh D", "Nakamura, Hikaru", "Candidates", "1/2-1/2"),
            ("Classical Sicilian notes", "Kasparov, Garry", "Anand, Viswanathan", "Linares", "0-1")
        ]
        for sample in samples where !library.studies.contains(where: { $0.title == sample.0 }) {
            let game = library.newStudy(title: sample.0)
            game.white = sample.1
            game.black = sample.2
            game.event = sample.3
            game.result = sample.4
            for uci in ["e2e4", "c7c5", "g1f3", "d7d6", "d2d4", "c5d4", "f3d4", "g8f6"] {
                if let move = game.currentPosition.legalMove(uci: uci) { _ = game.play(move) }
            }
            library.changed()
        }
        let openings = library.folders.first(where: { $0.name == "Opening Books" })
            ?? library.createFolder(name: "Opening Books")!
        let tournaments = library.folders.first(where: { $0.name == "Tournaments" })
            ?? library.createFolder(name: "Tournaments")!
        for game in library.studies {
            if game.title.contains("Sicilian") || game.title.contains("preparation") {
                library.move(game, to: openings.id)
            } else if game.title.contains("World Championship") {
                library.move(game, to: tournaments.id)
            }
        }
        library.selectedStudyID = library.studies.first?.id
    }

    private enum PreviewError: Error { case render, encode }
}
