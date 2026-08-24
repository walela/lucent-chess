import Foundation

@main
struct CoreChecks {
    static func main() throws {
        try check("starting position has 20 legal moves") {
            ChessPosition.starting.legalMoves().count == 20
        }

        try check("perft depth 3 is 8,902") {
            perft(ChessPosition.starting, depth: 3) == 8_902
        }

        var scholar = ChessPosition.starting
        for uci in ["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6"] {
            guard let move = scholar.legalMove(uci: uci) else { throw Failure("legal move \(uci) was rejected") }
            scholar = scholar.applyingUnchecked(move)
        }
        guard let mate = scholar.legalMove(uci: "h5f7") else { throw Failure("mate move was rejected") }
        try check("SAN recognizes checkmate") { scholar.san(for: mate) == "Qxf7#" }

        let castlePosition = ChessPosition(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")!
        try check("both white castles are legal") {
            let moves = Set(castlePosition.legalMoves(from: Square.from("e1")!).map(\.uci))
            return moves.contains("e1g1") && moves.contains("e1c1")
        }

        let enPassant = ChessPosition(fen: "8/8/8/3pP3/8/8/8/K6k w - d6 0 1")!
        try check("en passant is generated") {
            enPassant.legalMove(uci: "e5d6")?.isEnPassant == true
        }

        let pgn = """
        [Event "Ruy Lopez notes"]
        [Site "Offline Mac"]
        [Date "2026.08.23"]
        [Round "7"]
        [White "Reader"]
        [Black "Book"]
        [Result "*"]
        [WhiteElo "2100"]
        [BlackElo "2200"]
        [ECO "C60"]

        {A complete game stored locally.} 1.e4 e5 2.Nf3 Nc6 3.Bb5 {The Spanish opening.} (3.Bc4 Nf6) 3...a6 *
        """
        let studies = try PGNService.parse(pgn)
        let study = studies[0]
        try check("PGN main line and variation survive import") {
            guard let nc6 = study.root.children.first?.children.first?.children.first?.children.first,
                  nc6.children.count == 2 else { return false }
            return Set(nc6.children.compactMap(\.moveSAN)) == Set(["Bb5", "Bc4"])
        }
        let exported = PGNService.export(study)
        try check("exported PGN can be imported") { (try? PGNService.parse(exported).count) == 1 }
        try check("PGN metadata and initial comments survive roundtrip") {
            guard let roundtrip = try? PGNService.parse(exported).first else { return false }
            return roundtrip.site == "Offline Mac"
                && roundtrip.round == "7"
                && roundtrip.whiteElo == "2100"
                && roundtrip.blackElo == "2200"
                && roundtrip.eco == "C60"
                && roundtrip.root.comment == "A complete game stored locally."
        }

        print("All Lucent Chess core checks passed.")
    }

    private static func perft(_ position: ChessPosition, depth: Int) -> Int {
        if depth == 0 { return 1 }
        return position.legalMoves().reduce(0) { $0 + perft(position.applyingUnchecked($1), depth: depth - 1) }
    }

    private static func check(_ name: String, _ test: () throws -> Bool) throws {
        guard try test() else { throw Failure(name) }
        print("✓ \(name)")
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
