import AppKit
import Foundation

@main
struct CollectionDraftChecks {
    @MainActor static func main() throws {
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("CollectionDraftChecks-\(UUID()).json")
        let library = LibraryStore(archiveURL: archive)
        let folder = library.createFolder(name: "Reference games")!
        let game = library.newStudy(title: "Reference")
        let originalID = game.id
        _ = game.play(game.currentPosition.legalMove(uci: "e2e4")!)
        library.changed(notation: true)
        game.dirtyState = false
        library.move(game, to: folder.id)
        let originalPGN = PGNService.export(game)
        let count = library.studies.count

        game.goToStart()
        library.selectionChanged()
        _ = game.play(game.currentPosition.legalMove(uci: "e2e4")!)
        library.changed(notation: true)
        try check("replaying existing moves does not create a draft or dirty the original") {
            library.studies.count == count && game.id == originalID && !game.hasUnsavedChanges
        }
        _ = game.play(game.currentPosition.legalMove(uci: "c7c5")!)
        library.changed(notation: true)
        let draftID = game.id
        try check("first edit creates one selected Unfiled draft and preserves original PGN") {
            draftID != originalID && game.folderID == nil && library.selectedStudy === game
                && library.studies.count == count + 1
                && PGNService.export(library.studies.first { $0.id == originalID }!) == originalPGN
        }
        game.currentNode.comment = "My analysis"
        library.changed(notation: true)
        try check("continued edits reuse the draft") { game.id == draftID && library.studies.count == count + 1 }
        library.saveNow()
        let restored = LibraryStore(archiveURL: archive)
        try check("draft and collection original both survive restart") {
            restored.selectedStudy?.id == draftID && restored.selectedStudy?.folderID == nil
                && restored.selectedStudy?.currentNode.comment == "My analysis"
                && (try? PGNService.export(restored.catalog!.load(originalID))) == originalPGN
        }
        library.move(game, to: folder.id)
        let filedPGN = PGNService.export(game)
        game.white = "Annotated by me"
        library.changed()
        try check("editing metadata after explicit filing creates a new Unfiled draft") {
            game.id != draftID && game.folderID == nil
                && PGNService.export(library.studies.first { $0.id == draftID }!) == filedPGN
        }
        let filed = library.studies.first { $0.id == originalID }!
        library.select(filed)
        filed.starterCollectionID = "fixture"
        library.duplicateSelected()
        try check("duplicates never inherit collection or bundled-game identity") {
            library.selectedStudy?.folderID == nil && library.selectedStudy?.starterCollectionID == nil
        }
        library.select(filed)
        let fresh = library.newStudy()
        try check("new game is Unfiled while a collection game was selected") { fresh.folderID == nil }

        let source = URL(string: "https://example.org/games")!
        let imported = ChessStudy(white: "White A", black: "Black A")
        let result = library.importCanonicalGames([imported], sourceName: "Fixture", sourceURL: source, collectionName: "Implicit")
        try check("source imports create a named collection by default") {
            imported.folderID != nil && result.folderName == "Implicit" && library.folders.contains { $0.name == "Implicit" }
        }
        let explicit = ChessStudy(white: "White B", black: "Black B")
        library.importCanonicalGames([explicit], sourceName: "Fixture", sourceURL: source, collectionName: "Ignored", folderID: folder.id)
        try check("explicitly selected import destination is respected") { explicit.folderID == folder.id }
        library.select(explicit)
        explicit.root.comment = "Study note"
        library.changed(notation: true)
        try check("notes on a collected import preserve the source and clear draft provenance") {
            explicit.folderID == nil && explicit.sourceName == nil && explicit.filePath == nil
        }
        library.saveNow()
        print("All collection draft checks passed.")
    }
    private static func check(_ name: String, _ test: () -> Bool) throws {
        guard test() else { throw NSError(domain: "CollectionDraftChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
        print("✓ \(name)")
    }
}
