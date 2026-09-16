import CryptoKit
import Foundation

/// A piece that can stand on a search-mask square. Besides the twelve men,
/// database search masks offer "jokers" (any white man, any black man) and,
/// for the Exclude board, an empty-square marker.
enum MaskPiece: String, Codable, Hashable, CaseIterable, Sendable {
    case whiteKing = "K", whiteQueen = "Q", whiteRook = "R", whiteBishop = "B", whiteKnight = "N", whitePawn = "P"
    case blackKing = "k", blackQueen = "q", blackRook = "r", blackBishop = "b", blackKnight = "n", blackPawn = "p"
    case anyWhite = "A", anyBlack = "a", empty = "_"

    init(_ piece: ChessPiece) {
        let letter = piece.kind.fenLetter
        self = MaskPiece(rawValue: piece.color == .white ? String(letter).uppercased() : String(letter))!
    }

    var piece: ChessPiece? {
        switch self {
        case .anyWhite, .anyBlack, .empty: return nil
        default:
            let color: PieceColor = rawValue == rawValue.uppercased() ? .white : .black
            let kind = PieceKind.allCases.first { String($0.fenLetter) == rawValue.lowercased() }!
            return ChessPiece(color: color, kind: kind)
        }
    }

    var color: PieceColor? {
        switch self {
        case .anyWhite: return .white
        case .anyBlack: return .black
        case .empty: return nil
        default: return piece?.color
        }
    }

    var oppositeColor: MaskPiece {
        switch self {
        case .anyWhite: return .anyBlack
        case .anyBlack: return .anyWhite
        case .empty: return .empty
        default: let p = piece!; return MaskPiece(ChessPiece(color: p.color.opposite, kind: p.kind))
        }
    }

    /// Whether the occupant of a square (nil for empty) satisfies this marker.
    func accepts(_ occupant: ChessPiece?) -> Bool {
        switch self {
        case .anyWhite: return occupant?.color == .white
        case .anyBlack: return occupant?.color == .black
        case .empty: return occupant == nil
        default: return occupant == piece
        }
    }

    var label: String {
        switch self {
        case .anyWhite: return "Any white man"
        case .anyBlack: return "Any black man"
        case .empty: return "Empty square"
        default: let p = piece!; return "\(p.color.rawValue.capitalized) \(p.kind.rawValue)"
        }
    }

    /// Short notation such as "wB", "bN", "w*", "b*", "–".
    var abbreviation: String {
        switch self {
        case .anyWhite: return "w*"
        case .anyBlack: return "b*"
        case .empty: return "–"
        default: let p = piece!; return (p.color == .white ? "w" : "b") + (p.kind == .pawn ? "P" : p.kind.sanLetter)
        }
    }
}

/// A positional fragment search in the style of database search masks.
/// Squares are indexed a1 = 0 … h8 = 63 (rank * 8 + file), as in `Square`.
///
/// - `lookFor`: every placement must hold.
/// - `either`: at least one placement must hold (the "Or" board), when non-empty.
/// - `exclude`: none of these placements may hold; several pieces per square.
/// - Mirroring searches the reflected fragment too. Horizontal mirroring swaps
///   ranks and colours (a sacrifice on h7 also finds one on h2), vertical
///   mirroring swaps the a and h wings.
/// - `firstMove`/`lastMove` bound the moves in which the fragment may occur;
///   `length` is the number of consecutive plies it must persist.
struct PositionSearchMask: Codable, Hashable, Sendable {
    var lookFor: [Int: MaskPiece] = [:]
    var either: [Int: Set<MaskPiece>] = [:]
    var exclude: [Int: Set<MaskPiece>] = [:]
    var mirrorHorizontal = false
    var mirrorVertical = false
    var sideToMove: PieceColor? = nil
    var firstMove: Int? = nil
    var lastMove: Int? = nil
    var length = 1
    /// Treat every square without a Look-for piece as required to be empty.
    var exactBoard = false

