import AppKit

@main
struct GenerateFritzInspiredPieces {
    struct Piece {
        let suffix: String
        let symbol: String
        let size: Int
        let baseline: Int
    }

    static let pieces = [
        Piece(suffix: "P", symbol: "♟", size: 75, baseline: 82),
        Piece(suffix: "N", symbol: "♞", size: 80, baseline: 83),
        Piece(suffix: "B", symbol: "♝", size: 79, baseline: 83),
        Piece(suffix: "R", symbol: "♜", size: 78, baseline: 82),
        Piece(suffix: "Q", symbol: "♛", size: 78, baseline: 82),
        Piece(suffix: "K", symbol: "♚", size: 79, baseline: 83)
    ]

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(
                domain: "GenerateFritzInspiredPieces",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Usage: GenerateFritzInspiredPieces output-directory"]
            )
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for color in ["w", "b"] {
            for piece in pieces {
                let image = render(piece: piece, color: color)
                guard let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let data = bitmap.representation(using: .png, properties: [.compressionFactor: 0.92]) else {
                    throw NSError(domain: "GenerateFritzInspiredPieces", code: 2)
                }
                try data.write(to: output.appendingPathComponent("\(color)\(piece.suffix).png"), options: .atomic)
            }
        }
        for url in try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
        where url.pathExtension.lowercased() == "svg" {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func render(piece: Piece, color: String) -> NSImage {
        let isWhite = color == "w"
        let fill = isWhite
            ? NSColor(calibratedRed: 0.98, green: 0.93, blue: 0.79, alpha: 1)
            : NSColor(calibratedWhite: 0.075, alpha: 1)
        let outline = isWhite
            ? NSColor(calibratedWhite: 0.07, alpha: 1)
            : NSColor(calibratedWhite: 0.66, alpha: 1)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(isWhite ? 0.44 : 0.58)
        shadow.shadowBlurRadius = 13
        shadow.shadowOffset = NSSize(width: 0, height: -8)

        var fontSize = CGFloat(piece.size) * 5.35
        var attributes: [NSAttributedString.Key: Any] = [:]
        var bounds = NSRect.zero
        repeat {
            let font = NSFont(name: "Apple Symbols", size: fontSize)
                ?? NSFont.systemFont(ofSize: fontSize, weight: .regular)
            attributes = [
                .font: font,
                .foregroundColor: fill,
                .strokeColor: outline,
                .strokeWidth: isWhite ? -2.2 : -0.85,
                .shadow: shadow
            ]
            bounds = (piece.symbol as NSString).boundingRect(
                with: NSSize(width: 600, height: 600),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes
            )
            fontSize -= 6
        } while (bounds.width > 456 || bounds.height > 456) && fontSize > 260

        let canvas = NSSize(width: 512, height: 512)
        return NSImage(size: canvas, flipped: false) { _ in
            let x = (canvas.width - bounds.width) / 2 - bounds.origin.x
            let y = (canvas.height - bounds.height) / 2 - bounds.origin.y - 4
            (piece.symbol as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
            return true
        }
    }
}
