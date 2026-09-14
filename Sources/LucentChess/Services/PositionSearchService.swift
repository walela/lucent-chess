import Foundation
import Darwin
import CryptoKit

struct PositionSearchResult: Sendable {
    let key: String
    let count: Int
    let skipped: Int
    let cached: Bool
}

enum PositionSearchService {
    private static let condition = NSCondition()
    nonisolated(unsafe) private static var running = Set<String>()

    static func search(catalog: DatabaseCatalog, request: CatalogRequest,
                       progress: @escaping @Sendable (String) -> Void) throws -> PositionSearchResult {
        let board = try CatalogFilter.boardKey(request.filter.boardFEN)
        let version = try catalog.contentVersion(for: request)
        var filter = request.filter; filter.boardFEN = board
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // v2 invalidates incomplete results from the old CBH branch traversal.
        let signature = "lucent-position-v2|" + catalog.url.path + "|" + String(decoding: try encoder.encode(filter), as: UTF8.self) + "|\(request.folder ?? "all")|\(request.unfiled)|\(request.recent)|\(request.search)|\(request.result)|\(request.file)|\(version)|\(request.recent ? Int(Date().timeIntervalSince1970/30) : 0)"
        let key = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        condition.lock()
        while running.contains(key) {
            _ = condition.wait(until: Date().addingTimeInterval(0.2))
            if Task<Never,Never>.isCancelled { condition.unlock(); throw CancellationError() }
        }
        running.insert(key); condition.unlock()
        defer { condition.lock(); running.remove(key); condition.broadcast(); condition.unlock() }
        let db = try SQLConnection(catalog.positionCacheURL)
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA max_page_count=131072;")
        try db.exec("""
        CREATE TABLE IF NOT EXISTS searches(id INTEGER PRIMARY KEY,key TEXT UNIQUE NOT NULL,complete INTEGER NOT NULL DEFAULT 0,count INTEGER NOT NULL DEFAULT 0,skipped INTEGER NOT NULL DEFAULT 0,created REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS matches(search_id INTEGER NOT NULL,game_rowid INTEGER NOT NULL,ply INTEGER NOT NULL,PRIMARY KEY(search_id,game_rowid)) WITHOUT ROWID;
        """)
        let cached = try db.prepare("SELECT count,skipped FROM searches WHERE key=? AND complete=1")
        try cached.bind([.text(key)])
        if try cached.next() {
            let result=PositionSearchResult(key:key,count:cached.int(0),skipped:cached.int(1),cached:true)
            cached.reset()
            let touch=try db.prepare("UPDATE searches SET created=? WHERE key=?")
            try touch.bind([.number(Date().timeIntervalSince1970),.text(key)]);try touch.run()
            return result
        }
        cached.reset()
        try pruneCompletedResults(db)
        let old = try db.prepare("DELETE FROM matches WHERE search_id IN (SELECT id FROM searches WHERE key=?)")
        try old.bind([.text(key)]); try old.run()
        let job = try db.prepare("INSERT INTO searches(key,created) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET complete=0,count=0,skipped=0,created=excluded.created")
        try job.bind([.text(key),.number(Date().timeIntervalSince1970)]); try job.run()
        let idQuery = try db.prepare("SELECT id FROM searches WHERE key=?");try idQuery.bind([.text(key)]);_ = try idQuery.next()
        let searchID = idQuery.int(0);idQuery.reset()
        var finished = false
        defer {
            if !finished {
                db.stopCancellationChecks()
                try? db.exec("ROLLBACK")
                try? db.exec("DELETE FROM matches WHERE search_id=\(searchID); DELETE FROM searches WHERE id=\(searchID)")
            }
        }
        var header = request; header.positionSearchKey = nil; header.filter.boardFEN = ""; header.cursor = nil
        progress("Finding games that match the header filters…")
        let candidateReader = try catalog.candidateReader(header)
        let total = candidateReader.count
        let insert = try db.prepare("INSERT OR IGNORE INTO matches VALUES(?,?,?)")
        var helpers: [String: PositionMatcher] = [:]
        defer { for helper in helpers.values { helper.close() } }
        var sources: [String: CatalogSource] = [:]
        var pgnReaders: [String:PGNPositionScanner] = [:]
        var checked = 0, matched = 0, skipped = 0
        var lastProgress = Date.distantPast
        struct Candidate { let row: Int; let id: UUID; let source: String?; let record: Int; let payload: Data?; let length: Int }
        var lastRow = 0
        while true {
            try Task.checkCancellation()
            var batch: [Candidate] = []
            // Release each read snapshot before decoding, so searches do not pin the import WAL.
            do {
              let candidates = try candidateReader.batch(after: lastRow)
              while try candidates.next() {
                lastRow = candidates.int(0)
                guard let id = UUID(uuidString: candidates.text(1)) else { continue }
                batch.append(Candidate(row:candidates.int(0),id:id,source:candidates.optionalText(2),record:candidates.int(3),payload:candidates.isNull(4) ? nil : candidates.data(4),length:candidates.int(5)))
              }
            }
            if batch.isEmpty { break }
            var results: [(Candidate,Int)] = []
            var native: [String:[Candidate]] = [:]
            for game in batch {
                if let payload = game.payload {
                    do { results.append((game,try matchPayload(payload,board:board))) } catch { results.append((game,-2)) }
                } else if let sourceID = game.source {
                    if sources[sourceID] == nil { sources[sourceID] = try catalog.source(id: sourceID) }
                    guard let source = sources[sourceID] else { results.append((game,-2));continue }
                    if source.kind == "cbh" { native[source.path,default:[]].append(game) }
                    else {
                        do {
                            if pgnReaders[source.path] == nil {
                                if pgnReaders.count >= 4 {pgnReaders.removeAll()}
                                pgnReaders[source.path] = try PGNPositionScanner(path:source.path,board:board)
                            }
                            let ply=try pgnReaders[source.path]!.match(offset:game.record,length:game.length)
                            results.append((game,ply))
                        } catch is CancellationError { throw CancellationError() }
                        catch { results.append((game,-2)) }
                    }
                } else { results.append((game,-2)) }
            }
            for (path,games) in native {
                if helpers[path] == nil {
                    if helpers.count >= 4 { for helper in helpers.values { helper.close() };helpers.removeAll() }
                    helpers[path] = try PositionMatcher(path:path,board:board)
                }
                let values = try helpers[path]!.match(games.map(\.record))
                results += zip(games,values).map { ($0,$1) }
            }
            try Task.checkCancellation()
            try db.exec("BEGIN IMMEDIATE")
            for (game,ply) in results {
                checked += 1
                if ply == -2 { skipped += 1 }
                if ply >= 0 {
                    try insert.bind([.int(searchID),.int(game.row),.int(ply)]); try insert.run();insert.reset();matched+=1
                }
            }
            try db.exec("COMMIT")
            if Date().timeIntervalSince(lastProgress)>0.2 {
                progress("Searching board: \(checked.formatted()) of \(total.formatted()) games · \(matched.formatted()) matches")
                lastProgress=Date()
            }
        }
        try Task.checkCancellation()
        guard try catalog.contentVersion(for: request) == version else { throw CatalogError.message("The library changed during the board search. Run the search again for current results.") }
        let finish = try db.prepare("UPDATE searches SET complete=1,count=?,skipped=? WHERE id=?")
        try finish.bind([.int(matched),.int(skipped),.int(searchID)]);try finish.run()
        finished=true
        return PositionSearchResult(key:key,count:matched,skipped:skipped,cached:false)
    }

