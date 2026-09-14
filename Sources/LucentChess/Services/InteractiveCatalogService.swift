import Foundation
import CryptoKit
import Darwin

// Prepared imported metadata and exact position postings are immutable. Small,
// editable games are maintained transactionally in local_headers/local_positions.
// Only the visible page is hydrated into ChessStudy objects.
enum InteractiveCatalogService {
    struct NativeRow: Decodable {
        let id:String;let bytes:Data;let whiteElo:Int64;let blackElo:Int64
        var value:String {String(decoding:bytes,as:UTF8.self)}
        enum CodingKeys:String,CodingKey {case id,valueHex,whiteElo,blackElo}
        init(from decoder:Decoder) throws {
            let values=try decoder.container(keyedBy:CodingKeys.self)
            id=try values.decode(String.self,forKey:.id);whiteElo=try values.decode(Int64.self,forKey:.whiteElo);blackElo=try values.decode(Int64.self,forKey:.blackElo)
            let hex=Array(try values.decode(String.self,forKey:.valueHex).utf8)
            guard hex.count%2==0,hex.count<=2*1024*1024 else {throw CatalogError.message("Invalid sort key from the native reader.")}
            func digit(_ byte:UInt8)throws->UInt8 {
                if byte>=48&&byte<=57{return byte-48};if byte>=97&&byte<=102{return byte-87}
                throw CatalogError.message("Invalid sort key from the native reader.")
            }
            var result=Data();result.reserveCapacity(hex.count/2)
            for i in stride(from:0,to:hex.count,by:2){result.append(try digit(hex[i])*16+digit(hex[i+1]))}
            bytes=result
        }
    }
    struct NativePage: Decodable { let count: Int; let skipped: Int; let rows: [NativeRow] }
    struct State { let generation: String; let sources: [CatalogSource] }
    private static let gate = NSCondition()
    private static var preparing = Set<String>()
    private static var verified: [String:String] = [:]
    private static var active: [String:Int] = [:]

    static func root(_ catalog: DatabaseCatalog) -> URL {
        catalog.url.deletingLastPathComponent().appendingPathComponent("InteractiveIndexes/v2", isDirectory: true)
    }

    static func state(_ catalog: DatabaseCatalog) throws -> State {
        let db = try SQLConnection(catalog.url)
        let query = try db.prepare("SELECT id,path,kind,name,folder,count,hash FROM sources WHERE count>0 AND kind IN ('cbh','pgn') ORDER BY id")
        var sources: [CatalogSource] = []
        var pieces = ["lucent-metadata-2-token-3"]
        while try query.next() {
            let source = CatalogSource(id:query.text(0),path:query.text(1),kind:query.text(2),name:query.text(3),folder:query.optionalText(4),count:query.int(5),hash:query.optionalText(6))
            sources.append(source)
            pieces += [source.id,source.path,source.kind,source.hash ?? "",String(source.count)]
        }
        let layout = try db.prepare("SELECT CAST(value AS TEXT) FROM metadata WHERE key='interactiveLayout'")
        if try layout.next() { pieces.append(layout.text(0)) }
        return State(generation:digest(pieces),sources:sources)
    }

    private static func digest(_ parts: [String]) -> String {
        let data = try! JSONEncoder().encode(parts)
        return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }

    private final class Preparation: @unchecked Sendable {
        var result: Result<Void,Error>?
        var message = ""
    }
    private static var jobs: [String:Preparation] = [:]

    // Preparation belongs to the library, not to a board-position request.
    // Scrubbing the board cancels waiting/query work while the shared preparation
    // continues. Native workers notice application exit and checkpoint on disk.
    static func singleFlight(_ key: String, progress: @escaping @Sendable (String) -> Void, body: @escaping @Sendable (@escaping @Sendable (String) -> Void) throws -> Void) throws {
        try Task.checkCancellation()
        gate.lock()
        let job:Preparation
        if let existing=jobs[key] {job=existing;gate.unlock()}
        else {
            job=Preparation();jobs[key]=job;preparing.insert(key);gate.unlock()
            Task.detached(priority:.userInitiated) {
                let result=Result {try body {message in gate.lock();job.message=message;gate.broadcast();gate.unlock()}}
                finish(job,key:key,result:result)
            }
        }
        var last=""
        while true {
            try Task.checkCancellation()
            gate.lock();let result=job.result,message=job.message
            if result == nil {gate.wait(until:Date().addingTimeInterval(0.1))}
            gate.unlock()
            if message != last {last=message;progress(message)}
            if let result {try result.get();return}
        }
    }

