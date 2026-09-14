import Foundation
import SQLite3

extension DatabaseCatalog {
    // Editable games have their own compact metadata rows. Sorting these rows
    // never scans the imported database or touches the move-tree payloads.
    static let localColumns = ["id","source_id","record","white","black","event","title","site","date","result","moves","round","players","round_sort","folder","source_name","file_path","source_url","starter","dirty","modified","created","saved","fingerprint","white_elo","black_elo","elo_indexed"]

    static var localSchema: String {
        let columns = localColumns.joined(separator: ",")
        let incoming = localColumns.map { "new.\($0)" }.joined(separator: ",")
        let assignments = localColumns.filter { $0 != "id" }.map { "\($0)=excluded.\($0)" }.joined(separator: ",")
        let changed = localColumns.filter { $0 != "id" }.map { "old.\($0) IS NOT new.\($0)" }.joined(separator: " OR ")
        var sql = """
        CREATE TABLE IF NOT EXISTS local_headers(
          rowid INTEGER PRIMARY KEY,id TEXT UNIQUE NOT NULL,source_id TEXT,record INTEGER NOT NULL DEFAULT 0,
          white TEXT NOT NULL,black TEXT NOT NULL,event TEXT NOT NULL,title TEXT NOT NULL,site TEXT NOT NULL DEFAULT '',
          date REAL NOT NULL,result TEXT NOT NULL,moves INTEGER NOT NULL DEFAULT 0,round TEXT NOT NULL DEFAULT '',
          players TEXT NOT NULL,round_sort TEXT NOT NULL,folder TEXT,source_name TEXT,file_path TEXT,source_url TEXT,starter TEXT,
          dirty INTEGER NOT NULL DEFAULT 0,modified REAL NOT NULL,created REAL NOT NULL,saved REAL,fingerprint TEXT,
          white_elo TEXT,black_elo TEXT,elo_indexed INTEGER NOT NULL DEFAULT 0,position_state INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS local_positions(board TEXT NOT NULL,game_id TEXT NOT NULL,PRIMARY KEY(board,game_id)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS local_positions_game ON local_positions(game_id);
        CREATE INDEX IF NOT EXISTS local_positions_pending ON local_headers(id) WHERE position_state=0;
        CREATE INDEX IF NOT EXISTS local_ratings_pending ON local_headers(id) WHERE elo_indexed=0;
        CREATE VIRTUAL TABLE IF NOT EXISTS local_fts USING fts5(white,black,event,title,source_name,folder,content='local_headers',content_rowid='rowid',tokenize='unicode61 remove_diacritics 2');
        CREATE TRIGGER IF NOT EXISTS local_header_insert AFTER INSERT ON local_headers BEGIN
          INSERT INTO local_fts(rowid,white,black,event,title,source_name,folder) VALUES(new.rowid,new.white,new.black,new.event,new.title,new.source_name,new.folder);
        END;
        CREATE TRIGGER IF NOT EXISTS local_header_delete AFTER DELETE ON local_headers BEGIN
          INSERT INTO local_fts(local_fts,rowid,white,black,event,title,source_name,folder) VALUES('delete',old.rowid,old.white,old.black,old.event,old.title,old.source_name,old.folder);
          DELETE FROM local_positions WHERE game_id=old.id;
        END;
        CREATE TRIGGER IF NOT EXISTS local_header_update AFTER UPDATE OF white,black,event,title,source_name,folder ON local_headers
        WHEN old.white IS NOT new.white OR old.black IS NOT new.black OR old.event IS NOT new.event OR old.title IS NOT new.title OR old.source_name IS NOT new.source_name OR old.folder IS NOT new.folder BEGIN
          INSERT INTO local_fts(local_fts,rowid,white,black,event,title,source_name,folder) VALUES('delete',old.rowid,old.white,old.black,old.event,old.title,old.source_name,old.folder);
          INSERT INTO local_fts(rowid,white,black,event,title,source_name,folder) VALUES(new.rowid,new.white,new.black,new.event,new.title,new.source_name,new.folder);
        END;
        CREATE TRIGGER IF NOT EXISTS game_local_insert AFTER INSERT ON games WHEN new.payload IS NOT NULL BEGIN
          INSERT INTO local_headers(\(columns)) VALUES(\(incoming)) ON CONFLICT(id) DO UPDATE SET \(assignments),position_state=0;
        END;
        CREATE TRIGGER IF NOT EXISTS game_local_update AFTER UPDATE ON games WHEN new.payload IS NOT NULL AND (old.payload IS NOT new.payload OR \(changed)) BEGIN
          INSERT INTO local_headers(\(columns)) VALUES(\(incoming)) ON CONFLICT(id) DO UPDATE SET \(assignments),position_state=CASE WHEN old.payload IS NOT new.payload THEN 0 ELSE local_headers.position_state END;
        END;
        CREATE TRIGGER IF NOT EXISTS game_local_clear AFTER UPDATE OF payload ON games WHEN new.payload IS NULL AND old.payload IS NOT NULL BEGIN
          DELETE FROM local_headers WHERE id=old.id;
        END;
        CREATE TRIGGER IF NOT EXISTS game_local_delete AFTER DELETE ON games WHEN old.payload IS NOT NULL BEGIN
          DELETE FROM local_headers WHERE id=old.id;
        END;
        CREATE TABLE IF NOT EXISTS imported_overrides(id TEXT PRIMARY KEY,source_id TEXT NOT NULL,record INTEGER NOT NULL,folder TEXT,deleted INTEGER NOT NULL);
        DROP TRIGGER IF EXISTS imported_layout_delete;
        DROP TRIGGER IF EXISTS imported_layout_update;
        DROP TRIGGER IF EXISTS imported_folder_update;
        CREATE TRIGGER imported_layout_delete AFTER DELETE ON games WHEN old.source_id IS NOT NULL AND old.payload IS NULL AND NOT EXISTS(SELECT 1 FROM metadata WHERE key='interactiveBulk') BEGIN
          INSERT OR REPLACE INTO imported_overrides VALUES(old.id,old.source_id,old.record,old.folder,1);
        END;
        CREATE TRIGGER imported_folder_update AFTER UPDATE OF folder ON games WHEN old.source_id IS NOT NULL AND old.payload IS NULL AND new.payload IS NULL AND old.folder IS NOT new.folder AND NOT EXISTS(SELECT 1 FROM metadata WHERE key='interactiveBulk') BEGIN
          INSERT OR REPLACE INTO imported_overrides VALUES(new.id,new.source_id,new.record,new.folder,0);
        END;
        CREATE TRIGGER imported_layout_update AFTER UPDATE ON games WHEN old.source_id IS NOT NULL AND old.payload IS NULL AND (old.payload IS NOT new.payload OR \(localColumns.filter {$0 != "id" && $0 != "folder"}.map {"old.\($0) IS NOT new.\($0)"}.joined(separator:" OR "))) AND NOT EXISTS(SELECT 1 FROM metadata WHERE key='interactiveBulk') BEGIN
          DELETE FROM imported_overrides WHERE id=old.id;
          INSERT INTO metadata VALUES('interactiveLayout',lower(hex(randomblob(16)))) ON CONFLICT(key) DO UPDATE SET value=excluded.value;
        END;
        """
        for (name, column) in [("date","date"),("players","players"),("white_elo","CAST(coalesce(white_elo,'0') AS INTEGER)"),("black_elo","CAST(coalesce(black_elo,'0') AS INTEGER)"),("event","event"),("result","result"),("moves","moves"),("round_sort","round_sort")] {
            sql += "CREATE INDEX IF NOT EXISTS local_games_\(name) ON local_headers(\(column),id);"
            sql += "CREATE INDEX IF NOT EXISTS local_games_folder_\(name) ON local_headers(folder,\(column),id);"
        }
        return sql
    }

