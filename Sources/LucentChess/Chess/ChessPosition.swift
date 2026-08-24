import Foundation

struct ChessPosition: Codable, Equatable {
    static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    var squares: [ChessPiece?]
    var sideToMove: PieceColor
    var castlingRights: CastlingRights
    var enPassantSquare: Square?
    var halfmoveClock: Int
    var fullmoveNumber: Int

    init(
        squares: [ChessPiece?] = Array(repeating: nil, count: 64),
        sideToMove: PieceColor = .white,
        castlingRights: CastlingRights = [],
        enPassantSquare: Square? = nil,
        halfmoveClock: Int = 0,
        fullmoveNumber: Int = 1
    ) {
        self.squares = squares
        self.sideToMove = sideToMove
        self.castlingRights = castlingRights
        self.enPassantSquare = enPassantSquare
        self.halfmoveClock = halfmoveClock
        self.fullmoveNumber = fullmoveNumber
    }

    init?(fen: String) {
        let parts = fen.split(separator: " ")
        guard parts.count >= 4 else { return nil }
        let ranks = parts[0].split(separator: "/")
        guard ranks.count == 8 else { return nil }
        var board: [ChessPiece?] = Array(repeating: nil, count: 64)
        for (fenRank, row) in ranks.enumerated() {
            var file = 0
            for char in row {
                if let empty = char.wholeNumberValue {
                    file += empty
                    continue
                }
                guard file < 8, let piece = Self.piece(from: char) else { return nil }
                board[(7 - fenRank) * 8 + file] = piece
                file += 1
            }
            guard file == 8 else { return nil }
        }
        squares = board
        sideToMove = parts[1] == "b" ? .black : .white
        var rights: CastlingRights = []
        if parts[2].contains("K") { rights.insert(.whiteKing) }
        if parts[2].contains("Q") { rights.insert(.whiteQueen) }
        if parts[2].contains("k") { rights.insert(.blackKing) }
        if parts[2].contains("q") { rights.insert(.blackQueen) }
        castlingRights = rights
        enPassantSquare = parts[3] == "-" ? nil : Square.from(String(parts[3]))
        halfmoveClock = parts.count > 4 ? Int(parts[4]) ?? 0 : 0
        fullmoveNumber = parts.count > 5 ? Int(parts[5]) ?? 1 : 1
    }

    static var starting: ChessPosition { ChessPosition(fen: startFEN)! }

    subscript(_ square: Square) -> ChessPiece? {
        get { square.isValid ? squares[square.index] : nil }
        set { if square.isValid { squares[square.index] = newValue } }
    }

    var fen: String {
        var rows: [String] = []
        for rank in stride(from: 7, through: 0, by: -1) {
            var row = ""
            var empty = 0
            for file in 0..<8 {
                if let piece = self[Square(file: file, rank: rank)] {
                    if empty > 0 { row += String(empty); empty = 0 }
                    let char = piece.fenLetter
                    row.append(piece.color == .white ? Character(String(char).uppercased()) : char)
                } else {
                    empty += 1
                }
            }
            if empty > 0 { row += String(empty) }
            rows.append(row)
        }
        var castle = ""
        if castlingRights.contains(.whiteKing) { castle += "K" }
        if castlingRights.contains(.whiteQueen) { castle += "Q" }
        if castlingRights.contains(.blackKing) { castle += "k" }
        if castlingRights.contains(.blackQueen) { castle += "q" }
        if castle.isEmpty { castle = "-" }
        return "\(rows.joined(separator: "/")) \(sideToMove == .white ? "w" : "b") \(castle) \(enPassantSquare?.name ?? "-") \(halfmoveClock) \(fullmoveNumber)"
    }

    func legalMoves(from source: Square? = nil) -> [ChessMove] {
        pseudoLegalMoves(from: source).filter { move in
            let mover = sideToMove
            let next = applyingUnchecked(move)
            return !next.isKingInCheck(mover)
        }
    }

    func legalMove(uci: String) -> ChessMove? {
        guard let parsed = ChessMove.fromUCI(uci) else { return nil }
        return legalMoves(from: parsed.from).first { $0.to == parsed.to && ($0.promotion ?? .queen) == (parsed.promotion ?? .queen) }
    }

