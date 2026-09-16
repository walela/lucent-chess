import Foundation
import SQLite3

struct DatabaseGameReference: Codable, Sendable {
    let id: String
    let sourceID: String?
    let record: Int
}

struct CatalogCursor: Hashable, Sendable {
    let value: String
    let id: String
    var rawValue: Data? = nil
}

struct CatalogPage: @unchecked Sendable {
    let games: [ChessStudy]
    let next: CatalogCursor?
    let count: Int
}

struct CatalogRequest: Hashable, Sendable {
    var localOnly = false
    var revision = 0
    var contentRevision = ""
    var folder: String? = nil
    var unfiled = false
    var recent = false
    var search = ""
    var result = "all"
    var file = "all"
    var sort = "date"
    var ascending = false
    var cursor: CatalogCursor? = nil
    var filter = CatalogFilter()
    var positionSearchKey: String?
}

struct CatalogSource: Sendable {
    let id: String
    let path: String
    let kind: String
    let name: String
    let folder: String?
    let count: Int
    var hash: String? = nil
}

// Connections are confined to each operation. WAL allows paged readers while an import is indexing.
final class DatabaseCatalog: @unchecked Sendable {
    let url: URL
    let sourcesURL: URL
    static let pageSize = 200
    private let cacheLock = NSLock()
    private var countCache: [CatalogCountKey:Int] = [:]
    private var textCountCache: [String:Int] = [:]
    private var localMaskCache: [String:String] = [:]
    private struct CatalogCountKey: Hashable { let request: CatalogRequest; let version: String }


    init(url: URL) throws {
        self.url = url
        sourcesURL = url.deletingLastPathComponent().appendingPathComponent("Databases", isDirectory: true)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLConnection(url)
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        try db.exec(Self.schema)
        let columns = try db.prepare("PRAGMA table_info(games)")
        var names = Set<String>()
        while try columns.next() { names.insert(columns.text(1)) }
        for (name, definition) in [("white_elo", "TEXT"), ("black_elo", "TEXT"), ("elo_indexed", "INTEGER NOT NULL DEFAULT 0")] where !names.contains(name) {
            try db.exec("ALTER TABLE games ADD COLUMN \(name) \(definition)")
        }
        try db.exec(Self.localSchema)
    }

    static let schema = """
    CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value BLOB NOT NULL);
    CREATE TABLE IF NOT EXISTS sources(id TEXT PRIMARY KEY,path TEXT NOT NULL,kind TEXT NOT NULL,name TEXT NOT NULL,url TEXT NOT NULL,hash TEXT,folder TEXT,count INTEGER NOT NULL DEFAULT 0);
    CREATE UNIQUE INDEX IF NOT EXISTS sources_hash ON sources(hash) WHERE hash IS NOT NULL;
    CREATE INDEX IF NOT EXISTS sources_url ON sources(url);
    CREATE TABLE IF NOT EXISTS games(
      id TEXT PRIMARY KEY,source_id TEXT,record INTEGER NOT NULL DEFAULT 0,record_length INTEGER NOT NULL DEFAULT 0,payload BLOB,
      white TEXT NOT NULL,black TEXT NOT NULL,event TEXT NOT NULL,title TEXT NOT NULL,site TEXT NOT NULL DEFAULT '',
      date REAL NOT NULL,result TEXT NOT NULL,moves INTEGER NOT NULL DEFAULT 0,round TEXT NOT NULL DEFAULT '',
      players TEXT NOT NULL,round_sort TEXT NOT NULL,folder TEXT,source_name TEXT,file_path TEXT,source_url TEXT,starter TEXT,
      dirty INTEGER NOT NULL DEFAULT 0,modified REAL NOT NULL,created REAL NOT NULL,saved REAL,fingerprint TEXT,white_elo TEXT,black_elo TEXT,elo_indexed INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX IF NOT EXISTS games_source ON games(source_id,record);
    CREATE INDEX IF NOT EXISTS games_fingerprint ON games(fingerprint) WHERE fingerprint IS NOT NULL;
    CREATE INDEX IF NOT EXISTS games_modified ON games(modified);
    CREATE TABLE IF NOT EXISTS counts(folder TEXT PRIMARY KEY,count INTEGER NOT NULL);
    CREATE VIRTUAL TABLE IF NOT EXISTS games_fts USING fts5(white,black,event,title,source_name,folder,content='games',content_rowid='rowid',tokenize='unicode61 remove_diacritics 2');
    CREATE TRIGGER IF NOT EXISTS games_insert AFTER INSERT ON games BEGIN
      INSERT INTO games_fts(rowid,white,black,event,title,source_name,folder) VALUES(new.rowid,new.white,new.black,new.event,new.title,new.source_name,new.folder);
      INSERT INTO counts VALUES(coalesce(new.folder,''),1) ON CONFLICT(folder) DO UPDATE SET count=count+1;
    END;
    CREATE TRIGGER IF NOT EXISTS games_delete AFTER DELETE ON games BEGIN
      INSERT INTO games_fts(games_fts,rowid,white,black,event,title,source_name,folder) VALUES('delete',old.rowid,old.white,old.black,old.event,old.title,old.source_name,old.folder);
      UPDATE counts SET count=count-1 WHERE folder=coalesce(old.folder,'');
    END;
    DROP TRIGGER IF EXISTS games_update;
    CREATE TRIGGER IF NOT EXISTS games_update_fts AFTER UPDATE OF white,black,event,title,source_name,folder ON games
    WHEN old.white IS NOT new.white OR old.black IS NOT new.black OR old.event IS NOT new.event OR old.title IS NOT new.title OR old.source_name IS NOT new.source_name OR old.folder IS NOT new.folder BEGIN
      INSERT INTO games_fts(games_fts,rowid,white,black,event,title,source_name,folder) VALUES('delete',old.rowid,old.white,old.black,old.event,old.title,old.source_name,old.folder);
      INSERT INTO games_fts(rowid,white,black,event,title,source_name,folder) VALUES(new.rowid,new.white,new.black,new.event,new.title,new.source_name,new.folder);
    END;
    CREATE TRIGGER IF NOT EXISTS games_update_counts AFTER UPDATE OF folder ON games WHEN old.folder IS NOT new.folder BEGIN
      UPDATE counts SET count=count-1 WHERE folder=coalesce(old.folder,'');
      INSERT INTO counts VALUES(coalesce(new.folder,''),1) ON CONFLICT(folder) DO UPDATE SET count=count+1;
    END;
    """ + ["date", "players"].map { column in
        "CREATE INDEX IF NOT EXISTS games_\(column) ON games(\(column),id); CREATE INDEX IF NOT EXISTS games_folder_\(column) ON games(folder,\(column),id);"
    }.joined()

