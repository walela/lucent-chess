import AppKit
import SwiftUI

/// The position tab of a database search mask: three definition boards
/// (Look for, Or, Exclude), piece jokers, mirroring and a move window.
/// Left click places the selected piece, right click the opposite colour,
/// option-click clears a square.
struct PositionSearchMaskView: View {
    enum Board: String, CaseIterable, Identifiable {
        case lookFor = "Look for", either = "Or", exclude = "Exclude"
        var id: String { rawValue }
        var help: String {
            switch self {
            case .lookFor: return "Pieces that must stand on these squares."
            case .either: return "At least one of these placements must hold."
            case .exclude: return "None of these pieces may stand on these squares. Several pieces per square are allowed."
            }
        }
    }

    let initialMask: PositionSearchMask?
    let initialFEN: String
    let currentPositionFEN: String?
    let apply: (PositionSearchMask) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var mask = PositionSearchMask()
    @State private var board: Board = .lookFor
    @State private var selected: MaskPiece? = .whitePawn
    @State private var flipped = false
    @State private var firstText = ""
    @State private var lastText = ""
    @State private var lengthText = "1"
    @State private var error: String?

    private let boardSize: CGFloat = 416

    init(initialMask: PositionSearchMask?, initialFEN: String, currentPositionFEN: String?, apply: @escaping (PositionSearchMask) -> Void) {
        self.initialMask = initialMask; self.initialFEN = initialFEN; self.currentPositionFEN = currentPositionFEN; self.apply = apply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Position search").font(LucentTheme.Fonts.sectionTitle)
                Text("Define a positional fragment. Games match when their main line reaches a position containing it; other squares are ignored.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 10) {
                    boardPicker
                    maskBoard
                    HStack {
                        Button("Copy board", action: copyCurrentBoard).disabled(currentPositionFEN == nil && library.selectedStudy == nil)
                            .help("Transfers the current game position to the Look for board.")
                        Button("Clear \(board.rawValue.lowercased())") { clear(board) }
                        Button("Clear all") { mask = PositionSearchMask() }
                        Spacer()
                        Button { flipped.toggle() } label: { Image(systemName: "arrow.up.arrow.down") }.help("Flip board")
                    }
                }.frame(width: boardSize)
                VStack(alignment: .leading, spacing: 14) {
                    palette
                    Divider()
                    options
                }.frame(width: 300)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(mask.isEmpty ? "Place pieces on the Look for or Or board to define the search." : mask.summary)
                    .font(.callout.monospacedDigit()).foregroundStyle(mask.isEmpty ? .secondary : .primary).lineLimit(2)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }.frame(minHeight: 34, alignment: .topLeading)
            Divider()
            HStack {
                Text(mask.exactFEN != nil ? "Exact positions answer from the prepared index." : "Fragments scan every game in scope once; results are cached.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Search", action: submit).buttonStyle(.borderedProminent).tint(LucentTheme.accent).keyboardShortcut(.defaultAction).disabled(mask.isEmpty)
            }
        }
        .padding(24)
        .background(colorScheme == .light ? LucentTheme.Surface.panel : Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: load)
        .onChange(of: mask) { _, _ in error = nil }
    }

    // MARK: Boards

    private var boardPicker: some View {
        Picker("Board", selection: $board) {
            ForEach(Board.allCases) { kind in
                Text(count(kind) > 0 ? "\(kind.rawValue) (\(count(kind)))" : kind.rawValue).tag(kind)
            }
        }.pickerStyle(.segmented).labelsHidden().help(board.help)
    }

    private func count(_ kind: Board) -> Int {
        switch kind {
        case .lookFor: return mask.lookFor.count
        case .either: return mask.either.values.reduce(0) { $0 + $1.count }
        case .exclude: return mask.exclude.values.reduce(0) { $0 + $1.count }
        }
    }

    private var maskBoard: some View {
        let cell = boardSize / 8
        return ChessBoardView(position: ChessPosition(), lastMoveUCI: nil, allowsInteraction: false,
                              showsEngineArrow: false, flipped: flipped, moveHandler: { _ in })
            .accessibilityHidden(true)
            .overlay {
                VStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<8, id: \.self) { column in
                                let square = Square(file: flipped ? 7 - column : column, rank: flipped ? row : 7 - row)
                                squareContent(square, cell: cell).frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(boardTint, lineWidth: board == .lookFor ? 0 : 3))
            .overlay {
                MaskClickCatcher(flipped: flipped) { square, kind in handle(square, kind) }
            }
            .frame(width: boardSize, height: boardSize)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(board.rawValue) board: \(mask.summary)")
    }

    private var boardTint: Color { board == .either ? .blue.opacity(0.6) : .red.opacity(0.6) }

    @ViewBuilder private func squareContent(_ square: Square, cell: CGFloat) -> some View {
        let pieces = pieces(on: square)
        if pieces.count == 1, let piece = pieces.first {
            MaskPieceGlyph(piece: piece, cell: cell, settings: appearance)
        } else if pieces.count > 1 {
            let half = cell / 2
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    MaskPieceGlyph(piece: pieces[0], cell: half, settings: appearance)
                    if pieces.count > 1 { MaskPieceGlyph(piece: pieces[1], cell: half, settings: appearance) } else { Color.clear.frame(width: half, height: half) }
                }
                HStack(spacing: 0) {
                    if pieces.count > 2 { MaskPieceGlyph(piece: pieces[2], cell: half, settings: appearance) } else { Color.clear.frame(width: half, height: half) }
                    if pieces.count > 3 { MaskPieceGlyph(piece: pieces[3], cell: half, settings: appearance) } else { Color.clear.frame(width: half, height: half) }
                }
            }
        } else {
            Color.clear
        }
    }

    private func pieces(on square: Square) -> [MaskPiece] {
        switch board {
        case .lookFor: return mask.lookFor[square.index].map { [$0] } ?? []
        case .either: return (mask.either[square.index] ?? []).sorted { $0.rawValue < $1.rawValue }
        case .exclude: return (mask.exclude[square.index] ?? []).sorted { $0.rawValue < $1.rawValue }
        }
    }

    private func handle(_ square: Square, _ kind: MaskClickCatcher.Click) {
        guard square.isValid else { return }
        switch kind {
        case .clear: remove(all: square)
        case .primary: place(selected, on: square)
        case .secondary: place(selected?.oppositeColor, on: square)
        }
    }

    private func place(_ piece: MaskPiece?, on square: Square) {
        guard let piece else { remove(all: square); return }
        switch board {
        case .lookFor:
            mask.lookFor[square.index] = mask.lookFor[square.index] == piece ? nil : piece
        case .either:
            toggle(piece, in: &mask.either, square)
        case .exclude:
            toggle(piece, in: &mask.exclude, square)
        }
    }

    private func toggle(_ piece: MaskPiece, in board: inout [Int: Set<MaskPiece>], _ square: Square) {
        var set = board[square.index] ?? []
        if set.contains(piece) { set.remove(piece) } else if set.count < 4 { set.insert(piece) }
        board[square.index] = set.isEmpty ? nil : set
    }

    private func remove(all square: Square) {
        switch board {
        case .lookFor: mask.lookFor[square.index] = nil
        case .either: mask.either[square.index] = nil
        case .exclude: mask.exclude[square.index] = nil
        }
    }

    private func clear(_ kind: Board) {
        switch kind {
        case .lookFor: mask.lookFor = [:]; mask.exactBoard = false
        case .either: mask.either = [:]
        case .exclude: mask.exclude = [:]
        }
    }

    private func copyCurrentBoard() {
        guard let fen = currentPositionFEN ?? library.selectedStudy?.currentPosition.fen, let position = ChessPosition(fen: fen) else { return }
        mask.lookFor = [:]
        for index in 0..<64 { if let piece = position[Square(index)] { mask.lookFor[index] = MaskPiece(piece) } }
        mask.sideToMove = position.sideToMove
        board = .lookFor
    }

    // MARK: Palette

    private var palette: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pieces").font(.headline)
            ForEach(PieceColor.allCases, id: \.self) { color in
                HStack(spacing: 5) {
                    ForEach([PieceKind.king, .queen, .rook, .bishop, .knight, .pawn], id: \.self) { kind in
                        paletteButton(MaskPiece(ChessPiece(color: color, kind: kind)))
                    }
                }
            }
            HStack(spacing: 5) {
                paletteButton(.anyWhite)
                paletteButton(.anyBlack)
                paletteButton(.empty)
                Button { selected = nil } label: {
                    Label("Eraser", systemImage: "eraser").labelStyle(.iconOnly).frame(width: 42, height: 42)
                        .background(selected == nil ? LucentTheme.accent.opacity(0.2) : Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected == nil ? LucentTheme.accent : .clear, lineWidth: 2))
                }.buttonStyle(.plain).help("Eraser: click a square to clear it").accessibilityLabel("Eraser").accessibilityAddTraits(selected == nil ? .isSelected : [])
            }
            Text("Jokers stand for any white or any black man; the empty marker requires a free square. Right-click places the opposite colour; ⌥-click clears a square.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func paletteButton(_ piece: MaskPiece) -> some View {
        Button { selected = piece } label: {
            MaskPieceGlyph(piece: piece, cell: 42, settings: appearance)
                .background(selected == piece ? LucentTheme.accent.opacity(0.2) : Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected == piece ? LucentTheme.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain).help(piece.label).accessibilityLabel(piece.label).accessibilityAddTraits(selected == piece ? .isSelected : [])
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mirror").font(.headline)
            HStack(spacing: 16) {
                Toggle("Horizontal", isOn: $mask.mirrorHorizontal).toggleStyle(.checkbox)
                    .help("Also finds the fragment with ranks and colours reversed (a sacrifice on h7 also finds one on h2).")
                Toggle("Vertical", isOn: $mask.mirrorVertical).toggleStyle(.checkbox)
                    .help("Also finds the fragment reflected between the a and h wings.")
            }
            Text("Side to move").font(.headline)
            Picker("Side to move", selection: $mask.sideToMove) {
                Text("Either").tag(PieceColor?.none)
                Text("White").tag(PieceColor?.some(.white))
                Text("Black").tag(PieceColor?.some(.black))
            }.pickerStyle(.segmented).labelsHidden().disabled(mask.length > 1)
                .help(mask.length > 1 ? "A fragment lasting two or more plies has both sides on move, so the side does not apply." : "Which side must be on move in the matching position.")
            Text("Moves").font(.headline)
            HStack(spacing: 10) {
                field("First", text: $firstText, help: "Ignore the fragment before this move.")
                field("Length", text: $lengthText, help: "Consecutive plies (half-moves) the fragment must stay on the board.")
                field("Last", text: $lastText, help: "Ignore the fragment after this move.")
            }
            Toggle("Exact position — every other square empty", isOn: $mask.exactBoard).toggleStyle(.checkbox)
                .help("Turns the Look for board into a complete position. With a side to move and no mirror or move limits it is answered from the prepared index.")
        }
    }

    private func field(_ title: String, text: Binding<String>, help: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text).textFieldStyle(.roundedBorder).frame(width: 78).multilineTextAlignment(.trailing)
                .onChange(of: text.wrappedValue) { _, _ in syncNumbers() }
        }.help(help)
    }

    private func syncNumbers() {
        mask.firstMove = Int(firstText.trimmingCharacters(in: .whitespaces))
        mask.lastMove = Int(lastText.trimmingCharacters(in: .whitespaces))
        mask.length = Int(lengthText.trimmingCharacters(in: .whitespaces)) ?? 1
    }

    // MARK: Lifecycle

    private func load() {
        flipped = appearance.boardFlipped
        if let initialMask {
            mask = initialMask
        } else if let position = ChessPosition(fen: initialFEN) {
            for index in 0..<64 { if let piece = position[Square(index)] { mask.lookFor[index] = MaskPiece(piece) } }
            mask.sideToMove = position.sideToMove
            mask.exactBoard = true
        }
        firstText = mask.firstMove.map(String.init) ?? ""
        lastText = mask.lastMove.map(String.init) ?? ""
        lengthText = String(mask.length)
    }

    private func submit() {
        syncNumbers()
        for (text, name) in [(firstText, "First"), (lastText, "Last"), (lengthText, "Length")] where !text.trimmingCharacters(in: .whitespaces).isEmpty && Int(text.trimmingCharacters(in: .whitespaces)) == nil {
            error = "\(name) must be a whole number."; return
        }
        do { try mask.validate(); apply(mask); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

/// A search-mask piece: the twelve men from the active piece set, jokers as a
/// question mark on a white or black disc, the empty marker as a dashed ring.
struct MaskPieceGlyph: View {
    let piece: MaskPiece
    let cell: CGFloat
    @ObservedObject var settings: AppearanceSettings

    var body: some View {
        if let chessPiece = piece.piece {
            PieceGlyph(piece: chessPiece, cell: cell, settings: settings)
        } else {
            ZStack {
                switch piece {
                case .anyWhite, .anyBlack:
                    Circle().fill(piece == .anyWhite ? Color.white : Color(white: 0.12))
                        .overlay(Circle().stroke(piece == .anyWhite ? Color(white: 0.25) : Color(white: 0.85), lineWidth: max(1, cell / 32)))
                        .frame(width: cell * 0.62, height: cell * 0.62)
                    Text("?").font(.system(size: cell * 0.4, weight: .bold, design: .rounded))
                        .foregroundStyle(piece == .anyWhite ? Color(white: 0.15) : Color.white)
                default:
                    Circle().stroke(style: StrokeStyle(lineWidth: max(1.5, cell / 24), dash: [cell / 10, cell / 14]))
                        .foregroundStyle(Color.red.opacity(0.85))
                        .frame(width: cell * 0.5, height: cell * 0.5)
                    Image(systemName: "xmark").font(.system(size: cell * 0.24, weight: .bold)).foregroundStyle(Color.red.opacity(0.85))
                }
            }
            .frame(width: cell, height: cell)
        }
    }
}

/// Reports left, right and option clicks on board squares. SwiftUI buttons
/// cannot distinguish the mouse button, and a search mask needs all three.
struct MaskClickCatcher: NSViewRepresentable {
    enum Click { case primary, secondary, clear }
    let flipped: Bool
    let onClick: (Square, Click) -> Void

    func makeNSView(context: Context) -> CatcherView { let view = CatcherView(); update(view); return view }
    func updateNSView(_ view: CatcherView, context: Context) { update(view) }
    private func update(_ view: CatcherView) { view.boardFlipped = flipped; view.onClick = onClick }

    final class CatcherView: NSView {
        var boardFlipped = false
        var onClick: ((Square, Click) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) { report(event, event.modifierFlags.contains(.option) ? .clear : event.modifierFlags.contains(.control) ? .secondary : .primary) }
        override func rightMouseDown(with event: NSEvent) { report(event, event.modifierFlags.contains(.option) ? .clear : .secondary) }
        private func report(_ event: NSEvent, _ click: Click) {
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.width > 0, bounds.height > 0, bounds.contains(point) else { return }
            let column = Int(point.x / (bounds.width / 8)), rowFromTop = Int((bounds.height - point.y) / (bounds.height / 8))
            let square = Square(file: boardFlipped ? 7 - column : column, rank: boardFlipped ? rowFromTop : 7 - rowFromTop)
            onClick?(square, click)
        }
    }
}