    func applying(_ move: ChessMove) -> ChessPosition? {
        guard let legal = legalMoves(from: move.from).first(where: {
            $0.to == move.to && ($0.promotion ?? .queen) == (move.promotion ?? .queen)
        }) else { return nil }
        return applyingUnchecked(legal)
    }

    func applyingUnchecked(_ move: ChessMove) -> ChessPosition {
        var next = self
        guard let movingPiece = self[move.from] else { return next }
        let captured = self[move.to]
        next[move.from] = nil
        next[move.to] = ChessPiece(color: movingPiece.color, kind: move.promotion ?? movingPiece.kind)

        if move.isEnPassant {
            next[Square(file: move.to.file, rank: move.from.rank)] = nil
        }
        if move.isCastle {
            let kingSide = move.to.file == 6
            let rookFrom = Square(file: kingSide ? 7 : 0, rank: move.from.rank)
            let rookTo = Square(file: kingSide ? 5 : 3, rank: move.from.rank)
            next[rookTo] = next[rookFrom]
            next[rookFrom] = nil
        }

        next.updateCastlingRights(for: move, piece: movingPiece, captured: captured)
        next.enPassantSquare = nil
        if movingPiece.kind == .pawn && abs(move.to.rank - move.from.rank) == 2 {
            next.enPassantSquare = Square(file: move.from.file, rank: (move.from.rank + move.to.rank) / 2)
        }
        next.halfmoveClock = (movingPiece.kind == .pawn || captured != nil || move.isEnPassant) ? 0 : halfmoveClock + 1
        if sideToMove == .black { next.fullmoveNumber += 1 }
        next.sideToMove = sideToMove.opposite
        return next
    }

    func san(for move: ChessMove) -> String {
        guard let piece = self[move.from] else { return move.uci }
        if move.isCastle { return suffixCheck(move.to.file == 6 ? "O-O" : "O-O-O", after: move) }
        let isCapture = self[move.to] != nil || move.isEnPassant
        var notation = piece.kind.sanLetter
        if piece.kind != .pawn {
            let competitors = legalMoves().filter {
                $0.to == move.to && $0.from != move.from && self[$0.from]?.kind == piece.kind
            }
            if !competitors.isEmpty {
                let sameFile = competitors.contains { $0.from.file == move.from.file }
                let sameRank = competitors.contains { $0.from.rank == move.from.rank }
                if !sameFile || sameRank {
                    notation += String(UnicodeScalar(97 + move.from.file)!)
                }
                if sameFile {
                    notation += String(move.from.rank + 1)
                }
            }
        } else if isCapture {
            notation += String(UnicodeScalar(97 + move.from.file)!)
        }
        if isCapture { notation += "x" }
        notation += move.to.name
        if let promotion = move.promotion { notation += "=" + promotion.sanLetter }
        return suffixCheck(notation, after: move)
    }

    func move(matchingSAN rawSAN: String) -> ChessMove? {
        let cleaned = Self.normalizedSAN(rawSAN)
        if let uci = legalMove(uci: cleaned) { return uci }
        return legalMoves().first { Self.normalizedSAN(san(for: $0)) == cleaned }
    }

    func isKingInCheck(_ color: PieceColor) -> Bool {
        guard let kingIndex = squares.indices.first(where: { squares[$0] == ChessPiece(color: color, kind: .king) }) else { return true }
        return isSquareAttacked(Square(kingIndex), by: color.opposite)
    }