    func metadata<T: Decodable>(_ key: String, as: T.Type) throws -> T? {
        let db = try SQLConnection(url)
        let query = try db.prepare("SELECT value FROM metadata WHERE key=?")
        try query.bind([.text(key)])
        guard try query.next() else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: query.data(0))
    }

    func saveMetadata<T: Encodable>(_ key: String, value: T) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let db = try SQLConnection(url)
        let query = try db.prepare("INSERT INTO metadata VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        try query.bind([.text(key), .blob(encoder.encode(value))]); try query.run()
    }

    func save(_ studies: [ChessStudy], fingerprints: [String: String] = [:]) throws {
        let snapshots = studies.filter { $0.databaseReference == nil }.map(StudyPersistenceSnapshot.init)
        try saveSnapshots(snapshots, fingerprints: fingerprints)
    }

    func saveSnapshots(_ snapshots: [StudyPersistenceSnapshot], fingerprints: [String: String] = [:]) throws {
        let db = try SQLConnection(url)
        try db.exec("BEGIN IMMEDIATE")
        do {
            let query = try db.prepare("""
            INSERT INTO games(id,payload,white,black,event,title,site,date,result,moves,round,players,round_sort,folder,source_name,file_path,source_url,starter,dirty,modified,created,saved,fingerprint,white_elo,black_elo,elo_indexed)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1)
            ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,white=excluded.white,black=excluded.black,event=excluded.event,title=excluded.title,site=excluded.site,date=excluded.date,result=excluded.result,moves=excluded.moves,round=excluded.round,players=excluded.players,round_sort=excluded.round_sort,folder=excluded.folder,source_name=excluded.source_name,file_path=excluded.file_path,source_url=excluded.source_url,starter=excluded.starter,dirty=excluded.dirty,modified=excluded.modified,created=excluded.created,saved=excluded.saved,fingerprint=coalesce(excluded.fingerprint,games.fingerprint),white_elo=excluded.white_elo,black_elo=excluded.black_elo,elo_indexed=1
            WHERE games.payload IS NOT excluded.payload
            """)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            var changedFolders = Set<String>()
            let priorFolder = try db.prepare("SELECT folder FROM games WHERE id=?")
            for game in snapshots {
                var firstChild: [UUID: UUID] = [:]
                for node in game.nodes {
                    if let parent = node.parentID, firstChild[parent] == nil { firstChild[parent] = node.id }
                }
                var moveCount = 0, nodeID = game.nodes.first?.id
                while let id = nodeID, let next = firstChild[id], moveCount < game.nodes.count {
                    moveCount += 1; nodeID = next
                }
                let players = "\(game.white) – \(game.black)".lowercased()
                let round = game.round ?? ""
                let roundSort = Double(round).map { String(format: "%020.4f", $0) } ?? round.lowercased()
                try priorFolder.bind([.text(game.id.uuidString)])
                let oldFolder = try priorFolder.next() ? priorFolder.text(0) : nil
                priorFolder.reset()
                try query.bind([.text(game.id.uuidString), .blob(encoder.encode(game)), .text(game.white), .text(game.black), .text(game.event), .text(game.title), .text(game.site ?? ""), .number(game.date.timeIntervalSince1970), .text(game.result), .int(moveCount), .text(round), .text(players), .text(roundSort), .optional(game.folderID?.uuidString), .optional(game.sourceName), .optional(game.filePath), .optional(game.sourceURL), .optional(game.starterCollectionID), .int(game.dirtyState == true ? 1 : 0), .number(game.modifiedAt.timeIntervalSince1970), .number(game.createdAt.timeIntervalSince1970), game.lastSavedAt.map { .number($0.timeIntervalSince1970) } ?? .null, .optional(fingerprints[game.id.uuidString]), .optional(game.whiteElo), .optional(game.blackElo)])
                try query.run(); query.reset()
                if sqlite3_changes(db.handle) > 0 {
                    try Self.updateLocalPositions(game,db:db)
                    changedFolders.insert(game.folderID?.uuidString ?? "")
                    if let oldFolder { changedFolders.insert(oldFolder) }
                }
            }
            if !changedFolders.isEmpty { try Self.invalidatePositionSearches(db, folders: changedFolders) }
            try db.exec("COMMIT")
        } catch { try? db.exec("ROLLBACK"); throw error }
    }

    func counts() throws -> [String: Int] {
        let db = try SQLConnection(url); let query = try db.prepare("SELECT folder,count FROM counts")
        var result: [String: Int] = [:]
        while try query.next() { result[query.text(0)] = query.int(1) }
        return result
    }

    func recentCount() throws -> Int {
        let db = try SQLConnection(url); let q = try db.prepare("SELECT count(*) FROM games WHERE modified>?")
        try q.bind([.number(Date().addingTimeInterval(-14*86400).timeIntervalSince1970)])
        return try q.next() ? q.int(0) : 0
    }

    func containsFingerprint(_ value: String) throws -> Bool {
        let db = try SQLConnection(url); let query = try db.prepare("SELECT 1 FROM games WHERE fingerprint=? LIMIT 1")
        try query.bind([.text(value)]); return try query.next()
    }

    func page(_ request: CatalogRequest) throws -> CatalogPage {
        guard request.localOnly else {throw CatalogError.message("Imported databases must use InteractiveCatalogService.")}
        return try sqliteOraclePage(request)
    }

    // Retained as an independent differential-test oracle for legacy catalogs.
    // Production callers are fenced into the prepared service or local headers.
    func sqliteOraclePage(_ request: CatalogRequest) throws -> CatalogPage {
        try request.validateCursor()
        let db = try SQLConnection(url)
        let table = request.localOnly ? "local_headers AS games" : "games"
        let column: String
        let indexName: String
        let numericSort: Bool
        switch request.sort {
        case "whiteElo", "blackElo":
            indexName = request.sort == "whiteElo" ? "white_elo" : "black_elo"
            column = "CAST(coalesce(\(indexName),'0') AS INTEGER)"
            numericSort = true
            if !request.localOnly { try prepareRatingSort(request) }
        case "players", "event", "result", "moves":
            column = request.sort; indexName = column; numericSort = column == "moves"
        case "round": column = "round_sort"; indexName = column; numericSort = false
        default: column = "date"; indexName = column; numericSort = true
        }
        if !request.localOnly && indexName != "date" && indexName != "players" {
            // Build additional sort indexes only when requested, on the query worker.
            try db.exec("CREATE INDEX IF NOT EXISTS games_\(indexName) ON games(\(column),id); CREATE INDEX IF NOT EXISTS games_folder_\(indexName) ON games(folder,\(column),id);")
        }
        try request.filter.validate()
        if !request.localOnly && request.filter.hasRatings && request.sort != "whiteElo" && request.sort != "blackElo" { try prepareRatingSort(request) }
        var (conditions, values, textMatches) = try predicate(request, db: db)
        let tokens = request.search.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let baseWhere = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        let denseSearch = (textMatches ?? 0) > 10_000
        let ratingIndex = !request.localOnly && request.positionSearchKey == nil && textMatches == nil && request.filter.hasRatings
            ? try prepareRatingFilterIndex(request, db: db) : nil
        var countRequest=request;countRequest.revision=0;countRequest.contentRevision="";countRequest.cursor=nil;countRequest.sort="date";countRequest.ascending=false
        let cacheKey=CatalogCountKey(request:countRequest,version:try contentVersion(for: request) + (request.recent ? ":\(Int(Date().timeIntervalSince1970/30))" : ""))
        let cachedCount=cacheLock.withLock {countCache[cacheKey]}
        let count: Int
        if let cachedCount { count=cachedCount }
        else if request.positionSearchKey != nil { count=textMatches ?? 0 }
        else if let textMatches, !request.filter.hasRanges, !request.filter.hasPosition, request.positionSearchKey == nil, !request.unfiled, !request.recent, request.result == "all", request.file == "all" {
            count = textMatches
        } else if !request.localOnly && !request.filter.hasHeaders && request.positionSearchKey == nil && !request.recent && request.result == "all" && request.file == "all" && tokens.isEmpty {
            let counts = try counts()
            count = request.folder.map { counts[$0] ?? 0 } ?? (request.unfiled ? counts[""] ?? 0 : counts.values.reduce(0,+))
        } else {
            let countIndex = request.localOnly ? "" : (textMatches != nil && !denseSearch ? " NOT INDEXED" : (ratingIndex.map { " INDEXED BY \($0)" } ?? (denseSearch && (request.folder != nil || request.unfiled) && !request.recent && request.result == "all" && request.file == "all" ? " INDEXED BY games_folder_date" : "")))
            let q = try db.prepare("SELECT count(*) FROM " + table + countIndex + baseWhere); try q.bind(values)
            count = try q.next() ? q.int(0) : 0
        }
        cacheLock.withLock {
            if countCache.count>64 {countCache.removeAll(keepingCapacity:true)}
            countCache[cacheKey]=count
        }
        if let cursor = request.cursor {
            conditions.append("(\(column),id) \(request.ascending ? ">" : "<") (?,?)")
            values.append(numericSort ? (indexName == "date" ? .number(Double(cursor.value) ?? 0) : .int(Int(cursor.value) ?? 0)) : (cursor.rawValue.map(SQLValue.rawText) ?? .text(cursor.value)))
            values.append(.text(cursor.id))
        }
        let whereSQL = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        let direction = request.ascending ? "ASC" : "DESC"
        // For broad matches, scan the ordering index and test the materialized FTS row-id set.
        // Otherwise SQLite fetches and sorts millions of full rows before returning one page.
        let orderIndex = request.localOnly ? "" : (denseSearch || ratingIndex != nil ? " INDEXED BY games_\((request.folder != nil || request.unfiled) ? "folder_" : "")\(indexName)" : (textMatches != nil ? " NOT INDEXED" : ""))
        let query = try db.prepare("SELECT id,source_id,record,white,black,event,title,site,date,result,moves,round,folder,source_name,file_path,source_url,starter,dirty,modified,created,saved,\(column),white_elo,black_elo,elo_indexed FROM " + table + orderIndex + whereSQL + " ORDER BY \(column) \(direction),id \(direction) LIMIT \(Self.pageSize + 1)")
        try query.bind(values)
        var games: [ChessStudy] = []; var missingRatings: [ChessStudy] = []; var last: CatalogCursor?
        while try query.next() {
            if games.count == Self.pageSize {
                query.reset()
                try hydrateRatings(missingRatings)
                return CatalogPage(games: games, next: last, count: count)
            }
            let game = try Self.preview(query)
            if query.int(24) == 0 { missingRatings.append(game) }
            games.append(game); last = CatalogCursor(value: indexName == "date" ? String(query.double(21)) : query.text(21), id: game.id.uuidString, rawValue: numericSort ? nil : query.data(21))
        }
        query.reset()
        try hydrateRatings(missingRatings)
        return CatalogPage(games: games, next: nil, count: count)
    }

    var positionCacheURL: URL { url.deletingLastPathComponent().appendingPathComponent("PositionSearch.sqlite") }

    private func predicate(_ request: CatalogRequest, db: SQLConnection, countTextMatches: Bool = true) throws -> ([String], [SQLValue], Int?) {
        if let key=request.positionSearchKey {
            let attach=try db.prepare("ATTACH DATABASE ? AS positions");try attach.bind([.text(positionCacheURL.path)]);try attach.run()
            let info=try db.prepare("SELECT id,count FROM positions.searches WHERE key=? AND complete=1");try info.bind([.text(key)])
            guard try info.next() else {throw CatalogError.message("The board-search cache expired. Run the search again.")}
            let searchID=info.int(0),count=info.int(1)
            // Probe the cache's primary key for dense results instead of rebuilding a
            // potentially multi-million-row IN set on every page or sort change.
            var conditions=[count > 10_000
                ? "EXISTS (SELECT 1 FROM positions.matches m WHERE m.search_id=? AND m.game_rowid=games.rowid)"
                : "rowid IN (SELECT game_rowid FROM positions.matches WHERE search_id=?)"]
            var values:[SQLValue]=[.int(searchID)]
            if let folder=request.folder {conditions.append("folder=?");values.append(.text(folder))}
            if request.unfiled {conditions.append("folder IS NULL")}
            return (conditions,values,count)
        }
        var conditions: [String] = []; var values: [SQLValue] = []
        let ftsTable = request.localOnly ? "local_fts" : "games_fts"
        if request.localOnly && !request.filter.boardFEN.isEmpty {
            conditions.append("id IN (SELECT game_id FROM local_positions WHERE board=?)")
            values.append(.text(try CatalogFilter.boardKey(request.filter.boardFEN)))
        }
        if request.localOnly, let mask = request.filter.mask {
            // Saved and edited games are few; test every main-line board they
            // reach against the mask (placement, side and mirrors; the move
            // window and persistence apply to imported games and the preview).
            // Legacy imports live here too (over a million rows), so match on the
            // stored text with compiled masks and remember the result per library version.
            let key = mask.cacheKey + "|" + (try contentVersion())
            var ids = cacheLock.withLock { localMaskCache[key] }
            if ids == nil {
                let variants = mask.compiled()
                let rows = try db.prepare("SELECT board,game_id FROM local_positions")
                var matched = Set<String>()
                while try rows.next() {
                    let id = rows.text(1)
                    if matched.contains(id) { continue }
                    if PositionSearchMask.matches(boardText: rows.text(0), variants: variants) { matched.insert(id) }
                }
                ids = String(decoding: try JSONEncoder().encode(Array(matched)), as: UTF8.self)
                cacheLock.withLock { if localMaskCache.count > 16 { localMaskCache.removeAll(keepingCapacity: true) }; localMaskCache[key] = ids }
            }
            conditions.append("id IN (SELECT value FROM json_each(?))")
            values.append(.text(ids!))
        }
        if let folder = request.folder { conditions.append("folder=?"); values.append(.text(folder)) }
        if request.unfiled { conditions.append("folder IS NULL") }
        if request.recent { conditions.append("modified>?"); values.append(.number(Date().addingTimeInterval(-14 * 86400).timeIntervalSince1970)) }
        switch request.result {
        case "whiteWin": conditions.append("result='1-0'")
        case "blackWin": conditions.append("result='0-1'")
        case "draw": conditions.append("result='1/2-1/2'")
        case "unfinished": conditions.append("result NOT IN ('1-0','0-1','1/2-1/2')")
        default: break }
        switch request.file {
        case "savedPGN": conditions.append("file_path IS NOT NULL AND dirty=0")
        case "needsSaving": conditions.append("dirty=1")
        case "included": conditions.append("starter IS NOT NULL")
        case "imported": conditions.append("source_name IS NOT NULL")
        case "autosaved": conditions.append("source_name IS NULL AND file_path IS NULL AND starter IS NULL")
        default: break }
        let tokens = request.search.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        func terms(_ text: String) -> String {
            text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.map { "\"\($0)\"*" }.joined(separator: " AND ")
        }
        var expressions: [String] = []
        if !tokens.isEmpty { expressions.append("{white black event title source_name} : (\(terms(request.search)))") }
        for (column, text) in [("white",request.filter.white),("black",request.filter.black),("event",request.filter.tournament)] {
            let query = terms(text)
            if !query.isEmpty { expressions.append("\(column) : (\(query))") }
        }
        let player = terms(request.filter.player)
        if !player.isEmpty { expressions.append("(white : (\(player)) OR black : (\(player)))") }
        var matchExpression = expressions.joined(separator: " AND ")
        if !expressions.isEmpty, let folder = request.folder {
            matchExpression += " AND folder : \"" + folder.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var textMatches: Int?
        if !expressions.isEmpty {
            if countTextMatches {
            let textKey=try contentVersion(for: request)+"|"+ftsTable+"|"+matchExpression
            if let cached=cacheLock.withLock({textCountCache[textKey]}) {textMatches=cached}
            else {
                let fts=try db.prepare("SELECT count(*) FROM \(ftsTable) WHERE \(ftsTable) MATCH ?")
                try fts.bind([.text(matchExpression)])
                textMatches=try fts.next() ? fts.int(0) : 0
                cacheLock.withLock {
                    if textCountCache.count>128 {textCountCache.removeAll(keepingCapacity:true)}
                    textCountCache[textKey]=textMatches
                }
            }
            }
            if textMatches == 0 { conditions.append("0") }
            conditions.append("rowid IN (SELECT rowid FROM \(ftsTable) WHERE \(ftsTable) MATCH ?)")
            values.append(.text(matchExpression))
        }
        for (field, low, high) in [("white_elo",request.filter.whiteMin,request.filter.whiteMax),("black_elo",request.filter.blackMin,request.filter.blackMax)] {
            let column = "CAST(coalesce(\(field),'0') AS INTEGER)"
            if low != nil || high != nil { conditions.append("\(column)>0") }
            if let low { conditions.append("\(column)>=?"); values.append(.int(low)) }
            if let high { conditions.append("\(column)<=?"); values.append(.int(high)) }
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        if let year = request.filter.yearMin, let date = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) {
            conditions.append("date>=?"); values.append(.number(date.timeIntervalSince1970))
        }
        if let year = request.filter.yearMax, let date = calendar.date(from: DateComponents(year: year+1, month: 1, day: 1)) {
            conditions.append("date<?"); values.append(.number(date.timeIntervalSince1970))
        }
        return (conditions,values,textMatches)
    }

    func candidateReader(_ request: CatalogRequest) throws -> CatalogCandidateReader {
        try request.filter.validate()
        if request.filter.hasRatings { try prepareRatingSort(request) }
        let db = try SQLConnection(url)
        let (conditions, values, _) = try predicate(request, db: db, countTextMatches: false)
        // Materialize only row IDs once. TEMP storage is file-backed and is deleted
        // with this connection. Decoding never holds a library read transaction.
        try db.exec("CREATE TEMP TABLE position_candidates(game_rowid INTEGER PRIMARY KEY)")
        // The folder ordering index is disastrous for sparse FTS candidates at scale.
        let rowIDLookup: String
        if conditions.contains(where: { $0.hasPrefix("rowid IN") }) { rowIDLookup = " NOT INDEXED" }
        else if request.filter.hasRatings { rowIDLookup = " INDEXED BY " + (try prepareRatingFilterIndex(request, db: db)) }
        else { rowIDLookup = "" }
        let query=try db.prepare("INSERT INTO position_candidates SELECT rowid FROM games" + rowIDLookup + (conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator:" AND ")))
        try query.bind(values);try query.run()
        return CatalogCandidateReader(db:db,count:Int(sqlite3_changes(db.handle)))
    }

    func collectionVersions() throws -> [String:String] {
        let db=try SQLConnection(url)
        let q=try db.prepare("SELECT c.folder,coalesce(CAST(m.value AS TEXT),'') || ':' || c.count FROM counts c LEFT JOIN metadata m ON m.key='contentVersion:' || c.folder")
        var versions:[String:String]=[:]
        while try q.next() {versions[q.text(0)]=q.text(1)}
        return versions
    }

    func contentVersion(for request: CatalogRequest = CatalogRequest()) throws -> String {
        let db = try SQLConnection(url)
        let scope = request.folder ?? (request.unfiled ? "" : nil)
        let countSQL = scope == nil ? "SELECT coalesce(sum(count),0) FROM counts" : "SELECT coalesce(sum(count),0) FROM counts WHERE folder=?"
        let q = try db.prepare("SELECT (SELECT coalesce(CAST(value AS TEXT),'') FROM metadata WHERE key=?),(\(countSQL))")
        var values:[SQLValue]=[.text(scope.map { "contentVersion:" + $0 } ?? "contentVersion")]
        if let scope { values.append(.text(scope)) }
        try q.bind(values); _ = try q.next()
        return q.text(0) + ":" + q.text(1)
    }
    func invalidatePositionSearches() throws {
        let db = try SQLConnection(url)
        try Self.invalidatePositionSearches(db)
    }
    private static func invalidatePositionSearches(_ db: SQLConnection, folders: Set<String> = []) throws {
        let q = try db.prepare("INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        for key in ["contentVersion"] + folders.map({"contentVersion:" + $0}) {
            try q.bind([.text(key),.text(UUID().uuidString)]); try q.run();q.reset()
        }
    }

    static func preview(_ query: SQLStatement) throws -> ChessStudy {
        guard let id = UUID(uuidString: query.text(0)) else { throw CatalogError.message("Invalid game identifier in the library index.") }
        let game = ChessStudy(id: id, title: query.text(6), white: query.text(3), black: query.text(4), event: query.text(5), site: query.text(7), round: query.text(11), date: Date(timeIntervalSince1970: query.double(8)), result: query.text(9))
        game.folderID = query.optionalText(12).flatMap(UUID.init(uuidString:))
        game.sourceName = query.optionalText(13); game.filePath = query.optionalText(14); game.sourceURL = query.optionalText(15)
        game.starterCollectionID = query.optionalText(16); game.dirtyState = query.int(17) != 0
        game.modifiedAt = Date(timeIntervalSince1970: query.double(18)); game.createdAt = Date(timeIntervalSince1970: query.double(19))
        game.lastSavedAt = query.isNull(20) ? nil : Date(timeIntervalSince1970: query.double(20))
        game.databaseReference = DatabaseGameReference(id: id.uuidString, sourceID: query.optionalText(1), record: query.int(2))
        game.whiteElo = query.optionalText(22).flatMap { (Int($0) ?? 0) > 0 ? $0 : nil }
        game.blackElo = query.optionalText(23).flatMap { (Int($0) ?? 0) > 0 ? $0 : nil }
        game.indexedPlyCount = query.int(10)
        return game
    }

    // Counts must not fetch a full game row for each opponent rating. One compact,
    // lazily built covering index serves rating/year/result filters in this scope.
    private func prepareRatingFilterIndex(_ request: CatalogRequest, db: SQLConnection) throws -> String {
        let whiteFirst = request.filter.whiteMin != nil || request.filter.whiteMax != nil
        let fields = whiteFirst ? ["white_elo", "black_elo"] : ["black_elo", "white_elo"]
        let scoped = request.folder != nil || request.unfiled
        let name = "games_" + (scoped ? "folder_" : "") + "filter_" + fields[0]
        let columns = (scoped ? ["folder"] : []) + fields.map { "CAST(coalesce(\($0),'0') AS INTEGER)" } + ["date", "result"]
        try db.exec("CREATE INDEX IF NOT EXISTS \(name) ON games(\(columns.joined(separator: ",")))")
        return name
    }

    // Sorting must include ratings beyond the first page, including catalogs created by 1.18.0.
    // Fill old metadata in bounded batches before creating the numeric ordering index.
    private func prepareRatingSort(_ request: CatalogRequest) throws {
        let db = try SQLConnection(url)
        try db.exec("CREATE INDEX IF NOT EXISTS games_missing_elo ON games(id) WHERE elo_indexed=0; CREATE INDEX IF NOT EXISTS games_folder_missing_elo ON games(folder,id) WHERE elo_indexed=0;")
        var lastID = ""
        while true {
            try Task.checkCancellation()
            var whereSQL = "elo_indexed=0 AND id>?"
            var values: [SQLValue] = [.text(lastID)]
            if let folder = request.folder { whereSQL += " AND folder=?"; values.append(.text(folder)) }
            if request.unfiled { whereSQL += " AND folder IS NULL" }
            let query = try db.prepare("SELECT id FROM games WHERE " + whereSQL + " ORDER BY id LIMIT 200")
            try query.bind(values)
            var batch: [ChessStudy] = []
            while try query.next() {
                lastID = query.text(0)
                if let id = UUID(uuidString: lastID) { batch.append(ChessStudy(id: id)) }
            }
            query.reset()
            guard !batch.isEmpty else { return }
            try hydrateRatings(batch, requireCache: true)
        }
    }

    // Older catalogs acquire ratings only for the visible page. Read metadata, never move trees.
    func hydrateRatings(_ games: [ChessStudy], requireCache: Bool = false) throws {
        guard !games.isEmpty else { return }
        struct Ratings: Decodable { var whiteElo: String?; var blackElo: String? }
        let db = try SQLConnection(url)
        let read = try db.prepare("SELECT g.payload,s.path,s.kind,g.record,g.record_length FROM games g LEFT JOIN sources s ON s.id=g.source_id WHERE g.id=?")
        var filled: [ChessStudy] = []
        for game in games {
            try Task.checkCancellation()
            try read.bind([.text(game.id.uuidString)])
            defer { read.reset() }
            guard try read.next() else { continue }
            do {
                if !read.isNull(0) {
                    let ratings = try JSONDecoder().decode(Ratings.self, from: read.data(0))
                    game.whiteElo = ratings.whiteElo; game.blackElo = ratings.blackElo
                } else {
                    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: read.text(1)))
                    defer { try? handle.close() }
                    if read.text(2) == "cbh" {
                        try handle.seek(toOffset: UInt64(46 + read.int(3) * 46 + 31))
                        guard let data = try handle.read(upToCount: 4), data.count == 4 else { continue }
                        let bytes = Array(data)
                        let white = ((Int(bytes[0]) << 8) | Int(bytes[1])) & 0xFFF
                        let black = ((Int(bytes[2]) << 8) | Int(bytes[3])) & 0xFFF
                        game.whiteElo = white > 0 ? String(white) : nil
                        game.blackElo = black > 0 ? String(black) : nil
                    } else if read.text(2) == "pgn" {
                        try handle.seek(toOffset: UInt64(read.int(3)))
                        let data = try handle.read(upToCount: min(read.int(4), 64 * 1024)) ?? Data()
                        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                            let line = line.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
                            if line.isEmpty { continue }
                            guard line.hasPrefix("[") else { break }
                            let pieces = line.split(separator: "\"", omittingEmptySubsequences: false)
                            guard pieces.count >= 3 else { continue }
                            let tag = pieces[0].dropFirst().trimmingCharacters(in: .whitespaces)
                            if tag == "WhiteElo" { game.whiteElo = String(pieces[1]) }
                            if tag == "BlackElo" { game.blackElo = String(pieces[1]) }
                        }
                    } else { continue }
                }
                filled.append(game)
            } catch is CancellationError { throw CancellationError() }
            catch { continue } // An unavailable source still has browsable indexed headers.
        }
        if requireCache && filled.count != games.count {
            throw CatalogError.message("Could not read ratings from a source database. Restore its managed source files before sorting by Elo.")
        }
        // Cache this page if no importer holds the writer lock. Ratings can still display if it does.
        try db.exec("PRAGMA busy_timeout=0")
        do {
            try db.exec("BEGIN IMMEDIATE")
            let update = try db.prepare("UPDATE games SET white_elo=?,black_elo=?,elo_indexed=1 WHERE id=?")
            for game in filled {
                try update.bind([.optional(game.whiteElo),.optional(game.blackElo),.text(game.id.uuidString)])
                try update.run(); update.reset()
            }
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            if requireCache { throw error }
        }
    }

    func load(_ id: UUID) throws -> ChessStudy {
        let db = try SQLConnection(url)
        let q = try db.prepare("SELECT payload,source_id,record,folder,source_name,source_url,record_length FROM games WHERE id=?")
        try q.bind([.text(id.uuidString)])
        guard try q.next() else { throw CatalogError.message("This game is no longer in the library.") }
        if !q.isNull(0) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let game = try decoder.decode(StudyPersistenceSnapshot.self, from: q.data(0)).makeStudy()
            game.folderID = q.optionalText(3).flatMap(UUID.init(uuidString:))
            return game
        }
        guard let sourceID = q.optionalText(1), let source = try source(id: sourceID) else { throw CatalogError.message("The game's source database is missing.") }
        let game: ChessStudy
        if source.kind == "cbh" {
            game = try ChessBaseImportService.readRecord(URL(fileURLWithPath: source.path), index: q.int(2))
        } else if source.kind == "pgn" {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: source.path))
            defer { try? handle.close() }
            let length = q.int(6)
            guard length > 0, length <= 64*1024*1024 else { throw CatalogError.message("This individual game is too large to open.") }
            try handle.seek(toOffset: UInt64(q.int(2)))
            let bytes = try handle.read(upToCount: length) ?? Data()
            guard bytes.count == length, let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .windowsCP1252), let parsed = try PGNService.parse(text).first else { throw PGNError.noGames }
            game = parsed
        } else { throw CatalogError.message("This database format cannot be opened.") }
        game.id = id; game.folderID = q.optionalText(3).flatMap(UUID.init(uuidString:))
        game.sourceName = q.optionalText(4); game.sourceURL = q.optionalText(5)
        game.dirtyState = false; game.lastSavedAt = Date()
        game.databaseReference = DatabaseGameReference(id: id.uuidString, sourceID: sourceID, record: q.int(2))
        return game
    }

    func source(id: String? = nil, url sourceURL: String? = nil, hash: String? = nil) throws -> CatalogSource? {
        let db = try SQLConnection(url)
        let q = try db.prepare("SELECT id,path,kind,name,folder,count FROM sources WHERE " + (id != nil ? "id=?" : hash != nil ? "hash=?" : "url=?") + " LIMIT 1")
        try q.bind([.text(id ?? hash ?? sourceURL ?? "")])
        guard try q.next() else { return nil }
        return CatalogSource(id: q.text(0), path: q.text(1), kind: q.text(2), name: q.text(3), folder: q.optionalText(4), count: q.int(5))
    }

    func addSource(id: String, path: String, kind: String, name: String, original: String, hash: String?, folder: UUID, count: Int = 0) throws {
        let db = try SQLConnection(url)
        let q = try db.prepare("INSERT INTO sources(id,path,kind,name,url,hash,folder,count) VALUES(?,?,?,?,?,?,?,?)")
        try q.bind([.text(id),.text(path),.text(kind),.text(name),.text(original),.optional(hash),.text(folder.uuidString),.int(count)]); try q.run()
    }

    func committedSourceFolders() throws -> [GameFolder] {
        let db=try SQLConnection(url)
        let q=try db.prepare("SELECT folder,name FROM sources WHERE count>0 AND folder IS NOT NULL ORDER BY rowid")
        var folders:[GameFolder]=[],seen=Set<UUID>()
        while try q.next() {
            if let id=UUID(uuidString:q.text(0)),seen.insert(id).inserted {folders.append(GameFolder(id:id,name:q.text(1)))}
        }
        return folders
    }

    private static func finishInteractiveBulk(_ db: SQLConnection) throws {
        try db.exec("DELETE FROM metadata WHERE key='interactiveBulk'; DELETE FROM imported_overrides; INSERT OR REPLACE INTO metadata VALUES('interactiveLayout',lower(hex(randomblob(16))))")
    }

    func removeSource(_ id: String) throws {
        let db = try SQLConnection(url); try db.exec("BEGIN IMMEDIATE")
        do {
            try db.exec("INSERT OR REPLACE INTO metadata VALUES('interactiveBulk','1')")
            for sql in ["DELETE FROM games WHERE source_id=?", "DELETE FROM sources WHERE id=?"] {
                let q = try db.prepare(sql); try q.bind([.text(id)]); try q.run()
            }; try Self.finishInteractiveBulk(db); try db.exec("COMMIT")
        } catch { try? db.exec("ROLLBACK"); throw error }
    }

    func move(_ id: UUID, folder: UUID?) throws {
        try mutateGame(id, sql:"UPDATE games SET folder=? WHERE id=?", values:[.optional(folder?.uuidString),.text(id.uuidString)], additionalFolders:[folder?.uuidString ?? ""])
    }
    func delete(_ id: UUID) throws {
        try mutateGame(id, sql:"DELETE FROM games WHERE id=?", values:[.text(id.uuidString)])
    }
    private func mutateGame(_ id: UUID, sql: String, values: [SQLValue], additionalFolders: Set<String> = []) throws {
        let db = try SQLConnection(url);try db.exec("BEGIN IMMEDIATE")
        do {
            let old=try db.prepare("SELECT folder FROM games WHERE id=?");try old.bind([.text(id.uuidString)])
            var folders=additionalFolders
            if try old.next() {folders.insert(old.text(0))};old.reset()
            let q=try db.prepare(sql);try q.bind(values);try q.run()
            try Self.invalidatePositionSearches(db,folders:folders);try db.exec("COMMIT")
        } catch {try? db.exec("ROLLBACK");throw error}
    }
    func removeFolder(_ id: UUID) throws {
        let db = try SQLConnection(url);try db.exec("BEGIN IMMEDIATE")
        do {
            try db.exec("INSERT OR REPLACE INTO metadata VALUES('interactiveBulk','1')")
            let q=try db.prepare("UPDATE games SET folder=NULL WHERE folder=?")
            try q.bind([.text(id.uuidString)]);try q.run()
            try Self.finishInteractiveBulk(db)
            try Self.invalidatePositionSearches(db,folders:[id.uuidString,""]);try db.exec("COMMIT")
        } catch {try? db.exec("ROLLBACK");throw error}
    }

}

