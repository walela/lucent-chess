import Foundation

/// Searches indexed PGN byte ranges without building a study, rendering SAN, or
/// parsing variations. One file handle is reused for all candidates from a source.
final class PGNPositionScanner {
    private let handle: FileHandle
    private let target: ChessPosition
    private let requiredHomePawns: [(Square,ChessPiece)]
    private let whitePawnCount: Int
    private let blackPawnCount: Int

    init(path: String, board: String) throws {
        handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        guard let target = ChessPosition(fen: board + " - - 0 1") else {
            throw CatalogError.message("Invalid board-search position.")
        }
        self.target = target
        whitePawnCount=target.squares.filter {$0 == ChessPiece(color:.white,kind:.pawn)}.count
        blackPawnCount=target.squares.filter {$0 == ChessPiece(color:.black,kind:.pawn)}.count
        requiredHomePawns=PieceColor.allCases.flatMap { color in
            (0..<8).compactMap { file -> (Square,ChessPiece)? in
                let square=Square(file:file,rank:color.pawnStartRank),pawn=ChessPiece(color:color,kind:.pawn)
                return target[square] == pawn ? (square,pawn) : nil
            }
        }
    }
    deinit { try? handle.close() }

    func match(offset: Int, length: Int) throws -> Int {
        guard offset >= 0, length > 0 else { return -2 }
        try handle.seek(toOffset: UInt64(offset))
        let reader = PGNRangeReader(handle: handle, length: length)
        var position = ChessPosition.starting
        var token = try reader.token()
        while let value = token, value.hasPrefix("[") {
            let name=value.dropFirst().prefix { !$0.isWhitespace && $0 != "]" }
            if name == "FEN", let first = value.firstIndex(of: "\""), let last = value.lastIndex(of: "\""), first < last {
                guard let custom = ChessPosition(fen: String(value[value.index(after:first)..<last])) else { return -2 }
                position = custom
            }
            if name == "Variant", !value.contains("\"Standard\"") { return -2 }
            token = try reader.token()
        }
        var ply = 0, depth = 0
        if matches(position) { return 0 }
        if !canReach(position) { return -1 }
        while let raw = token {
            try Task.checkCancellation()
            if raw == "(" { depth += 1 }
            else if raw == ")" { guard depth > 0 else { return -2 }; depth -= 1 }
            else if depth == 0 {
                if ["1-0", "0-1", "1/2-1/2", "*"].contains(raw) { return -1 }
                var san = raw
                let prefix = san.prefix { $0.isNumber }
                if !prefix.isEmpty, san.dropFirst(prefix.count).first == "." {
                    san = String(san.dropFirst(prefix.count).drop { $0 == "." })
                }
                if !san.isEmpty, !san.hasPrefix("$"), !["!", "?", "!!", "??", "!?", "?!", "e.p.", "..."].contains(san) {
                    guard let move = Self.move(san, in: position) else { return -2 }
                    position = position.applyingUnchecked(move)
                    ply += 1
                    if matches(position) { return ply }
                    if !canReach(position) { return -1 }
                }
            }
            token = try reader.token()
        }
        return depth == 0 ? -1 : -2
    }

    private func matches(_ position: ChessPosition) -> Bool {
        position.sideToMove == target.sideToMove && position.squares == target.squares
    }

    private func canReach(_ position: ChessPosition) -> Bool {
        // A pawn cannot return to its starting rank, nor can a new pawn appear.
        // This safely rejects most incompatible openings after only a few plies.
        for (square,pawn) in requiredHomePawns where position[square] != pawn {return false}
        var white=0,black=0
        for piece in position.squares {
            if let piece, piece.kind == .pawn {
                if piece.color == .white {white += 1} else {black += 1}
            }
        }
        if white < whitePawnCount || black < blackPawnCount {return false}
        return true
    }

