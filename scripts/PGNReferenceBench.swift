import Foundation

@main struct PGNReferenceBench {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let sample=try DatabaseCatalog(url:URL(fileURLWithPath:CommandLine.arguments[1]))
        let root=URL(fileURLWithPath:CommandLine.arguments[2])
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let input=root.appendingPathComponent("Sample.pgn")
        let previews=try sample.page(CatalogRequest()).games.prefix(64)
        var games:[ChessStudy]=[]
        for preview in previews {
            if let game=try? sample.load(preview.id) {games.append(game)}
        }
        let pgn=games.map(PGNService.export).joined(separator:"\n\n")+"\n\n"
        try String(repeating:pgn,count:16).write(to:input,atomically:true,encoding:.utf8)
        print("PGN corpus: \(games.count) decoded real games repeated 16 times = \(games.count*16) games")
        let library=LibraryStore(archiveURL:root.appendingPathComponent("Library.json"))
        let start=Date();guard await library.importFiles(from:[input]) else {throw CatalogError.message(library.lastError ?? "Import failed")}
        print("PGN import: \(Date().timeIntervalSince(start)) s")
        let catalog=library.catalog!
        var base=CatalogRequest();base.folder=library.lastImportedFolderID!.uuidString
        for (label,fen) in [("e4","rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"),("deep final position",games[0].root.mainLineEnd.positionFEN),("full main-line miss","4k3/8/8/8/8/8/8/4K3 w - - 0 1")] {
            var request=base;request.filter.boardFEN=fen
            let start=Date();let result=try await library.page(request)
            print("PGN \(label): \(Date().timeIntervalSince(start)) s, \(result.count) matches")
            let again=Date();_ = try await library.page(request)
            print("PGN \(label) cached page: \(Date().timeIntervalSince(again)) s")
        }
        let q=try SQLConnection(catalog.positionCacheURL).prepare("SELECT max(skipped) FROM searches WHERE complete=1")
        _ = try q.next();print("Maximum skipped PGN games: \(q.int(0))")
    }
}
private extension MoveNode {
    var mainLineEnd: MoveNode {var node=self;while let next=node.children.first {node=next};return node}
}
