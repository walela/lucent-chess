import Foundation

enum PieceColor: String, Codable, CaseIterable {
    case white, black

    var opposite: PieceColor { self == .white ? .black : .white }
    var pawnDirection: Int { self == .white ? 1 : -1 }
    var homeRank: Int { self == .white ? 0 : 7 }
    var pawnStartRank: Int { self == .white ? 1 : 6 }
    var promotionRank: Int { self == .white ? 7 : 0 }
}

enum PieceKind: String, Codable, CaseIterable {
    case pawn, knight, bishop, rook, queen, king

    var sanLetter: String {
        switch self {
        case .pawn: return ""
        case .knight: return "N"
        case .bishop: return "B"
        case .rook: return "R"
        case .queen: return "Q"
        case .king: return "K"
        }
    }

    var fenLetter: Character {
        switch self {
        case .pawn: return "p"
        case .knight: return "n"
        case .bishop: return "b"
        case .rook: return "r"
        case .queen: return "q"
        case .king: return "k"
        }
    }
}

struct ChessPiece: Codable, Equatable, Hashable {
    var color: PieceColor
    var kind: PieceKind

    var unicode: String {
        switch (color, kind) {
        case (.white, .king): return "♔"
        case (.white, .queen): return "♕"
        case (.white, .rook): return "♖"
        case (.white, .bishop): return "♗"
        case (.white, .knight): return "♘"
        case (.white, .pawn): return "♙"
        case (.black, .king): return "♚"
        case (.black, .queen): return "♛"
        case (.black, .rook): return "♜"
        case (.black, .bishop): return "♝"
        case (.black, .knight): return "♞"
        case (.black, .pawn): return "♟"
        }
    }
}

struct Square: Codable, Equatable, Hashable, Comparable, CustomStringConvertible {
    let index: Int

    init(_ index: Int) { self.index = index }
    init(file: Int, rank: Int) {
        self.index = (0..<8).contains(file) && (0..<8).contains(rank) ? rank * 8 + file : -1
    }

    var file: Int { index % 8 }
    var rank: Int { index / 8 }
    var isValid: Bool { (0..<64).contains(index) && (0..<8).contains(file) && (0..<8).contains(rank) }
    var name: String {
        guard isValid else { return "--" }
        return String(UnicodeScalar(97 + file)!) + String(rank + 1)
    }
    var description: String { name }

    static func < (lhs: Square, rhs: Square) -> Bool { lhs.index < rhs.index }

    static func from(_ algebraic: String) -> Square? {
        let chars = Array(algebraic.lowercased())
        guard chars.count == 2,
              let fileASCII = chars[0].asciiValue,
              let rank = Int(String(chars[1])),
              (97...104).contains(fileASCII), (1...8).contains(rank) else { return nil }
        return Square(file: Int(fileASCII - 97), rank: rank - 1)
    }
}

struct ChessMove: Codable, Equatable, Hashable, Identifiable {
    var from: Square
    var to: Square
    var promotion: PieceKind?
    var isEnPassant = false
    var isCastle = false

    var id: String { uci }
    var uci: String {
        var result = from.name + to.name
        if let promotion { result.append(promotion.fenLetter) }
        return result
    }

    static func fromUCI(_ text: String) -> ChessMove? {
        guard text.count >= 4 else { return nil }
        let chars = Array(text.lowercased())
        guard let from = Square.from(String(chars[0...1])),
              let to = Square.from(String(chars[2...3])) else { return nil }
        var promotion: PieceKind?
        if chars.count > 4 {
            promotion = ["q": PieceKind.queen, "r": .rook, "b": .bishop, "n": .knight][String(chars[4])]
        }
        return ChessMove(from: from, to: to, promotion: promotion)
    }
}

struct CastlingRights: OptionSet, Codable, Hashable {
    let rawValue: Int
    static let whiteKing = CastlingRights(rawValue: 1 << 0)
    static let whiteQueen = CastlingRights(rawValue: 1 << 1)
    static let blackKing = CastlingRights(rawValue: 1 << 2)
    static let blackQueen = CastlingRights(rawValue: 1 << 3)
    static let all: CastlingRights = [.whiteKing, .whiteQueen, .blackKing, .blackQueen]
}

extension Character {
    fileprivate var asciiValue: UInt8? { String(self).utf8.first }
}
