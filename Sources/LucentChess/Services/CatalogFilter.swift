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

    var hasRatings: Bool { whiteMin != nil || whiteMax != nil || blackMin != nil || blackMax != nil }
    var hasRanges: Bool { hasRatings || yearMin != nil || yearMax != nil }
    var hasHeaders: Bool { !player.isEmpty || !white.isEmpty || !black.isEmpty || !tournament.isEmpty || hasRatings || yearMin != nil || yearMax != nil }
    var isActive: Bool { hasHeaders || !boardFEN.isEmpty }
    func validate() throws {
        for (low, high, maximum, label) in [(whiteMin,whiteMax,4000,"White Elo"),(blackMin,blackMax,4000,"Black Elo"),(yearMin,yearMax,9998,"Year")] {
            if let low, low < 1 || low > maximum { throw CatalogError.message("\(label) must be between 1 and \(maximum).") }
            if let high, high < 1 || high > maximum { throw CatalogError.message("\(label) must be between 1 and \(maximum).") }
            if let low, let high, low > high { throw CatalogError.message("\(label): the minimum must not exceed the maximum.") }
        }
        if !boardFEN.isEmpty { _ = try Self.boardKey(boardFEN) }
    }
    // Board search matches piece placement and side to move, regardless of clocks/castling/en-passant.
    static func boardKey(_ fen: String) throws -> String {
        let position = try PositionSetup.parseFEN(fen)
        return position.fen.split(separator: " ").prefix(2).joined(separator: " ")
    }
}