final class CatalogCandidateReader {
    private let db: SQLConnection
    let count: Int
    init(db: SQLConnection, count: Int) {self.db=db;self.count=count}
    func batch(after rowID: Int) throws -> SQLStatement {
        let q=try db.prepare("SELECT g.rowid,g.id,g.source_id,g.record,g.payload,g.record_length FROM position_candidates p CROSS JOIN games g WHERE p.game_rowid>? AND g.rowid=p.game_rowid ORDER BY p.game_rowid LIMIT 512")
        try q.bind([.int(rowID)]);return q
    }
}

enum CatalogError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

enum SQLValue {
    case rawText(Data), text(String), blob(Data), number(Double), int(Int), null
    static func optional(_ value: String?) -> SQLValue { value.map(SQLValue.text) ?? .null }
}
final class SQLConnection {
    var handle: OpaquePointer?
    init(_ url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open the library index."
            if let handle { sqlite3_close(handle) }; handle = nil
            throw CatalogError.message(message)
        }
        sqlite3_busy_timeout(handle, 30_000)
        sqlite3_progress_handler(handle, 1000, { _ in Task<Never,Never>.isCancelled ? 1 : 0 }, nil)
        try exec("PRAGMA cache_size=-32768; PRAGMA temp_store=FILE;")
    }
    deinit { if let handle { sqlite3_close(handle) } }
    func exec(_ sql: String) throws {
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        if result == SQLITE_INTERRUPT { throw CancellationError() }
        guard result == SQLITE_OK else { throw error() }
    }
    func stopCancellationChecks() { sqlite3_progress_handler(handle, 0, nil, nil) }
    func error() -> CatalogError { .message(String(cString: sqlite3_errmsg(handle))) }
    func prepare(_ sql: String) throws -> SQLStatement { try SQLStatement(self, sql) }
}
final class SQLStatement {
    let db: SQLConnection
    var handle: OpaquePointer?
    init(_ db: SQLConnection, _ sql: String) throws {
        self.db = db
        guard sqlite3_prepare_v2(db.handle, sql, -1, &handle, nil) == SQLITE_OK else { throw db.error() }
    }
    deinit { sqlite3_finalize(handle) }
    func reset() { sqlite3_reset(handle); sqlite3_clear_bindings(handle) }
    func bind(_ values: [SQLValue]) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let result: Int32
            let position = Int32(index + 1)
            switch value {
            case let .text(text): result = sqlite3_bind_text(handle, position, text, -1, transient)
            case let .rawText(data): result = data.isEmpty ? sqlite3_bind_text(handle, position, "", 0, transient) : data.withUnsafeBytes { sqlite3_bind_text(handle, position, $0.baseAddress?.assumingMemoryBound(to:CChar.self), Int32(data.count), transient) }
            case let .blob(data): result = data.withUnsafeBytes { sqlite3_bind_blob(handle, position, $0.baseAddress, Int32(data.count), transient) }
            case let .number(number): result = sqlite3_bind_double(handle, position, number)
            case let .int(number): result = sqlite3_bind_int64(handle, position, Int64(number))
            case .null: result = sqlite3_bind_null(handle, position)
            }
            guard result == SQLITE_OK else { throw CatalogError.message("SQLite bind error \(result): \(String(cString: sqlite3_errstr(result)))") }
        }
    }
    func next() throws -> Bool {
        let result = sqlite3_step(handle)
        if result == SQLITE_INTERRUPT { throw CancellationError() }
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw CatalogError.message("SQLite query error \(result): \(String(cString: sqlite3_errmsg(db.handle)))") }
        return result == SQLITE_ROW
    }
    func run() throws { _ = try next() }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }
    func text(_ column: Int32) -> String {
        guard let bytes=sqlite3_column_text(handle,column) else {return ""}
        let data=Data(bytes:bytes,count:Int(sqlite3_column_bytes(handle,column)))
        return String(data:data,encoding:.utf8) ?? String(data:data,encoding:.windowsCP1252) ?? String(decoding:data,as:UTF8.self)
    }
    func optionalText(_ column: Int32) -> String? { isNull(column) ? nil : text(column) }
    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(handle,column)) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(handle,column) }
    func data(_ column: Int32) -> Data { sqlite3_column_blob(handle,column).map { Data(bytes:$0,count:Int(sqlite3_column_bytes(handle,column))) } ?? Data() }
}
