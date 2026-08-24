import AppKit

enum ThemeAssetStore {
    private static let pieceCache = NSCache<NSString, NSImage>()
    private static let boardCache = NSCache<NSString, NSImage>()

    static func pieceImage(set: PieceSetOption, piece: ChessPiece) -> NSImage? {
        let color = piece.color == .white ? "w" : "b"
        let kind: String
        switch piece.kind {
        case .pawn: kind = "P"
        case .knight: kind = "N"
        case .bishop: kind = "B"
        case .rook: kind = "R"
        case .queen: kind = "Q"
        case .king: kind = "K"
        }
        let baseName: String
        if set.id == "disguised" { baseName = color }
        else if set.id == "mono" { baseName = kind }
        else { baseName = color + kind }
        let key = "\(set.id)/\(baseName)" as NSString
        if let cached = pieceCache.object(forKey: key) { return cached }
        for fileExtension in ["svg", "webp", "png"] {
            if let url = resourceURL(
                name: baseName,
                extension: fileExtension,
                subdirectory: "Pieces/\(set.id)"
            ), let image = NSImage(contentsOf: url) {
                pieceCache.setObject(image, forKey: key)
                return image
            }
        }
        return nil
    }

    static func boardImage(theme: BoardThemeOption) -> NSImage? {
        guard let fileName = theme.fileName else { return nil }
        let key = fileName as NSString
        if let cached = boardCache.object(forKey: key) { return cached }
        let fileURL = URL(fileURLWithPath: fileName)
        guard let url = resourceURL(
            name: fileURL.deletingPathExtension().lastPathComponent,
            extension: fileURL.pathExtension,
            subdirectory: "BoardThemes"
        ), let image = NSImage(contentsOf: url) else { return nil }
        boardCache.setObject(image, forKey: key)
        return image
    }

    private static func resourceURL(name: String, extension fileExtension: String, subdirectory: String) -> URL? {
        for bundle in [Bundle.main] + Bundle.allBundles {
            if let url = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: subdirectory) {
                return url
            }
            if let url = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Resources/\(subdirectory)") {
                return url
            }
            if let resources = bundle.resourceURL {
                let direct = resources
                    .appendingPathComponent(subdirectory, isDirectory: true)
                    .appendingPathComponent("\(name).\(fileExtension)")
                if FileManager.default.fileExists(atPath: direct.path) { return direct }
            }
        }
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LucentChess/Resources/\(subdirectory)/\(name).\(fileExtension)")
        return FileManager.default.fileExists(atPath: development.path) ? development : nil
    }
}
