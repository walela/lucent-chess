import AppKit
import SwiftUI

/// Renders SAN piece letters as figurines using any bundled piece set, the
/// same way ChessBase draws its notation. Display-only; PGN keeps standard
/// letters.
///
/// Two modes: tinted (the piece's alpha silhouette filled with the text color,
/// resolved per appearance so it adapts to light and dark mode) and natural
/// (the black piece artwork drawn as-is, for colorful sets like Fresca
/// Camelot).
enum FigurineRenderer {
    static let pieceLetters: Set<Character> = ["K", "Q", "R", "B", "N"]

    private static var baseImages: [String: NSImage] = [:]
    private static var sizedImages: [String: NSImage] = [:]

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

    private static func baseImage(for letter: Character, set: PieceSetOption) -> NSImage? {
        let key = "\(set.id)/\(letter)"
        if let cached = baseImages[key] { return cached }
        guard let kind = pieceKind(for: letter),
              let image = ThemeAssetStore.pieceImage(set: set, piece: ChessPiece(color: .black, kind: kind))
        else { return nil }
        baseImages[key] = image
        return image
    }

    // MARK: AppKit (notation text view)

    /// A text attachment for one figurine. Tinting happens inside the drawing
    /// handler so dynamic colors resolve per appearance at draw time.
    static func attachment(
        for letter: Character,
        font: NSFont,
        color: NSColor,
        set: PieceSetOption,
        tinted: Bool
    ) -> NSTextAttachment? {
        guard let base = baseImage(for: letter, set: set) else { return nil }
        let side = font.pointSize * 1.14
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            base.draw(in: rect)
            if tinted {
                color.set()
                rect.fill(using: .sourceAtop)
            }
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - side) / 2, width: side, height: side)
        return attachment
    }

    // MARK: SwiftUI (engine lines, previews)

    private static func sizedImage(for letter: Character, side: CGFloat, set: PieceSetOption, tinted: Bool) -> NSImage? {
        let key = "\(set.id)/\(letter)/\(side)/\(tinted)"
        if let cached = sizedImages[key] { return cached }
        guard let base = baseImage(for: letter, set: set) else { return nil }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            base.draw(in: rect)
            return true
        }
        // Template rendering inherits the surrounding foreground style, which
        // is how tinted figurines follow text color in SwiftUI.
        image.isTemplate = tinted
        sizedImages[key] = image
        return image
    }

    /// One SAN move as Text with inline figurine images.
    static func text(for san: String, size: CGFloat, set: PieceSetOption, tinted: Bool) -> Text {
        var result = Text(verbatim: "")
        var previous: Character?
        for character in san {
            let isFigurinePosition = previous == nil || previous == "="
            if isFigurinePosition,
               pieceLetters.contains(character),
               let image = sizedImage(for: character, side: size, set: set, tinted: tinted) {
                result = result + Text(Image(nsImage: image)).baselineOffset(-size * 0.16)
            } else {
                result = result + Text(String(character))
            }
            previous = character
        }
        return result
    }

    static func line(_ moves: [String], size: CGFloat, set: PieceSetOption, tinted: Bool) -> Text {
        var result = Text(verbatim: "")
        for (index, move) in moves.enumerated() {
            if index > 0 { result = result + Text(" ") }
            result = result + text(for: move, size: size, set: set, tinted: tinted)
        }
        return result
    }
}
