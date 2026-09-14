import Foundation

/// Explicit preparation plus end-to-end service measurements. Unlike the old
/// scan benchmark this never creates large query-time SQLite sorting indexes.
@main struct InteractiveBench {
    static func main() async throws {
        setbuf(stdout,nil)
        guard CommandLine.arguments.count>=3,CommandLine.arguments[1]=="--prepare" else {
            print("Usage: InteractiveBench --prepare <catalog.sqlite> [--adopt-positions <completed-directory>]")
            return
        }
        let catalog=try DatabaseCatalog(url:URL(fileURLWithPath:CommandLine.arguments[2]))
        if CommandLine.arguments.count==5,CommandLine.arguments[3]=="--adopt-positions" {
            let staging=URL(fileURLWithPath:CommandLine.arguments[4])
            let stamp=try String(contentsOf:staging.appendingPathComponent("source.txt"),encoding:.utf8)
            let source=try InteractiveCatalogService.state(catalog).sources.first {stamp.components(separatedBy:"\n").dropFirst().first == $0.path}
            guard let source else {throw CatalogError.message("The completed index does not belong to this library.")}
            let destination=InteractiveCatalogService.root(catalog).appendingPathComponent("Positions/"+source.id)
            guard !FileManager.default.fileExists(atPath:destination.path) else {throw CatalogError.message("Refusing to replace an existing prepared index.")}
            try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
            try FileManager.default.moveItem(at:staging,to:destination)
            try InteractiveCatalogService.sourceIdentity(source).write(to:destination.appendingPathComponent("identity.txt"),atomically:true,encoding:.utf8)
            print("Adopted validated position preparation for \(source.name)")
        }
        var board=CatalogRequest();board.filter.boardFEN=ChessPosition.startFEN
        let before=Date()
        _ = try InteractiveCatalogService.page(catalog:catalog,request:board,progress:{print($0)})
        print("Preparation including existing-index integrity checks: \(Date().timeIntervalSince(before)) seconds")
        var requests:[(String,CatalogRequest)]=[]
        for sort in ["date","players","whiteElo","blackElo","event","result","moves","round"] {var request=CatalogRequest();request.sort=sort;requests.append((sort,request))}
        var elo=CatalogRequest();elo.filter.whiteMin=2400;elo.filter.blackMin=2400;requests.append(("both Elo >=2400",elo))
        var prefix=CatalogRequest();prefix.search="A";requests.append(("name prefix A",prefix))
        requests.append(("starting board",board))
        board.filter.boardFEN="rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b - - 0 1";requests.append(("1.e4",board))
        var report:[[String:Any]]=[]
        for repeatIndex in 0..<3 {
            for (label,request) in requests {
                let start=Date();let page=try InteractiveCatalogService.page(catalog:catalog,request:request)
                let milliseconds=Date().timeIntervalSince(start)*1000
                print("\(label): \(String(format:"%.2f",milliseconds)) ms; \(page.count) games; \(page.games.count) visible")
                report.append(["query":label,"repeat":repeatIndex,"milliseconds":milliseconds,"count":page.count,"rows":page.games.count])
            }
        }
        if let option=CommandLine.arguments.firstIndex(of:"--corpus"),option+1<CommandLine.arguments.count {
            let corpus=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[option+1]))) as! [[String:Any]]
            for (index,position) in corpus.prefix(64).enumerated() {
                var request=CatalogRequest();request.filter.boardFEN=position["fen"] as! String
                let start=Date();let page=try InteractiveCatalogService.page(catalog:catalog,request:request)
                let milliseconds=Date().timeIntervalSince(start)*1000
                guard page.count>0 else {throw CatalogError.message("A corpus position lost its originating game.")}
                print("Unseen board \(index): \(String(format:"%.2f",milliseconds)) ms; \(page.count) games")
                report.append(["query":"unseen board","repeat":index,"milliseconds":milliseconds,"count":page.count,"rows":page.games.count])
            }
        }
        let output=FileManager.default.temporaryDirectory.appendingPathComponent("lucent-interactive-service-bench.json")
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print(output.path)
    }
}