    private static func finish(_ job: Preparation, key: String, result: Result<Void,Error>) {
        gate.lock();job.result=result;jobs.removeValue(forKey:key);preparing.remove(key);gate.broadcast();gate.unlock()
    }

    static func run(_ arguments: [String], progress: @escaping @Sendable (String) -> Void = { _ in }) throws {
        try Task.checkCancellation()
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("lucent-prepare-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath:log.path,contents:nil)
        let output = try FileHandle(forWritingTo:log)
        defer { try? output.close(); try? FileManager.default.removeItem(at:log) }
        let process = Process(), finished = DispatchSemaphore(value:0)
        process.executableURL = try ChessBaseImportService.bundledReader()
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = output
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        var reported = "", nextUpdate = Date.distantPast
        while finished.wait(timeout:.now() + .milliseconds(5)) == .timedOut {
            if Task.isCancelled {
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
                throw CancellationError()
            }
            if Date() >= nextUpdate {
                nextUpdate = Date().addingTimeInterval(0.3)
                let text = (try? String(contentsOf:log,encoding:.utf8)) ?? ""
                for line in text.split(separator:"\n").suffix(1) {
                    guard let data = line.data(using:.utf8), let item = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { continue }
                    var message = ""
                    if let order = item["order"] as? String { message = "Preparing sort order: \(order)" }
                    else if let games = item["games"] as? Int { message = "Preparing database: \(games.formatted()) games" }
                    else if let done = item["prepared"] as? Int { message = "Preparing positions: \(done.formatted()) games" }
                    else if let end = item["end"] as? Int { message = "Preparing positions: \(end.formatted()) games" }
                    if !message.isEmpty && message != reported { reported = message; progress(message) }
                }
            }
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf:log,encoding:.utf8))?.split(separator:"\n").last.map(String.init) ?? "The native database reader stopped."
            throw CatalogError.message(detail)
        }
    }

    private static func requestFile(_ object: [String:Any], in directory: URL) throws -> URL {
        let path = directory.appendingPathComponent("request-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]).write(to:path)
        return path
    }

    static func object(_ request: CatalogRequest, positionRoot: URL) throws -> [String:Any] {
        var result: [String:Any] = ["sort":request.sort,"ascending":request.ascending,"unfiled":request.unfiled,
            "search":request.search,"player":request.filter.player,"white":request.filter.white,"black":request.filter.black,
            "tournament":request.filter.tournament,"result":request.result,"file":request.file,"positionRoot":positionRoot.path]
        if let folder=request.folder { result["folder"]=folder }
        for (name,value) in [("whiteMin",request.filter.whiteMin),("whiteMax",request.filter.whiteMax),("blackMin",request.filter.blackMin),("blackMax",request.filter.blackMax)] { if let value {result[name]=value} }
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone = .current
        if let year=request.filter.yearMin {result["dateMin"]=calendar.date(from:DateComponents(year:year,month:1,day:1))!.timeIntervalSince1970}
        if let year=request.filter.yearMax {result["dateMax"]=calendar.date(from:DateComponents(year:year+1,month:1,day:1))!.timeIntervalSince1970}
        if request.recent {result["recentAfter"]=Date().addingTimeInterval(-14*86400).timeIntervalSince1970}
        if !request.filter.boardFEN.isEmpty {result["board"]=try CatalogFilter.boardKey(request.filter.boardFEN)}
        if let cursor=request.cursor {result["cursorValue"]=cursor.value;result["cursorID"]=cursor.id;if let bytes=cursor.rawValue {result["cursorHex"]=bytes.map {String(format:"%02x",$0)}.joined()}}
        return result
    }

    private static let integrityFiles = ["catalog.bin","names.bin","name-order.bin","tokens.bin","players.bin","sources.json","groups.bin","checksums.txt"]
    private static func verify(_ directory: URL, progress: @escaping @Sendable (String) -> Void) throws {
        let attributes=try integrityFiles.map {name -> String in
            let info=try FileManager.default.attributesOfItem(atPath:directory.appendingPathComponent(name).path)
            return "\(name):\(info[.size] ?? 0):\((info[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }.joined(separator:"|")
        gate.lock();let cached=verified[directory.path];gate.unlock()
        if cached==attributes {return}
        progress("Checking prepared database metadata…")
        try run(["--verify-catalog-metadata",directory.path])
        gate.lock();verified[directory.path]=attributes;gate.unlock()
    }

    private static func pruneMetadata(keeping current: URL) {
        let parent=current.deletingLastPathComponent()
        guard let directories=try? FileManager.default.contentsOfDirectory(at:parent,includingPropertiesForKeys:[.contentModificationDateKey]) else {return}
        let prior=directories.filter {$0 != current && $0.lastPathComponent.count==64}.sorted {
            ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        // Keep the previous generation as well; active pages and builders hold
        // references. Native readers also take a shared lock for other app instances.
        for directory in prior.dropFirst() {
            gate.lock();let busy=(active[directory.path] ?? 0)>0 || preparing.contains(directory.path);gate.unlock()
            if busy {continue}
            let descriptor=Darwin.open(directory.appendingPathComponent("build.lock").path,O_RDONLY)
            guard descriptor>=0 else {continue}
            if flock(descriptor,LOCK_EX|LOCK_NB)==0 {try? FileManager.default.removeItem(at:directory)}
            Darwin.close(descriptor)
        }
    }

    static func prepareMetadata(catalog: DatabaseCatalog, state: State, progress: @escaping @Sendable (String) -> Void) throws -> URL {
        let directory=root(catalog).appendingPathComponent("Metadata/"+state.generation,isDirectory:true)
        try singleFlight(directory.path,progress:progress) { update in
            if (try? String(contentsOf:directory.appendingPathComponent("complete.txt"),encoding:.utf8)) == state.generation {
                do {try verify(directory,progress:update);return}
                catch is CancellationError {throw CancellationError()}
                catch {try resetDerivedDirectory(directory)}
            }
            update("Preparing database sorting and name search once…")
            try run(["--prepare-catalog-metadata",catalog.url.path,directory.path,state.generation],progress:update)
            guard try self.state(catalog).generation == state.generation else {throw CatalogError.message("The imported library changed during preparation. Run the search again.")}
            try verify(directory,progress:update)
            pruneMetadata(keeping:directory)
        }
        return directory
    }

    private static func resetDerivedDirectory(_ directory: URL) throws {
        guard FileManager.default.fileExists(atPath:directory.path) else {return}
        let lock=Darwin.open(directory.appendingPathComponent("build.lock").path,O_RDWR|O_CREAT,0o600)
        guard lock>=0 else {throw CatalogError.message("Could not open the prepared index lock.")}
        defer {Darwin.close(lock)}
        guard flock(lock,LOCK_EX|LOCK_NB)==0 else {throw CatalogError.message("The prepared index is still in use. Retry shortly.")}
        try FileManager.default.removeItem(at:directory)
    }

    private static func sourceIsCurrent(_ source: CatalogSource, directory: URL) -> Bool {
        guard let stamp=try? String(contentsOf:directory.appendingPathComponent("source.txt"),encoding:.utf8),stamp.hasPrefix("lucent-exact-position-2-mainline-3\n") else {return false}
        let path=URL(fileURLWithPath:source.path)
        let files=source.kind=="cbh" ? ["cbh","cbg","cba"].map {path.deletingPathExtension().appendingPathExtension($0)} : [path]
        for file in files {
            var info=stat()
            guard stat(file.path,&info)==0 else {return false}
            let nanos=Int64(info.st_mtimespec.tv_sec)*1_000_000_000+Int64(info.st_mtimespec.tv_nsec)
            if !stamp.components(separatedBy:"\n").contains("\(file.path):\(info.st_size):\(nanos)") {return false}
        }
        return true
    }

    static func sourceIdentity(_ source: CatalogSource) -> String {digest(["lucent-positions-2-mainline-3",source.id,source.hash ?? "",source.kind])}

    static func preparePositions(catalog: DatabaseCatalog, source: CatalogSource, progress: @escaping @Sendable (String) -> Void) throws {
        let directory=root(catalog).appendingPathComponent("Positions/"+source.id,isDirectory:true)
        try singleFlight(directory.path,progress:progress) { update in
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let descriptor=Darwin.open(directory.appendingPathComponent("build.lock").path,O_RDWR|O_CREAT,0o600)
            if descriptor>=0 {Darwin.close(descriptor)}
            let identity=sourceIdentity(source)
            let manifest=directory.appendingPathComponent("identity.txt")
            let oldIdentity=try? String(contentsOf:manifest,encoding:.utf8)
            let hasSource=FileManager.default.fileExists(atPath:directory.appendingPathComponent("source.txt").path)
            let current=sourceIsCurrent(source,directory:directory)
            if FileManager.default.fileExists(atPath:directory.appendingPathComponent("complete.txt").path),oldIdentity==identity,current {return}
            if (oldIdentity != nil && oldIdentity != identity) || (hasSource && !current) {try resetDerivedDirectory(directory)}
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try identity.write(to:manifest,atomically:true,encoding:.utf8)
            update("Preparing \(source.name) positions in the background. You can keep playing.")
            if source.kind == "cbh" {try run(["--prepare-cbh-positions",source.path,directory.path,String(UInt32.max)],progress:update)}
            else {try run(["--prepare-pgn-positions",source.path,catalog.url.path,source.id,directory.path],progress:update)}
        }
    }

    struct NativeTreeRow: Decodable { let uci: String; let games, whiteWins, draws, blackWins: Int; let eloSum: Int64; let eloCount: Int; let latestYear: Int }
    struct NativeTree: Decodable { let games: Int; let skipped: Int; let rows: [NativeTreeRow]; let ended: Int }

    /// Next-move statistics for the board in `request` over every imported game
    /// in scope, computed natively from the exact position index: one lookup per
    /// legal continuation, intersected with the parent position's games.
    static func positionTree(catalog: DatabaseCatalog, request: CatalogRequest, children: [(uci: String, board: String)],
                             progress: @escaping @Sendable (String) -> Void = { _ in }) throws -> NativeTree {
        try request.filter.validate()
        let initial=try state(catalog)
        guard !initial.sources.isEmpty, !request.filter.boardFEN.isEmpty else {return NativeTree(games:0,skipped:0,rows:[],ended:0)}
        let activePath=root(catalog).appendingPathComponent("Metadata/"+initial.generation).path
        gate.lock();active[activePath,default:0]+=1;gate.unlock()
        defer {gate.lock();active[activePath,default:0]-=1;gate.unlock()}
        let metadata=try prepareMetadata(catalog:catalog,state:initial,progress:progress)
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("lucent-tree-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:temp)}
        var parameters=try object(request,positionRoot:root(catalog).appendingPathComponent("Positions"))
        parameters["overrides"]=try catalog.importedOverrides()
        parameters["children"]=children.map {["uci":$0.uci,"board":$0.board]}
        let query=try requestFile(parameters,in:temp)
        let output=temp.appendingPathComponent("result.json")
        try run(["--catalog-source-scope",metadata.path,query.path,output.path])
        let scope=try JSONDecoder().decode([String].self,from:Data(contentsOf:output))
        for source in initial.sources where scope.contains(source.id) {try preparePositions(catalog:catalog,source:source,progress:progress)}
        try Task.checkCancellation()
        try run(["--query-position-tree",metadata.path,query.path,output.path])
        return try JSONDecoder().decode(NativeTree.self,from:Data(contentsOf:output))
    }

    static func page(catalog: DatabaseCatalog, request: CatalogRequest, progress: @escaping @Sendable (String) -> Void = { _ in }) throws -> CatalogPage {
        try request.filter.validate();try request.validateCursor()
        try singleFlight(catalog.url.path+":local",progress:progress) { update in
            try catalog.prepareLocalHeaders()
            try catalog.prepareLocalRatings()
        }
        if !request.filter.boardFEN.isEmpty {
            try singleFlight(catalog.url.path+":localPositions",progress:progress) {update in try catalog.prepareLocalPositions(progress:update)}
        }
        let initial=try state(catalog)
        let activePath=root(catalog).appendingPathComponent("Metadata/"+initial.generation).path
        gate.lock();active[activePath,default:0]+=1;gate.unlock()
        defer {gate.lock();active[activePath,default:0]-=1;gate.unlock()}
        var native=NativePage(count:0,skipped:0,rows:[])
        if !initial.sources.isEmpty && !request.localOnly {
            let metadata=try prepareMetadata(catalog:catalog,state:initial,progress:progress)
            let temp=FileManager.default.temporaryDirectory.appendingPathComponent("lucent-query-\(UUID().uuidString)",isDirectory:true)
            try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
            defer {try? FileManager.default.removeItem(at:temp)}
            var parameters=try object(request,positionRoot:root(catalog).appendingPathComponent("Positions"))
            parameters["overrides"]=try catalog.importedOverrides()
            let query=try requestFile(parameters,in:temp)
            let output=temp.appendingPathComponent("result.json")
            if !request.filter.boardFEN.isEmpty {
                try run(["--catalog-source-scope",metadata.path,query.path,output.path])
                let scope=try JSONDecoder().decode([String].self,from:Data(contentsOf:output))
                for source in initial.sources where scope.contains(source.id) {try preparePositions(catalog:catalog,source:source,progress:progress)}
            }
            try Task.checkCancellation()
            try run(["--query-catalog-metadata",metadata.path,query.path,output.path])
            native=try JSONDecoder().decode(NativePage.self,from:Data(contentsOf:output))
        }
        var localRequest=request;localRequest.localOnly=true;localRequest.positionSearchKey=nil
        let local=try catalog.page(localRequest)
        let localKeys=try catalog.sortKeys(ids:local.games.map { $0.id.uuidString },sort:request.sort)
        struct Entry {let id:String;let value:String;let bytes:Data;let native:NativeRow?;let game:ChessStudy?}
        var entries=native.rows.map {Entry(id:$0.id,value:$0.value,bytes:$0.bytes,native:$0,game:nil)}
        entries += local.games.compactMap {game in localKeys[game.id.uuidString].map {Entry(id:game.id.uuidString,value:$0.value,bytes:$0.rawValue ?? Data($0.value.utf8),native:nil,game:game)}}
        func less(_ a:Entry,_ b:Entry)->Bool {
            let order:ComparisonResult
            if ["whiteElo","blackElo","moves"].contains(request.sort) {
                let x=Int64(a.value) ?? 0,y=Int64(b.value) ?? 0;order=x==y ? .orderedSame : x<y ? .orderedAscending : .orderedDescending
            }else if request.sort == "date" || !["players","event","result","round"].contains(request.sort) {
                let x=Double(a.value) ?? 0,y=Double(b.value) ?? 0;order=x==y ? .orderedSame : x<y ? .orderedAscending : .orderedDescending
            }else {order=a.bytes==b.bytes ? .orderedSame : a.bytes.lexicographicallyPrecedes(b.bytes) ? .orderedAscending : .orderedDescending}
            if order == .orderedSame {return request.ascending ? a.id<b.id : a.id>b.id}
            return request.ascending ? order == .orderedAscending : order == .orderedDescending
        }
        entries.sort(by:less)
        let visible=Array(entries.prefix(DatabaseCatalog.pageSize))
        let previews=try catalog.previews(ids:visible.filter {$0.native != nil}.map(\.id))
        let games=try visible.map {entry -> ChessStudy in
            if let game=entry.game {return game}
            guard let row=entry.native,let game=previews[entry.id] else {throw CatalogError.message("The library changed while loading this page. Run the search again.")}
            game.whiteElo=row.whiteElo>0 ? String(row.whiteElo) : nil;game.blackElo=row.blackElo>0 ? String(row.blackElo) : nil
            return game
        }
        guard try state(catalog).generation == initial.generation else {throw CatalogError.message("The library changed while loading this page. Run the search again.")}
        let hasMore=entries.count>DatabaseCatalog.pageSize || local.next != nil
        let next=hasMore ? visible.last.map {CatalogCursor(value:$0.value,id:$0.id,rawValue:$0.bytes)} : nil
        let incomplete=native.skipped + (!request.filter.boardFEN.isEmpty ? try catalog.incompleteLocalPositions(request) : 0)
        progress(incomplete>0 ? "\(incomplete.formatted()) games have incomplete position coverage." : "")
        return CatalogPage(games:games,next:next,count:native.count+local.count)
    }
}

extension DatabaseCatalog {
    func importedOverrides() throws -> [[String:Any]] {
        let db=try SQLConnection(url),q=try db.prepare("SELECT id,source_id,record,folder,deleted FROM imported_overrides")
        var result:[[String:Any]]=[]
        while try q.next(){result.append(["id":q.text(0),"source":q.text(1),"record":q.int(2),"folder":q.text(3),"deleted":q.int(4)])}
        return result
    }
    static func sortColumn(_ sort: String) -> String {
        switch sort {
        case "whiteElo":return "CAST(coalesce(white_elo,'0') AS INTEGER)"
        case "blackElo":return "CAST(coalesce(black_elo,'0') AS INTEGER)"
        case "players","event","result","moves":return sort
        case "round":return "round_sort"
        default:return "date"
        }
    }
    func sortKeys(ids: [String], sort: String) throws -> [String:CatalogCursor] {
        if ids.isEmpty {return [:]}
        let db=try SQLConnection(url)
        let q=try db.prepare("SELECT id,\(Self.sortColumn(sort)) FROM local_headers WHERE id IN (\(ids.map {_ in "?"}.joined(separator:",")))")
        try q.bind(ids.map(SQLValue.text));var result:[String:CatalogCursor]=[:]
        while try q.next(){let id=q.text(0);result[id]=CatalogCursor(value:Self.sortColumn(sort)=="date" ? String(q.double(1)) : q.text(1),id:id,rawValue:["players","event","result","round"].contains(sort) ? q.data(1) : nil)}
        return result
    }
    func previews(ids: [String]) throws -> [String:ChessStudy] {
        if ids.isEmpty {return [:]}
        let db=try SQLConnection(url)
        let q=try db.prepare("SELECT id,source_id,record,white,black,event,title,site,date,result,moves,round,folder,source_name,file_path,source_url,starter,dirty,modified,created,saved,date,white_elo,black_elo,elo_indexed FROM games WHERE id IN (\(ids.map {_ in "?"}.joined(separator:",")))")
        try q.bind(ids.map(SQLValue.text));var result:[String:ChessStudy]=[:]
        while try q.next(){let game=try Self.preview(q);result[game.id.uuidString]=game}
        return result
    }
    func prepareLocalRatings() throws {
        struct Ratings:Decodable {var whiteElo:String?;var blackElo:String?}
        while true {
            try Task.checkCancellation()
            let db=try SQLConnection(url)
            try db.exec("PRAGMA busy_timeout=100")
            let q=try db.prepare("SELECT h.id,g.payload FROM local_headers h LEFT JOIN games g ON g.id=h.id WHERE h.elo_indexed=0 LIMIT 100")
            var pending:[(String,Data?)]=[]
            while try q.next(){pending.append((q.text(0),q.isNull(1) ? nil : q.data(1)))}
            q.reset();if pending.isEmpty{return}
            do {try db.exec("BEGIN IMMEDIATE")} catch {return} // An import owns the writer; retry later.
            do {
                let update=try db.prepare("UPDATE games SET white_elo=?,black_elo=?,elo_indexed=1 WHERE id=? AND payload=?")
                let remove=try db.prepare("DELETE FROM local_headers WHERE id=? AND NOT EXISTS(SELECT 1 FROM games WHERE games.id=local_headers.id AND games.payload IS NOT NULL)")
                for (id,payload) in pending {
                    if let payload {
                        let ratings=try? JSONDecoder().decode(Ratings.self,from:payload)
                        try update.bind([.optional(ratings?.whiteElo),.optional(ratings?.blackElo),.text(id),.blob(payload)]);try update.run();update.reset()
                    }else {try remove.bind([.text(id)]);try remove.run();remove.reset()}
                }
                try db.exec("COMMIT")
            }catch{try? db.exec("ROLLBACK");throw error}
        }
    }
    func incompleteLocalPositions(_ request: CatalogRequest) throws -> Int {
        let db=try SQLConnection(url)
        var conditions=["position_state!=1"],values:[SQLValue]=[]
        if let folder=request.folder {conditions.append("folder=?");values.append(.text(folder))}
        if request.unfiled {conditions.append("folder IS NULL")}
        let q=try db.prepare("SELECT count(*) FROM local_headers WHERE "+conditions.joined(separator:" AND "));try q.bind(values)
        return try q.next() ? q.int(0) : 0
    }
}
