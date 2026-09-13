import AppKit
import Foundation

@main
struct CatalogChecks {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LucentCatalogChecks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Library.json")
        let library = LibraryStore(archiveURL: archive)
        try check("new catalog opens without errors") { library.lastError == nil && library.totalGameCount == 1 }
        let input = root.appendingPathComponent("Import.cbv")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("annotations.cbv"), to: input)
        let began = Date()
        let success = await library.importFiles(from: [input])
        try check("database import creates and selects a named collection") {
            success && library.folders.contains { $0.name == "Import" && $0.id == library.lastImportedFolderID }
        }
        let folder = library.folders.first { $0.name == "Import" }!
        try check("indexing counts games without constructing or caching their move trees") {
            library.gameCount(in: folder) == 4 && library.totalGameCount == 5 && library.studies.count == 1
        }
        var request = CatalogRequest(); request.folder = folder.id.uuidString
        let page = try await library.page(request)
        try check("paged results carry metadata and references instead of move trees") {
            page.count == 4 && page.games.count == 4 && page.games.allSatisfy { $0.indexedPlyCount != nil && $0.root.children.isEmpty }
        }
        let catalog = library.catalog!
        let expected = try ChessBaseImportService.read(input)
        for preview in page.games {
            let loaded = try catalog.load(preview.id)
            let original = expected.games.first { $0.black == loaded.black }!
            try check("on-demand game preserves \(loaded.black) moves and annotations") {
                PGNService.export(loaded) == PGNService.export(original)
            }
        }
        let prior = library.totalGameCount
        _ = await library.importFiles(from: [input])
        try check("reimporting the same database adds no duplicate records or collections") {
            library.totalGameCount == prior && library.folders.filter { $0.name == "Import" }.count == 1
        }
        try FileManager.default.removeItem(at: input)
        let first = page.games[0]
        let originalPGN = PGNService.export(try catalog.load(first.id))
        library.select(first)
        library.selectedStudy!.root.comment += " Private study note"
        library.changed(notation: true)
        library.saveNow()
        try check("editing an indexed original creates an Unfiled draft and retains source game") {
            library.selectedStudy?.id != first.id && library.selectedStudy?.folderID == nil
                && library.selectedStudy?.databaseReference == nil
                && (try? PGNService.export(catalog.load(first.id))) == originalPGN
        }
        let reopened = LibraryStore(archiveURL: archive)
        try check("restart loads a bounded working set and keeps collection counts and draft") {
            reopened.totalGameCount == prior+1 && reopened.studies.count <= 1 && reopened.selectedStudy?.root.comment.contains("Private study note") == true
        }
        expected.games[0].whiteElo = "2712"; expected.games[0].blackElo = "2638"
        let pgn = root.appendingPathComponent("Portable collection.pgn")
        try (expected.games.map(PGNService.export).joined(separator:"\n")).write(to:pgn,atomically:true,encoding:.utf8)
        let pgnSuccess = await library.importFiles(from:[pgn])
        let pgnFolder = library.lastImportedFolderID!
        request.folder = pgnFolder.uuidString
        let pgnPage = try await library.page(request)
        try check("PGN databases are indexed into their own collection without eager SAN parsing") {
            pgnSuccess && pgnPage.count == 4 && pgnPage.games.allSatisfy { $0.root.children.isEmpty }
        }
        for preview in pgnPage.games {
            let game = try catalog.load(preview.id)
            try check("PGN byte range opens the correct \(game.black) game") {
                expected.games.contains { $0.black == game.black && PGNService.export($0) == PGNService.export(game) }
            }
        }
        let rated = pgnPage.games.first { $0.black == expected.games[0].black }!
        try check("PGN previews expose both Elo ratings without loading moves") {
            rated.whiteElo == "2712" && rated.blackElo == "2638" && rated.root.children.isEmpty
        }
        // Simulate the previously shipped SQLite schema, then upgrade it in place.
        do {
            let old = try SQLConnection(catalog.url)
            for name in ["white_elo", "black_elo", "elo_indexed"] { try old.exec("ALTER TABLE games DROP COLUMN \(name)") }
        }
        let upgraded = try DatabaseCatalog(url: catalog.url)
        let upgradedPage = try upgraded.page(request)
        try check("existing PGN catalogs recover ratings from headers on a bounded page") {
            upgradedPage.games.contains { $0.black == rated.black && $0.whiteElo == "2712" && $0.blackElo == "2638" && $0.root.children.isEmpty }
        }
        request.search = "Symbol"; request.cursor = nil
        let search = try await library.page(request)
        try check("indexed prefix search filters metadata") { search.count == 1 && search.games[0].black == "Symbol" }
        let legacyURL = root.appendingPathComponent("Legacy.json")
        let legacy = expected.games[0]
        legacy.sourceName = "Prior.cbv";legacy.sourceURL = URL(fileURLWithPath:"/tmp/Prior.cbv").absoluteString
        let snapshot = LibraryPersistenceSnapshot(studies:[legacy],selectedStudyID:legacy.id,folders:[],seedVersion:1)
        let encoder = JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        let backup = try encoder.encode(snapshot);try backup.write(to:legacyURL)
        let migrated = LibraryStore(archiveURL:legacyURL)
        try check("legacy JSON migrates intact and old database imports get a collection") {
            migrated.lastError == nil && migrated.totalGameCount == 1 && migrated.folders.first?.name == "Prior"
                && migrated.selectedStudy?.folderID != nil && (try? Data(contentsOf:legacyURL)) == backup
                && migrated.selectedStudy?.mainLinePlyCount == legacy.mainLinePlyCount
        }
        do {
            let db = try SQLConnection(migrated.catalog!.url)
            try db.exec("UPDATE games SET white_elo=NULL,black_elo=NULL,elo_indexed=0")
        }
        let oldPayloadPage = try migrated.catalog!.page(CatalogRequest())
        try check("existing saved games recover both ratings without rebuilding move trees") {
            oldPayloadPage.games.first?.whiteElo == "2712" && oldPayloadPage.games.first?.blackElo == "2638" && oldPayloadPage.games.first?.root.children.isEmpty == true
        }
        let queryWorker = Task.detached {
            let connection = try SQLConnection(catalog.url)
            try connection.exec("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000000) SELECT sum(x) FROM n")
        }
        try await Task.sleep(for:.milliseconds(20)); queryWorker.cancel()
        var interrupted = false
        do { try await queryWorker.value } catch is CancellationError { interrupted = true }
        try check("cancelled searches interrupt SQLite work promptly") { interrupted }
        let small = fixtures.appendingPathComponent("small.cbv")
        let unpacked = try CBVArchive.extractFile(small, to:root.appendingPathComponent("streamed"))
        try check("streaming compressed CBV extraction preserves every companion byte") {
            unpacked.allSatisfy { file in
                (try? Data(contentsOf:file)) == (try? Data(contentsOf:fixtures.appendingPathComponent("small/" + file.lastPathComponent)))
            }
        }
        let many = root.appendingPathComponent("Many games.pgn")
        let one = PGNService.export(expected.games[0])
        try String(repeating:one+"\n",count:601).write(to:many,atomically:true,encoding:.utf8)
        _ = await library.importFiles(from:[many])
        var paging = CatalogRequest();paging.folder = library.lastImportedFolderID!.uuidString
        var ids = Set<UUID>(), pages = 0
        repeat {
            let result = try await library.page(paging)
            try check("page \(pages+1) stays bounded and has no repeated records") {
                result.count == 601 && result.games.count <= DatabaseCatalog.pageSize && result.games.allSatisfy { ids.insert($0.id).inserted }
            }
            pages += 1;paging.cursor = result.next
        } while paging.cursor != nil && pages < 10
        try check("keyset pagination reaches the exact final record") { ids.count == 601 && pages == 4 }
        let ratingFolder = UUID()
        let ratingGames = (0..<451).map { index in
            let game = ChessStudy(white: "Rating \(index)", black: "Opponent", whiteElo: index % 17 == 0 ? nil : String(900 + index * 137 % 2000), blackElo: String(800 + index * 83 % 2100))
            game.folderID = ratingFolder
            return game
        }
        try catalog.save(ratingGames)
        do {
            let db = try SQLConnection(catalog.url)
            let reset = try db.prepare("UPDATE games SET white_elo=NULL,black_elo=NULL,elo_indexed=0 WHERE folder=?")
            try reset.bind([.text(ratingFolder.uuidString)]); try reset.run()
        }
        for field in ["whiteElo", "blackElo"] {
            for ascending in [true, false] {
                var request = CatalogRequest(); request.folder = ratingFolder.uuidString
                request.sort = field; request.ascending = ascending
                var result: [ChessStudy] = []
                repeat {
                    let page = try catalog.page(request); result += page.games; request.cursor = page.next
                } while request.cursor != nil
                let ratings = result.map { Int((field == "whiteElo" ? $0.whiteElo : $0.blackElo) ?? "") ?? 0 }
                let expected = ratingGames.map { Int((field == "whiteElo" ? $0.whiteElo : $0.blackElo) ?? "") ?? 0 }.sorted(by: ascending ? (<) : (>))
                try check("\(field) sorts numerically \(ascending ? "ascending" : "descending") across all pages, including legacy metadata and missing ratings") {
                    ratings == expected && Set(result.map(\.id)).count == ratingGames.count && result.allSatisfy { $0.root.children.isEmpty }
                }
            }
        }
        if CommandLine.arguments.count > 2 {
            let real = URL(fileURLWithPath:CommandLine.arguments[2])
            let timer = Date()
            _ = await library.importFiles(from:[real])
            var realRequest = CatalogRequest();realRequest.folder = library.lastImportedFolderID!.uuidString
            let realPage = try await library.page(realRequest)
            try check("real MegaBase archive indexes all 10,738 games without loading them") { realPage.count == 10738 && library.studies.count < 64 }
            print("Real archive hash, extraction, copy, index and page: \(Date().timeIntervalSince(timer)) seconds")
            for preview in realPage.games.prefix(3) {
                let game = try catalog.load(preview.id)
                try check("real indexed header opens matching game on demand") { game.white == preview.white && game.black == preview.black && game.mainLinePlyCount > 0 && game.whiteElo == preview.whiteElo && game.blackElo == preview.blackElo }
            }
            do {
                let db = try SQLConnection(catalog.url)
                let reset = try db.prepare("UPDATE games SET white_elo=NULL,black_elo=NULL,elo_indexed=0 WHERE folder=?")
                try reset.bind([.text(realRequest.folder!)]); try reset.run()
            }
            let recovered = try catalog.page(realRequest)
            try check("older ChessBase catalogs recover ratings directly from header records") {
                zip(recovered.games,realPage.games).allSatisfy { $0.whiteElo == $1.whiteElo && $0.blackElo == $1.blackElo }
            }
            let cancelled = LibraryStore(archiveURL:root.appendingPathComponent("Cancelled.json"))
            let task = Task { await cancelled.importFiles(from:[real]) }
            try await Task.sleep(for:.milliseconds(20));cancelled.cancelImport()
            let result = await task.value
            try check("cancelling import leaves no partial collection or indexed games") { !result && cancelled.totalGameCount == 1 && cancelled.folders.isEmpty }
        }
        if CommandLine.arguments.count > 3 {
            let copy = root.appendingPathComponent("RealMigration.json")
            try FileManager.default.copyItem(at:URL(fileURLWithPath:CommandLine.arguments[3]),to:copy)
            let timer = Date();let realMigration = LibraryStore(archiveURL:copy)
            try check("the existing real library migrates without error") { realMigration.lastError == nil && realMigration.totalGameCount > 10000 && realMigration.studies.count <= 1 }
            print("Real JSON migration: \(realMigration.totalGameCount) games in \(Date().timeIntervalSince(timer)) seconds")
            let reopenedAt = Date();let reopenedMigration = LibraryStore(archiveURL:copy)
            try check("reopening the migrated real library preserves total counts") { reopenedMigration.totalGameCount == realMigration.totalGameCount && reopenedMigration.lastError == nil }
            print("Migrated library reopen: \(Date().timeIntervalSince(reopenedAt)) seconds")
        }
        print("Catalog checks passed in \(String(format:"%.2f",Date().timeIntervalSince(began))) seconds.")
    }
    private static func check(_ name:String,_ test:()->Bool) throws {
        guard test() else { throw NSError(domain:"CatalogChecks",code:1,userInfo:[NSLocalizedDescriptionKey:name]) }
        print("Passed: \(name)")
    }
}
