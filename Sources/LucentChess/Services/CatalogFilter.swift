import Foundation

struct CatalogFilter: Codable, Hashable, Sendable {
    var player = ""
    var white = ""
    var black = ""
    var tournament = ""
    var whiteMin: Int?
    var whiteMax: Int?
    var blackMin: Int?
    var blackMax: Int?
    var yearMin: Int?
    var yearMax: Int?
    var boardFEN = ""
    /// A positional fragment (search-mask) query; exclusive with `boardFEN`.
    var mask: PositionSearchMask? = nil

    var hasRatings: Bool { whiteMin != nil || whiteMax != nil || blackMin != nil || blackMax != nil }
    var hasRanges: Bool { hasRatings || yearMin != nil || yearMax != nil }
    var hasHeaders: Bool { !player.isEmpty || !white.isEmpty || !black.isEmpty || !tournament.isEmpty || hasRatings || yearMin != nil || yearMax != nil }
    var hasPosition: Bool { !boardFEN.isEmpty || mask != nil }
    var isActive: Bool { hasHeaders || hasPosition }
    func validate() throws {
        for (low, high, maximum, label) in [(whiteMin,whiteMax,4000,"White Elo"),(blackMin,blackMax,4000,"Black Elo"),(yearMin,yearMax,9998,"Year")] {
            if let low, low < 1 || low > maximum { throw CatalogError.message("\(label) must be between 1 and \(maximum).") }
            if let high, high < 1 || high > maximum { throw CatalogError.message("\(label) must be between 1 and \(maximum).") }
            if let low, let high, low > high { throw CatalogError.message("\(label): the minimum must not exceed the maximum.") }
        }
        if !boardFEN.isEmpty { _ = try Self.boardKey(boardFEN) }
        if let mask { try mask.validate() }
        if !boardFEN.isEmpty && mask != nil { throw CatalogError.message("Use either an exact board or a search mask, not both.") }
    }
    // Board search matches piece placement and side to move, regardless of clocks/castling/en-passant.
    static func boardKey(_ fen: String) throws -> String {
        let position = try PositionSetup.parseFEN(fen)
        return position.fen.split(separator: " ").prefix(2).joined(separator: " ")
    }
}

// A cursor is an internal exact sort key; malformed values must fail instead of
// restarting from zero and repeating pages indefinitely.
extension CatalogRequest {
    func validateCursor() throws {
        guard let cursor else {return}
        guard UUID(uuidString:cursor.id) != nil else {throw CatalogError.message("Invalid page cursor.")}
        let value=cursor.rawValue.flatMap {String(data:$0,encoding:.utf8)} ?? cursor.value
        if ["whiteElo","blackElo","moves"].contains(sort) {
            guard Int64(value) != nil else {throw CatalogError.message("Invalid numeric page cursor.")}
        }else if !["players","event","result","round"].contains(sort) {
            guard let number=Double(value),number.isFinite else {throw CatalogError.message("Invalid date page cursor.")}
        }
    }
}
