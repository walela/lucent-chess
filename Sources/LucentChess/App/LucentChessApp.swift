import SwiftUI

@main
struct LucentChessApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var engine = StockfishService()
    @StateObject private var appearance = AppearanceSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(engine)
                .environmentObject(appearance)
                .preferredColorScheme(appearance.interfaceAppearance.colorScheme)
                .frame(minWidth: 1_180, minHeight: 720)
                .onDisappear { library.saveNow(); engine.stopEngine() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Game") {
                    library.newStudy()
                    NotificationCenter.default.post(name: .openSelectedGame, object: nil)
                }
                    .keyboardShortcut("n")
                Button("Open PGN…") { NotificationCenter.default.post(name: .importPGN, object: nil) }
                    .keyboardShortcut("o")
                Button("Import from Source…") { NotificationCenter.default.post(name: .importSource, object: nil) }
                    .keyboardShortcut("o", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Game") { library.saveSelected() }
                    .keyboardShortcut("s")
                    .disabled(library.selectedStudy == nil)
                Button("Save Game As…") { library.saveSelectedAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(library.selectedStudy == nil)
            }
            CommandMenu("Game") {
                Button("Game Library") { NotificationCenter.default.post(name: .showDashboard, object: nil) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
                Button("First Move") { NotificationCenter.default.post(name: .firstMove, object: nil) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("Previous Move") { NotificationCenter.default.post(name: .previousMove, object: nil) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Next Move") { NotificationCenter.default.post(name: .nextMove, object: nil) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("Last Move") { NotificationCenter.default.post(name: .lastMove, object: nil) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Divider()
                Button("Flip Board") { appearance.boardFlipped.toggle() }
                    .keyboardShortcut("f")
                Button("Toggle Engine") { NotificationCenter.default.post(name: .toggleEngine, object: nil) }
                    .keyboardShortcut("e")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(engine)
                .environmentObject(appearance)
                .preferredColorScheme(appearance.interfaceAppearance.colorScheme)
                .frame(width: 520, height: 430)
        }
    }
}
