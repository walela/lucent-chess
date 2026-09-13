import Foundation
import SQLite3

struct DatabaseGameReference: Codable, Sendable {
    let id: String
    let sourceID: String?
    let record: Int
}

struct CatalogCursor: Equatable, Sendable {
    let value: String
    let id: String
}

struct CatalogPage: @unchecked Sendable {
    let games: [ChessStudy]
    let next: CatalogCursor?
    let count: Int
}

struct CatalogRequest: Equatable, Sendable {
    var revision = 0
    var folder: String? = nil
    var unfiled = false
    var recent = false
    var search = ""
    var result = "all"
    var file = "all"
    var sort = "date"
    var ascending = false
    var cursor: CatalogCursor? = nil
}

struct CatalogSource: Sendable {
    let id: String
    let path: String
    let kind: String
    let name: String
    let folder: String?
    let count: Int
}

// Connections are confined to each operation. WAL allows paged readers while an import is indexing.
final class DatabaseCatalog: @unchecked Sendable {
    let url: URL
    let sourcesURL: URL
    static let pageSize = 200

    init(url: URL) throws {
        self.url = url
        sourcesURL = url.deletingLastPathComponent().appendingPathComponent("Databases", isDirectory: true)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLConnection(url)
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        try db.exec(Self.schema)
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
      dirty INTEGER NOT NULL DEFAULT 0,modified REAL NOT NULL,created REAL NOT NULL,saved REAL,fingerprint TEXT);
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
            INSERT INTO games(id,payload,white,black,event,title,site,date,result,moves,round,players,round_sort,folder,source_name,file_path,source_url,starter,dirty,modified,created,saved,fingerprint)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,white=excluded.white,black=excluded.black,event=excluded.event,title=excluded.title,site=excluded.site,date=excluded.date,result=excluded.result,moves=excluded.moves,round=excluded.round,players=excluded.players,round_sort=excluded.round_sort,folder=excluded.folder,source_name=excluded.source_name,file_path=excluded.file_path,source_url=excluded.source_url,starter=excluded.starter,dirty=excluded.dirty,modified=excluded.modified,created=excluded.created,saved=excluded.saved,fingerprint=coalesce(excluded.fingerprint,games.fingerprint)
            WHERE games.payload IS NOT excluded.payload
            """)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
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
                try query.bind([.text(game.id.uuidString), .blob(encoder.encode(game)), .text(game.white), .text(game.black), .text(game.event), .text(game.title), .text(game.site ?? ""), .number(game.date.timeIntervalSince1970), .text(game.result), .int(moveCount), .text(round), .text(players), .text(roundSort), .optional(game.folderID?.uuidString), .optional(game.sourceName), .optional(game.filePath), .optional(game.sourceURL), .optional(game.starterCollectionID), .int(game.dirtyState == true ? 1 : 0), .number(game.modifiedAt.timeIntervalSince1970), .number(game.createdAt.timeIntervalSince1970), game.lastSavedAt.map { .number($0.timeIntervalSince1970) } ?? .null, .optional(fingerprints[game.id.uuidString])])
                try query.run(); query.reset()
            }
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
        let db = try SQLConnection(url)
        let column: String
        switch request.sort { case "players", "event", "result", "moves": column = request.sort
        case "round": column = "round_sort"
        default: column = "date" }
        if column != "date" && column != "players" {
            // Build additional sort indexes only when requested, on the query worker.
            try db.exec("CREATE INDEX IF NOT EXISTS games_\(column) ON games(\(column),id); CREATE INDEX IF NOT EXISTS games_folder_\(column) ON games(folder,\(column),id);")
        }
        var conditions: [String] = []; var values: [SQLValue] = []
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
        var matchExpression = tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")
        if !tokens.isEmpty, let folder = request.folder {
            matchExpression += " AND folder : \"" + folder.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var textMatches: Int?
        if !tokens.isEmpty {
            let fts = try db.prepare("SELECT count(*) FROM games_fts WHERE games_fts MATCH ?")
            try fts.bind([.text(matchExpression)])
            textMatches = try fts.next() ? fts.int(0) : 0
            if textMatches == 0 { return CatalogPage(games: [], next: nil, count: 0) }
            conditions.append("rowid IN (SELECT rowid FROM games_fts WHERE games_fts MATCH ?)")
            values.append(.text(matchExpression))
        }
        let baseWhere = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        let denseSearch = (textMatches ?? 0) > 10_000
        let count: Int
        if let textMatches, !request.unfiled, !request.recent, request.result == "all", request.file == "all" {
            count = textMatches
        } else if !request.recent && request.result == "all" && request.file == "all" && tokens.isEmpty {
            let counts = try counts()
            count = request.folder.map { counts[$0] ?? 0 } ?? (request.unfiled ? counts[""] ?? 0 : counts.values.reduce(0,+))
        } else {
            let countIndex = denseSearch && (request.folder != nil || request.unfiled) && !request.recent && request.result == "all" && request.file == "all" ? " INDEXED BY games_folder_date" : ""
            let q = try db.prepare("SELECT count(*) FROM games" + countIndex + baseWhere); try q.bind(values)
            count = try q.next() ? q.int(0) : 0
        }
        if let cursor = request.cursor {
            conditions.append("(\(column),id) \(request.ascending ? ">" : "<") (?,?)")
            values.append(column == "date" || column == "moves" ? .number(Double(cursor.value) ?? 0) : .text(cursor.value))
            values.append(.text(cursor.id))
        }
        let whereSQL = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        let direction = request.ascending ? "ASC" : "DESC"
        // For broad matches, scan the ordering index and test the materialized FTS row-id set.
        // Otherwise SQLite fetches and sorts millions of full rows before returning one page.
        let orderIndex = denseSearch ? " INDEXED BY games_\((request.folder != nil || request.unfiled) ? "folder_" : "")\(column)" : ""
        let query = try db.prepare("SELECT id,source_id,record,white,black,event,title,site,date,result,moves,round,folder,source_name,file_path,source_url,starter,dirty,modified,created,saved,\(column) FROM games" + orderIndex + whereSQL + " ORDER BY \(column) \(direction),id \(direction) LIMIT \(Self.pageSize + 1)")
        try query.bind(values)
        var games: [ChessStudy] = []; var last: CatalogCursor?
        while try query.next() {
            if games.count == Self.pageSize { return CatalogPage(games: games, next: last, count: count) }
            let game = try Self.preview(query)
            games.append(game); last = CatalogCursor(value: query.text(21), id: game.id.uuidString)
        }
        return CatalogPage(games: games, next: nil, count: count)
    }

    private static func preview(_ query: SQLStatement) throws -> ChessStudy {
        guard let id = UUID(uuidString: query.text(0)) else { throw CatalogError.message("Invalid game identifier in the library index.") }
        let game = ChessStudy(id: id, title: query.text(6), white: query.text(3), black: query.text(4), event: query.text(5), site: query.text(7), round: query.text(11), date: Date(timeIntervalSince1970: query.double(8)), result: query.text(9))
        game.folderID = query.optionalText(12).flatMap(UUID.init(uuidString:))
        game.sourceName = query.optionalText(13); game.filePath = query.optionalText(14); game.sourceURL = query.optionalText(15)
        game.starterCollectionID = query.optionalText(16); game.dirtyState = query.int(17) != 0
        game.modifiedAt = Date(timeIntervalSince1970: query.double(18)); game.createdAt = Date(timeIntervalSince1970: query.double(19))
        game.lastSavedAt = query.isNull(20) ? nil : Date(timeIntervalSince1970: query.double(20))
        game.databaseReference = DatabaseGameReference(id: id.uuidString, sourceID: query.optionalText(1), record: query.int(2))
        game.indexedPlyCount = query.int(10)
        return game
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

    func removeSource(_ id: String) throws {
        let db = try SQLConnection(url); try db.exec("BEGIN IMMEDIATE")
        do {
            for sql in ["DELETE FROM games WHERE source_id=?", "DELETE FROM sources WHERE id=?"] {
                let q = try db.prepare(sql); try q.bind([.text(id)]); try q.run()
            }; try db.exec("COMMIT")
        } catch { try? db.exec("ROLLBACK"); throw error }
    }

    func move(_ id: UUID, folder: UUID?) throws {
        let db = try SQLConnection(url); let q = try db.prepare("UPDATE games SET folder=? WHERE id=?")
        try q.bind([.optional(folder?.uuidString),.text(id.uuidString)]); try q.run()
    }
    func delete(_ id: UUID) throws {
        let db = try SQLConnection(url); let q = try db.prepare("DELETE FROM games WHERE id=?")
        try q.bind([.text(id.uuidString)]); try q.run()
    }
    func removeFolder(_ id: UUID) throws {
        let db = try SQLConnection(url); let q = try db.prepare("UPDATE games SET folder=NULL WHERE folder=?")
        try q.bind([.text(id.uuidString)]); try q.run()
    }
}

enum CatalogError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

enum SQLValue {
    case text(String), blob(Data), number(Double), int(Int), null
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
            case let .blob(data): result = data.withUnsafeBytes { sqlite3_bind_blob(handle, position, $0.baseAddress, Int32(data.count), transient) }
            case let .number(number): result = sqlite3_bind_double(handle, position, number)
            case let .int(number): result = sqlite3_bind_int64(handle, position, Int64(number))
            case .null: result = sqlite3_bind_null(handle, position)
            }
            guard result == SQLITE_OK else { throw db.error() }
        }
    }
    func next() throws -> Bool {
        let result = sqlite3_step(handle)
        if result == SQLITE_INTERRUPT { throw CancellationError() }
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw db.error() }
        return result == SQLITE_ROW
    }
    func run() throws { _ = try next() }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }
    func text(_ column: Int32) -> String { sqlite3_column_text(handle,column).map { String(cString:$0) } ?? "" }
    func optionalText(_ column: Int32) -> String? { isNull(column) ? nil : text(column) }
    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(handle,column)) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(handle,column) }
    func data(_ column: Int32) -> Data { sqlite3_column_blob(handle,column).map { Data(bytes:$0,count:Int(sqlite3_column_bytes(handle,column))) } ?? Data() }
}