    func isSquareAttacked(_ square: Square, by color: PieceColor) -> Bool {
        let pawnSourceRank = square.rank - color.pawnDirection
        for df in [-1, 1] {
            let source = Square(file: square.file + df, rank: pawnSourceRank)
            if source.isValid, self[source] == ChessPiece(color: color, kind: .pawn) { return true }
        }
        for (df, dr) in [(1,2),(2,1),(2,-1),(1,-2),(-1,-2),(-2,-1),(-2,1),(-1,2)] {
            let source = Square(file: square.file + df, rank: square.rank + dr)
            if source.isValid, self[source] == ChessPiece(color: color, kind: .knight) { return true }
        }
        for (directions, kinds) in [
            ([(1,0),(-1,0),(0,1),(0,-1)], [PieceKind.rook, .queen]),
            ([(1,1),(1,-1),(-1,1),(-1,-1)], [PieceKind.bishop, .queen])
        ] {
            for (df, dr) in directions {
                var f = square.file + df, r = square.rank + dr
                while (0..<8).contains(f), (0..<8).contains(r) {
                    let source = Square(file: f, rank: r)
                    if let piece = self[source] {
                        if piece.color == color && kinds.contains(piece.kind) { return true }
                        break
                    }
                    f += df; r += dr
                }
            }
        }
        for df in -1...1 { for dr in -1...1 where df != 0 || dr != 0 {
            let source = Square(file: square.file + df, rank: square.rank + dr)
            if source.isValid, self[source] == ChessPiece(color: color, kind: .king) { return true }
        }}
        return false
    }

    private func pseudoLegalMoves(from source: Square?) -> [ChessMove] {
        var moves: [ChessMove] = []
        let sources = source.map { [$0] } ?? squares.indices.map(Square.init)
        for from in sources {
            guard let piece = self[from], piece.color == sideToMove else { continue }
            switch piece.kind {
            case .pawn: appendPawnMoves(from: from, piece: piece, to: &moves)
            case .knight: appendLeaperMoves(from: from, offsets: [(1,2),(2,1),(2,-1),(1,-2),(-1,-2),(-2,-1),(-2,1),(-1,2)], to: &moves)
            case .bishop: appendSlidingMoves(from: from, directions: [(1,1),(1,-1),(-1,1),(-1,-1)], to: &moves)
            case .rook: appendSlidingMoves(from: from, directions: [(1,0),(-1,0),(0,1),(0,-1)], to: &moves)
            case .queen: appendSlidingMoves(from: from, directions: [(1,0),(-1,0),(0,1),(0,-1),(1,1),(1,-1),(-1,1),(-1,-1)], to: &moves)
            case .king:
                appendLeaperMoves(from: from, offsets: [(1,0),(-1,0),(0,1),(0,-1),(1,1),(1,-1),(-1,1),(-1,-1)], to: &moves)
                appendCastles(from: from, color: piece.color, to: &moves)
            }
        }
        return moves
    }

    private func appendPawnMoves(from: Square, piece: ChessPiece, to moves: inout [ChessMove]) {
        let one = Square(file: from.file, rank: from.rank + piece.color.pawnDirection)
        if one.isValid, self[one] == nil {
            appendPawnMove(from: from, to: one, into: &moves)
            let two = Square(file: from.file, rank: from.rank + piece.color.pawnDirection * 2)
            if from.rank == piece.color.pawnStartRank, self[two] == nil { moves.append(ChessMove(from: from, to: two)) }
        }
        for df in [-1, 1] {
            let target = Square(file: from.file + df, rank: from.rank + piece.color.pawnDirection)
            guard target.isValid else { continue }
            if let victim = self[target], victim.color != piece.color {
                appendPawnMove(from: from, to: target, into: &moves)
            } else if target == enPassantSquare {
                moves.append(ChessMove(from: from, to: target, isEnPassant: true))
            }
        }
    }

    private func appendPawnMove(from: Square, to: Square, into moves: inout [ChessMove]) {
        if to.rank == sideToMove.promotionRank {
            for kind in [PieceKind.queen, .rook, .bishop, .knight] { moves.append(ChessMove(from: from, to: to, promotion: kind)) }
        } else { moves.append(ChessMove(from: from, to: to)) }
    }

    private func appendLeaperMoves(from: Square, offsets: [(Int, Int)], to moves: inout [ChessMove]) {
        for (df, dr) in offsets {
            let target = Square(file: from.file + df, rank: from.rank + dr)
            guard target.isValid else { continue }
            if self[target]?.color != sideToMove { moves.append(ChessMove(from: from, to: target)) }
        }
    }

