import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class LibraryStore: ObservableObject {
    @Published var studies: [ChessStudy] = [] {
        didSet {
            var index: [UUID: ChessStudy] = [:]
            index.reserveCapacity(studies.count)
            for study in studies { index[study.id] = study }
            studyByID = index
        }
    }
    @Published var folders: [GameFolder] = []
    @Published var selectedStudyID: UUID?
    @Published var lastError: String?
    @Published var searchText = ""

    private let archiveURL: URL
    private var studyByID: [UUID: ChessStudy] = [:]
    private var pendingSave: DispatchWorkItem?
    private var saveGeneration = 0
    private var installedSeedVersion = 0
    private static let persistenceQueue = DispatchQueue(label: "local.lucent.chess.persistence", qos: .utility)

    init(archiveURL: URL? = nil, starterGamesURL: URL? = nil) {
        let shouldUseBundledStarterGames = archiveURL == nil && starterGamesURL == nil
        if let archiveURL {
            self.archiveURL = archiveURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.archiveURL = base.appendingPathComponent("Lucent Chess", isDirectory: true).appendingPathComponent("Library.json")
        }
        load()
        if let starterGamesURL = starterGamesURL ?? (shouldUseBundledStarterGames ? Self.bundledStarterGamesURL() : nil) {
            installStarterGamesIfNeeded(from: starterGamesURL)
        }
    }

    var selectedStudy: ChessStudy? {
        guard let id = selectedStudyID else { return nil }
        return studyByID[id]
    }

    var filteredStudies: [ChessStudy] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return studies }
        return studies.filter {
            [
                $0.title, $0.white, $0.black, $0.event, $0.site ?? "", $0.round ?? "",
                $0.eco ?? "", $0.result, $0.fileURL?.lastPathComponent ?? ""
            ].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var unsavedGameCount: Int { studies.filter(\.hasUnsavedChanges).count }
    var autosavedGameCount: Int { studies.count(where: \.isAutosaved) }

    @discardableResult
    func newStudy(
        title: String = "New Game",
        startFEN: String = ChessPosition.startFEN,
        folderID: UUID? = nil
    ) -> ChessStudy {
        let study = ChessStudy(title: title, startFEN: startFEN)
        study.folderID = validFolderID(folderID)
        studies.insert(study, at: 0)
        selectedStudyID = study.id
        saveSoon()
        return study
    }

    func select(_ study: ChessStudy) {
        selectedStudyID = study.id
    }

    func duplicateSelected() {
        guard let selectedStudy,
              let copy = try? StudyPersistenceSnapshot(selectedStudy).makeStudy() else { return }
        copy.id = UUID()
        copy.title += " copy"
        copy.createdAt = Date()
        copy.modifiedAt = Date()
        copy.filePath = nil
        copy.lastSavedAt = nil
        copy.dirtyState = nil
        studies.insert(copy, at: 0)
        selectedStudyID = copy.id
        saveSoon()
    }

    func deleteSelected() {
        guard let id = selectedStudyID, let index = studies.firstIndex(where: { $0.id == id }) else { return }
        studies.remove(at: index)
        selectedStudyID = studies.first?.id
        saveSoon()
    }

    func delete(_ study: ChessStudy) {
        selectedStudyID = study.id
        deleteSelected()
    }

    @discardableResult
    func createFolder(name: String) -> GameFolder? {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let uniqueName = uniqueFolderName(cleaned)
        let folder = GameFolder(name: uniqueName)
        folders.append(folder)
        folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveSoon()
        return folder
    }

    func renameFolder(_ folder: GameFolder, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        folders[index].name = uniqueFolderName(cleaned, excluding: folder.id)
        folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveSoon()
    }

    func deleteFolder(_ folder: GameFolder) {
        folders.removeAll { $0.id == folder.id }
        for study in studies where study.folderID == folder.id { study.folderID = nil }
        objectWillChange.send()
        saveSoon()
    }

    func move(_ study: ChessStudy, to folderID: UUID?) {
        study.folderID = validFolderID(folderID)
        objectWillChange.send()
        saveSoon()
    }

    func move(studyID: UUID, to folderID: UUID?) {
        guard let study = studyByID[studyID] else { return }
        move(study, to: folderID)
    }

    func gameCount(in folder: GameFolder) -> Int {
        studies.count { $0.folderID == folder.id }
    }

    @discardableResult
    func importPGN(from urls: [URL], folderID: UUID? = nil) -> [ChessStudy] {
        do {
            var imported: [ChessStudy] = []
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let games = try PGNService.parse(String(contentsOf: url, encoding: .utf8))
                if games.count == 1, let game = games.first {
                    game.filePath = url.path
                    game.lastSavedAt = Date()
                    game.dirtyState = false
                    if let index = studies.firstIndex(where: { $0.filePath == url.path }) {
                        game.folderID = studies[index].folderID
                        game.id = studies[index].id
                        studies[index] = game
                    } else {
                        game.folderID = validFolderID(folderID)
                        imported.append(game)
                    }
                } else {
                    for game in games { game.folderID = validFolderID(folderID) }
                    imported.append(contentsOf: games)
                }
            }
            studies.insert(contentsOf: imported, at: 0)
            if let first = imported.first { selectedStudyID = first.id }
            else if urls.count == 1 { selectedStudyID = studies.first(where: { $0.filePath == urls[0].path })?.id ?? selectedStudyID }
            saveSoon()
            return imported
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    func saveSelected() {
        guard let selectedStudy else { return }
        if let url = selectedStudy.fileURL {
            do { try save(selectedStudy, to: url) }
            catch { lastError = error.localizedDescription }
        } else {
            saveSelectedAs()
        }
    }

    func saveSelectedAs() {
        guard let selectedStudy else { return }
        let panel = NSSavePanel()
        panel.title = "Save Chess Game"
        panel.message = "Save this game as a standard PGN file that other chess applications can open."
        panel.allowedContentTypes = [UTType(filenameExtension: "pgn") ?? .plainText]
        panel.nameFieldStringValue = selectedStudy.suggestedFileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try save(selectedStudy, to: url) }
        catch { lastError = error.localizedDescription }
    }

    func exportSelectedPGN() { saveSelectedAs() }

    func save(_ study: ChessStudy, to url: URL) throws {
        try PGNService.export(study).write(to: url, atomically: true, encoding: .utf8)
        study.filePath = url.path
        study.lastSavedAt = Date()
        study.dirtyState = false
        study.markChanged(notation: false)
        saveSoon()
    }

    func changed(notation: Bool = false) {
        guard let study = selectedStudy else { return }
        study.modifiedAt = Date()
        study.dirtyState = true
        study.markChanged(notation: notation)
        saveSoon()
    }

    func selectionChanged() {
        selectedStudy?.markSelectionChanged()
    }

    func saveSoon() {
        pendingSave?.cancel()
        saveGeneration += 1
        let generation = saveGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.saveGeneration == generation else { return }
            self.pendingSave = nil
            self.saveSnapshotInBackground()
        }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        saveGeneration += 1
        let snapshot = persistenceSnapshot()
        do {
            try Self.persistenceQueue.sync {
                try Self.write(Self.encode(snapshot), to: archiveURL)
            }
        } catch { lastError = error.localizedDescription }
    }

    private func saveSnapshotInBackground() {
        let snapshot = persistenceSnapshot()
        let destination = archiveURL
        Self.persistenceQueue.async { [weak self] in
            do {
                let data = try Self.encode(snapshot)
                try Self.write(data, to: destination)
            } catch {
                DispatchQueue.main.async { self?.lastError = error.localizedDescription }
            }
        }
    }

    private func persistenceSnapshot() -> LibraryPersistenceSnapshot {
        LibraryPersistenceSnapshot(
            studies: studies,
            selectedStudyID: selectedStudyID,
            folders: folders,
            seedVersion: installedSeedVersion
        )
    }

    nonisolated private static func encode(_ snapshot: LibraryPersistenceSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    nonisolated private static func write(_ data: Data, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    private func load() {
        do {
            let data = try Data(contentsOf: archiveURL)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            if let snapshot = try? decoder.decode(LibraryPersistenceSnapshot.self, from: data) {
                studies = try snapshot.makeStudies()
                folders = (snapshot.folders ?? []).sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                installedSeedVersion = snapshot.seedVersion ?? 0
                selectedStudyID = snapshot.selectedStudyID ?? studies.first?.id
            } else {
                // Pre-1.7 libraries stored recursive move trees. Retain this one-way
                // compatibility path; the next save upgrades them to flat snapshots.
                let archive = try decoder.decode(LibraryArchive.self, from: data)
                studies = archive.studies
                folders = (archive.folders ?? []).sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                installedSeedVersion = archive.seedVersion ?? 0
                selectedStudyID = archive.selectedStudyID ?? studies.first?.id
            }

            let knownFolderIDs = Set(folders.map(\.id))
            for study in studies where study.folderID.map({ !knownFolderIDs.contains($0) }) == true {
                study.folderID = nil
            }
        } catch {
            let welcome = Self.welcomeStudy()
            studies = [welcome]
            selectedStudyID = welcome.id
            saveNow()
        }
    }

    private func validFolderID(_ id: UUID?) -> UUID? {
        guard let id, folders.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private func uniqueFolderName(_ requested: String, excluding excludedID: UUID? = nil) -> String {
        let existing = Set(folders.filter { $0.id != excludedID }.map { $0.name.lowercased() })
        guard existing.contains(requested.lowercased()) else { return requested }
        var number = 2
        while existing.contains("\(requested) \(number)".lowercased()) { number += 1 }
        return "\(requested) \(number)"
    }

    private func installStarterGamesIfNeeded(from resourceURL: URL) {
        guard installedSeedVersion < StarterGameCollection.currentVersion else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let starterArchive = try decoder.decode(
                LibraryArchive.self,
                from: Data(contentsOf: resourceURL.appendingPathComponent("StarterGames.json"))
            )
            let parsedCollections = StarterGameCollection.all.map { collection in
                (collection, starterArchive.studies.filter { $0.starterCollectionID == collection.id })
            }

            var knownFingerprints = Set(studies.map(Self.gameFingerprint))
            for (collection, parsedGames) in parsedCollections {
                let newGames = parsedGames.filter { !knownFingerprints.contains(Self.gameFingerprint($0)) }
                guard !newGames.isEmpty else { continue }
                let destination = folders.first(where: {
                    $0.name.compare(collection.folderName, options: .caseInsensitive) == .orderedSame
                }) ?? createFolder(name: collection.folderName)!
                for game in newGames {
                    game.title = "Game \(game.round ?? "?")"
                    game.event = collection.folderName
                    game.folderID = destination.id
                    game.starterCollectionID = collection.id
                    game.createdAt = game.date
                    game.modifiedAt = game.date
                    game.lastSavedAt = game.date
                    game.dirtyState = false
                    knownFingerprints.insert(Self.gameFingerprint(game))
                }
                studies.append(contentsOf: newGames)
            }
            installedSeedVersion = StarterGameCollection.currentVersion
            saveNow()
        } catch {
            lastError = "The bundled starter games could not be installed: \(error.localizedDescription)"
        }
    }

    private static func gameFingerprint(_ study: ChessStudy) -> String {
        var moves: [String] = []
        var node = study.root
        while let child = node.children.first {
            if let move = child.moveUCI { moves.append(move) }
            node = child
        }
        return [
            study.white.lowercased(), study.black.lowercased(), study.event.lowercased(),
            study.round ?? "", study.result, moves.joined(separator: " ")
        ].joined(separator: "|")
    }

    private static func bundledStarterGamesURL() -> URL? {
        for bundle in [Bundle.main] + Bundle.allBundles {
            if let resources = bundle.resourceURL {
                let direct = resources.appendingPathComponent("SeedGames", isDirectory: true)
                if FileManager.default.fileExists(atPath: direct.path) { return direct }
                let nested = resources.appendingPathComponent("Resources/SeedGames", isDirectory: true)
                if FileManager.default.fileExists(atPath: nested.path) { return nested }
            }
        }
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LucentChess/Resources/SeedGames", isDirectory: true)
        return FileManager.default.fileExists(atPath: development.path) ? development : nil
    }

    private static func welcomeStudy() -> ChessStudy {
        let study = ChessStudy(title: "Welcome to Lucent Chess", white: "Your ideas", black: "The position", event: "A local study")
        let main = ["e2e4", "e7e5", "g1f3", "b8c6", "f1b5"]
        for uci in main {
            if let move = study.currentPosition.legalMove(uci: uci) { _ = study.play(move) }
        }
        study.currentNode.comment = "Add comments here, explore alternatives on the board, and ask your local Stockfish what it thinks. Everything stays on this Mac."
        study.goToStart()
        if let d4 = study.currentPosition.legalMove(uci: "d2d4") { _ = study.play(d4) }
        study.currentNode.comment = "Playing a different move at any earlier position creates a variation automatically."
        study.goToStart()
        return study
    }
}

private struct StarterGameCollection {
    static let currentVersion = 1
    static let all = [
        StarterGameCollection(id: "candidates-2026-open", fileName: "wchcand26.pgn", folderName: "Candidates 2026"),
        StarterGameCollection(id: "candidates-2026-women", fileName: "wchwcand26.pgn", folderName: "Women’s Candidates 2026"),
        StarterGameCollection(id: "kasparov-karpov-1984", fileName: "WorldChamp1984.pgn", folderName: "Kasparov–Karpov 1984"),
        StarterGameCollection(id: "kasparov-karpov-1985", fileName: "WorldChamp1985.pgn", folderName: "Kasparov–Karpov 1985"),
        StarterGameCollection(id: "kasparov-karpov-1986", fileName: "WorldChamp1986.pgn", folderName: "Kasparov–Karpov 1986"),
        StarterGameCollection(id: "kasparov-karpov-1987", fileName: "WorldChamp1987.pgn", folderName: "Kasparov–Karpov 1987"),
        StarterGameCollection(id: "kasparov-karpov-1990", fileName: "WorldChamp1990.pgn", folderName: "Kasparov–Karpov 1990")
    ]

    let id: String
    let fileName: String
    let folderName: String
}
