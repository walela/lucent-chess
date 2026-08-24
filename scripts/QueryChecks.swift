import Foundation

@main
struct QueryChecks {
    static func main() throws {
        let whiteWin = game(
            title: "Game A", white: "Zukertort", black: "Anderssen", event: "London",
            result: "1-0", date: Date(timeIntervalSince1970: 100), filePath: nil, starter: nil
        )
        let draw = game(
            title: "Game B", white: "Capablanca", black: "Lasker", event: "Havana",
            result: "1/2-1/2", date: Date(timeIntervalSince1970: 300), filePath: "/tmp/game-b.pgn", starter: nil
        )
        let blackWin = game(
            title: "Game C", white: "Botvinnik", black: "Tal", event: "Moscow",
            result: "0-1", date: Date(timeIntervalSince1970: 200), filePath: nil, starter: "archive"
        )
        whiteWin.dirtyState = true
        draw.dirtyState = false
        blackWin.dirtyState = false
        whiteWin.round = "14"
        draw.round = "2"
        blackWin.round = "7"
        addMoves(2, to: whiteWin)
        addMoves(4, to: draw)
        addMoves(3, to: blackWin)
        let games = [whiteWin, draw, blackWin]

        try check("result filter selects only draws") {
            GameLibraryQuery(result: .draw).apply(to: games).map(\.id) == [draw.id]
        }
        try check("file filters distinguish PGNs, edits, and included games") {
            GameLibraryQuery(file: .savedPGN).apply(to: games).map(\.id) == [draw.id]
                && GameLibraryQuery(file: .needsSaving).apply(to: games).map(\.id) == [whiteWin.id]
                && GameLibraryQuery(file: .included).apply(to: games).map(\.id) == [blackWin.id]
                && GameLibraryQuery(file: .autosaved).apply(to: games).map(\.id) == [whiteWin.id]
        }
        try check("date sort defaults to newest first") {
            GameLibraryQuery(sort: .date, ascending: false).apply(to: games).map(\.id) == [draw.id, blackWin.id, whiteWin.id]
        }
        try check("player sort works in both directions") {
            let ascending = GameLibraryQuery(sort: .players, ascending: true).apply(to: games).map(\.id)
            let descending = GameLibraryQuery(sort: .players, ascending: false).apply(to: games).map(\.id)
            return ascending == [blackWin.id, draw.id, whiteWin.id]
                && descending == [whiteWin.id, draw.id, blackWin.id]
        }
        try check("move-count sort uses main-line length") {
            GameLibraryQuery(sort: .moves, ascending: false).apply(to: games).map(\.id) == [draw.id, blackWin.id, whiteWin.id]
        }
        try check("round sort uses natural numeric order") {
            GameLibraryQuery(sort: .round, ascending: false).apply(to: games).map(\.id) == [whiteWin.id, blackWin.id, draw.id]
        }
        print("All dashboard query checks passed.")
    }

    private static func game(
        title: String,
        white: String,
        black: String,
        event: String,
        result: String,
        date: Date,
        filePath: String?,
        starter: String?
    ) -> ChessStudy {
        let study = ChessStudy(title: title, white: white, black: black, event: event, date: date, result: result)
        study.filePath = filePath
        study.starterCollectionID = starter
        return study
    }

    private static func addMoves(_ count: Int, to study: ChessStudy) {
        let line = ["e2e4", "e7e5", "g1f3", "b8c6"]
        for uci in line.prefix(count) {
            guard let move = study.currentPosition.legalMove(uci: uci) else { continue }
            _ = study.play(move)
        }
    }

    private static func check(_ name: String, _ test: () -> Bool) throws {
        guard test() else { throw Failure(name) }
        print("✓ \(name)")
    }

    private struct Failure: LocalizedError {
        let name: String
        init(_ name: String) { self.name = name }
        var errorDescription: String? { "Check failed: \(name)" }
    }
}
