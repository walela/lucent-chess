import AppKit
import Foundation
import Darwin

@main
struct TrainingChecks {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        let enginePath = "/opt/homebrew/bin/stockfish"
        guard FileManager.default.isExecutableFile(atPath: enginePath) else {
            throw Failure("Stockfish is required for the training integration checks")
        }
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("TrainingChecks-\(UUID().uuidString).json")
        let library = LibraryStore(archiveURL: archive)
        let source = library.newStudy(title: "Original study")
        let originalFEN = source.currentPosition.fen
        let originalCount = library.studies.count
        let session = TrainingSession()
        session.start(from: .starting, humanColor: .white, strength: .club, seconds: 0.1,
                      enginePath: enginePath, library: library)
        try check("training creates a separate game without changing the selected study") {
            library.selectedStudyID == source.id && session.study?.id != source.id && library.studies.count == originalCount + 1
        }
        session.play(ChessPosition.starting.legalMove(uci: "e2e4")!)
        try wait(until: { !session.isThinking }, timeout: 15)
        try check("Stockfish replies legally and returns control to the human") {
            session.canPlay && session.study?.currentPly == 2 && source.currentPosition.fen == originalFEN
        }
        let training = session.study!
        let ply = training.currentPly
        session.play(ChessMove.fromUCI("a7a6")!)
        try check("illegal or wrong-side human moves are ignored") { training.currentPly == ply }
        session.stop()
        session.start(from: .starting, humanColor: .black, strength: .full, seconds: 0.1,
                      enginePath: enginePath, library: library)
        try wait(until: { !session.isThinking }, timeout: 15)
        try check("playing Black lets Stockfish make the first move") {
            session.canPlay && session.study?.currentPly == 1 && session.study?.currentPosition.sideToMove == .black
        }
        session.start(from: .starting, humanColor: .black, strength: .full, seconds: 5,
                      enginePath: enginePath, library: library)
        let cancelled = session.study!
        session.stop()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        try check("stopping cancels the engine without appending a late move") {
            !session.isActive && !session.isThinking && cancelled.currentPly == 0
        }
        let custom = ChessPosition(fen: "r3k2r/8/8/3pP3/8/8/8/R3K2R w KQkq d6 0 20")!
        session.start(from: custom, humanColor: .white, strength: .club, seconds: 0.1,
                      enginePath: enginePath, library: library)
        try check("custom starting positions preserve castling, en passant and move numbers") {
            session.study?.root.positionFEN == custom.fen
                && session.study?.currentPosition.legalMove(uci: "e1g1") != nil
                && session.study?.currentPosition.legalMove(uci: "e5d6")?.isEnPassant == true
        }
        session.resign()
        try check("resigning records a result and ends training") {
            session.study?.result == "0-1" && !session.isActive
        }
        let mate = ChessPosition(fen: "7k/6Q1/6K1/8/8/8/8/8 b - - 0 1")!
        session.start(from: mate, humanColor: .white, strength: .club, seconds: 0.1,
                      enginePath: enginePath, library: library)
        try check("checkmate is resolved without asking the engine for a move") {
            !session.isActive && !session.isThinking && session.study?.result == "1-0"
        }
        let stalemate = ChessPosition(fen: "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1")!
        session.start(from: stalemate, humanColor: .white, strength: .club, seconds: 0.1,
                      enginePath: enginePath, library: library)
        try check("stalemate ends as a draw") { !session.isActive && session.study?.result == "1/2-1/2" }
        session.start(from: .starting, humanColor: .black, strength: .club, seconds: 0.1,
                      enginePath: "/missing/engine", library: library)
        try wait(until: { !session.isThinking }, timeout: 2)
        try check("missing engines end the session with a useful error") {
            !session.isActive && session.status.contains("installed Stockfish")
        }
        library.saveNow()
        try check("training history can be exported and imported as a separate PGN") {
            let roundtrip = try? PGNService.parse(PGNService.export(training)).first
            return roundtrip?.mainLinePlyCount == 2 && library.selectedStudyID == source.id
        }
        print("All training checks passed.")
    }
    private static func check(_ title: String, _ test: () -> Bool) throws {
        guard test() else { throw Failure(title) }
        print("✓ \(title)")
    }
    @MainActor private static func wait(until condition: () -> Bool, timeout: Double) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.04)) }
        guard condition() else { throw Failure("Engine response timed out") }
    }
    private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