    // Leave room for another dense query before hitting the 512 MiB hard cap.
    // Recent cache hits are touched above; the grace interval protects the handoff
    // between resolving a search and reading its first result page in another window.
    static func pruneCompletedResults(_ db: SQLConnection, budgetPages: Int = 65_536, now: Date = Date()) throws {
        try db.exec("BEGIN IMMEDIATE")
        do {
            let expiry = now.addingTimeInterval(-86_400).timeIntervalSince1970
            try db.exec("DELETE FROM matches WHERE search_id IN (SELECT id FROM searches WHERE complete=1 AND created<\(expiry)); DELETE FROM searches WHERE complete=1 AND created<\(expiry)")
            while true {
                let size = try db.prepare("SELECT (SELECT page_count FROM pragma_page_count) - (SELECT freelist_count FROM pragma_freelist_count)")
                let used = try size.next() ? size.int(0) : 0
                size.reset()
                if used <= budgetPages { break }
                let oldest = try db.prepare("SELECT id FROM searches WHERE complete=1 AND created<? ORDER BY created LIMIT 1")
                try oldest.bind([.number(now.addingTimeInterval(-60).timeIntervalSince1970)])
                guard try oldest.next() else { break }
                let id = oldest.int(0); oldest.reset()
                try db.exec("DELETE FROM matches WHERE search_id=\(id); DELETE FROM searches WHERE id=\(id)")
            }
            try db.exec("COMMIT")
        } catch {
            db.stopCancellationChecks()
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    private static func matchPayload(_ payload: Data, board: String) throws -> Int {
        struct Node: Decodable { let id: UUID; let parentID: UUID?; let positionFEN: String }
        struct Game: Decodable { let nodes: [Node] }
        let game = try JSONDecoder().decode(Game.self,from:payload)
        var children: [UUID:Node] = [:]
        for node in game.nodes { if let parent=node.parentID,children[parent]==nil { children[parent]=node } }
        var current=game.nodes.first { $0.parentID==nil },ply=0
        while let node=current,ply<=game.nodes.count {
            if node.positionFEN.split(separator:" ").prefix(2).joined(separator:" ")==board { return ply }
            current=children[node.id];ply+=1
        }
        return -1
    }
}

private final class PositionMatcher {
    let process = Process()
    let input = Pipe(), output = Pipe()
    private var buffered = Data()
    init(path: String, board: String) throws {
        process.executableURL = try ChessBaseImportService.bundledReader()
        process.arguments = ["--match-position",path,board,"stream"]
        process.standardInput=input;process.standardOutput=output;process.standardError=FileHandle.nullDevice
        try process.run()
    }
    func match(_ records: [Int]) throws -> [Int] {
        try Task.checkCancellation()
        try input.fileHandleForWriting.write(contentsOf:Data((records.map(String.init).joined(separator:"\n")+"\n").utf8))
        var result: [Int] = []
        while result.count < records.count {
            if let end=buffered.firstIndex(of:10) {
                let text=String(decoding:buffered[..<end],as:UTF8.self)
                buffered.removeSubrange(...end)
                guard let number=Int(text) else { throw CatalogError.message("The position reader returned an invalid result.") }
                result.append(number)
            } else {
                // FileHandle.read(upToCount:) can wait to fill the requested buffer on a pipe.
                // POSIX read returns the available protocol lines without waiting for EOF.
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 100)
                try Task.checkCancellation()
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                guard ready > 0 else { throw CatalogError.message("Could not read position-search results.") }
                var bytes=[UInt8](repeating:0,count:4096)
                let amount=Darwin.read(output.fileHandleForReading.fileDescriptor,&bytes,bytes.count)
                if amount<0 && errno==EINTR {continue}
                guard amount>0 else {
                    try Task.checkCancellation()
                    throw CatalogError.message("The position reader stopped while decoding a game. Narrow the filters and retry.")
                }
                buffered.append(contentsOf:bytes.prefix(amount))
            }
            try Task.checkCancellation()
        }
        return result
    }
    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
    }
}
