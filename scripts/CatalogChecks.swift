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
            for trigger in ["game_local_insert","game_local_update","game_local_clear","game_local_delete","imported_layout_update","imported_layout_delete","imported_folder_update"] {
                try old.exec("DROP TRIGGER IF EXISTS \(trigger)")
            }
            try old.exec("DROP TABLE local_headers; DROP TABLE local_positions; DROP TABLE local_fts; DELETE FROM metadata WHERE key='localHeadersReady'")
            for name in ["white_elo", "black_elo", "elo_indexed"] { try old.exec("ALTER TABLE games DROP COLUMN \(name)") }
        }
        let upgraded = try DatabaseCatalog(url: catalog.url)
        let upgradedPage = try upgraded.sqliteOraclePage(request)
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
        let oldPayloadPage = try migrated.catalog!.sqliteOraclePage(CatalogRequest())
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
                    let page = try catalog.sqliteOraclePage(request); result += page.games; request.cursor = page.next
                } while request.cursor != nil
                let ratings = result.map { Int((field == "whiteElo" ? $0.whiteElo : $0.blackElo) ?? "") ?? 0 }
                let expected = ratingGames.map { Int((field == "whiteElo" ? $0.whiteElo : $0.blackElo) ?? "") ?? 0 }.sorted(by: ascending ? (<) : (>))
                try check("\(field) sorts numerically \(ascending ? "ascending" : "descending") across all pages, including legacy metadata and missing ratings") {
                    ratings == expected && Set(result.map(\.id)).count == ratingGames.count && result.allSatisfy { $0.root.children.isEmpty }
                }
            }
        }
        var ratingFilter=CatalogRequest();ratingFilter.folder=ratingFolder.uuidString
        ratingFilter.filter.whiteMin=1000;ratingFilter.filter.blackMin=1000
        let expectedRated=Set(ratingGames.filter { (Int($0.whiteElo ?? "") ?? 0)>=1000 && (Int($0.blackElo ?? "") ?? 0)>=1000 }.map(\.id))
        var filteredIDs=Set<UUID>()
        repeat {
            let page=try catalog.sqliteOraclePage(ratingFilter)
            try check("covering Elo counts stay exact across pages") {page.count==expectedRated.count}
            filteredIDs.formUnion(page.games.map(\.id));ratingFilter.cursor=page.next
        } while ratingFilter.cursor != nil
        try check("combined Elo filters paginate all and only matching games") {filteredIDs==expectedRated}
        ratingFilter.filter.boardFEN=ChessPosition.startFEN
        let ratedPositions=try await library.page(ratingFilter)
        try check("board candidate selection shares the covering Elo predicate") {
            ratedPositions.count==expectedRated.count && Set(ratedPositions.games.map(\.id)).isSubset(of:expectedRated)
        }
        let evictionDB=try SQLConnection(root.appendingPathComponent("CacheEviction.sqlite"))
        try evictionDB.exec("CREATE TABLE searches(id INTEGER PRIMARY KEY,complete INTEGER,created REAL); CREATE TABLE matches(search_id INTEGER,game_rowid INTEGER)")
        let cacheNow=Date()
        try evictionDB.exec("INSERT INTO searches VALUES(1,1,\(cacheNow.timeIntervalSince1970-120)),(2,1,\(cacheNow.timeIntervalSince1970)),(3,0,\(cacheNow.timeIntervalSince1970-120)); INSERT INTO matches VALUES(1,10),(2,20),(3,30)")
        try PositionSearchService.pruneCompletedResults(evictionDB,budgetPages:0,now:cacheNow)
        let survivors=try evictionDB.prepare("SELECT search_id FROM matches ORDER BY search_id")
        var remainingCacheIDs:[Int]=[]
        while try survivors.next() {remainingCacheIDs.append(survivors.int(0))}
        try check("cache pressure evicts old completed results but preserves recent and in-flight searches") {remainingCacheIDs==[2,3]}
        // Shared header predicates combine independently and apply before board scanning.
        let filterFolder = UUID()
        var utc = Calendar(identifier:.gregorian);utc.timeZone=TimeZone(secondsFromGMT:0)!
        let alpha=ChessStudy(white:"Álpha, Anna",black:"Beta, Ben",event:"City Masters",whiteElo:"2700",blackElo:"900",date:utc.date(from:DateComponents(year:2021,month:12,day:31))!,result:"1-0")
        let beta=ChessStudy(white:"Beta, Ben",black:"Alpha, Anna",event:"Open Masters",whiteElo:"900",blackElo:"2700",date:utc.date(from:DateComponents(year:2022,month:1,day:1))!,result:"1/2-1/2")
        let unknown=ChessStudy(white:"Unknown",black:"Alpha, Anna",event:"City Masters",date:alpha.date,result:"*")
        for game in [alpha,beta,unknown] {game.folderID=filterFolder}
        try catalog.save([alpha,beta,unknown])
        var filters=CatalogRequest();filters.folder=filterFolder.uuidString;filters.filter.player="Alpha"
        try check("player search matches either color with accent normalization") {try catalog.sqliteOraclePage(filters).count==3}
        filters.filter.white="Alpha";filters.filter.black="Beta";filters.filter.tournament="City";filters.filter.whiteMin=2600;filters.filter.whiteMax=2800;filters.filter.blackMax=1000;filters.filter.yearMin=2021;filters.filter.yearMax=2021;filters.result="whiteWin"
        try check("player colors, Elo bands, tournament, year endpoints and result combine correctly") {try catalog.sqliteOraclePage(filters).games.map(\.id)==[alpha.id]}
        filters.filter=CatalogFilter();filters.result="all";filters.filter.blackMax=3000
        try check("Elo bounds exclude unrated players") {try catalog.sqliteOraclePage(filters).count==2}
        filters.filter=CatalogFilter();filters.filter.yearMin=2022
        try check("year lower bound includes January first and excludes prior December") {try catalog.sqliteOraclePage(filters).games.map(\.id)==[beta.id]}
        filters.filter.player="Alpha' OR 1=1 --"
        try check("filter values remain data, never SQL") {try catalog.sqliteOraclePage(filters).count==0}

        var localCalendar=Calendar(identifier:.gregorian);localCalendar.timeZone = .current
        let januaryFirst=ChessStudy(white:"Local New Year",date:localCalendar.date(from:DateComponents(year:2024,month:1,day:1))!)
        januaryFirst.folderID=filterFolder;try catalog.save([januaryFirst])
        var localYear=CatalogRequest();localYear.folder=filterFolder.uuidString;localYear.filter.yearMin=2024;localYear.filter.yearMax=2024
        try check("year filters include January first in the table's local calendar") {try catalog.sqliteOraclePage(localYear).games.map(\.id)==[januaryFirst.id]}

        var rejectedSpace=false
        do {try IndexedDatabaseImport.validateIndexSpace(gameCount:10_000_000,availableBytes:2_000_000_000)} catch {rejectedSpace=true}
        try check("large ChessBase imports reject insufficient checkpoint space before indexing") {rejectedSpace}
        try IndexedDatabaseImport.validateIndexSpace(gameCount:10_000,availableBytes:1_000_000_000)

        // A successful commit must survive failures during later import bookkeeping.
        let preservedSource=try catalog.source(url:input.absoluteString)!
        let preservedDirectory=catalog.sourcesURL.appendingPathComponent(preservedSource.id)
        try IndexedDatabaseImport.cleanupFailedImport(catalog:catalog,sourceID:preservedSource.id,directory:preservedDirectory)
        try check("post-commit import errors preserve indexed games and managed source files") {
            try FileManager.default.fileExists(atPath:preservedDirectory.path) && catalog.source(id:preservedSource.id)?.count==4
        }
        let blockedID=UUID().uuidString,blockedDirectory=catalog.sourcesURL.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:blockedDirectory,withIntermediateDirectories:true)
        try Data("keep me".utf8).write(to:blockedDirectory.appendingPathComponent("source"))
        try catalog.addSource(id:blockedID,path:"",kind:"cbh",name:"Cleanup test",original:"test:cleanup",hash:nil,folder:filterFolder)
        let blockedDB=try SQLConnection(catalog.url)
        try blockedDB.exec("CREATE TRIGGER block_source_cleanup BEFORE DELETE ON sources BEGIN SELECT RAISE(FAIL,'Simulated disk error'); END")
        do {try IndexedDatabaseImport.cleanupFailedImport(catalog:catalog,sourceID:blockedID,directory:blockedDirectory)} catch { }
        try check("failed index cleanup never deletes its recovery source files") {FileManager.default.fileExists(atPath:blockedDirectory.appendingPathComponent("source").path)}
        try blockedDB.exec("DROP TRIGGER block_source_cleanup")
        try IndexedDatabaseImport.cleanupFailedImport(catalog:catalog,sourceID:blockedID,directory:blockedDirectory)
        try check("uncommitted imports are removed after successful index cleanup") {!FileManager.default.fileExists(atPath:blockedDirectory.path)}

        // Compare the native board scanner to fully decoded games, including custom starts.
        for targetGame in expected.games {
            var target=targetGame.root
            for _ in 0..<4 {if let child=target.children.first {target=child}}
            let board=try CatalogFilter.boardKey(target.positionFEN)
            let expectedIDs=Set(expected.games.filter { game in
                var node:MoveNode?=game.root
                while let current=node {if current.positionFEN.split(separator:" ").prefix(2).joined(separator:" ")==board{return true};node=current.children.first}
                return false
            }.map(\.black))
            var boardRequest=CatalogRequest();boardRequest.folder=folder.id.uuidString;boardRequest.filter.boardFEN=target.positionFEN
            let result=try await library.page(boardRequest)
            try check("native main-line board matching agrees with decoded fixture \(targetGame.black)") {Set(result.games.map(\.black))==expectedIDs}
            let state=try InteractiveCatalogService.state(catalog)
            let metadata=try InteractiveCatalogService.prepareMetadata(catalog:catalog,state:state,progress:{_ in})
            let before=try FileManager.default.attributesOfItem(atPath:metadata.appendingPathComponent("catalog.bin").path)[.modificationDate] as? Date
            let again=try await library.page(boardRequest)
            let after=try FileManager.default.attributesOfItem(atPath:metadata.appendingPathComponent("catalog.bin").path)[.modificationDate] as? Date
            try check("repeated board lookup reuses immutable preparation") {again.games.map(\.id)==result.games.map(\.id) && before==after}
        }
        // CBH serializes the main continuation inside push/pop blocks before
        // returning to the branch point for alternatives. Exercise positions
        // beyond those blocks, not just the first few opening moves.
        let variationInput = fixtures.appendingPathComponent("variations/WithVariations.cbh")
        let annotated = try ChessBaseImportService.read(variationInput)
        try check("annotated board-search fixture decodes completely") { annotated.skipped == 0 && annotated.games.count == 28 }
        _ = await library.importFiles(from: [variationInput])
        let annotatedFolder = library.lastImportedFolderID!.uuidString
        let exactIndex = root.appendingPathComponent("ExactPositions", isDirectory: true)
        func runPositionTool(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = try ChessBaseImportService.bundledReader()
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CatalogError.message("Position index helper failed: \(arguments.first ?? "")") }
        }
        try runPositionTool(["--prepare-cbh-positions", variationInput.path, exactIndex.path, "4294967295"])
        // A completed preparation must resume without rewriting immutable parts.
        let indexPart = exactIndex.appendingPathComponent("part-0000000000.lcpi")
        let beforeResume = try Data(contentsOf: indexPart)
        try runPositionTool(["--prepare-cbh-positions", variationInput.path, exactIndex.path, "4294967295"])
        try check("completed position preparation resumes without changing the index") { try Data(contentsOf: indexPart) == beforeResume }
        var mainlineRecords: [String: Set<Int>] = [:]
        var branchTargets = Set<String>()
        for (record, game) in annotated.games.enumerated() {
            var node = game.root
            while true {
                let board = try CatalogFilter.boardKey(node.positionFEN)
                mainlineRecords[board, default: []].insert(record)
                if node.children.count > 1 {
                    for child in node.children { branchTargets.insert(try CatalogFilter.boardKey(child.positionFEN)) }
                }
                guard let next = node.children.first else { branchTargets.insert(board); break }
                node = next
            }
        }
        for board in branchTargets.sorted() {
            var query = CatalogRequest(); query.folder = annotatedFolder
            query.filter.boardFEN = board + " - - 0 1"
            let result = try await library.page(query)
            let actual = Set(result.games.compactMap { $0.databaseReference?.record })
            let expected = mainlineRecords[board] ?? []
            try check("CBH branches preserve main-line matches for \(board) (expected \(expected.sorted()), got \(actual.sorted()))") { actual == expected }
            let matchesFile = root.appendingPathComponent("position-matches.bits")
            try runPositionTool(["--query-position-index", exactIndex.path, query.filter.boardFEN, matchesFile.path])
            let bits = try Data(contentsOf: matchesFile)
            let indexed = Set((0..<28).filter { bits[32 + $0 / 8] & (1 << ($0 % 8)) != 0 })
            try check("persistent exact position index agrees with the full annotated game trees") { indexed == expected }
        }
        print("Verified \(branchTargets.count) main-line and variation positions across 28 annotated ChessBase games.")

        let specialLines:[(String,String)] = [
            ("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1","1. O-O O-O-O *"),
            ("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1","1. exd6 Kd7 *"),
            ("4k3/P7/8/8/8/8/8/4K3 w - - 0 1","1. a8=N Kd7 *"),
            ("4k3/8/8/8/8/8/8/1N2KN2 w - - 0 1","1. Nbd2 Kd7 *"),
            ("4k3/8/8/8/8/R7/8/R3K3 w - - 0 1","1. R1a2 Kd7 *"),
            (ChessPosition.startFEN,"1.e4 {Comment (ignored)} e5$1 2.Qh5 Nc6 (2... Nf6) 3.Bc4 Nf6 4.Qxf7# 1-0")
        ]
        for (start,moves) in specialLines {
            let text="[Event \"Scanner fidelity\"]\n[FEN \"\(start)\"]\n[Result \"*\"]\n\n\(moves)"
            let file=root.appendingPathComponent("Scanner.pgn")
            try text.write(to:file,atomically:true,encoding:.utf8)
            let decoded=try PGNService.parse(text.replacingOccurrences(of:"e5$1",with:"e5 $1"))[0]
            let rangeCatalog = root.appendingPathComponent("PGNRange-\(UUID()).sqlite")
            do {
                let db = try SQLConnection(rangeCatalog)
                try db.exec("CREATE TABLE games(source_id TEXT,record INTEGER,record_length INTEGER,payload BLOB)")
                let row = try db.prepare("INSERT INTO games VALUES('test',0,?,NULL)")
                try row.bind([.int(text.utf8.count)]); try row.run()
            }
            let pgnIndex = root.appendingPathComponent("PGNPositions-\(UUID())")
            try runPositionTool(["--prepare-pgn-positions", file.path, rangeCatalog.path, "test", pgnIndex.path])
            var node:MoveNode?=decoded.root,ply=0
            while let current=node {
                let scanner=try PGNPositionScanner(path:file.path,board:CatalogFilter.boardKey(current.positionFEN))
                let match=try scanner.match(offset:0,length:text.utf8.count)
                try check("streaming PGN matches full decoder for special-move line at ply \(ply)") {match==ply}
                let nativeMatches = root.appendingPathComponent("pgn-matches.bits")
                try runPositionTool(["--query-position-index", pgnIndex.path, current.positionFEN, nativeMatches.path])
                let nativeBits = try Data(contentsOf: nativeMatches)
                try check("native PGN position index preserves special-move position at ply \(ply)") { nativeBits.count == 40 && nativeBits[32] == 1 && nativeBits[16] == 0 }
                node=current.children.first;ply+=1
            }
        }

        let transposePGN="""
        [Event "Transposition test"]
        [White "First"]
        [Black "Transposition"]
        [Result "*"]

        1. Nf3 d5 2. d4 Nf6 *

        [Event "Transposition test"]
        [White "Second"]
        [Black "Transposition"]
        [Result "*"]

        1. d4 Nf6 2. Nf3 d5 *

        [Event "Transposition test"]
        [White "Variation only"]
        [Black "Excluded"]
        [Result "*"]

        1. e4 (1. Nf3 d5 2. d4 Nf6) e5 *
        """
        let transposeFile=root.appendingPathComponent("Transpositions.pgn");try transposePGN.write(to:transposeFile,atomically:true,encoding:.utf8)
        _ = await library.importFiles(from:[transposeFile])
        let transposeGames=try PGNService.parse(transposePGN)
        transposeGames[0].goToEnd()
        var transposed=CatalogRequest();transposed.folder=library.lastImportedFolderID!.uuidString;transposed.filter.boardFEN=transposeGames[0].currentPosition.fen
        let matches=try await library.page(transposed)
        try check("board search finds transpositions in PGN main lines and excludes variation-only positions") {Set(matches.games.map(\.white))==Set(["First","Second"])}
        let transposedSource = try catalog.source(id: matches.games[0].databaseReference!.sourceID!)!
        let transposedIndex = root.appendingPathComponent("PGNTranspositions")
        try runPositionTool(["--prepare-pgn-positions", transposedSource.path, catalog.url.path, transposedSource.id, transposedIndex.path])
        let transposedBits = root.appendingPathComponent("transposed.bits")
        try runPositionTool(["--query-position-index", transposedIndex.path, transposed.filter.boardFEN, transposedBits.path])
        try check("persistent PGN position index finds both move orders and excludes variation-only match") { try Data(contentsOf: transposedBits)[32] == 3 }
        let cachedBeforeEdit=try PositionSearchService.search(catalog:catalog,request:transposed,progress:{_ in})
        let unrelated=ChessStudy(white:"Working game",black:"Outside reference collection")
        try catalog.save([unrelated])
        let cachedAfterEdit=try PositionSearchService.search(catalog:catalog,request:transposed,progress:{_ in})
        try check("working games outside the reference collection preserve its cached board results") {cachedBeforeEdit.key==cachedAfterEdit.key && cachedAfterEdit.cached}
        let unchangedVersion=try catalog.contentVersion()
        try catalog.save([unrelated])
        try check("saving an unchanged payload preserves content versions and caches") {try catalog.contentVersion()==unchangedVersion}
        let localFolder=UUID()
        for game in transposeGames {game.folderID=localFolder}
        try catalog.save(transposeGames)
        var localRequest=transposed;localRequest.folder=localFolder.uuidString
        let localMatches=try await library.page(localRequest)
        try check("saved move-tree board search follows only the main line") {localMatches.count==2}
        var renamed=localRequest;renamed.filter.white="Renamed"
        let beforeRename=try await library.page(renamed)
        transposeGames[0].white="Renamed"
        try catalog.save([transposeGames[0]])
        let afterRename=try await library.page(renamed)
        try check("header edits invalidate board caches even when collection counts are unchanged") {beforeRename.count==0 && afterRename.count==1}
        try catalog.move(transposeGames[0].id,folder:nil)
        let afterMove=try await library.page(localRequest)
        try check("moving a game out of a collection invalidates its board cache") {afterMove.count==1}
        try catalog.move(transposeGames[0].id,folder:localFolder)
        let afterReturn=try await library.page(localRequest)
        try check("moving a game back restores the exact board results") {afterReturn.count==2}
        let removed=matches.games[0];library.delete(removed);library.saveNow()
        let changed=try await library.page(transposed)
        try check("deleting a game invalidates cached board results") {changed.count==1 && changed.games[0].id != removed.id}
        let cancelBoard=Task {try await library.page(transposed)};cancelBoard.cancel()
        var searchCancelled=false
        do {_ = try await cancelBoard.value} catch is CancellationError {searchCancelled=true}
        try check("cancelled board queries do not publish stale results") {searchCancelled}
        let recoveredFolder=UUID()
        try catalog.addSource(id:UUID().uuidString,path:"",kind:"legacy",name:"Recovered committed collection",original:"test:committed",hash:nil,folder:recoveredFolder,count:1)
        let recoveryLibrary=LibraryStore(archiveURL:archive)
        try check("restart recovers a collection committed before its window metadata was saved") {recoveryLibrary.folders.contains {$0.id==recoveredFolder && $0.name=="Recovered committed collection"}}
        // Compare the production merge path with SQLite's exact order across
        // imported PGN/CBH and editable games, in both directions and all pages.
        for sort in ["date","players","whiteElo","blackElo","event","result","moves","round"] {
            for ascending in [true,false] {
                var combined=CatalogRequest();combined.sort=sort;combined.ascending=ascending
                var actual:[UUID]=[],expected:[UUID]=[]
                repeat {let page=try await library.page(combined);actual += page.games.map(\.id);combined.cursor=page.next} while combined.cursor != nil
                combined.cursor=nil
                repeat {let page=try catalog.sqliteOraclePage(combined);expected += page.games.map(\.id);combined.cursor=page.next} while combined.cursor != nil
                try check("native/local merge matches SQLite for \(sort), ascending=\(ascending), all pages") {actual==expected && Set(actual).count==actual.count}
            }
        }
        let generationBefore=try InteractiveCatalogService.state(catalog).generation
        unrelated.root.comment += " Incremental saved-game update"
        try catalog.save([unrelated])
        try check("autosave never invalidates imported metadata preparation") {try InteractiveCatalogService.state(catalog).generation==generationBefore}
        var hidden=CatalogRequest();hidden.search=pgnFolder.uuidString
        try check("global search does not match hidden folder UUIDs") {try InteractiveCatalogService.page(catalog:catalog,request:hidden).count==0}
        var contradiction=transposed;contradiction.unfiled=true
        try check("contradictory collection scopes return no games") {try InteractiveCatalogService.page(catalog:catalog,request:contradiction).count==0}

        let overlayGeneration=try InteractiveCatalogService.state(catalog).generation
        let movedFolder=UUID(),originalFolder=rated.folderID
        try catalog.move(rated.id,folder:movedFolder)
        var movedQuery=CatalogRequest();movedQuery.folder=movedFolder.uuidString;movedQuery.filter.boardFEN=try catalog.load(rated.id).root.positionFEN
        let movedPage=try await library.page(movedQuery)
        try check("an imported game moves into a new board-search scope without rebuilding metadata") {try movedPage.games.map(\.id)==[rated.id] && InteractiveCatalogService.state(catalog).generation==overlayGeneration}
        try catalog.move(rated.id,folder:originalFolder)
        let movedBack=try await library.page(movedQuery)
        try check("the move overlay removes a game from its previous search scope") {movedBack.count==0}
        let integrityState=try InteractiveCatalogService.state(catalog)
        let integrityDirectory=try InteractiveCatalogService.prepareMetadata(catalog:catalog,state:integrityState,progress:{_ in})
        let dictionaryOrder=integrityDirectory.appendingPathComponent("name-order.bin")
        var corrupt=try Data(contentsOf:dictionaryOrder);corrupt[0]^=1;try corrupt.write(to:dictionaryOrder)
        let repaired=try await library.page(CatalogRequest())
        try check("damaged derived metadata is rebuilt before it can return incorrect results") {try repaired.count==catalog.counts().values.reduce(0,+)}
        let broken=ChessStudy(white:"Recoverable bad payload");try catalog.save([broken])
        let brokenDB=try SQLConnection(catalog.url),damage=try brokenDB.prepare("UPDATE games SET payload=x'7b',elo_indexed=0 WHERE id=?")
        try damage.bind([.text(broken.id.uuidString)]);try damage.run()
        var brokenQuery=CatalogRequest();brokenQuery.filter.white="Recoverable bad"
        let brokenPage=try await library.page(brokenQuery)
        try check("one malformed saved payload does not block library browsing") {brokenPage.games.map(\.id)==[broken.id]}
        try catalog.delete(broken.id)
        var invalidCursor=CatalogRequest();invalidCursor.localOnly=true;invalidCursor.cursor=CatalogCursor(value:"not a number",id:UUID().uuidString)
        var cursorRejected=false
        do {_ = try InteractiveCatalogService.page(catalog:catalog,request:invalidCursor)}catch{cursorRejected=true}
        try check("invalid numeric cursors fail rather than silently repeating pages") {cursorRejected}
        final class WorkCount:@unchecked Sendable {
            let lock=NSLock();var value=0
            func increment(){lock.withLock {value+=1}}
        }
        let starts=DispatchSemaphore(value:0),workCount=WorkCount(),preparationKey=UUID().uuidString
        let waiting=Task.detached {
            try InteractiveCatalogService.singleFlight(preparationKey,progress:{_ in}) {_ in
                workCount.increment();starts.signal();Thread.sleep(forTimeInterval:0.2)
            }
        }
        starts.wait();waiting.cancel()
        try InteractiveCatalogService.singleFlight(preparationKey,progress:{_ in}) {_ in workCount.increment()}
        var waitingCancelled=false
        do {try await waiting.value}catch is CancellationError {waitingCancelled=true}
        try check("cancelling a board request preserves its shared background preparation") {waitingCancelled && workCount.value==1}

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
            let recovered = try catalog.sqliteOraclePage(realRequest)
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
    private static func check(_ name:String,_ test:() throws ->Bool) throws {
        guard try test() else { throw NSError(domain:"CatalogChecks",code:1,userInfo:[NSLocalizedDescriptionKey:name]) }
        print("Passed: \(name)")
    }
}
