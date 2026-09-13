import AppKit
import SwiftUI

@main
struct LucentChessApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var engine = StockfishService()
    @StateObject private var training = TrainingSession()
    @StateObject private var appearance = AppearanceSettings()

    var body: some Scene {
        Window("Lucent Chess", id: AppWindowID.library) {
            RootView()
                .environmentObject(library)
                .environmentObject(appearance)
                .preferredColorScheme(appearance.interfaceAppearance.colorScheme)
                .frame(minWidth: 1_180, minHeight: 720)
                .onDisappear { library.saveNow() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands { LucentCommands(library: library, appearance: appearance) }

        WindowGroup("Collection", id: AppWindowID.collection, for: UUID.self) { $collectionID in
            if let collectionID {
                RootView(collectionID: collectionID)
                    .environmentObject(library)
                    .environmentObject(appearance)
                    .preferredColorScheme(appearance.interfaceAppearance.colorScheme)
                    .frame(minWidth: 1_180, minHeight: 720)
                    .onDisappear { library.saveNow() }
            }
        }
        .defaultSize(width: 1_320, height: 820)
        .windowStyle(.hiddenTitleBar)

        Window("Lucent Chess — Game", id: AppWindowID.game) {
            GameWindowRoot()
                .environmentObject(library)
                .environmentObject(engine)
                .environmentObject(training)
                .environmentObject(appearance)
                .preferredColorScheme(appearance.interfaceAppearance.colorScheme)
                .frame(minWidth: 1_180, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)

        Window("Play Stockfish", id: AppWindowID.training) {
            TrainingGameView()
                .environmentObject(library)
                .environmentObject(engine)
                .environmentObject(training)
                .environmentObject(appearance)
                .preferredColorScheme(appearance.interfaceAppearance.colorScheme)
        }
        .windowStyle(.hiddenTitleBar)

        Window("Set Up Position", id: AppWindowID.positionSetup) {
            PositionSetupView()
                .environmentObject(library)
                .environmentObject(appearance)
                .preferredColorScheme(appearance.interfaceAppearance.colorScheme)
        }
        .windowResizability(.contentSize)

        Window("Save to Collection", id: AppWindowID.saveToCollection) {
            if let study = library.selectedStudy {
                SaveToCollectionView(study: study)
                    .environmentObject(library)
                    .preferredColorScheme(appearance.interfaceAppearance.colorScheme)
            }
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(engine)
                .environmentObject(training)
                .environmentObject(appearance)
                .preferredColorScheme(appearance.interfaceAppearance.colorScheme)
                .frame(width: 520, height: 430)
        }
    }
}

private struct LucentCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.isTrainingWindow) private var isTrainingWindow
    @ObservedObject var library: LibraryStore
    @ObservedObject var appearance: AppearanceSettings

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Game") {
                library.newStudy()
                NotificationCenter.default.post(name: .openSelectedGame, object: nil)
            }
            .keyboardShortcut("n")
                .disabled(isTrainingWindow == true || library.isImportingFiles)
            Button("Open Games…") { NotificationCenter.default.post(name: .importPGN, object: nil) }
                .keyboardShortcut("o")
                .disabled(isTrainingWindow == true || library.isImportingFiles)
            Button("Import from Source…") { NotificationCenter.default.post(name: .importSource, object: nil) }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(isTrainingWindow == true || library.isImportingFiles)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save to Collection…") { openWindow(id: AppWindowID.saveToCollection) }
                .keyboardShortcut("s")
                .disabled(library.selectedStudy == nil || isTrainingWindow == true || library.isImportingFiles)
            Button("Export PGN…") { library.saveSelectedAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(library.selectedStudy == nil || isTrainingWindow == true || library.isImportingFiles)
            Button("Show in Finder") {
                if let url = library.selectedStudy?.fileURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            .disabled(library.selectedStudy?.fileURL == nil || isTrainingWindow == true)
        }
        CommandMenu("Game") {
            Button("Set Up Position…") { openWindow(id: AppWindowID.positionSetup) }
                .keyboardShortcut("s", modifiers: [.command, .shift, .option])
                .disabled(isTrainingWindow == true || library.isImportingFiles)
            Divider()
            Button("Game Library") { NotificationCenter.default.post(name: .showDashboard, object: nil) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("First Move") { NotificationCenter.default.post(name: .firstMove, object: nil) }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(isTrainingWindow == true || library.isImportingFiles)
            Button("Previous Move") { NotificationCenter.default.post(name: .previousMove, object: nil) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(isTrainingWindow == true || library.isImportingFiles)
            Button("Next Move") { NotificationCenter.default.post(name: .nextMove, object: nil) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(isTrainingWindow == true || library.isImportingFiles)
            Button("Last Move") { NotificationCenter.default.post(name: .lastMove, object: nil) }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(isTrainingWindow == true || library.isImportingFiles)
            Divider()
            Button("Flip Board") { appearance.boardFlipped.toggle() }
                .keyboardShortcut("f")
                .disabled(isTrainingWindow == true || library.isImportingFiles)
            Button("Toggle Engine") { NotificationCenter.default.post(name: .toggleEngine, object: nil) }
                .keyboardShortcut("e")
                .disabled(isTrainingWindow == true || library.isImportingFiles)
        }
    }
}