    func prepareLocalHeaders() throws {
        let db = try SQLConnection(url)
        let ready = try db.prepare("SELECT 1 FROM metadata WHERE key='localHeadersReady'")
        if try ready.next() { return }
        ready.reset()
        // All editable rows created by Lucent have source_id NULL. Use the
        // existing source index instead of scanning millions of imported rows.
        let columns = Self.localColumns.joined(separator: ",")
        try db.exec("BEGIN IMMEDIATE")
        do {
            try db.exec("INSERT OR IGNORE INTO local_headers(\(columns)) SELECT \(columns) FROM games WHERE source_id IS NULL AND payload IS NOT NULL")
            try db.exec("INSERT OR IGNORE INTO local_headers(\(columns)) SELECT \(columns) FROM games WHERE source_id IN (SELECT id FROM sources WHERE kind NOT IN ('cbh','pgn')) AND payload IS NOT NULL")
            try db.exec("INSERT OR REPLACE INTO metadata VALUES('localHeadersReady','1'); COMMIT")
        } catch { try? db.exec("ROLLBACK"); throw error }
    }

    static func updateLocalPositions(_ game: StudyPersistenceSnapshot, db: SQLConnection) throws {
        struct Node: Decodable { let id: UUID; let parentID: UUID?; let positionFEN: String }
        let nodes = game.nodes.map { Node(id: $0.id, parentID: $0.parentID, positionFEN: $0.positionFEN) }
        try replaceLocalPositions(id: game.id.uuidString, nodes: nodes.map { ($0.id,$0.parentID,$0.positionFEN) }, db: db)
    }

