import Foundation

enum PGNError: LocalizedError {
    case noGames
    case invalidMove(String, Int)

    var errorDescription: String? {
        switch self {
        case .noGames: return "No chess game was found in this PGN."
        case let .invalidMove(move, number): return "Could not understand move ‘\(move)’ near ply \(number)."
        }
    }
}

enum PGNService {
    static func parse(_ text: String) throws -> [ChessStudy] {
        let chunks = splitGames(text)
        guard !chunks.isEmpty else { throw PGNError.noGames }
        return try chunks.map(parseGame)
    }

    static func export(_ study: ChessStudy) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        let startFEN = study.root.positionFEN
        var tags = [
            "[Event \"\(escape(study.event.isEmpty ? study.title : study.event))\"]",
            "[Site \"\(escape(study.site?.nonEmpty ?? "?"))\"]",
            "[Date \"\(formatter.string(from: study.date))\"]",
            "[Round \"\(escape(study.round?.nonEmpty ?? "?"))\"]",
            "[White \"\(escape(study.white.isEmpty ? "?" : study.white))\"]",
            "[Black \"\(escape(study.black.isEmpty ? "?" : study.black))\"]",
            "[Result \"\(study.result)\"]"
        ]
        if let whiteElo = study.whiteElo?.nonEmpty { tags.append("[WhiteElo \"\(escape(whiteElo))\"]") }
        if let blackElo = study.blackElo?.nonEmpty { tags.append("[BlackElo \"\(escape(blackElo))\"]") }
        if let eco = study.eco?.nonEmpty { tags.append("[ECO \"\(escape(eco))\"]") }
        if startFEN != ChessPosition.startFEN {
            tags.append("[SetUp \"1\"]")
            tags.append("[FEN \"\(startFEN)\"]")
        }
        let body = renderChildren(of: study.root, position: ChessPosition(fen: startFEN) ?? .starting, forceNumber: true)
        let rootComment = study.root.comment.isEmpty ? "" : "{\(study.root.comment)} "
        return tags.joined(separator: "\n") + "\n\n" + rootComment + body + (body.isEmpty ? "" : " ") + study.result + "\n"
    }

    private static func parseGame(_ text: String) throws -> ChessStudy {
        let tagPattern = #"(?m)^\[([A-Za-z0-9_]+)\s+\"((?:\\.|[^\"])*)\"\]\s*$"#
        let regex = try NSRegularExpression(pattern: tagPattern)
        let ns = text as NSString
        var tags: [String: String] = [:]
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            tags[ns.substring(with: match.range(at: 1))] = ns.substring(with: match.range(at: 2))
                .replacingOccurrences(of: "\\\"", with: "\"")
        }
        let startFEN = tags["FEN"] ?? ChessPosition.startFEN
        let study = ChessStudy(
            title: tags["Event"].flatMap { $0 == "?" ? nil : $0 } ?? "Imported game",
            white: tags["White"] ?? "",
            black: tags["Black"] ?? "",
            event: tags["Event"] ?? "",
            site: tags["Site"]?.nonEmpty,
            round: tags["Round"]?.nonEmpty,
            whiteElo: tags["WhiteElo"]?.nonEmpty,
            blackElo: tags["BlackElo"]?.nonEmpty,
            eco: tags["ECO"]?.nonEmpty,
            result: tags["Result"] ?? "*",
            startFEN: startFEN
        )
        if let date = tags["Date"] {
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy.MM.dd"
            if let parsed = formatter.date(from: date.replacingOccurrences(of: "?", with: "1")) { study.date = parsed }
        }
        let movetext = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        let tokens = tokenize(movetext)
        var current = study.root
        var nodeMap: [UUID: MoveNode] = [study.root.id: study.root]
        var variationStack: [MoveNode] = []
        var ply = 0
        for token in tokens {
            switch token {
            case "(":
                variationStack.append(current)
                current = current.parentID.flatMap { nodeMap[$0] } ?? study.root
            case ")":
                if let saved = variationStack.popLast() { current = saved }
            default:
                if token.hasPrefix("{") {
                    let comment = String(token.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                    current.comment += (current.comment.isEmpty ? "" : "\n") + comment
                } else if token.hasPrefix("$") {
                    if let nag = Int(token.dropFirst()) { current.nags.append(nag) }
                } else if isIgnoredToken(token) {
                    continue
                } else {
                    let moveToken = token.replacingOccurrences(
                        of: #"^\d+\.(?:\.\.)?"#,
                        with: "",
                        options: .regularExpression
                    )
                    if moveToken.isEmpty { continue }
                    let position = ChessPosition(fen: current.positionFEN) ?? .starting
                    guard let move = position.move(matchingSAN: moveToken) else { throw PGNError.invalidMove(moveToken, ply + 1) }
                    if let existing = current.children.first(where: { $0.moveUCI == move.uci }) {
                        current = existing
                    } else {
                        let child = MoveNode(
                            parentID: current.id,
                            moveUCI: move.uci,
                            moveSAN: position.san(for: move),
                            positionFEN: position.applyingUnchecked(move).fen
                        )
                        current.children.append(child)
                        nodeMap[child.id] = child
                        current = child
                    }
                    ply += 1
                }
            }
        }
        study.lastNodeID = study.root.id
        study.rebuildNodeIndex()
        return study
    }

    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char.isWhitespace { index = text.index(after: index); continue }
            if char == "{" {
                let end = text[index...].firstIndex(of: "}") ?? text.index(before: text.endIndex)
                tokens.append(String(text[index...end]))
                index = text.index(after: end)
            } else if char == ";" {
                let end = text[index...].firstIndex(of: "\n") ?? text.endIndex
                index = end
            } else if char == "(" || char == ")" {
                tokens.append(String(char)); index = text.index(after: index)
            } else {
                var end = index
                while end < text.endIndex, !text[end].isWhitespace, !"(){};".contains(text[end]) { end = text.index(after: end) }
                tokens.append(String(text[index..<end]))
                index = end
            }
        }
        return tokens
    }

    private static func isIgnoredToken(_ token: String) -> Bool {
        token.range(of: #"^\d+\.(\.\.)?$"#, options: .regularExpression) != nil ||
        ["1-0", "0-1", "1/2-1/2", "*"].contains(token) ||
        ["!!", "??", "!?", "?!", "!", "?"].contains(token)
    }

    private static func splitGames(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let pattern = #"(?m)(?=^\[Event\s+\")"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [normalized] }
        let ns = normalized as NSString
        let matches = regex.matches(in: normalized, range: NSRange(location: 0, length: ns.length))
        if matches.count <= 1 { return normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [normalized] }
        return matches.enumerated().map { index, match in
            let start = match.range.location
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            return ns.substring(with: NSRange(location: start, length: end - start))
        }
    }

    private static func renderChildren(of node: MoveNode, position: ChessPosition, forceNumber: Bool) -> String {
        guard let main = node.children.first, let uci = main.moveUCI, let move = position.legalMove(uci: uci) else { return "" }
        let prefix: String
        if position.sideToMove == .white { prefix = "\(position.fullmoveNumber). " }
        else { prefix = forceNumber ? "\(position.fullmoveNumber)... " : "" }
        var text = prefix + (main.moveSAN ?? position.san(for: move))
        if !main.comment.isEmpty { text += " {\(main.comment)}" }
        for nag in main.nags { text += " $\(nag)" }
        for variation in node.children.dropFirst() {
            let wrapper = MoveNode(positionFEN: node.positionFEN, children: [variation])
            text += " (" + renderChildren(of: wrapper, position: position, forceNumber: true) + ")"
        }
        let next = position.applyingUnchecked(move)
        let continuation = renderChildren(of: main, position: next, forceNumber: false)
        if !continuation.isEmpty { text += " " + continuation }
        return text
    }

    private static func escape(_ text: String) -> String { text.replacingOccurrences(of: "\"", with: "\\\"") }
}

private extension String {
    var nonEmpty: String? { isEmpty || self == "?" ? nil : self }
}
