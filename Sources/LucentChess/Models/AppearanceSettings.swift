import SwiftUI

enum InterfaceAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.stars.fill"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct PieceSetOption: Identifiable, Hashable {
    let id: String
    let name: String
    let monochrome: Bool

    init(_ id: String, _ name: String, monochrome: Bool = false) {
        self.id = id
        self.name = name
        self.monochrome = monochrome
    }

    static let all: [PieceSetOption] = [
        .init("cburnett", "Cburnett"), .init("fritz-inspired", "Fritz-inspired"),
        .init("alpha", "Alpha"),
        .init("anarcandy", "Anarcandy"), .init("caliente", "Caliente"),
        .init("california", "California"), .init("cardinal", "Cardinal"),
        .init("celtic", "Celtic"), .init("chess7", "Chess 7"),
        .init("chessnut", "Chessnut"), .init("companion", "Companion"),
        .init("cooke", "Cooke"), .init("disguised", "Disguised"),
        .init("dubrovny", "Dubrovny"), .init("fantasy", "Fantasy"),
        .init("firi", "Firi"), .init("fresca", "Fresca"),
        .init("gioco", "Gioco"), .init("governor", "Governor"),
        .init("horsey", "Horsey"), .init("icpieces", "IC Pieces"),
        .init("kiwen-suwi", "Kiwen Suwi"), .init("kosal", "Kosal"),
        .init("leipzig", "Leipzig"), .init("letter", "Letter"),
        .init("maestro", "Maestro"), .init("merida", "Merida"),
        .init("monarchy", "Monarchy"), .init("mono", "Mono", monochrome: true),
        .init("mpchess", "MPChess"), .init("papercut", "Papercut"),
        .init("pirouetti", "Pirouetti"), .init("pixel", "Pixel"),
        .init("rhosgfx", "RhosGFX"), .init("shahi-ivory-brown", "Şahî Ivory"),
        .init("shapes", "Shapes"), .init("spatial", "Spatial"),
        .init("staunty", "Staunty"), .init("tatiana", "Tatiana"),
        .init("totoy", "Totoy"), .init("xkcd", "XKCD")
    ]

    static func find(_ id: String) -> PieceSetOption { all.first { $0.id == id } ?? all[0] }
}

struct BoardThemeOption: Identifiable, Hashable {
    let id: String
    let name: String
    let fileName: String?
    let lightHex: String
    let darkHex: String

    init(_ id: String, _ name: String, _ fileName: String? = nil, light: String = "E8D6B4", dark: String = "7A452A") {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.lightHex = light
        self.darkHex = dark
    }

    static let all: [BoardThemeOption] = [
        .init("brown", "Brown", "brown.webp", light: "F0D9B5", dark: "B58863"),
        .init("wood", "Wood", "wood.jpg", light: "D8B27B", dark: "8A5732"),
        .init("wood2", "Wood II", "wood2.jpg", light: "E1C39A", dark: "9A673F"),
        .init("wood3", "Wood III", "wood3.jpg", light: "D6B285", dark: "7C4B2C"),
        .init("wood4", "Wood IV", "wood4.jpg", light: "E3C7A0", dark: "916342"),
        .init("maple", "Maple", "maple.jpg", light: "E9D8B5", dark: "B7885A"),
        .init("maple2", "Maple II", "maple2.jpg", light: "E8CFA4", dark: "A66F43"),
        .init("blue", "Blue", "blue.webp", light: "DEE3E6", dark: "8CA2AD"),
        .init("blue2", "Blue II", "blue2.jpg", light: "D9E4E8", dark: "7295A8"),
        .init("blue3", "Blue III", "blue3.jpg", light: "CAD9DF", dark: "587B90"),
        .init("blue-marble", "Blue Marble", "blue-marble.jpg", light: "D4E1E5", dark: "638696"),
        .init("green", "Green", "green.webp", light: "FFFFDD", dark: "86A666"),
        .init("green-plastic", "Green Plastic", "green-plastic.webp", light: "D7E2C0", dark: "62864D"),
        .init("olive", "Olive", "olive.jpg", light: "E6E3C0", dark: "8C8A55"),
        .init("purple", "Purple", "purple.webp", light: "E5D4E8", dark: "9674A4"),
        .init("purple-diag", "Purple Diagonal", "purple-diag.webp", light: "E3D8EB", dark: "8D68A1"),
        .init("pink-pyramid", "Pink Pyramid", "pink-pyramid.webp", light: "F4D9DF", dark: "C87C91"),
        .init("canvas2", "Canvas", "canvas2.jpg", light: "E2D4B5", dark: "9B805A"),
        .init("leather", "Leather", "leather.jpg", light: "D2B48C", dark: "795034"),
        .init("marble", "Marble", "marble.jpg", light: "E6E7E8", dark: "7B858B"),
        .init("metal", "Metal", "metal.jpg", light: "D0D5D7", dark: "6F797E"),
        .init("grey", "Grey", "grey.jpg", light: "D2D2D2", dark: "888888"),
        .init("ic", "Ice", "ic.webp", light: "E7F0F2", dark: "8BA9B0"),
        .init("ncf", "NCF", "ncf-board.webp", light: "F0D9B5", dark: "B58863"),
        .init("horsey", "Horsey", "horsey.jpg", light: "EEE0C2", dark: "9F7551"),
        .init("custom", "Custom")
    ]

