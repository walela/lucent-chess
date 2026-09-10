import AppKit
import SwiftUI

struct PositionSetupView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.colorScheme) private var colorScheme
    @State private var setup = PositionSetup(position: .starting)
    @State private var selectedPiece: ChessPiece? = ChessPiece(color: .white, kind: .king)
    @State private var flipped = false
    @State private var fenText = ChessPosition.startFEN
    @State private var importError: String?

    private let boardSize: CGFloat = 416
    private var hasPendingFEN: Bool {
        fenText.trimmingCharacters(in: .whitespacesAndNewlines) != setup.position.fen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Set up position").font(LucentTheme.Fonts.sectionTitle)
                Text("Choose a piece, then click squares to place it. Click the same piece again to remove it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 14) {
                    editingBoard
                    HStack {
                        Button("Clear board") { replacePosition(ChessPosition()) }
                        Button("Starting position") { replacePosition(.starting) }
                        Spacer()
                        Button { flipped.toggle() } label: { Image(systemName: "arrow.up.arrow.down") }
                            .help("Flip board").accessibilityLabel("Flip setup board")
                    }
                }.frame(width: boardSize)
                VStack(alignment: .leading, spacing: 16) {
                    piecePalette
                    Divider()
                    positionSettings
                }.frame(width: 292)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("FEN").font(.headline)
                    Spacer()
                    Button("Copy FEN") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(setup.position.fen, forType: .string)
                    }
                    Button("Load FEN", action: loadFEN).disabled(!hasPendingFEN)
                }
                TextField("Paste a FEN position", text: $fenText)
                    .font(.system(.callout, design: .monospaced)).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("FEN position")
                    .onChange(of: fenText) { _, _ in importError = nil }
                Text(importError ?? setup.validationError ?? (hasPendingFEN ? "Click Load FEN to apply your pasted position." : "Ready to open as a new game."))
                    .font(.caption)
                    .foregroundStyle(importError != nil || setup.validationError != nil ? Color.red : Color.secondary)
                    .frame(minHeight: 16, alignment: .leading)
            }
            Divider()
            HStack {
                Text("Creates a new game in your library.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Create game", action: createGame)
                    .buttonStyle(.borderedProminent).tint(LucentTheme.accent)
                    .disabled(setup.validationError != nil || hasPendingFEN)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .background(colorScheme == .light ? LucentTheme.Surface.panel : Color(nsColor: .windowBackgroundColor))
        .onAppear {
            replacePosition(library.selectedStudy?.currentPosition ?? .starting)
            flipped = appearance.boardFlipped
        }
        .onChange(of: setup.position) { _, position in
            fenText = position.fen
            importError = nil
        }
    }

    private var editingBoard: some View {
        ChessBoardView(position: setup.position, lastMoveUCI: nil, allowsInteraction: false,
                       showsEngineArrow: false, flipped: flipped, moveHandler: { _ in })
            .accessibilityHidden(true)
            .overlay {
                VStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<8, id: \.self) { column in
                                let square = Square(file: flipped ? 7 - column : column, rank: flipped ? row : 7 - row)
                                Button { setup.place(selectedPiece, on: square) } label: {
                                    Color.clear.frame(width: boardSize / 8, height: boardSize / 8).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(squareLabel(square))
                                .help(squareLabel(square))
                                .contextMenu {
                                    Button("Remove piece") { setup.place(nil, on: square) }
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: boardSize, height: boardSize)
    }

    private var piecePalette: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pieces").font(.headline)
            ForEach(PieceColor.allCases, id: \.self) { color in
                HStack(spacing: 5) {
                    ForEach([PieceKind.king, .queen, .rook, .bishop, .knight, .pawn], id: \.self) { kind in
                        let piece = ChessPiece(color: color, kind: kind)
                        Button { selectedPiece = piece } label: {
                            PieceGlyph(piece: piece, cell: 42, settings: appearance)
                                .background(selectedPiece == piece ? LucentTheme.accent.opacity(0.2) : Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selectedPiece == piece ? LucentTheme.accent : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(color.rawValue.capitalized) \(kind.rawValue)")
                        .accessibilityAddTraits(selectedPiece == piece ? .isSelected : [])
                        .help("\(color.rawValue.capitalized) \(kind.rawValue)")
                    }
                }
            }
            Button { selectedPiece = nil } label: {
                Label("Eraser", systemImage: "eraser")
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(selectedPiece == nil ? LucentTheme.accent.opacity(0.2) : Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selectedPiece == nil ? LucentTheme.accent : .clear, lineWidth: 2))
            }.buttonStyle(.plain).accessibilityAddTraits(selectedPiece == nil ? .isSelected : [])
        }
    }

    private var positionSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Side to move").font(.headline)
            Picker("Side to move", selection: Binding(
                get: { setup.position.sideToMove },
                set: { setup.position.sideToMove = $0; setup.position.enPassantSquare = nil }
            )) {
                Text("White").tag(PieceColor.white)
                Text("Black").tag(PieceColor.black)
            }.pickerStyle(.segmented).labelsHidden()
            Text("Castling rights").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    castleToggle("White O-O", .whiteKing)
                    castleToggle("White O-O-O", .whiteQueen)
                }
                GridRow {
                    castleToggle("Black O-O", .blackKing)
                    castleToggle("Black O-O-O", .blackQueen)
                }
            }
            Picker("En passant", selection: Binding(
                get: { setup.position.enPassantSquare?.name ?? "-" },
                set: { setup.position.enPassantSquare = Square.from($0) }
            )) {
                Text("None").tag("-")
                ForEach(0..<8, id: \.self) { file in
                    let square = Square(file: file, rank: setup.position.sideToMove == .white ? 5 : 2)
                    Text(square.name).tag(square.name)
                }
            }
            HStack {
                Text("Move number")
                Spacer()
                TextField("Move number", value: $setup.position.fullmoveNumber, format: .number.grouping(.never))
                    .frame(width: 76).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Halfmove clock")
                Spacer()
                TextField("Halfmove clock", value: $setup.position.halfmoveClock, format: .number.grouping(.never))
                    .frame(width: 76).textFieldStyle(.roundedBorder)
            }.help("Halfmoves since the last pawn move or capture; used for the fifty-move rule.")
        }
    }

    private func castleToggle(_ title: String, _ right: CastlingRights) -> some View {
        Toggle(title, isOn: Binding(
            get: { setup.position.castlingRights.contains(right) },
            set: { enabled in
                if enabled { setup.position.castlingRights.insert(right) }
                else { setup.position.castlingRights.remove(right) }
            }
        ))
        .toggleStyle(.checkbox).disabled(!setup.availableCastlingRights.contains(right))
    }

    private func squareLabel(_ square: Square) -> String {
        let piece = setup.position[square]
        return "\(square.name), \(piece.map { "\($0.color.rawValue) \($0.kind.rawValue)" } ?? "empty")"
    }

    private func replacePosition(_ position: ChessPosition) {
        setup = PositionSetup(position: position)
        fenText = position.fen
        importError = nil
    }

    private func loadFEN() {
        do { replacePosition(try PositionSetup.parseFEN(fenText)) }
        catch { importError = error.localizedDescription }
    }

    private func createGame() {
        guard setup.validationError == nil, !hasPendingFEN else { return }
        library.newStudy(title: "Custom position", startFEN: setup.position.fen)
        openWindow(id: AppWindowID.game)
        close()
    }

    private func close() { dismissWindow(id: AppWindowID.positionSetup) }
}