    var isEmpty: Bool { lookFor.isEmpty && either.isEmpty && (exclude.isEmpty || exactBoard) }

    /// A streak of two or more plies has both sides on move, so the side
    /// constraint only applies to single-ply fragments.
    var effectiveSide: PieceColor? { length > 1 ? nil : sideToMove }

    var pieceCount: Int { lookFor.count + either.values.reduce(0) { $0 + $1.count } + exclude.values.reduce(0) { $0 + $1.count } }

    func validate() throws {
        if lookFor.isEmpty && either.isEmpty { throw CatalogError.message("Place at least one piece on the search board.") }
        for (square, piece) in lookFor {
            let excluded = exclude[square] ?? []
            let joker: MaskPiece? = piece.color == .white ? .anyWhite : piece.color == .black ? .anyBlack : nil
            if excluded.contains(piece) || joker.map(excluded.contains) == true {
                throw CatalogError.message("\(Square(square).name) both requires and excludes \(piece.label.lowercased()).")
            }
        }
        for value in [firstMove, lastMove].compactMap({ $0 }) where value < 1 || value > 9999 { throw CatalogError.message("Move limits must be between 1 and 9999.") }
        if let firstMove, let lastMove, firstMove > lastMove { throw CatalogError.message("The last move must not precede the first move.") }
        if length < 1 || length > 999 { throw CatalogError.message("Length must be between 1 and 999 plies.") }
        if exactBoard {
            let kings = lookFor.values.filter { $0 == .whiteKing || $0 == .blackKing }
            if kings.count != 2 { throw CatalogError.message("An exact position needs one king of each colour.") }
        }
    }

    /// When the mask describes one complete position, the exact position index
    /// answers it directly. Otherwise every game in scope is scanned.
    var exactFEN: String? {
        guard exactBoard, !mirrorHorizontal, !mirrorVertical, firstMove == nil, lastMove == nil, length == 1,
              either.isEmpty, let side = sideToMove, lookFor.values.allSatisfy({ $0.piece != nil }),
              lookFor.values.filter({ $0 == .whiteKing }).count == 1, lookFor.values.filter({ $0 == .blackKing }).count == 1 else { return nil }
        var position = ChessPosition()
        for (square, piece) in lookFor { position[Square(square)] = piece.piece }
        position.sideToMove = side
        return (try? CatalogFilter.boardKey(position.fen)) != nil ? position.fen : nil
    }

    // MARK: Native request

    /// The request understood by the native scanner: "look" is 64 characters
    /// a1…h8 ('.' any), "or"/"exclude" are 64 comma-separated piece sets.
    var nativeRequest: [String: String] {
        var look = Array(repeating: Character("."), count: 64)
        if exactBoard { look = Array(repeating: "_", count: 64) }
        for (square, piece) in lookFor where (0..<64).contains(square) { look[square] = Character(piece.rawValue) }
        func sets(_ board: [Int: Set<MaskPiece>]) -> String {
            (0..<64).map { square in (board[square] ?? []).map(\.rawValue).sorted().joined() }.joined(separator: ",")
        }
        var result: [String: String] = ["look": String(look), "length": String(max(1, length))]
        if !either.isEmpty { result["or"] = sets(either) }
        if !exclude.isEmpty { result["exclude"] = sets(exclude) }
        if mirrorHorizontal { result["mirrorH"] = "1" }
        if mirrorVertical { result["mirrorV"] = "1" }
        if let side = effectiveSide { result["side"] = side == .white ? "w" : "b" }
        if let firstMove { result["first"] = String(firstMove) }
        if let lastMove { result["last"] = String(lastMove) }
        return result
    }

