import Foundation

/// One continuation from the searched position, aggregated over the games listed.
struct OpeningTreeRow: Identifiable, Hashable, Sendable {
    let uci: String
    let san: String
    var games = 0
    var whiteWins = 0
    var draws = 0
    var blackWins = 0
    var eloSum = 0
    var eloCount = 0
    var latestYear = 0

    var id: String { uci }
    /// White's score in percent, the conventional tree column.
    var score: Double { games == 0 ? 0 : (Double(whiteWins) + Double(draws) / 2) / Double(games) * 100 }
    var averageElo: Int? { eloCount == 0 ? nil : eloSum / eloCount }
}

struct OpeningTree: Sendable {
    var rows: [OpeningTreeRow] = []
    /// Games whose main line reached the position and was decoded.
    var analysed = 0
    /// Games that end at the searched position.
    var ended = 0
    /// Listed games whose moves could not be read.
    var unreadable = 0
    var isEmpty: Bool { rows.isEmpty && ended == 0 }

    /// Folds a further page of games into this summary.
    mutating func merge(_ other: OpeningTree) {
        var byMove = Dictionary(uniqueKeysWithValues: rows.map { ($0.uci, $0) })
        for row in other.rows {
            if var existing = byMove[row.uci] {
                existing.games += row.games; existing.whiteWins += row.whiteWins; existing.draws += row.draws
                existing.blackWins += row.blackWins; existing.eloSum += row.eloSum; existing.eloCount += row.eloCount
                existing.latestYear = max(existing.latestYear, row.latestYear)
                byMove[row.uci] = existing
            } else { byMove[row.uci] = row }
        }
        rows = byMove.values.sorted { $0.games != $1.games ? $0.games > $1.games : $0.san < $1.san }
        analysed += other.analysed; ended += other.ended; unreadable += other.unreadable
    }
}

/// Builds the continuation table for the games currently listed in the
/// reference panel. Main lines are decoded once per page in a single reader
/// invocation per ChessBase source; PGN and saved games are parsed directly.
enum OpeningTreeService {
    private struct Reference { let id: UUID; let source: String?; let record: Int; let length: Int; let hasPayload: Bool }
    private struct Outcome { let result: String; let whiteElo: Int; let blackElo: Int; let year: Int }

    /// The continuation table over the whole database in scope: imported games
    /// come from the native exact position index (no decoding), saved and edited
    /// games are replayed directly. `request` carries the board and scope.
    static func buildFull(catalog: DatabaseCatalog, request: CatalogRequest) throws -> OpeningTree {
        guard let position = ChessPosition(fen: request.filter.boardFEN) else { return OpeningTree() }
        let moves = position.legalMoves()
        let children = try moves.map { move in (uci: move.uci, board: try CatalogFilter.boardKey(position.applyingUnchecked(move).fen)) }
        let sans = Dictionary(moves.map { ($0.uci, position.san(for: $0)) }, uniquingKeysWith: { first, _ in first })
        let native = try InteractiveCatalogService.positionTree(catalog: catalog, request: request, children: children)
        var tree = OpeningTree()
        tree.analysed = native.games
        tree.ended = native.ended
        tree.rows = native.rows.compactMap { row in
            guard let san = sans[row.uci] else { return nil }
            var result = OpeningTreeRow(uci: row.uci, san: san)
            result.games = row.games; result.whiteWins = row.whiteWins; result.draws = row.draws; result.blackWins = row.blackWins
            result.eloSum = Int(clamping: row.eloSum); result.eloCount = row.eloCount; result.latestYear = row.latestYear
            return result
        }.sorted { $0.games != $1.games ? $0.games > $1.games : $0.san < $1.san }
        try Task.checkCancellation()
        // Saved and edited games live in SQLite, not the immutable snapshot; there
        // are few of them, so replaying the first page of matches is exact enough.
        var local = request; local.localOnly = true; local.cursor = nil; local.positionSearchKey = nil
        let page = try catalog.page(local)
        if !page.games.isEmpty { tree.merge(try build(catalog: catalog, games: page.games, boardFEN: request.filter.boardFEN)) }
        return tree
    }