    private static func replaceLocalPositions(id: String, nodes: [(UUID,UUID?,String)], db: SQLConnection) throws {
        var firstChild: [UUID:UUID] = [:], byID: [UUID:String] = [:]
        var current: UUID?, invalid = false
        for (node,parent,fen) in nodes {
            if byID.updateValue(fen,forKey:node) != nil { invalid = true }
            if let parent { if firstChild[parent] == nil { firstChild[parent] = node } }
            else if current == nil { current = node } else { invalid = true }
        }
        let remove = try db.prepare("DELETE FROM local_positions WHERE game_id=?")
        try remove.bind([.text(id)]); try remove.run()
        let insert = try db.prepare("INSERT OR IGNORE INTO local_positions VALUES(?,?)")
        var visited = Set<UUID>()
        while let node = current {
            guard visited.insert(node).inserted, let fen = byID[node], let board = try? CatalogFilter.boardKey(fen) else { invalid = true; break }
            try insert.bind([.text(board),.text(id)]); try insert.run(); insert.reset()
            current = firstChild[node]
        }
        let done = try db.prepare("UPDATE local_headers SET position_state=? WHERE id=?")
        try done.bind([.int(invalid || nodes.isEmpty ? 2 : 1),.text(id)]); try done.run()
    }

    func prepareLocalPositions(progress: @escaping @Sendable (String) -> Void) throws {
        struct Node: Decodable { let id: UUID; let parentID: UUID?; let positionFEN: String }
        struct Game: Decodable { let nodes: [Node] }
        var prepared = 0
        while true {
            try Task.checkCancellation()
            let db = try SQLConnection(url)
            try db.exec("PRAGMA busy_timeout=100")
            let read = try db.prepare("SELECT h.id,g.payload FROM local_headers h JOIN games g ON g.id=h.id WHERE h.position_state=0 ORDER BY h.id LIMIT 100")
            var games: [(String,Data)] = []
            while try read.next() { games.append((read.text(0),read.data(1))) }
            read.reset()
            if games.isEmpty { return }
            let beforeBatch=prepared
            // Verify the captured payload in the write transaction so an
            // autosave cannot publish stale positions over a newer game.
            do {try db.exec("BEGIN IMMEDIATE")} catch {progress("Saved-game positions will finish preparing after the import.");return}
            do {
                let current = try db.prepare("SELECT 1 FROM games WHERE id=? AND payload=?")
                for (id,payload) in games {
                    try current.bind([.text(id),.blob(payload)])
                    let unchanged = try current.next(); current.reset()
                    guard unchanged else { continue }
                    let game = try? JSONDecoder().decode(Game.self,from:payload)
                    try Self.replaceLocalPositions(id:id,nodes:game?.nodes.map { ($0.id,$0.parentID,$0.positionFEN) } ?? [],db:db)
                    prepared += 1
                }
                try db.exec("COMMIT")
            } catch { try? db.exec("ROLLBACK"); throw error }
            if prepared==beforeBatch {progress("Saved-game positions changed; preparation will resume on the next search.");return}
            progress("Preparing saved games: \(prepared.formatted()) games")
        }
    }
}
