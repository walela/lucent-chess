import XCTest
@testable import LucentChess

final class ChessCoreTests: XCTestCase {
    func testStartingPositionAndPerft() {
        XCTAssertEqual(ChessPosition.starting.legalMoves().count, 20)
        XCTAssertEqual(perft(.starting, depth: 3), 8_902)
    }

    func testPGNRoundTripWithVariation() throws {
        let pgn = """
        [Event "Round trip"]
        [Result "*"]

        1.e4 e5 2.Nf3 Nc6 3.Bb5 {Spanish} (3.Bc4 Nf6) 3...a6 *
        """
        let imported = try XCTUnwrap(PGNService.parse(pgn).first)
        XCTAssertEqual(try PGNService.parse(PGNService.export(imported)).count, 1)
    }

    private func perft(_ position: ChessPosition, depth: Int) -> Int {
        guard depth > 0 else { return 1 }
        return position.legalMoves().reduce(0) { $0 + perft(position.applyingUnchecked($1), depth: depth - 1) }
    }
}
