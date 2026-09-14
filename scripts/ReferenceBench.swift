import Foundation

/// Run against a disposable, indexed database, never the user's live library.
@main struct ReferenceBench {
    static func main() async throws {
        setbuf(stdout,nil)
        let catalog = try DatabaseCatalog(url:URL(fileURLWithPath:CommandLine.arguments[1]))
        var base=CatalogRequest();base.folder=CommandLine.arguments.count>2 ? CommandLine.arguments[2] : nil
        func measure(_ name:String,_ request:CatalogRequest) throws -> CatalogPage {
            let start=Date();let result=try catalog.page(request)
            print("\(name): \(String(format:"%.4f",Date().timeIntervalSince(start))) s, \(result.count) matches, \(result.games.count) rows")
            return result
        }
        let first=try measure("All first page",base)
        var next=base;next.cursor=first.next;_ = try measure("All next page",next)
        for player in ["A","Alekhine"] {
            var request=base;request.filter.player=player
            let first=try measure("Player \(player) cold",request)
            _ = try measure("Player \(player) repeat",request)
            request.cursor=first.next;_ = try measure("Player \(player) next page",request)
        }
        var combined=base;combined.filter.player="Alekhine";combined.filter.yearMin=1920;combined.filter.yearMax=1940;combined.result="whiteWin"
        _ = try measure("Combined player/year/result cold",combined)
        _ = try measure("Combined player/year/result repeat",combined)
        var elo=base;elo.filter.whiteMin=2400;elo.filter.blackMin=2400
        _ = try measure("Both Elo >=2400 cold (includes index creation)",elo)
        _ = try measure("Both Elo >=2400 repeat",elo)
        var board=base;board.filter.boardFEN="rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"
        var lastProgress=Date()
        let start=Date()
        let search=try PositionSearchService.search(catalog:catalog,request:board,progress: { message in
            // Progress is supplied by the synchronous worker.
            if message.contains("Finding") {print(message)}
        })
        print("Board e4 scan: \(Date().timeIntervalSince(start)) s, \(search.count) matches, \(search.skipped) skipped, cached=\(search.cached)")
        lastProgress=Date()
        let repeatSearch=try PositionSearchService.search(catalog:catalog,request:board,progress:{_ in})
        print("Board repeat lookup: \(Date().timeIntervalSince(lastProgress)) s, cached=\(repeatSearch.cached)")
        board.positionSearchKey=search.key
        let boardPage=try measure("Board result first page",board)
        board.cursor=boardPage.next;_ = try measure("Board result next page",board)
        board.cursor=nil;board.sort="players";_ = try measure("Board result player sort",board)
        var rare=base;rare.filter.boardFEN="4k3/8/8/8/8/8/8/4K3 w - - 0 1"
        let cancelRequest=rare
        let work=Task.detached {try PositionSearchService.search(catalog:catalog,request:cancelRequest,progress:{_ in})}
        try await Task.sleep(for:.milliseconds(100));let cancelledAt=Date();work.cancel()
        do {_ = try await work.value;throw CatalogError.message("Expected cancellation")}
        catch is CancellationError {print("Board cancellation latency: \(Date().timeIntervalSince(cancelledAt)) s")}
        if let game=first.games.first {
            let start=Date();let full=try catalog.load(game.id)
            print("Open game: \(Date().timeIntervalSince(start)) s, \(full.mainLinePlyCount) plies")
        }
    }
}
