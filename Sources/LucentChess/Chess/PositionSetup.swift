import Foundation

/// Editable positions may be incomplete; only validated positions reach a game or engine.
struct PositionSetup {
    var position: ChessPosition

    mutating func place(_ piece: ChessPiece?, on square: Square) {
        position[square] = position[square] == piece ? nil : piece
        position.castlingRights.formIntersection(availableCastlingRights)
        position.enPassantSquare = nil
        position.halfmoveClock = 0
    }

    var availableCastlingRights: CastlingRights {
        var rights: CastlingRights = []
        for color in PieceColor.allCases {
            let rank = color.homeRank
            guard position[Square(file: 4, rank: rank)] == ChessPiece(color: color, kind: .king) else { continue }
            if position[Square(file: 7, rank: rank)] == ChessPiece(color: color, kind: .rook) {
                rights.insert(color == .white ? .whiteKing : .blackKing)
            }
            if position[Square(file: 0, rank: rank)] == ChessPiece(color: color, kind: .rook) {
                rights.insert(color == .white ? .whiteQueen : .blackQueen)
            }
        }
        return rights
    }

    var validationError: String? {
        for color in PieceColor.allCases {
            let pieces = position.squares.compactMap { $0 }.filter { $0.color == color }
            guard pieces.filter({ $0.kind == .king }).count == 1 else {
                return "Place exactly one \(color.rawValue) king."
            }
            guard pieces.filter({ $0.kind == .pawn }).count <= 8, pieces.count <= 16 else {
                return "\(color.rawValue.capitalized) can have at most 8 pawns and 16 pieces."
            }
        }
        for rank in [0, 7] {
            if (0..<8).contains(where: { position[Square(file: $0, rank: rank)]?.kind == .pawn }) {
                return "Pawns cannot be on the first or eighth rank."
            }
        }
        if position.isKingInCheck(position.sideToMove.opposite) {
            return "The side that just moved cannot be in check. Check the kings and side to move."
        }
        if !position.castlingRights.subtracting(availableCastlingRights).isEmpty {
            return "Castling requires the king and rook on their starting squares."
        }
        guard (0...999_999).contains(position.halfmoveClock), (1...999_999).contains(position.fullmoveNumber) else {
            return "Move number must be 1–999999 and halfmove clock 0–999999."
        }
        if let target = position.enPassantSquare {
            let mover = position.sideToMove.opposite
            let pawn = Square(file: target.file, rank: target.rank + mover.pawnDirection)
            let origin = Square(file: target.file, rank: target.rank - mover.pawnDirection)
            guard target.rank == (position.sideToMove == .white ? 5 : 2),
                  position[target] == nil, position[origin] == nil,
                  position[pawn] == ChessPiece(color: mover, kind: .pawn), position.halfmoveClock == 0 else {
                return "En passant needs a pawn that just advanced two squares and a halfmove clock of 0."
            }
        }
        return nil
    }

    /// Keep strict setup input separate from the tolerant legacy PGN reader.
    static func parseFEN(_ text: String) throws -> ChessPosition {
        let fields = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count == 6, ["w", "b"].contains(fields[1]),
              fields[2] == "-" || (!fields[2].isEmpty && fields[2].allSatisfy({ "KQkq".contains($0) })
                && Set(fields[2]).count == fields[2].count),
              fields[3] == "-" || Square.from(fields[3])?.name == fields[3],
              !fields[4].isEmpty, fields[4].allSatisfy({ "0123456789".contains($0) }),
              !fields[5].isEmpty, fields[5].allSatisfy({ "0123456789".contains($0) }),
              Int(fields[4]) != nil, Int(fields[5]) != nil else {
            throw SetupError("Enter a complete FEN: board, side to move, castling, en passant, halfmove clock, and move number.")
        }
        let ranks = fields[0].split(separator: "/", omittingEmptySubsequences: false)
        guard ranks.count == 8, ranks.allSatisfy({ row in
            !row.isEmpty && row.allSatisfy { "12345678prnbqkPRNBQK".contains($0) }
        }), let position = ChessPosition(fen: fields.joined(separator: " ")) else {
            throw SetupError("The FEN board must have eight ranks of eight squares.")
        }
        if let error = PositionSetup(position: position).validationError { throw SetupError(error) }
        return position
    }

    struct SetupError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