    static func build(catalog: DatabaseCatalog, games: [ChessStudy], boardFEN: String) throws -> OpeningTree {
        var tree = OpeningTree()
        guard !games.isEmpty else { return tree }
        let board = try CatalogFilter.boardKey(boardFEN)
        let outcomes = Dictionary(uniqueKeysWithValues: games.map { game in
            (game.id, Outcome(result: game.result, whiteElo: Int(game.whiteElo ?? "") ?? 0, blackElo: Int(game.blackElo ?? "") ?? 0,
                              year: Calendar(identifier: .gregorian).component(.year, from: game.date)))
        })
        let references = try locate(catalog: catalog, ids: games.map(\.id))
        var rows: [String: OpeningTreeRow] = [:]

        func record(_ id: UUID, start: ChessPosition, line: [ChessMove]) {
            guard let outcome = outcomes[id] else { return }
            var position = start
            var index = 0
            while true {
                if position.fen.split(separator: " ").prefix(2).joined(separator: " ") == board { break }
                guard index < line.count else { tree.unreadable += 1; return }
                position = position.applyingUnchecked(line[index]); index += 1
            }
            tree.analysed += 1
            guard index < line.count else { tree.ended += 1; return }
            let move = line[index]
            var row = rows[move.uci] ?? OpeningTreeRow(uci: move.uci, san: position.san(for: move))
            row.games += 1
            switch outcome.result {
            case "1-0": row.whiteWins += 1
            case "0-1": row.blackWins += 1
            case "1/2-1/2": row.draws += 1
            default: break
            }
            for elo in [outcome.whiteElo, outcome.blackElo] where elo > 0 { row.eloSum += elo; row.eloCount += 1 }
            row.latestYear = max(row.latestYear, outcome.year)
            rows[move.uci] = row
        }

        func record(_ id: UUID, study: ChessStudy) {
            var line: [ChessMove] = []
            var node = study.root
            let start = ChessPosition(fen: node.positionFEN) ?? .starting
            var position = start
            while let next = node.children.first, let uci = next.moveUCI, let move = position.legalMove(uci: uci) {
                line.append(move); position = position.applyingUnchecked(move); node = next
            }
            record(id, start: start, line: line)
        }

        var sources: [String: CatalogSource?] = [:]
        var grouped: [String: [Reference]] = [:]
        for reference in references {
            try Task.checkCancellation()
            if reference.hasPayload || reference.source == nil {
                if let study = try? catalog.load(reference.id) { record(reference.id, study: study) } else { tree.unreadable += 1 }
                continue
            }
            grouped[reference.source!, default: []].append(reference)
        }
        for (sourceID, members) in grouped {
            try Task.checkCancellation()
            if sources[sourceID] == nil { sources[sourceID] = try catalog.source(id: sourceID) }
            guard let source = sources[sourceID] ?? nil else { tree.unreadable += members.count; continue }
            if source.kind == "cbh" {
                let decoded = try ChessBaseImportService.readRecords(URL(fileURLWithPath: source.path), records: members.map(\.record))
                for member in members {
                    if let game = decoded[member.record], let main = game.mainLine() { record(member.id, start: main.start, line: main.moves) }
                    else { tree.unreadable += 1 }
                }
            } else if source.kind == "pgn" {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: source.path))
                defer { try? handle.close() }
                for member in members {
                    try Task.checkCancellation()
                    guard member.length > 0, member.length <= 4 * 1024 * 1024 else { tree.unreadable += 1; continue }
                    try handle.seek(toOffset: UInt64(member.record))
                    let bytes = try handle.read(upToCount: member.length) ?? Data()
                    guard bytes.count == member.length,
                          let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .windowsCP1252),
                          let study = try? PGNService.parse(text).first else { tree.unreadable += 1; continue }
                    record(member.id, study: study)
                }
            } else {
                for member in members {
                    if let study = try? catalog.load(member.id) { record(member.id, study: study) } else { tree.unreadable += 1 }
                }
            }
        }
        tree.rows = rows.values.sorted { $0.games != $1.games ? $0.games > $1.games : $0.san < $1.san }
        return tree
    }

    private static func locate(catalog: DatabaseCatalog, ids: [UUID]) throws -> [Reference] {
        guard !ids.isEmpty else { return [] }
        let db = try SQLConnection(catalog.url)
        let q = try db.prepare("SELECT id,source_id,record,coalesce(record_length,0),payload IS NOT NULL FROM games WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))")
        try q.bind(ids.map { .text($0.uuidString) })
        var result: [Reference] = []
        while try q.next() {
            guard let id = UUID(uuidString: q.text(0)) else { continue }
            result.append(Reference(id: id, source: q.optionalText(1), record: q.int(2), length: q.int(3), hasPayload: q.int(4) != 0))
        }
        return result
    }
}
