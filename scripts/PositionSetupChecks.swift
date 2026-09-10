import AppKit
import Foundation

@main
struct PositionSetupChecks {
    @MainActor static func main() throws {
        try check("starting position is accepted") {
            try PositionSetup.parseFEN(ChessPosition.startFEN) == .starting
        }
        let whiteFEN = "r3k2r/8/8/3pP3/8/8/8/R3K2R w KQkq d6 0 20"
        let blackFEN = "r3k2r/8/8/8/3Pp3/8/8/R3K2R b KQkq d3 0 20"
        let position = try PositionSetup.parseFEN(blackFEN)
        try check("both sides preserve en passant, castling, and move counters") {
            let white = try PositionSetup.parseFEN(whiteFEN)
            return white.legalMove(uci: "e5d6")?.isEnPassant == true
                && position.legalMove(uci: "e4d3")?.isEnPassant == true
                && position.legalMove(uci: "e8g8")?.isCastle == true
                && position.fullmoveNumber == 20 && position.fen == blackFEN
        }
        let invalid = [
            "8/8/8/8/8/8/8/8 w - - 0 1",
            "7k/8/8/8/8/8/8/K5KK w - - 0 1",
            "8/8/8/8/8/8/4k3/4K3 w - - 0 1",
            "7k/8/8/8/8/8/8/K6P w - - 0 1",
            "7k/8/8/8/8/8/8/K6R w - - 0 1",
            "7k/8/8/8/8/8/8/K7 w K - 0 1",
            "7k/8/8/8/8/8/8/K7 w - d6 0 1",
            "7k/8/8/8/8/8/8/K7 x - - 0 1",
            "7k/8/8/8/8/8/8/K7 w z - 0 1",
            "7k/8/8/8/8/8/8/K7 w - zz 0 1",
            "7k/8/8/8/8/8/8/K7 w - - -1 1",
            "7k/8/8/8/8/8/8/K7 w - - 0 0",
            "7k/8/8/8/8/8/8/K7 w - - 0 99999999999999999999999",
            "7k/8/8/8/8/8/8/K07 w - - 0 1",
            "7k/8/8/8/8/8/8/K7 w - - 0 1 extra",
            "7k/8/8/8/8/8/8/K7 w - -",
            whiteFEN.replacingOccurrences(of: "0 20", with: "1 20")
        ]
        for fen in invalid {
            try check("rejects invalid setup: \(fen)") { (try? PositionSetup.parseFEN(fen)) == nil }
        }
        try check("checkmate and stalemate remain valid study positions") {
            try PositionSetup.parseFEN("7k/6Q1/6K1/8/8/8/8/8 b - - 0 1").legalMoves().isEmpty
                && PositionSetup.parseFEN("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1").legalMoves().isEmpty
        }
        var setup = PositionSetup(position: .starting)
        setup.place(nil, on: Square.from("h1")!)
        try check("erasing a rook removes only its castling right") {
            setup.position.castlingRights == [.whiteQueen, .blackKing, .blackQueen]
        }
        setup.place(ChessPiece(color: .white, kind: .rook), on: Square.from("h1")!)
        try check("replacing a rook does not silently grant castling") {
            !setup.position.castlingRights.contains(.whiteKing) && setup.availableCastlingRights == .all
        }
        setup.place(ChessPiece(color: .white, kind: .rook), on: Square.from("h1")!)
        try check("clicking the selected piece again removes it") { setup.position[Square.from("h1")!] == nil }
        setup = PositionSetup(position: position)
        setup.place(nil, on: Square.from("a8")!)
        try check("board edits clear stale en passant state") { setup.position.enPassantSquare == nil }

        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("PositionSetupChecks-\(UUID()).json")
        let library = LibraryStore(archiveURL: archive)
        let source = library.newStudy(title: "Original study")
        _ = source.play(source.currentPosition.legalMove(uci: "e2e4")!)
        let sourceFEN = source.currentPosition.fen
        let count = library.studies.count
        let custom = library.newStudy(title: "Custom position", startFEN: position.fen)
        try check("custom game is selected without changing the original study") {
            library.selectedStudyID == custom.id && library.studies.count == count + 1
                && source.currentPosition.fen == sourceFEN && source.root.children.count == 1
                && custom.root.positionFEN == blackFEN
        }
        _ = custom.play(custom.currentPosition.legalMove(uci: "e4d3")!)
        let pgn = PGNService.export(custom)
        try check("PGN preserves custom FEN and Black's first move number") {
            let restored = try PGNService.parse(pgn)[0]
            return pgn.contains("[SetUp \"1\"]") && pgn.contains("20...")
                && restored.root.positionFEN == blackFEN
                && restored.root.children.first?.positionFEN == custom.root.children.first?.positionFEN
        }
        library.saveNow()
        let restored = LibraryStore(archiveURL: archive)
        try check("custom position and moves survive library reload") {
            restored.selectedStudy?.root.positionFEN == blackFEN
                && restored.selectedStudy?.root.children.first?.moveUCI == "e4d3"
        }
        print("All position setup checks passed.")
    }

    private static func check(_ name: String, _ test: () throws -> Bool) throws {
        guard try test() else { throw PositionSetup.SetupError(name) }
        print("✓ \(name)")
    }
}
