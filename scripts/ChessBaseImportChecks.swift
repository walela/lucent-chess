import Foundation
import Darwin

@main
struct ChessBaseImportChecks {
    @MainActor static func main() async {
        setbuf(stdout, nil)
        do { try await run() }
        catch { fputs("FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    @MainActor static func run() async throws {
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
        let reader = URL(fileURLWithPath: CommandLine.arguments[2])
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("LucentChessBaseChecks-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = try Data(contentsOf: fixtures.appendingPathComponent("small.cbv"))
        let extracted = try CBVArchive.extract(archive, to: temporary.appendingPathComponent("extracted"))
        try check("CBV decompression matches the original companion files byte for byte") {
            try !extracted.isEmpty && extracted.allSatisfy { file in
                try Data(contentsOf: file) == Data(contentsOf: fixtures.appendingPathComponent("small/\(file.lastPathComponent)"))
            }
        }
        let cbv = try ChessBaseImportService.read(fixtures.appendingPathComponent("annotations.cbv"), readerURL: reader)
        let cbh = try ChessBaseImportService.read(fixtures.appendingPathComponent("annotations/TestBase.cbh"), readerURL: reader)
        try check("CBV and CBH produce the same complete game trees") {
            !cbv.games.isEmpty && cbv.skipped == 0 && cbh.skipped == 0 && cbv.games.map { tree($0.root) } == cbh.games.map { tree($0.root) }
        }
        for (folder, database, reference) in [
            ("variations", "WithVariations", "GamesWithVariations"),
            ("position", "NonStandardStart", "NonStandardStart"),
            ("promotions", "ManyPromotions", "Promotions")
        ] {
            let batch = try ChessBaseImportService.read(fixtures.appendingPathComponent("\(folder)/\(database).cbh"), readerURL: reader)
            let text = try String(contentsOf: fixtures.appendingPathComponent("\(folder)/\(reference).pgn"), encoding: .utf8)
            let expected = try PGNService.parse(text)
            try check("\(folder) preserve the reference PGN move trees and main lines") {
                batch.skipped == 0 && batch.games.count == expected.count && zip(batch.games, expected).allSatisfy {
                    tree($0.root) == tree($1.root) && $0.white == $1.white && $0.black == $1.black && $0.result == $1.result
                }
            }
        }
        let annotated = try ChessBaseImportService.read(fixtures.appendingPathComponent("annotations/TestBase.cbh"), readerURL: reader)
        try check("move symbols and text comments survive CBH import") {
            annotated.games.count == 4 && annotated.skipped == 0
                && annotated.games[0].root.children.first?.nags == [1]
                && comments(annotated.games[3].root).contains("Dieser Text")
        }
        let upper = temporary.appendingPathComponent("uppercase")
        try FileManager.default.createDirectory(at: upper, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(at: fixtures.appendingPathComponent("annotations"), includingPropertiesForKeys: nil) {
            try FileManager.default.copyItem(at: file, to: upper.appendingPathComponent(file.lastPathComponent.uppercased()))
        }
        try check("uppercase database extensions import without renaming originals") {
            try ChessBaseImportService.read(upper.appendingPathComponent("TESTBASE.CBH"), readerURL: reader).games.count == cbh.games.count
                && FileManager.default.fileExists(atPath: upper.appendingPathComponent("TESTBASE.CBH").path)
        }
        try FileManager.default.removeItem(at: upper.appendingPathComponent("TESTBASE.CBG"))
        try check("missing companions report the missing extension") {
            do { _ = try ChessBaseImportService.read(upper.appendingPathComponent("TESTBASE.CBH"), readerURL: reader); return false }
            catch { return error.localizedDescription.contains(".cbg") }
        }
        try check("archive paths cannot escape temporary storage") {
            var unsafe = archive
            unsafe.replaceSubrange(8..<140, with: Array("../outside.cbh".utf8) + Array(repeating: UInt8(0), count: 132 - "../outside.cbh".utf8.count))
            do { _ = try CBVArchive.extract(unsafe, to: temporary.appendingPathComponent("unsafe")); return false }
            catch { return !FileManager.default.fileExists(atPath: temporary.appendingPathComponent("outside.cbh").path) }
        }
        try check("truncated CBV data fails without accepting partial files") {
            do { _ = try CBVArchive.extract(archive.dropLast(), to: temporary.appendingPathComponent("truncated")); return false }
            catch { return true }
        }
        let library = LibraryStore(archiveURL: temporary.appendingPathComponent("Library.json"))
        let existingCount = library.studies.count
        let result = library.importCanonicalGames(cbv.games, sourceName: "small.cbv", sourceURL: fixtures.appendingPathComponent("small.cbv"), collectionName: "small")
        try check("ChessBase imports remain Unfiled and never become writable source files") {
            result.importedCount == cbv.games.count && result.folderName == "Unfiled"
                && library.studies.count == existingCount + cbv.games.count
                && cbv.games.allSatisfy { $0.folderID == nil && $0.filePath == nil && $0.sourceName == "small.cbv" }
        }
        let duplicates = library.importCanonicalGames(cbh.games, sourceName: "small.cbh", sourceURL: fixtures.appendingPathComponent("small/small.cbh"), collectionName: "small")
        try check("reimporting the same ChessBase games skips duplicates") {
            duplicates.importedCount == 0 && duplicates.duplicateCount == cbh.games.count
        }
        let viaOpen = LibraryStore(archiveURL: temporary.appendingPathComponent("OpenGames.json"))
        let openExistingCount = viaOpen.studies.count
        let opened = await viaOpen.importFiles(from: [fixtures.appendingPathComponent("annotations.cbv")])
        try check("Open Games locates the bundled reader and completes the asynchronous import") {
            opened && !viaOpen.isImportingFiles && viaOpen.lastError == nil
                && viaOpen.studies.count == openExistingCount + cbv.games.count && viaOpen.importNotice != nil
                && viaOpen.selectedStudy?.sourceName == "annotations.cbv"
        }
        viaOpen.saveNow()
        library.saveNow()
        let restored = LibraryStore(archiveURL: temporary.appendingPathComponent("Library.json"))
        try check("imported game trees survive a library restart") {
            restored.studies.map { tree($0.root) } == library.studies.map { tree($0.root) }
        }
        // Repeat a known valid CBH index record across multiple reader batches.
        // Its companion offsets still point into the unchanged tiny fixture files.
        let large = temporary.appendingPathComponent("large")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("annotations"), to: large)
        let indexURL = large.appendingPathComponent("TestBase.cbh")
        let index = try Data(contentsOf: indexURL)
        var repeated = Data(index.prefix(46))
        for i in 0..<10_001 {
            let offset = 46 + (i % 3) * 46
            repeated.append(index.subdata(in: offset..<(offset + 46)))
        }
        try repeated.write(to: indexURL)
        let largeBatch = try ChessBaseImportService.read(indexURL, readerURL: reader)
        try check("databases above 10,000 records import through every batch including the final partial batch") {
            largeBatch.games.count == 10_001 && largeBatch.skipped == 0
                && largeBatch.games.enumerated().allSatisfy { i, game in
                    game.black == cbh.games[i % 3].black && tree(game.root) == tree(cbh.games[i % 3].root)
                }
        }
        if CommandLine.arguments.count > 4 {
            let source = URL(fileURLWithPath: CommandLine.arguments[3])
            let expected = Int(CommandLine.arguments[4])!
            let real = try ChessBaseImportService.read(source, readerURL: reader) { completed, total in
                print("Real database: \(completed)/\(total) records")
            }
            try check("real database accounts for every source record") {
                real.games.count + real.skipped == expected
            }
            print("Real database imported \(real.games.count) games; \(real.skipped) unsupported or unreadable records.")
        }
        print("All ChessBase import checks passed.")
    }

    private static func tree(_ node: MoveNode) -> String {
        (node.moveUCI ?? node.positionFEN) + "[" + node.children.map(tree).joined(separator: ",") + "]"
    }

    private static func comments(_ node: MoveNode) -> String {
        node.comment + node.children.map(comments).joined(separator: "\n")
    }

    private static func check(_ name: String, _ test: () throws -> Bool) throws {
        guard try test() else { throw NSError(domain: "ChessBaseImportChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
        print("Passed: \(name)")
    }
}