    /// Stable identity of the search semantics; scan results are cached under it.
    var cacheKey: String {
        let data = try! JSONSerialization.data(withJSONObject: nativeRequest, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Matching (saved games and the preview jump)

    private struct Variant {
        let lookFor: [(Int, MaskPiece)], either: [(Int, MaskPiece)], exclude: [(Int, MaskPiece)]
        let side: PieceColor?
        func matches(_ position: ChessPosition) -> Bool {
            if let side, position.sideToMove != side { return false }
            for (square, piece) in lookFor where !piece.accepts(position[Square(square)]) { return false }
            for (square, piece) in exclude where piece.accepts(position[Square(square)]) { return false }
            return either.isEmpty || either.contains { $0.1.accepts(position[Square($0.0)]) }
        }
    }

    private var variants: [Variant] {
        var lookFor = self.lookFor
        if exactBoard { for square in 0..<64 where lookFor[square] == nil { lookFor[square] = .empty } }
        let base = Variant(lookFor: lookFor.sorted { $0.key < $1.key }.map { ($0.key, $0.value) },
                           either: either.flatMap { entry in entry.value.map { (entry.key, $0) } },
                           exclude: exclude.flatMap { entry in entry.value.map { (entry.key, $0) } }, side: effectiveSide)
        func mirrored(_ variant: Variant, horizontal: Bool, vertical: Bool) -> Variant {
            func transform(_ entry: (Int, MaskPiece)) -> (Int, MaskPiece) {
                var rank = entry.0 / 8, file = entry.0 % 8, piece = entry.1
                if horizontal { rank = 7 - rank; piece = piece.oppositeColor }
                if vertical { file = 7 - file }
                return (rank * 8 + file, piece)
            }
            return Variant(lookFor: variant.lookFor.map(transform), either: variant.either.map(transform), exclude: variant.exclude.map(transform),
                           side: horizontal ? variant.side?.opposite : variant.side)
        }
        var result = [base]
        if mirrorHorizontal { result.append(mirrored(base, horizontal: true, vertical: false)) }
        if mirrorVertical { result.append(mirrored(base, horizontal: false, vertical: true)) }
        if mirrorHorizontal && mirrorVertical { result.append(mirrored(base, horizontal: true, vertical: true)) }
        return result
    }

    // MARK: Fast matching of "placement side" strings (local_positions rows)

    /// One mirrored variant compiled to piece-code bitmasks: codes follow the
    /// native key (1-6 white K Q R B N P, 9-14 black, 7 empty).
    struct Compiled: Sendable {
        var required: [(square: Int, allowed: UInt16)] = []
        var alternatives: [(square: Int, allowed: UInt16)] = []
        var side: UInt8? = nil
    }

    private static func codeMask(_ piece: MaskPiece) -> UInt16 {
        switch piece {
        case .anyWhite: return 0b0000_0000_0111_1110
        case .anyBlack: return 0b0111_1110_0000_0000
        case .empty: return 1 << 7
        default: return 1 << UInt16(code(piece.rawValue.utf8.first!))
        }
    }

    /// Piece code of a FEN letter; 7 for anything else.
    private static func code(_ letter: UInt8) -> Int {
        switch letter {
        case UInt8(ascii: "K"): return 1; case UInt8(ascii: "Q"): return 2; case UInt8(ascii: "R"): return 3
        case UInt8(ascii: "B"): return 4; case UInt8(ascii: "N"): return 5; case UInt8(ascii: "P"): return 6
        case UInt8(ascii: "k"): return 9; case UInt8(ascii: "q"): return 10; case UInt8(ascii: "r"): return 11
        case UInt8(ascii: "b"): return 12; case UInt8(ascii: "n"): return 13; case UInt8(ascii: "p"): return 14
        default: return 7
        }
    }

    func compiled() -> [Compiled] {
        variants.map { variant in
            var result = Compiled()
            var allowed = [UInt16](repeating: 0xFFFF, count: 64)
            for (square, piece) in variant.lookFor where (0..<64).contains(square) { allowed[square] &= Self.codeMask(piece) }
            for (square, piece) in variant.exclude where (0..<64).contains(square) { allowed[square] &= ~Self.codeMask(piece) }
            for square in 0..<64 where allowed[square] != 0xFFFF { result.required.append((square, allowed[square])) }
            for (square, piece) in variant.either where (0..<64).contains(square) { result.alternatives.append((square, Self.codeMask(piece))) }
            result.side = variant.side.map { $0 == .white ? UInt8(ascii: "w") : UInt8(ascii: "b") }
            return result
        }
    }

    /// Whether a "placement side" string (as stored in `local_positions`)
    /// satisfies any compiled variant. Avoids building a `ChessPosition`.
    static func matches(boardText: String, variants: [Compiled]) -> Bool {
        var codes = [UInt8](repeating: 7, count: 64)
        var side: UInt8 = 0
        var rank = 7, file = 0
        var bytes = boardText.utf8.makeIterator()
        while let byte = bytes.next() {
            if byte == UInt8(ascii: " ") { side = bytes.next() ?? 0; break }
            if byte == UInt8(ascii: "/") { rank -= 1; file = 0; continue }
            if byte >= UInt8(ascii: "1") && byte <= UInt8(ascii: "8") { file += Int(byte - UInt8(ascii: "0")); continue }
            if rank >= 0 && file < 8 { codes[rank * 8 + file] = UInt8(code(byte)) }
            file += 1
        }
        for variant in variants {
            if let wanted = variant.side, wanted != side { continue }
            var ok = true
            for check in variant.required where check.allowed >> UInt16(codes[check.square]) & 1 == 0 { ok = false; break }
            if !ok { continue }
            if variant.alternatives.isEmpty || variant.alternatives.contains(where: { $0.allowed >> UInt16(codes[$0.square]) & 1 == 1 }) { return true }
        }
        return false
    }

    /// Whether a single position satisfies the mask (placement, side and mirrors only).
    func matches(_ position: ChessPosition) -> Bool {
        let variants = self.variants
        return variants.contains { $0.matches(position) }
    }

    /// The first ply (0 = starting position) at which the fragment has held for
    /// `length` consecutive plies inside the move window, or nil.
    func firstMatch(in positions: [ChessPosition]) -> Int? {
        let variants = self.variants
        let firstPly = (firstMove ?? 1) <= 1 ? 0 : 2 * firstMove! - 1
        let lastPly = lastMove.map { 2 * $0 } ?? Int.max
        var streaks = Array(repeating: 0, count: variants.count)
        for (ply, position) in positions.enumerated() {
            if ply < firstPly || ply > lastPly { streaks = streaks.map { _ in 0 }; continue }
            for (index, variant) in variants.enumerated() {
                if variant.matches(position) { streaks[index] += 1; if streaks[index] >= max(1, length) { return ply } }
                else { streaks[index] = 0 }
            }
        }
        return nil
    }

    // MARK: Presentation

    /// A compact description such as "wBh7 bKg8 · not: bPh6 · mirror ↕ · Black to move".
    var summary: String {
        func list(_ board: [Int: Set<MaskPiece>]) -> String {
            board.sorted { $0.key < $1.key }.flatMap { entry in entry.value.sorted { $0.rawValue < $1.rawValue }.map { "\($0.abbreviation)\(Square(entry.key).name)" } }.joined(separator: " ")
        }
        var parts: [String] = []
        let placements = lookFor.sorted { $0.key < $1.key }.map { "\($0.value.abbreviation)\(Square($0.key).name)" }
        if !placements.isEmpty { parts.append(placements.joined(separator: " ")) }
        if exactBoard { parts.append("exact position") }
        if !either.isEmpty { parts.append("one of: " + list(either)) }
        if !exclude.isEmpty { parts.append("not: " + list(exclude)) }
        if mirrorHorizontal || mirrorVertical { parts.append("mirror " + (mirrorHorizontal ? "↕" : "") + (mirrorVertical ? "↔" : "")) }
        if let side = effectiveSide { parts.append(side == .white ? "White to move" : "Black to move") }
        if firstMove != nil || lastMove != nil { parts.append("moves \(firstMove.map(String.init) ?? "1")–\(lastMove.map(String.init) ?? "end")") }
        if length > 1 { parts.append("for \(length) plies") }
        return parts.joined(separator: " · ")
    }
}
