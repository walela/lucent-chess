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
    @Published var selectedStudyID: UUID? {
        didSet { rememberCollectionOriginal() }
    }
    @Published var lastError: String?
    @Published var importNotice: String?
    @Published var isImportingFiles = false
    @Published var fileImportProgress = "Importing games…"
    @Published var searchText = ""

    @Published var referencePositionFEN = ""
    @Published var referenceFilter = CatalogFilter()
    @Published var referenceResult = "all"
    @Published var referenceSearchRevision = 0
    func requestReferencePosition(_ fen: String) {
        var filter = referenceFilter
        filter.boardFEN = fen
        requestReferenceSearch(filter, result: referenceResult)
    }
    func requestReferenceSearch(_ filter: CatalogFilter, result: String) {
        referenceFilter = filter
        referenceResult = result
        referencePositionFEN = filter.boardFEN
        referenceSearchRevision += 1
    }
    @Published var referencePreviewFEN = ""
    @Published var catalogRevision = 0
    @Published var collectionVersions: [String:String] = [:]
    @Published var recentGameCount = 0
    @Published var folderCounts: [String: Int] = [:]
    @Published var lastImportedFolderID: UUID?
    @Published var isOpeningGame = false
    private(set) var catalog: DatabaseCatalog?
    private var importTask: Task<IndexedImportResult, Error>?
    private var openingGeneration = 0
    var totalGameCount: Int { folderCounts.values.reduce(0,+) }
    var unfiledGameCount: Int { folderCounts[""] ?? 0 }

    private let archiveURL: URL
    private var studyByID: [UUID: ChessStudy] = [:]
    private var collectionOriginal: StudyPersistenceSnapshot?
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
        do { catalog = try DatabaseCatalog(url: self.archiveURL.deletingPathExtension().appendingPathExtension("sqlite")) }
        catch { lastError = "Could not open the library index: \(error.localizedDescription)" }
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
                $0.eco ?? "", $0.result, $0.fileURL?.lastPathComponent ?? "", $0.sourceName ?? ""
            ].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var unsavedGameCount: Int { studies.filter(\.hasUnsavedChanges).count }
    var autosavedGameCount: Int { studies.count(where: \.isAutosaved) }

    @discardableResult
    func newStudy(
        title: String = "Untitled game",
        startFEN: String = ChessPosition.startFEN
    ) -> ChessStudy {
        let study = ChessStudy(title: title, startFEN: startFEN)
        studies.insert(study, at: 0)
        selectedStudyID = study.id
        saveSoon()
        return study
    }

    func select(_ study: ChessStudy) {
        do {
            let loaded = study.indexedPlyCount != nil ? try studyByID[study.id] ?? catalog?.load(study.id) ?? study : study
            if !studies.contains(where: { $0.id == loaded.id }) { studies.append(loaded) }
            if studies.count > 64 && !isImportingFiles {
                saveNow()
                studies = Array(studies.filter { $0.id != loaded.id }.suffix(63)) + [loaded]
            }
            selectedStudyID = loaded.id
        } catch { lastError = error.localizedDescription }
    }

    func openGame(_ preview: ChessStudy) async -> Bool {
        openingGeneration += 1
        let generation=openingGeneration
        isOpeningGame=true
        defer { if openingGeneration==generation {isOpeningGame=false} }
        do {
            let game: ChessStudy
            if let cached=studyByID[preview.id] {game=cached}
            else if let catalog, preview.indexedPlyCount != nil {
                game=try await Task.detached(priority:.userInitiated) {try catalog.load(preview.id)}.value
            } else {game=preview}
            guard openingGeneration==generation else {return false}
            select(game);return true
        } catch { if openingGeneration==generation {lastError=error.localizedDescription};return false }
    }

    func page(_ request: CatalogRequest, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> CatalogPage {
        guard let catalog else { throw CatalogError.message("The library index is unavailable.") }
        let worker = Task.detached(priority: .userInitiated) {
            return try InteractiveCatalogService.page(catalog:catalog,request:request,progress:progress)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }

    func refreshCatalog() {
        do {
            folderCounts = try catalog?.counts() ?? [:]
            collectionVersions = try catalog?.collectionVersions() ?? [:]
            catalogRevision += 1
            if let catalog {
                Task {
                    let count = try? await Task.detached { try catalog.recentCount() }.value
                    if let count { recentGameCount = count }
                }
            }
        }
        catch { lastError = error.localizedDescription }
    }

    func cancelImport() { importTask?.cancel() }


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
        copy.folderID = nil
        copy.starterCollectionID = nil
        copy.sourceName = nil
        copy.sourceURL = nil
        studies.insert(copy, at: 0)
        selectedStudyID = copy.id
        saveSoon()
    }

    func deleteSelected() {
        guard let id = selectedStudyID else { return }
        do { Self.persistenceQueue.sync {}; try catalog?.delete(id) } catch { lastError = error.localizedDescription; return }
        studies.removeAll { $0.id == id }
        selectedStudyID = studies.first?.id
        saveSoon(); refreshCatalog()
    }

    func delete(_ study: ChessStudy) {
        do { Self.persistenceQueue.sync {}; try catalog?.delete(study.id) } catch { lastError = error.localizedDescription; return }
        studies.removeAll { $0.id == study.id }
        if selectedStudyID == study.id { selectedStudyID = studies.first?.id }
        saveSoon(); refreshCatalog()
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
        do { Self.persistenceQueue.sync {}; try catalog?.removeFolder(folder.id) } catch { lastError = error.localizedDescription; return }
        folders.removeAll { $0.id == folder.id }
        for study in studies where study.folderID == folder.id { study.folderID = nil }
        objectWillChange.send()
        saveSoon()
    }

    func move(_ study: ChessStudy, to folderID: UUID?) {
        do { Self.persistenceQueue.sync {}; try catalog?.move(study.id, folder: validFolderID(folderID)) } catch { lastError = error.localizedDescription; return }
        refreshCatalog()
        study.folderID = validFolderID(folderID)
        if selectedStudyID == study.id { rememberCollectionOriginal() }
        objectWillChange.send()
        saveSoon()
    }

    func move(studyID: UUID, to folderID: UUID?) {
        if let study = studyByID[studyID] { move(study, to: folderID) }
        else {
            do { Self.persistenceQueue.sync {}; try catalog?.move(studyID, folder: validFolderID(folderID)); refreshCatalog() }
            catch { lastError = error.localizedDescription }
        }
    }

    func gameCount(in folder: GameFolder) -> Int {
        folderCounts[folder.id.uuidString] ?? 0
    }

    func importFiles(from urls: [URL], folderID: UUID? = nil) async -> Bool {
        guard !isImportingFiles else { return false }
        isImportingFiles = true
        lastError = nil
        importNotice = nil
        defer { isImportingFiles = false }
        var succeeded = false
        var summaries: [String] = []
        var failures: [String] = []
        for url in urls {
            do {
                guard let catalog else { throw CatalogError.message("The library index is unavailable.") }
                let destination = folderID.flatMap { id in folders.first { $0.id == id } }
                    ?? GameFolder(name: uniqueFolderName(url.deletingPathExtension().lastPathComponent))
                // Flush current edits before the indexer takes the write transaction.
                saveNow()
                let task = Task.detached(priority: .userInitiated) { [self] in
                    try IndexedDatabaseImport.importFile(url, catalog: catalog, folder: destination) { message in
                        Task { @MainActor in self.fileImportProgress = message }
                    }
                }
                importTask = task
                let result = try await task.value
                importTask = nil
                if !folders.contains(where: { $0.id == result.folder.id }) { folders.append(result.folder) }
                folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                lastImportedFolderID = result.folder.id
                summaries.append("\(url.lastPathComponent): \(result.count.formatted()) games \(result.existing ? "already available" : "indexed") in \(result.folder.name).")
                succeeded = true
                saveNow(); refreshCatalog()
            } catch is CancellationError {
                importTask = nil
                summaries.append("Import cancelled. No partially indexed games were added.")
                break
            } catch {
                importTask = nil
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { summaries.append(contentsOf: failures) }
        if !summaries.isEmpty { importNotice = summaries.joined(separator: "\n\n") }
        return succeeded
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

    @discardableResult
    func importCanonicalGames(
        _ incoming: [ChessStudy],
        sourceName: String,
        sourceURL: URL,
        collectionName: String,
        folderID requestedFolderID: UUID? = nil
    ) -> CanonicalImportMergeSummary {
        var known = Set(studies.map(Self.gameFingerprint))
        var accepted: [ChessStudy] = []
        accepted.reserveCapacity(incoming.count)
        var duplicateCount = 0

        for game in incoming {
            let fingerprint = Self.gameFingerprint(game)
            guard known.insert(fingerprint).inserted, (try? catalog?.containsFingerprint(fingerprint)) != true else {
                duplicateCount += 1
                continue
            }
            accepted.append(game)
        }

        guard !accepted.isEmpty else {
            let existingName = validFolderID(requestedFolderID)
                .flatMap { id in folders.first(where: { $0.id == id })?.name }
                ?? "Unfiled"
            return CanonicalImportMergeSummary(importedCount: 0, duplicateCount: duplicateCount, folderName: existingName)
        }

        let destination = validFolderID(requestedFolderID)
            .flatMap { id in folders.first(where: { $0.id == id }) }
            ?? folders.first(where: { $0.name == collectionName })
            ?? createFolder(name: collectionName)
        lastImportedFolderID = destination?.id

        let importedAt = Date()
        for game in accepted {
            game.folderID = destination?.id
            game.sourceName = sourceName
            game.sourceURL = sourceURL.absoluteString
            game.filePath = nil
            game.createdAt = importedAt
            game.modifiedAt = importedAt
            game.lastSavedAt = importedAt
            game.dirtyState = false
        }
        studies.insert(contentsOf: accepted, at: 0)
        saveNow()
        return CanonicalImportMergeSummary(
            importedCount: accepted.count,
            duplicateCount: duplicateCount,
            folderName: destination?.name ?? "Unfiled"
        )
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
        if study.databaseReference != nil { return }
        study.filePath = url.path
        study.lastSavedAt = Date()
        study.dirtyState = false
        study.sourceName = nil
        study.sourceURL = nil
        study.markChanged(notation: false)
        if selectedStudyID == study.id { rememberCollectionOriginal() }
        saveSoon()
    }

    func changed(notation: Bool = false) {
        guard let study = selectedStudy else { return }
        // Editors mutate the current object before calling changed. Keep that
        // object as the draft so bindings and text focus survive the first edit.
        if let original = collectionOriginal, original.id == study.id, (study.folderID != nil || study.databaseReference != nil) {
            var content = StudyPersistenceSnapshot(study)
            content.lastNodeID = original.lastNodeID
            content.modifiedAt = original.modifiedAt
            content.dirtyState = original.dirtyState
            if content == original {
                study.modifiedAt = original.modifiedAt
                study.dirtyState = original.dirtyState
                study.markSelectionChanged()
                saveSoon()
                return
            }
            do {
                let restored = try original.makeStudy()
                restored.databaseReference = study.databaseReference
                guard let index = studies.firstIndex(where: { $0 === study }) else { return }
                study.id = UUID()
                study.databaseReference = nil
                study.indexedPlyCount = nil
                study.folderID = nil
                study.starterCollectionID = nil
                study.filePath = nil
                study.lastSavedAt = nil
                study.sourceName = nil
                study.sourceURL = nil
                study.createdAt = Date()
                studies[index] = restored
                studies.insert(study, at: 0)
                selectedStudyID = study.id
            } catch {
                lastError = "Could not preserve the collection original: \(error.localizedDescription)"
                return
            }
        }
        study.modifiedAt = Date()
        study.dirtyState = true
        study.markChanged(notation: notation)
        saveSoon()
    }

    private func rememberCollectionOriginal() {
        collectionOriginal = selectedStudy.flatMap { study in
            (study.folderID == nil && study.databaseReference == nil) ? nil : StudyPersistenceSnapshot(study)
        }
    }

    func selectionChanged() {
        selectedStudy?.markSelectionChanged()
    }

    func saveSoon() {
        guard importTask == nil else { return }
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
        guard importTask == nil else { return }
        pendingSave?.cancel(); pendingSave = nil; saveGeneration += 1
        guard let catalog else { return }
        do {
            let local = studies.filter { $0.databaseReference == nil }
            let fingerprints = Dictionary(uniqueKeysWithValues: local.map { ($0.id.uuidString, Self.gameFingerprint($0)) })
            let snapshots = local.map(StudyPersistenceSnapshot.init)
            let state = CatalogLibraryState(selectedStudyID: selectedStudyID, folders: folders, seedVersion: installedSeedVersion)
            try Self.persistenceQueue.sync {
                try catalog.saveSnapshots(snapshots, fingerprints: fingerprints)
                try catalog.saveMetadata("state", value: state)
            }
            refreshCatalog()
        } catch { lastError = error.localizedDescription }
    }

    private func saveSnapshotInBackground() {
        guard let catalog else { return }
        let local = studies.filter { $0.databaseReference == nil }
        let snapshots = local.map(StudyPersistenceSnapshot.init)
        let fingerprints = Dictionary(uniqueKeysWithValues: local.map { ($0.id.uuidString, Self.gameFingerprint($0)) })
        let state = CatalogLibraryState(selectedStudyID: selectedStudyID, folders: folders, seedVersion: installedSeedVersion)
        Self.persistenceQueue.async { [weak self] in
            do {
                try catalog.saveSnapshots(snapshots, fingerprints: fingerprints)
                try catalog.saveMetadata("state", value: state)
                DispatchQueue.main.async { self?.refreshCatalog() }
            } catch { DispatchQueue.main.async { self?.lastError = error.localizedDescription } }
        }
    }

    private func load() {
        guard let catalog else { return }
        do {
            if let state = try catalog.metadata("state", as: CatalogLibraryState.self) {
                folders = state.folders; installedSeedVersion = state.seedVersion
                // A crash or disk error can happen after indexing commits but before
                // the window's collection metadata is saved. Recover that collection.
                let known=Set(folders.map(\.id))
                folders += try catalog.committedSourceFolders().filter { !known.contains($0.id) }
                if let id = state.selectedStudyID, let game = try? catalog.load(id) { studies = [game]; selectedStudyID = id }
                refreshCatalog()
                return
            }
            // One-time migration. Keep Library.json untouched as a recovery backup.
            if FileManager.default.fileExists(atPath: archiveURL.path) {
                let data = try Data(contentsOf: archiveURL)
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                if let snapshot = try? decoder.decode(LibraryPersistenceSnapshot.self, from: data) {
                    studies = try snapshot.makeStudies(); folders = snapshot.folders ?? []
                    installedSeedVersion = snapshot.seedVersion ?? 0; selectedStudyID = snapshot.selectedStudyID
                } else {
                    let archive = try decoder.decode(LibraryArchive.self, from: data)
                    studies = archive.studies; folders = archive.folders ?? []
                    installedSeedVersion = archive.seedVersion ?? 0; selectedStudyID = archive.selectedStudyID
                }
                let imported = Dictionary(grouping: studies.filter { $0.sourceURL != nil && ["cbv","cbh"].contains(URL(string:$0.sourceURL!)?.pathExtension.lowercased() ?? "") }, by: { $0.sourceURL! })
                for (sourceURL, games) in imported {
                    let name = URL(string:sourceURL)?.deletingPathExtension().lastPathComponent ?? "Imported database"
                    let destination = games.compactMap { $0.folderID }.first.flatMap { id in folders.first { $0.id == id } }
                        ?? GameFolder(name: uniqueFolderName(name))
                    if !folders.contains(where: { $0.id == destination.id }) { folders.append(destination) }
                    for game in games where game.folderID == nil { game.folderID = destination.id }
                    try catalog.addSource(id: UUID().uuidString, path:"",kind:"legacy",name:destination.name,original:sourceURL,hash:nil,folder:destination.id,count:games.count)
                }
            } else {
                studies = [Self.welcomeStudy()]; selectedStudyID = studies.first?.id
            }
            saveNow()
            // Retain only the working game after migration; other games open from SQLite.
            studies = studies.filter { $0.id == selectedStudyID }
            refreshCatalog()
        } catch {
            lastError = "The existing library could not be migrated. Its JSON backup is unchanged: \(error.localizedDescription)"
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

    static func gameFingerprint(_ study: ChessStudy) -> String {
        if let site = study.site,
           let match = site.range(of: #"(?i)lichess\.org/([a-z0-9]{8})"#, options: .regularExpression) {
            let matched = String(site[match])
            if let id = matched.split(separator: "/").last {
                return "lichess:\(id.lowercased())"
            }
        }

        var moves: [String] = []
        var node = study.root
        while let child = node.children.first {
            if let move = child.moveUCI { moves.append(move) }
            node = child
        }
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: study.date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let normalize: (String) -> String = {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .lowercased()
        }
        return [
            normalize(study.white), normalize(study.black), day, study.result,
            study.root.positionFEN, moves.joined(separator: " ")
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

struct CanonicalImportMergeSummary: Equatable {
    let importedCount: Int
    let duplicateCount: Int
    let folderName: String
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

private struct CatalogLibraryState: Codable {
    var selectedStudyID: UUID?
    var folders: [GameFolder]
    var seedVersion: Int
}
