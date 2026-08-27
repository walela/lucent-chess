import AppKit
import SwiftUI

/// Renders SAN piece letters as figurines using the bundled Lichess "mono"
/// silhouette set (AGPL, already attributed in the app resources), the same
/// way ChessBase draws its notation. Display-only; PGN keeps standard letters.
enum FigurineRenderer {
    static let pieceLetters: Set<Character> = ["K", "Q", "R", "B", "N"]

    private static var silhouettes: [Character: NSImage] = [:]
    private static var sizedTemplates: [String: NSImage] = [:]

    private static func pieceKind(for letter: Character) -> PieceKind? {
        switch letter {
        case "K": return .king
        case "Q": return .queen
        case "R": return .rook
        case "B": return .bishop
        case "N": return .knight
        default: return nil
        }
    }

    private static func silhouette(for letter: Character) -> NSImage? {
        if let cached = silhouettes[letter] { return cached }
        guard let set = PieceSetOption.all.first(where: { $0.id == "mono" }),
              let kind = pieceKind(for: letter),
              let image = ThemeAssetStore.pieceImage(set: set, piece: ChessPiece(color: .black, kind: kind))
        else { return nil }
        silhouettes[letter] = image
        return image
    }

    // MARK: AppKit (notation text view)

    /// A text attachment for one figurine, tinted with the given color inside
    /// the drawing handler so dynamic colors resolve per appearance at draw
    /// time — the figurine adapts to light and dark mode like the text.
    static func attachment(for letter: Character, font: NSFont, color: NSColor) -> NSTextAttachment? {
        guard let base = silhouette(for: letter) else { return nil }
        let side = font.pointSize * 1.14
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - side) / 2, width: side, height: side)
        return attachment
    }

    // MARK: SwiftUI (engine lines, previews)

    private static func sizedTemplate(for letter: Character, side: CGFloat) -> NSImage? {
        let key = "\(letter)/\(side)"
        if let cached = sizedTemplates[key] { return cached }
        guard let base = silhouette(for: letter) else { return nil }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            base.draw(in: rect)
            return true
        }
        image.isTemplate = true
        sizedTemplates[key] = image
        return image
    }

    /// One SAN move as Text with inline figurine images. Template rendering
    /// picks up the surrounding foreground style in both appearances.
    static func text(for san: String, size: CGFloat) -> Text {
        var result = Text(verbatim: "")
        var previous: Character?
        for character in san {
            let isFigurinePosition = previous == nil || previous == "="
            if isFigurinePosition,
               pieceLetters.contains(character),
               let image = sizedTemplate(for: character, side: size) {
                result = result + Text(Image(nsImage: image)).baselineOffset(-size * 0.16)
            } else {
                result = result + Text(String(character))
            }
            previous = character
        }
        return result
    }

    static func line(_ moves: [String], size: CGFloat) -> Text {
        var result = Text(verbatim: "")
        for (index, move) in moves.enumerated() {
            if index > 0 { result = result + Text(" ") }
            result = result + text(for: move, size: size)
        }
        return result
    }
}
