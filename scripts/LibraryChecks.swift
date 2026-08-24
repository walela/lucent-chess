import AppKit
import Foundation

@main
struct LibraryChecks {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LucentLibraryChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = folder.appendingPathComponent("Library.json")
        let gameFile = folder.appendingPathComponent("Carlsen - Anand.pgn")
        let library = LibraryStore(archiveURL: archive)
        let game = library.newStudy(title: "World Championship")
        game.white = "Carlsen, Magnus"
        game.black = "Anand, Viswanathan"
        game.event = "World Championship"
        game.site = "Sochi"
        game.round = "2"
        game.whiteElo = "2863"
        game.blackElo = "2792"
        game.eco = "C65"
        guard let e4 = game.currentPosition.legalMove(uci: "e2e4") else { throw Failure("e4 missing") }
        _ = game.play(e4)
        library.changed()

        try check("New games appear in Autosave before an explicit PGN save") {
            game.isAutosaved && library.autosavedGameCount == 2
        }

        try library.save(game, to: gameFile)
        try check("Save writes a real PGN file") { FileManager.default.fileExists(atPath: gameFile.path) }
        try check("Saved games retain their file location and clean state") {
            game.filePath == gameFile.path && !game.hasUnsavedChanges
        }
        try check("Explicit PGN saves remove games from Autosave") {
            !game.isAutosaved && library.autosavedGameCount == 1
        }
        let savedText = try String(contentsOf: gameFile, encoding: .utf8)
        try check("PGN save includes standard game metadata") {
            savedText.contains("[White \"Carlsen, Magnus\"]") && savedText.contains("[Site \"Sochi\"]") && savedText.contains("[ECO \"C65\"]")
        }

        library.searchText = "C65"
        try check("Library search includes ECO codes") { library.filteredStudies.map(\.id) == [game.id] }
        library.searchText = "Sochi"
        try check("Library search includes sites") { library.filteredStudies.map(\.id) == [game.id] }
        library.searchText = gameFile.lastPathComponent
        try check("Library search includes PGN filenames") { library.filteredStudies.map(\.id) == [game.id] }
        library.searchText = ""

        let modifiedBeforeNavigation = game.modifiedAt
        game.goToStart()
        library.selectionChanged()
        try check("Move navigation does not dirty a saved game") {
            game.modifiedAt == modifiedBeforeNavigation && !game.hasUnsavedChanges
        }

        game.root.children.first?.comment = "Prepared offline."
        library.changed()
        try check("Editing marks a saved game as changed") { game.hasUnsavedChanges }
        library.saveSelected()
        try check("Command-S style save updates the existing PGN") {
            !game.hasUnsavedChanges && ((try? String(contentsOf: gameFile, encoding: .utf8))?.contains("Prepared offline") == true)
        }

        guard let gameFolder = library.createFolder(name: "World Championships") else { throw Failure("folder was not created") }
        library.move(game, to: gameFolder.id)
        try check("Moving a game into a folder does not dirty its PGN") {
            game.folderID == gameFolder.id && !game.hasUnsavedChanges
        }
        let duplicateFolder = library.createFolder(name: "World Championships")
        try check("Duplicate folder names are disambiguated") {
            duplicateFolder?.name == "World Championships 2"
        }

        library.saveNow()
        let reloaded = LibraryStore(archiveURL: archive)
        try check("Library recovery preserves the external PGN link") {
            reloaded.studies.first(where: { $0.id == game.id })?.filePath == gameFile.path
        }
        try check("Folders and game membership survive relaunch") {
            reloaded.folders.contains(where: { $0.id == gameFolder.id })
                && reloaded.studies.first(where: { $0.id == game.id })?.folderID == gameFolder.id
        }

        if let reloadedFolder = reloaded.folders.first(where: { $0.id == gameFolder.id }),
           let reloadedGame = reloaded.studies.first(where: { $0.id == game.id }) {
            reloaded.deleteFolder(reloadedFolder)
            try check("Removing a folder keeps its games in the library") {
                reloaded.studies.contains(where: { $0.id == reloadedGame.id }) && reloadedGame.folderID == nil
            }
        } else {
            throw Failure("reloaded folder membership missing")
        }

        let encoded = try JSONEncoder().encode(game)
        var legacyObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacyObject["root"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(game.root))
        legacyObject.removeValue(forKey: "nodes")
        for key in ["site", "round", "whiteElo", "blackElo", "eco", "filePath", "lastSavedAt", "dirtyState", "folderID", "starterCollectionID"] { legacyObject.removeValue(forKey: key) }
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        try check("Older saved studies decode without data loss") {
            (try? JSONDecoder().decode(ChessStudy.self, from: legacyData))?.white == "Carlsen, Magnus"
        }

        let longGame = ChessStudy(title: "Marathon")
        var longNode = longGame.root
        for ply in 1...600 {
            let child = MoveNode(
                parentID: longNode.id,
                moveUCI: "a1a1",
                moveSAN: "move\(ply)",
                positionFEN: ChessPosition.startFEN
            )
            longNode.children.append(child)
            longNode = child
        }
        let longGameData = try JSONEncoder().encode(longGame)
        try check("Very long games persist without recursive JSON limits") {
            (try? JSONDecoder().decode(ChessStudy.self, from: longGameData))?.mainLinePlyCount == 600
        }

        var legacyArchiveObject = try JSONSerialization.jsonObject(with: Data(contentsOf: archive)) as! [String: Any]
        legacyArchiveObject.removeValue(forKey: "folders")
        legacyArchiveObject.removeValue(forKey: "seedVersion")
        if var oldStudies = legacyArchiveObject["studies"] as? [[String: Any]] {
            for index in oldStudies.indices {
                oldStudies[index].removeValue(forKey: "folderID")
                oldStudies[index].removeValue(forKey: "starterCollectionID")
            }
            legacyArchiveObject["studies"] = oldStudies
        }
        let legacyArchiveURL = folder.appendingPathComponent("LegacyLibrary.json")
        try JSONSerialization.data(withJSONObject: legacyArchiveObject).write(to: legacyArchiveURL)
        let migratedLibrary = LibraryStore(archiveURL: legacyArchiveURL)
        try check("Pre-folder libraries migrate with their games in Unfiled") {
            migratedLibrary.studies.contains(where: { $0.id == game.id })
                && migratedLibrary.folders.isEmpty
                && migratedLibrary.studies.allSatisfy { $0.folderID == nil }
        }

        print("All game library checks passed.")
    }

    private static func check(_ name: String, _ test: () -> Bool) throws {
        guard test() else { throw Failure(name) }
        print("✓ \(name)")
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