    private func appendSlidingMoves(from: Square, directions: [(Int, Int)], to moves: inout [ChessMove]) {
        for (df, dr) in directions {
            var f = from.file + df, r = from.rank + dr
            while (0..<8).contains(f), (0..<8).contains(r) {
                let target = Square(file: f, rank: r)
                if let occupant = self[target] {
                    if occupant.color != sideToMove { moves.append(ChessMove(from: from, to: target)) }
                    break
                }
                moves.append(ChessMove(from: from, to: target))
                f += df; r += dr
            }
        }
    }

    private func appendCastles(from: Square, color: PieceColor, to moves: inout [ChessMove]) {
        guard from == Square(file: 4, rank: color.homeRank), !isKingInCheck(color) else { return }
        let kingRight: CastlingRights = color == .white ? .whiteKing : .blackKing
        let queenRight: CastlingRights = color == .white ? .whiteQueen : .blackQueen
        if castlingRights.contains(kingRight),
           self[Square(file: 5, rank: color.homeRank)] == nil,
           self[Square(file: 6, rank: color.homeRank)] == nil,
           self[Square(file: 7, rank: color.homeRank)] == ChessPiece(color: color, kind: .rook),
           !isSquareAttacked(Square(file: 5, rank: color.homeRank), by: color.opposite),
           !isSquareAttacked(Square(file: 6, rank: color.homeRank), by: color.opposite) {
            moves.append(ChessMove(from: from, to: Square(file: 6, rank: color.homeRank), isCastle: true))
        }
        if castlingRights.contains(queenRight),
           self[Square(file: 1, rank: color.homeRank)] == nil,
           self[Square(file: 2, rank: color.homeRank)] == nil,
           self[Square(file: 3, rank: color.homeRank)] == nil,
           self[Square(file: 0, rank: color.homeRank)] == ChessPiece(color: color, kind: .rook),
           !isSquareAttacked(Square(file: 3, rank: color.homeRank), by: color.opposite),
           !isSquareAttacked(Square(file: 2, rank: color.homeRank), by: color.opposite) {
            moves.append(ChessMove(from: from, to: Square(file: 2, rank: color.homeRank), isCastle: true))
        }
    }

    private mutating func updateCastlingRights(for move: ChessMove, piece: ChessPiece, captured: ChessPiece?) {
        if piece.kind == .king {
            if piece.color == .white { castlingRights.subtract([.whiteKing, .whiteQueen]) }
            else { castlingRights.subtract([.blackKing, .blackQueen]) }
        }
        if piece.kind == .rook { removeRookRight(at: move.from) }
        if captured?.kind == .rook { removeRookRight(at: move.to) }
    }

    private mutating func removeRookRight(at square: Square) {
        switch square.name {
        case "a1": castlingRights.remove(.whiteQueen)
        case "h1": castlingRights.remove(.whiteKing)
        case "a8": castlingRights.remove(.blackQueen)
        case "h8": castlingRights.remove(.blackKing)
        default: break
        }
    }

    private func suffixCheck(_ notation: String, after move: ChessMove) -> String {
        let next = applyingUnchecked(move)
        guard next.isKingInCheck(next.sideToMove) else { return notation }
        return notation + (next.legalMoves().isEmpty ? "#" : "+")
    }

    private static func piece(from character: Character) -> ChessPiece? {
        let lower = Character(String(character).lowercased())
        let kind: PieceKind
        switch lower {
        case "p": kind = .pawn
        case "n": kind = .knight
        case "b": kind = .bishop
        case "r": kind = .rook
        case "q": kind = .queen
        case "k": kind = .king
        default: return nil
        }
        return ChessPiece(color: character.isUppercase ? .white : .black, kind: kind)
    }

    private static func normalizedSAN(_ san: String) -> String {
        san.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "0-0-0", with: "O-O-O")
            .replacingOccurrences(of: "0-0", with: "O-O")
            .replacingOccurrences(of: "e.p.", with: "")
            .replacingOccurrences(of: #"[+#!?]+$"#, with: "", options: .regularExpression)
    }
}

private extension ChessPiece {
    var fenLetter: Character { kind.fenLetter }
}
