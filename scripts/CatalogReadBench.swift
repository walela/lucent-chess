import Foundation

@main struct CatalogReadBench {
    static func main() throws {
        let catalog = try DatabaseCatalog(url:URL(fileURLWithPath:CommandLine.arguments[1]))
        var request = CatalogRequest()
        var measurements: [String:Double] = [:]
        for name in ["all_games","broad_search","collection_search"] {
            if name != "all_games" { request.search = "Evaluation" }
            if name == "collection_search" { request.folder = "E312649C-8F43-44CF-A90D-A43BCD8B0AF4" }
            let start = Date();let page = try catalog.page(request);let elapsed = Date().timeIntervalSince(start)
            guard page.games.count == 200, page.count == (name == "all_games" ? 10_000_000 : 2_500_000) else { fatalError("Incorrect page or count") }
            measurements[name] = elapsed
            print("\(name): \(elapsed) seconds; \(page.count) matches, \(page.games.count) loaded metadata rows")
        }
        let data = try JSONSerialization.data(withJSONObject:measurements,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
    }
}