    private static func move(_ raw: String, in position: ChessPosition) -> ChessMove? {
        var san = raw.replacingOccurrences(of:"0",with:"O")
        while let last = san.last, "+#!?".contains(last) { san.removeLast() }
        if san == "O-O" || san == "O-O-O" {
            return position.legalMoves().first { $0.isCastle && $0.to.file == (san == "O-O" ? 6 : 2) }
        }
        // Coordinate notation occasionally appears in otherwise standard PGN.
        if let uci = ChessMove.fromUCI(san), (4...5).contains(san.count),
           let move = position.legalMoves(from:uci.from).first(where:{$0.to == uci.to && $0.promotion == uci.promotion}) { return move }
        let pieces: [Character:PieceKind] = ["N":.knight,"B":.bishop,"R":.rook,"Q":.queen,"K":.king]
        var promotion: PieceKind?
        if let equal = san.firstIndex(of:"=") {
            let suffix = san[san.index(after:equal)...]
            guard suffix.count == 1, let piece = suffix.first.flatMap({pieces[$0]}), piece != .king else { return nil }
            promotion = piece; san = String(san[..<equal])
        }
        guard san.count >= 2, let to = Square.from(String(san.suffix(2))) else { return nil }
        var prefix = String(san.dropLast(2)), kind = PieceKind.pawn
        if let first = prefix.first, let piece = pieces[first] { kind = piece;prefix.removeFirst() }
        let capture = prefix.contains("x")
        prefix.removeAll { $0 == "x" }
        var file: Int?, rank: Int?
        for char in prefix {
            if let ascii = char.asciiValue, (97...104).contains(ascii), file == nil { file = Int(ascii-97) }
            else if let number = char.wholeNumberValue, (1...8).contains(number), rank == nil { rank = number-1 }
            else { return nil }
        }
        var match: ChessMove?
        for index in position.squares.indices {
            let from = Square(index)
            guard position[from] == ChessPiece(color:position.sideToMove,kind:kind),
                  file == nil || from.file == file, rank == nil || from.rank == rank else { continue }
            for candidate in position.legalMoves(from:from) where candidate.to == to && candidate.promotion == promotion {
                guard capture == (candidate.isEnPassant || position[to] != nil), match == nil else { return nil }
                match = candidate
            }
        }
        return match
    }
}

private final class PGNRangeReader {
    let handle: FileHandle
    var remaining: Int
    var buffer = Data(), index = 0
    init(handle: FileHandle, length: Int) { self.handle=handle;remaining=length }
    private func peek() throws -> UInt8? {
        if index == buffer.count {
            guard remaining > 0 else { return nil }
            try Task.checkCancellation()
            buffer = try handle.read(upToCount:min(remaining,16*1024)) ?? Data()
            remaining -= buffer.count;index = 0
            guard !buffer.isEmpty else { remaining=0;return nil }
        }
        return buffer[index]
    }
    private func take() throws -> UInt8? { let byte=try peek();if byte != nil {index += 1};return byte }
    func token() throws -> String? {
        while let byte = try peek() {
            if byte <= 32 || byte == 239 || byte == 187 || byte == 191 { _ = try take();continue }
            if byte == 123 { // Brace comment.
                _ = try take()
                while let next=try take(), next != 125 { }
                continue
            }
            if byte == 59 || byte == 37 { // Semicolon comment or PGN escape line.
                while let next=try take(), next != 10 { }
                continue
            }
            break
        }
        guard let first=try take() else { return nil }
        if first == 40 || first == 41 { return String(UnicodeScalar(first)) }
        var bytes=[first]
        if first == 91 { // Header tags may contain brackets inside quoted values.
            var quoted=false, escaped=false
            while let byte=try take() {
                guard bytes.count < 64*1024 else { throw CatalogError.message("A PGN header is too large to search.") }
                bytes.append(byte)
                if escaped {escaped=false;continue}
                if byte == 92 && quoted {escaped=true;continue}
                if byte == 34 {quoted.toggle()}
                if byte == 93 && !quoted {break}
            }
        } else {
            while let byte=try peek(), byte>32, ![40,41,123,125,59,91].contains(byte), !(byte==36 && first != 36) {
                guard bytes.count < 1024 else { throw CatalogError.message("A PGN move token is too large to search.") }
                bytes.append(try take()!)
            }
        }
        return String(decoding:bytes,as:UTF8.self)
    }
}
