import AppKit

@main
struct AssetChecks {
    @MainActor
    static func main() throws {
        var missing: [String] = []
        for set in PieceSetOption.all {
            for color in PieceColor.allCases {
                for kind in PieceKind.allCases {
                    if ThemeAssetStore.pieceImage(set: set, piece: ChessPiece(color: color, kind: kind)) == nil {
                        missing.append("\(set.id)/\(color.rawValue)-\(kind.rawValue)")
                    }
                }
            }
        }
        for theme in BoardThemeOption.all where theme.fileName != nil {
            if ThemeAssetStore.boardImage(theme: theme) == nil { missing.append("board/\(theme.id)") }
        }
        guard missing.isEmpty else {
            throw NSError(domain: "AssetChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing assets: \(missing.joined(separator: ", "))"])
        }
        print("✓ loaded \(PieceSetOption.all.count) piece sets (\(PieceSetOption.all.count * 12) piece variants)")
        print("✓ loaded \(BoardThemeOption.all.filter { $0.fileName != nil }.count) board themes")
    }
}
