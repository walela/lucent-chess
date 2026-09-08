import AppKit
import Combine
import Foundation

enum TrainingStrength: String, CaseIterable, Identifiable {
    case beginner = "1400", casual = "1600", club = "1800", advanced = "2000"
    case expert = "2200", master = "2400", strong = "2600", full = "Full strength"
    var id: String { rawValue }
    var elo: Int? { Int(rawValue) }
}

/// One isolated UCI search. Cancellation destroys this process, so a late
/// bestmove from an abandoned position can never enter a later game.
@MainActor
final class TrainingMoveRequest {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    private var buffer = ""
    private var options: [UCIEngineOption] = []
    private var positionCommand = ""
    private var strength = TrainingStrength.club
    private var milliseconds = 1000

    func move(enginePath: String, startFEN: String, moves: [String], strength: TrainingStrength,
              seconds: Double) async throws -> String {
        try Task.checkCancellation()
        self.strength = strength
        milliseconds = max(100, min(10_000, Int(seconds * 1000)))
        positionCommand = "position fen \(startFEN)" + (moves.isEmpty ? "" : " moves \(moves.joined(separator: " "))")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard FileManager.default.isExecutableFile(atPath: enginePath) else {
                    finish(.failure(Failure("Choose an installed Stockfish engine in Analysis → Engine settings.")))
                    return
                }
                let task = Process(), stdin = Pipe(), stdout = Pipe()
                task.executableURL = URL(fileURLWithPath: enginePath)
                task.standardInput = stdin
                task.standardOutput = stdout
                task.standardError = stdout
                input = stdin.fileHandleForWriting
                output = stdout.fileHandleForReading
                output?.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    Task { @MainActor [weak self] in self?.consume(text) }
                }
                task.terminationHandler = { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.finish(.failure(Failure("The playing engine stopped before returning a move.")))
                    }
                }
                do {
                    try task.run()
                    process = task
                    send("uci")
                    timeout = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(20 + seconds))
                        guard !Task.isCancelled else { return }
                        self?.finish(.failure(Failure("Stockfish took too long to respond. Try starting the training game again.")))
                    }
                } catch { finish(.failure(error)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func consume(_ text: String) {
        guard continuation != nil else { return }
        buffer += text
        let lines = buffer.components(separatedBy: .newlines)
        buffer = lines.last ?? ""
        for line in lines.dropLast() {
            if let option = StockfishService.parseOptionLine(line) { options.append(option) }
            else if line == "uciok" {
                option("Threads", "2")
                option("Hash", "64")
                option("MultiPV", "1")
                if let elo = strength.elo {
                    guard options.contains(where: { $0.name == "UCI_Elo" }),
                          options.contains(where: { $0.name == "UCI_LimitStrength" }) else {
                        finish(.failure(Failure("This engine does not support target strength. Choose Stockfish or Full strength.")))
                        return
                    }
                    option("UCI_LimitStrength", "true")
                    option("UCI_Elo", String(elo))
                } else {
                    option("UCI_LimitStrength", "false")
                    option("Skill Level", "20")
                }
                send("ucinewgame")
                send("isready")
            } else if line == "readyok" {
                send(positionCommand)
                send("go movetime \(milliseconds)")
            } else if line.hasPrefix("bestmove ") {
                let move = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                finish(.success(move))
                return
            }
        }
    }

    private func option(_ name: String, _ value: String) {
        guard let option = options.first(where: { $0.name == name }) else { return }
        var value = value
        if let number = Int(value), let minimum = option.minimum, let maximum = option.maximum {
            value = String(min(maximum, max(minimum, number)))
        }
        send("setoption name \(name) value \(value)")
    }

    private func send(_ command: String) {
        do { try input?.write(contentsOf: Data((command + "\n").utf8)) }
        catch { finish(.failure(error)) }
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        output?.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = nil
        continuation.resume(with: result)
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

@MainActor
final class TrainingSession: ObservableObject {
    @Published private(set) var study: ChessStudy?
    @Published private(set) var status = ""
    @Published private(set) var isThinking = false
    @Published private(set) var isActive = false
    private(set) var humanColor = PieceColor.white
    private(set) var strength = TrainingStrength.club
    private var seconds = 1.0
    private var enginePath = ""
    private var turnTask: Task<Void, Never>?
    private var generation = UUID()
    private weak var library: LibraryStore?

    var canPlay: Bool { isActive && !isThinking && study?.currentPosition.sideToMove == humanColor }

    func start(from position: ChessPosition, humanColor: PieceColor, strength: TrainingStrength,
               seconds: Double, enginePath: String, library: LibraryStore) {
        stop()
        self.library = library
        self.humanColor = humanColor
        self.strength = strength
        self.seconds = seconds
        self.enginePath = enginePath
        let opponent = strength.elo.map { "Stockfish (\($0))" } ?? "Stockfish"
        let game = ChessStudy(title: "Training against \(opponent)",
                              white: humanColor == .white ? "You" : opponent,
                              black: humanColor == .black ? "You" : opponent,
                              event: "Training from position", startFEN: position.fen)
        study = game
        // Add the training game without changing the study open in the other window.
        library.studies.insert(game, at: 0)
        isActive = true
        generation = UUID()
        changed()
        advance()
    }

    func play(_ move: ChessMove) {
        guard canPlay, let study, study.play(move) != nil else { return }
        changed()
        advance()
    }

    func stop() {
        generation = UUID()
        turnTask?.cancel()
        turnTask = nil
        isThinking = false
        if isActive { status = "Training stopped · saved in your library" }
        isActive = false
        library?.saveSoon()
    }

    func resign() {
        guard isActive, let study else { return }
        stop()
        study.result = humanColor == .white ? "0-1" : "1-0"
        status = "You resigned"
        changed()
    }

    private func changed() {
        study?.modifiedAt = Date()
        study?.dirtyState = true
        study?.markChanged(notation: true)
        library?.saveSoon()
    }

    private func advance() {
        guard isActive, let study else { return }
        let position = study.currentPosition
        if position.legalMoves().isEmpty {
            if position.isKingInCheck(position.sideToMove) {
                study.result = position.sideToMove == .white ? "0-1" : "1-0"
                status = position.sideToMove == humanColor ? "Checkmate · Stockfish wins" : "Checkmate · you win"
            } else { study.result = "1/2-1/2"; status = "Draw · stalemate" }
            isActive = false
            changed()
            return
        }
        let positions = [study.root.positionFEN] + study.path().map(\.positionFEN)
        if position.halfmoveClock >= 100 || Self.insufficientMaterial(position)
            || positions.filter({ Self.repetitionKey($0) == Self.repetitionKey(position.fen) }).count >= 3 {
            study.result = "1/2-1/2"
            status = "Draw"
            isActive = false
            changed()
            return
        }
        if position.sideToMove == humanColor {
            status = position.isKingInCheck(humanColor) ? "Your turn · check" : "Your turn"
            return
        }
        isThinking = true
        status = "Stockfish is thinking…"
        let token = generation, gameID = study.id, fen = position.fen
        let startFEN = study.root.positionFEN, moves = study.path().compactMap(\.moveUCI)
        turnTask = Task { [weak self] in
            guard let self else { return }
            do {
                let request = TrainingMoveRequest()
                let uci = try await request.move(enginePath: self.enginePath, startFEN: startFEN,
                                                 moves: moves, strength: self.strength, seconds: self.seconds)
                guard !Task.isCancelled, self.generation == token, self.isActive,
                      let game = self.study, game.id == gameID, game.currentPosition.fen == fen else { return }
                self.isThinking = false
                guard let move = game.currentPosition.legalMove(uci: uci), game.play(move) != nil else {
                    self.stop()
                    self.status = "Stockfish returned an invalid move. Training stopped."
                    return
                }
                self.changed()
                self.advance()
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.stop()
                self.status = error.localizedDescription
            }
        }
    }

    private static func repetitionKey(_ fen: String) -> String {
        guard let position = ChessPosition(fen: fen) else { return fen }
        var parts = fen.split(separator: " ").prefix(4).map(String.init)
        if !position.legalMoves().contains(where: \.isEnPassant) { parts[3] = "-" }
        return parts.joined(separator: " ")
    }

    private static func insufficientMaterial(_ position: ChessPosition) -> Bool {
        let pieces = position.squares.enumerated().compactMap { index, piece -> (Int, ChessPiece)? in
            guard let piece, piece.kind != .king else { return nil }
            return (index, piece)
        }
        if pieces.isEmpty { return true }
        if pieces.count == 1 { return [.bishop, .knight].contains(pieces[0].1.kind) }
        if pieces.allSatisfy({ $0.1.kind == .bishop }) {
            return Set(pieces.map { ($0.0 / 8 + $0.0 % 8) % 2 }).count == 1
        }
        return false
    }
}
