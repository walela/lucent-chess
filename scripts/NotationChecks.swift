import Foundation

@main
struct NotationChecks {
    static func main() throws {
        let pgn = """
        [Event "Nested variation test"]
        [Result "*"]

        1. e4 {The main\nchoice.} (1. d4 d5 2. c4) e5 (1... c5 2. Nf3 d6 (2... Nc6)) 2. Nf3 Nc6 *
        """
        guard let study = try PGNService.parse(pgn).first else { throw Failure("game did not parse") }
        let document = ChessNotationFormatter.document(for: study)
        let expected = "1. e4 {The main choice.} (1. d4 d5 2. c4) e5 (1... c5 2. Nf3 d6 (2... Nc6)) 2. Nf3 Nc6 *"
        try check("horizontal notation matches canonical nested PGN structure") {
            document.plainText == expected
        }

        let moveTokens = document.tokens.filter { $0.kind == .move }
        try check("every move is represented once by a selectable token") {
            moveTokens.count == nodeCount(study.root) - 1
                && Set(moveTokens.compactMap(\.nodeID)).count == moveTokens.count
        }
        try check("nested variations retain their visual depth") {
            moveTokens.contains { $0.text == "Nc6" && $0.variationDepth == 2 }
                && moveTokens.contains { $0.text == "d4" && $0.variationDepth == 1 }
        }
        try check("PGN comments flow inline and remain associated with their move") {
            document.tokens.contains {
                $0.kind == .comment
                    && $0.text == " {The main choice.}"
                    && $0.nodeID == study.root.children.first?.id
            }
        }

        let exported = PGNService.export(study)
        guard let roundtrip = try PGNService.parse(exported).first else { throw Failure("roundtrip failed") }
        try check("nested variation relationships survive PGN roundtrip") {
            ChessNotationFormatter.document(for: roundtrip).plainText == expected
        }
        try check("PGN export preserves the original comment content") {
            roundtrip.root.children.first?.comment == "The main\nchoice."
        }
        print("All horizontal notation checks passed.")
    }

    private static func nodeCount(_ node: MoveNode) -> Int {
        1 + node.children.reduce(0) { $0 + nodeCount($1) }
    }

    private static func check(_ name: String, _ test: () -> Bool) throws {
        guard test() else { throw Failure(name) }
        print("✓ \(name)")
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