    static func find(_ id: String) -> BoardThemeOption { all.first { $0.id == id } ?? all[0] }
}

final class AppearanceSettings: ObservableObject {
    @Published var interfaceAppearanceRaw: String { didSet { defaults.set(interfaceAppearanceRaw, forKey: "interfaceAppearance") } }
    @Published var boardThemeRaw: String { didSet { defaults.set(boardThemeRaw, forKey: "boardThemeV3") } }
    @Published var pieceSetRaw: String { didSet { defaults.set(pieceSetRaw, forKey: "pieceSetV3") } }
    @Published var showCoordinates: Bool { didSet { defaults.set(showCoordinates, forKey: "showCoordinates") } }
    @Published var showLegalMoves: Bool { didSet { defaults.set(showLegalMoves, forKey: "showLegalMoves") } }
    @Published var boardFlipped: Bool { didSet { defaults.set(boardFlipped, forKey: "boardFlipped") } }
    @Published var pieceScale: Double { didSet { defaults.set(pieceScale, forKey: "pieceScale") } }
    @Published var customLight: String { didSet { defaults.set(customLight, forKey: "customLight") } }
    @Published var customDark: String { didSet { defaults.set(customDark, forKey: "customDark") } }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        interfaceAppearanceRaw = defaults.string(forKey: "interfaceAppearance") ?? InterfaceAppearance.system.rawValue
        boardThemeRaw = defaults.string(forKey: "boardThemeV3") ?? "brown"
        pieceSetRaw = defaults.string(forKey: "pieceSetV3") ?? "cburnett"
        showCoordinates = defaults.object(forKey: "showCoordinates") as? Bool ?? true
        showLegalMoves = defaults.object(forKey: "showLegalMoves") as? Bool ?? true
        boardFlipped = defaults.object(forKey: "boardFlipped") as? Bool ?? false
        pieceScale = defaults.object(forKey: "pieceScale") as? Double ?? 0.84
        customLight = defaults.string(forKey: "customLight") ?? "E8D6B4"
        customDark = defaults.string(forKey: "customDark") ?? "6D432A"
    }

    var boardTheme: BoardThemeOption {
        get { BoardThemeOption.find(boardThemeRaw) }
        set { boardThemeRaw = newValue.id }
    }
    var interfaceAppearance: InterfaceAppearance {
        get { InterfaceAppearance(rawValue: interfaceAppearanceRaw) ?? .system }
        set { interfaceAppearanceRaw = newValue.rawValue }
    }
    var pieceSet: PieceSetOption {
        get { PieceSetOption.find(pieceSetRaw) }
        set { pieceSetRaw = newValue.id }
    }
    var lightSquare: Color { boardTheme.id == "custom" ? Color(hex: customLight) : Color(hex: boardTheme.lightHex) }
    var darkSquare: Color { boardTheme.id == "custom" ? Color(hex: customDark) : Color(hex: boardTheme.darkHex) }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b: Double
        if cleaned.count == 6 {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        } else { r = 1; g = 1; b = 1 }
        self = Color(red: r, green: g, blue: b)
    }
}
