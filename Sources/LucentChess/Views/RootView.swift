import SwiftUI
import UniformTypeIdentifiers

enum AppWindowID {
    static let library = "library"
    static let game = "game"
}

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

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.openWindow) private var openWindow
    @State private var importing = false
    @State private var importDestinationFolderID: UUID?
    @State private var showingSourceImport = false
    @State private var sourceImportDestinationFolderID: UUID?

    var body: some View {
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
                openSelectedGame()
            case let .failure(error):
                library.lastError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingSourceImport) {
            CanonicalImportView(destinationFolderID: sourceImportDestinationFolderID)
                .environmentObject(library)
        }
        .alert("Lucent Chess", isPresented: Binding(
            get: { library.lastError != nil },
            set: { if !$0 { library.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { library.lastError = nil }
        } message: {
            Text(library.lastError ?? "Something went wrong.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .importPGN)) { _ in
            openWindow(id: AppWindowID.library)
            importDestinationFolderID = nil
            importing = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .importSource)) { _ in
            openWindow(id: AppWindowID.library)
            sourceImportDestinationFolderID = nil
            showingSourceImport = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDashboard)) { _ in
            openWindow(id: AppWindowID.library)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSelectedGame)) { _ in openSelectedGame() }
        .onOpenURL { url in
            guard url.pathExtension.lowercased() == "pgn" else { return }
            _ = library.importPGN(from: [url])
            openSelectedGame()
        }
    }

    private func createGame(in folderID: UUID?) {
        let game = library.newStudy(folderID: folderID)
        open(game)
    }

    private func open(_ study: ChessStudy) {
        library.select(study)
        openWindow(id: AppWindowID.game)
    }

    private func openSelectedGame() {
        guard library.selectedStudy != nil else { return }
        openWindow(id: AppWindowID.game)
    }
}

struct GameWindowRoot: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var engine: StockfishService
    @Environment(\.openWindow) private var openWindow
    @State private var inspectorTab = RootView.InspectorTab.analysis

    var body: some View {
        Group {
            if let study = library.selectedStudy {
                StudyWorkspace(study: study, inspectorTab: $inspectorTab, showDashboard: showLibrary)
                    .id(study.id)
            } else {
                ContentUnavailableView(
                    "No game selected",
                    systemImage: "checkerboard.rectangle",
                    description: Text("Choose a game from the library to open it here.")
                )
                .overlay(alignment: .bottom) {
                    Button("Show Library", action: showLibrary).padding(30)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Lucent Chess", isPresented: Binding(
            get: { library.lastError != nil || engine.lastError != nil },
            set: {
                if !$0 {
                    library.lastError = nil
                    engine.lastError = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                library.lastError = nil
                engine.lastError = nil
            }
        } message: {
            Text(library.lastError ?? engine.lastError ?? "Something went wrong.")
        }
        .onAppear { updateSelectedGame() }
        .onDisappear {
            engine.stopEngine()
            library.saveNow()
        }
        .onChange(of: library.selectedStudyID) { _, _ in
            inspectorTab = .analysis
            updateSelectedGame()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDashboard)) { _ in showLibrary() }
        .onReceive(NotificationCenter.default.publisher(for: .firstMove)) { _ in navigate { $0.goToStart() } }
        .onReceive(NotificationCenter.default.publisher(for: .previousMove)) { _ in navigate { $0.goBack() } }
        .onReceive(NotificationCenter.default.publisher(for: .nextMove)) { _ in navigate { $0.goForward() } }
        .onReceive(NotificationCenter.default.publisher(for: .lastMove)) { _ in navigate { $0.goToEnd() } }
        .onReceive(NotificationCenter.default.publisher(for: .toggleEngine)) { _ in
            guard let study = library.selectedStudy else { return }
            engine.toggle(for: study.currentPosition)
        }
    }

    private func navigate(_ action: (ChessStudy) -> Void) {
        guard let study = library.selectedStudy else { return }
        action(study)
        library.selectionChanged()
        engine.updatePosition(study.currentPosition)
    }

    private func updateSelectedGame() {
        guard let study = library.selectedStudy else {
            engine.stopEngine()
            return
        }
        engine.updatePosition(study.currentPosition)
    }

    private func showLibrary() {
        openWindow(id: AppWindowID.library)
    }
}
