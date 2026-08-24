import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let importPGN = Notification.Name("LucentChess.importPGN")
    static let importSource = Notification.Name("LucentChess.importSource")
    static let showDashboard = Notification.Name("LucentChess.showDashboard")
    static let openSelectedGame = Notification.Name("LucentChess.openSelectedGame")
    static let firstMove = Notification.Name("LucentChess.firstMove")
    static let previousMove = Notification.Name("LucentChess.previousMove")
    static let nextMove = Notification.Name("LucentChess.nextMove")
    static let lastMove = Notification.Name("LucentChess.lastMove")
    static let toggleEngine = Notification.Name("LucentChess.toggleEngine")
}

struct RootView: View {
    enum InspectorTab: String, CaseIterable, Identifiable {
        case analysis = "Engine"
        case notes = "Game"
        case style = "Style"
        var id: String { rawValue }
    }

    private enum Screen { case dashboard, workspace }

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var engine: StockfishService
    @State private var importing = false
    @State private var importDestinationFolderID: UUID?
    @State private var showingSourceImport = false
    @State private var sourceImportDestinationFolderID: UUID?
    @State private var inspectorTab = InspectorTab.analysis
    @State private var screen = Screen.dashboard

    var body: some View {
        Group {
            switch screen {
            case .dashboard:
                GameDashboard(
                    openGame: open,
                    newGame: createGame,
                    importPGN: { folderID in
                        importDestinationFolderID = folderID
                        importing = true
                    },
                    importSource: { folderID in
                        sourceImportDestinationFolderID = folderID
                        showingSourceImport = true
                    }
                )
            case .workspace:
                if let study = library.selectedStudy {
                    StudyWorkspace(study: study, inspectorTab: $inspectorTab, showDashboard: showDashboard)
                } else {
                    ContentUnavailableView("No game selected", systemImage: "checkerboard.rectangle")
                        .overlay(alignment: .bottom) { Button("Back to Library", action: showDashboard).padding(30) }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [UTType(filenameExtension: "pgn") ?? .plainText],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                _ = library.importPGN(from: urls, folderID: importDestinationFolderID)
                importDestinationFolderID = nil
                if library.selectedStudy != nil { screen = .workspace }
            case let .failure(error):
                library.lastError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingSourceImport) {
            CanonicalImportView(destinationFolderID: sourceImportDestinationFolderID)
                .environmentObject(library)
        }
        .alert("Lucent Chess", isPresented: Binding(
            get: { library.lastError != nil || engine.lastError != nil },
            set: { if !$0 { library.lastError = nil; engine.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { library.lastError = nil; engine.lastError = nil }
        } message: {
            Text(library.lastError ?? engine.lastError ?? "Something went wrong.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .importPGN)) { _ in
            importDestinationFolderID = nil
            importing = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .importSource)) { _ in
            sourceImportDestinationFolderID = nil
            showingSourceImport = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDashboard)) { _ in showDashboard() }
        .onReceive(NotificationCenter.default.publisher(for: .openSelectedGame)) { _ in
            if library.selectedStudy != nil { screen = .workspace }
        }
        .onReceive(NotificationCenter.default.publisher(for: .firstMove)) { _ in navigate { $0.goToStart() } }
        .onReceive(NotificationCenter.default.publisher(for: .previousMove)) { _ in navigate { $0.goBack() } }
        .onReceive(NotificationCenter.default.publisher(for: .nextMove)) { _ in navigate { $0.goForward() } }
        .onReceive(NotificationCenter.default.publisher(for: .lastMove)) { _ in navigate { $0.goToEnd() } }
        .onReceive(NotificationCenter.default.publisher(for: .toggleEngine)) { _ in
            guard screen == .workspace, let study = library.selectedStudy else { return }
            engine.toggle(for: study.currentPosition)
        }
        .onChange(of: library.selectedStudyID) { _, _ in
            guard let study = library.selectedStudy else { return }
            engine.updatePosition(study.currentPosition)
        }
        .onOpenURL { url in
            guard url.pathExtension.lowercased() == "pgn" else { return }
            _ = library.importPGN(from: [url])
            if library.selectedStudy != nil { screen = .workspace }
        }
    }

    private func createGame(in folderID: UUID?) {
        let game = library.newStudy(folderID: folderID)
        open(game)
    }

    private func open(_ study: ChessStudy) {
        library.select(study)
        inspectorTab = .analysis
        screen = .workspace
    }

    private func showDashboard() {
        engine.stopEngine()
        screen = .dashboard
    }

    private func navigate(_ action: (ChessStudy) -> Void) {
        guard screen == .workspace, let study = library.selectedStudy else { return }
        action(study)
        library.selectionChanged()
        engine.updatePosition(study.currentPosition)
    }
}
