import Foundation

struct ChessNotationToken: Equatable {
    enum Kind: Equatable {
        case moveNumber
        case move
        case punctuation
        case comment
        case annotation
        case result
    }

    var text: String
    var kind: Kind
    var nodeID: UUID?
    var variationDepth: Int
}

struct ChessNotationDocument {
    var tokens: [ChessNotationToken]
    var plainText: String { tokens.map(\.text).joined() }
}

enum ChessNotationFormatter {
    static func document(for study: ChessStudy) -> ChessNotationDocument {
        var renderer = Renderer(study: study)
        return renderer.render()
    }

    private struct Renderer {
        let study: ChessStudy
        var tokens: [ChessNotationToken] = []

        mutating func render() -> ChessNotationDocument {
            if !study.root.comment.isEmpty {
                append("{\(inlineComment(study.root.comment))}\n\n", kind: .comment, depth: 0)
            }
            let position = ChessPosition(fen: study.root.positionFEN) ?? .starting
            renderChildren(of: study.root, position: position, forceNumber: true, depth: 0)
            if !study.root.children.isEmpty { append(" ", kind: .punctuation, depth: 0) }
            append(study.result, kind: .result, depth: 0)
            return ChessNotationDocument(tokens: tokens)
        }

        mutating func renderChildren(
            of parent: MoveNode,
            position: ChessPosition,
            forceNumber: Bool,
            depth: Int
        ) {
            guard let main = parent.children.first else { return }
            renderMove(main, position: position, forceNumber: forceNumber, depth: depth)

            for variation in parent.children.dropFirst() {
                append(" (", kind: .punctuation, depth: depth + 1)
                renderVariation(variation, position: position, depth: depth + 1)
                append(")", kind: .punctuation, depth: depth + 1)
            }

            guard let moveUCI = main.moveUCI, let move = position.legalMove(uci: moveUCI) else { return }
            let continuationPosition = position.applyingUnchecked(move)
            if !main.children.isEmpty {
                append(" ", kind: .punctuation, depth: depth)
                renderChildren(of: main, position: continuationPosition, forceNumber: false, depth: depth)
            }
        }

        mutating func renderVariation(_ node: MoveNode, position: ChessPosition, depth: Int) {
            renderMove(node, position: position, forceNumber: true, depth: depth)
            guard let moveUCI = node.moveUCI, let move = position.legalMove(uci: moveUCI) else { return }
            let continuationPosition = position.applyingUnchecked(move)
            if !node.children.isEmpty {
                append(" ", kind: .punctuation, depth: depth)
                renderChildren(of: node, position: continuationPosition, forceNumber: false, depth: depth)
            }
        }

        mutating func renderMove(
            _ node: MoveNode,
            position: ChessPosition,
            forceNumber: Bool,
            depth: Int
        ) {
            if position.sideToMove == .white {
                append("\(position.fullmoveNumber). ", kind: .moveNumber, depth: depth)
            } else if forceNumber {
                append("\(position.fullmoveNumber)... ", kind: .moveNumber, depth: depth)
            }
            append(node.moveSAN ?? node.moveUCI ?? "?", kind: .move, nodeID: node.id, depth: depth)
            for nag in node.nags {
                append(" \(nagSymbol(nag))", kind: .annotation, nodeID: node.id, depth: depth)
            }
            if !node.comment.isEmpty {
                append(" {\(inlineComment(node.comment))}", kind: .comment, nodeID: node.id, depth: depth)
            }
        }

        /// Comments remain untouched in the model and PGN export. The score is a
        /// flowing reading view, so editor line breaks are rendered as spaces.
        func inlineComment(_ comment: String) -> String {
            comment
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
        }

        mutating func append(
            _ text: String,
            kind: ChessNotationToken.Kind,
            nodeID: UUID? = nil,
            depth: Int
        ) {
            tokens.append(ChessNotationToken(text: text, kind: kind, nodeID: nodeID, variationDepth: depth))
        }

        func nagSymbol(_ nag: Int) -> String {
            switch nag {
            case 1: return "!"
            case 2: return "?"
            case 3: return "!!"
            case 4: return "??"
            case 5: return "!?"
            case 6: return "?!"
            default: return "$\(nag)"
            }
        }
    }
}
