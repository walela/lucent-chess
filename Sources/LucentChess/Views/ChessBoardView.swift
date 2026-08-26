import SwiftUI

struct ChessBoardView: View {
    @EnvironmentObject private var appearance: AppearanceSettings
    let position: ChessPosition
    let lastMoveUCI: String?
    let allowsInteraction: Bool
    let showsEngineArrow: Bool
    let showsCoordinates: Bool
    let moveHandler: (ChessMove) -> Void

    @State private var selected: Square?
    @State private var dragging: Square?
    @State private var dragLocation: CGPoint?
    @State private var promotionMoves: [ChessMove] = []

    init(
        position: ChessPosition,
        lastMoveUCI: String?,
        allowsInteraction: Bool = true,
        showsEngineArrow: Bool = true,
        showsCoordinates: Bool = true,
        moveHandler: @escaping (ChessMove) -> Void
    ) {
        self.position = position
        self.lastMoveUCI = lastMoveUCI
        self.allowsInteraction = allowsInteraction
        self.showsEngineArrow = showsEngineArrow
        self.showsCoordinates = showsCoordinates
        self.moveHandler = moveHandler
    }

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let cell = size / 8
            Group {
                if allowsInteraction {
                    boardContents(size: size, cell: cell)
                        .contentShape(Rectangle())
                        .coordinateSpace(name: "chessboard")
                        .highPriorityGesture(boardDragGesture(cell: cell))
                } else {
                    boardContents(size: size, cell: cell)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.16), lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        }
        .aspectRatio(1, contentMode: .fit)
        .confirmationDialog("Promote pawn", isPresented: Binding(
            get: { !promotionMoves.isEmpty },
            set: { if !$0 { promotionMoves = [] } }
        )) {
            ForEach([PieceKind.queen, .rook, .bishop, .knight], id: \.self) { kind in
                Button(kind.rawValue.capitalized) {
                    if let move = promotionMoves.first(where: { $0.promotion == kind }) { moveHandler(move) }
                    promotionMoves = []; selected = nil
                }
            }
        }
    }

    private func boardContents(size: CGFloat, cell: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if let board = ThemeAssetStore.boardImage(theme: appearance.boardTheme) {
                Image(nsImage: board)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .allowsHitTesting(false)
            }
            boardSquares(cell: cell)
            if showsEngineArrow {
                LiveEngineArrow(flipped: appearance.boardFlipped, cell: cell)
            }
            pieces(cell: cell)
            if let dragging, let location = dragLocation, let piece = position[dragging] {
                PieceGlyph(piece: piece, cell: cell, settings: appearance)
                    .position(location)
                    .allowsHitTesting(false)
                    .shadow(color: .black.opacity(0.35), radius: min(6, cell * 0.08), y: min(4, cell * 0.05))
            }
        }
    }

    @ViewBuilder
    private func boardSquares(cell: CGFloat) -> some View {
        let legalTargets = appearance.showLegalMoves ? Set(selected.map { position.legalMoves(from: $0).map(\.to) } ?? []) : []
        let lastMove = lastMoveUCI.flatMap(ChessMove.fromUCI)
        ForEach(0..<64, id: \.self) { displayIndex in
            let col = displayIndex % 8, row = displayIndex / 8
            let square = boardSquare(column: col, row: row)
            let isLight = (square.file + square.rank).isMultiple(of: 2)
            ZStack {
                Rectangle().fill(appearance.boardTheme.fileName == nil ? (isLight ? appearance.lightSquare : appearance.darkSquare) : Color.clear)
                if lastMove?.from == square || lastMove?.to == square { Rectangle().fill(LucentTheme.Board.lastMoveHighlight) }
                if selected == square { Rectangle().fill(Color.accentColor.opacity(0.42)) }
                if legalTargets.contains(square) {
                    if position[square] == nil {
                        Circle().fill(Color.black.opacity(0.28)).frame(width: cell * 0.22)
                    } else {
                        Circle().stroke(Color.black.opacity(0.35), lineWidth: cell * 0.075).padding(cell * 0.07)
                    }
                }
                if showsCoordinates && appearance.showCoordinates {
                    coordinates(for: square, displayColumn: col, displayRow: row, isLight: isLight, cell: cell)
                }
            }
            .frame(width: cell, height: cell)
            .contentShape(Rectangle())
            .position(x: CGFloat(col) * cell + cell / 2, y: CGFloat(row) * cell + cell / 2)
            .onTapGesture { tapped(square) }
        }
    }

    @ViewBuilder
    private func pieces(cell: CGFloat) -> some View {
        ForEach(0..<64, id: \.self) { index in
            let square = Square(index)
            if let piece = position[square] {
                let point = displayPoint(for: square, cell: cell)
                PieceGlyph(piece: piece, cell: cell, settings: appearance)
                    .position(point)
                    .opacity(dragging == square ? 0 : 1)
                    .allowsHitTesting(false)
                    .accessibilityLabel("\(piece.color.rawValue) \(piece.kind.rawValue) on \(square.name)")
            }
        }
    }

    private func coordinates(for square: Square, displayColumn: Int, displayRow: Int, isLight: Bool, cell: CGFloat) -> some View {
        let color = (isLight ? appearance.darkSquare : appearance.lightSquare).opacity(0.85)
        return ZStack {
            if displayColumn == 0 {
                Text(String(square.rank + 1))
                    .position(x: cell * 0.12, y: cell * 0.14)
            }
            if displayRow == 7 {
                Text(String(UnicodeScalar(97 + square.file)!))
                    .position(x: cell * 0.88, y: cell * 0.86)
            }
        }
        .font(.system(size: max(8, cell * 0.14), weight: .bold, design: .rounded))
        .foregroundStyle(color)
    }

    private func tapped(_ square: Square) {
        if let selected, selected != square {
            let legal = position.legalMoves(from: selected).filter { $0.to == square }
            if !legal.isEmpty { complete(legal); return }
        }
        if position[square]?.color == position.sideToMove { selected = selected == square ? nil : square }
        else { selected = nil }
    }

    private func attemptMove(from: Square, to: Square) {
        let legal = position.legalMoves(from: from).filter { $0.to == to }
        if !legal.isEmpty { complete(legal) }
    }

    private func boardDragGesture(cell: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("chessboard"))
            .onChanged { value in
                if dragging == nil {
                    guard let source = squareAt(value.startLocation, cell: cell),
                          position[source]?.color == position.sideToMove else { return }
                    dragging = source
                    selected = source
                }
                guard dragging != nil else { return }
                dragLocation = value.location
            }
            .onEnded { value in
                defer { dragging = nil; dragLocation = nil }
                guard let source = dragging,
                      let target = squareAt(value.location, cell: cell) else { return }
                attemptMove(from: source, to: target)
            }
    }

    private func complete(_ legal: [ChessMove]) {
        if legal.count > 1 { promotionMoves = legal }
        else if let move = legal.first { moveHandler(move); selected = nil }
    }

    private func boardSquare(column: Int, row: Int) -> Square {
        Square(file: appearance.boardFlipped ? 7 - column : column, rank: appearance.boardFlipped ? row : 7 - row)
    }

    private func displayPoint(for square: Square, cell: CGFloat) -> CGPoint {
        let column = appearance.boardFlipped ? 7 - square.file : square.file
        let row = appearance.boardFlipped ? square.rank : 7 - square.rank
        return CGPoint(x: CGFloat(column) * cell + cell / 2, y: CGFloat(row) * cell + cell / 2)
    }

    private func squareAt(_ point: CGPoint, cell: CGFloat) -> Square? {
        let col = Int(point.x / cell), row = Int(point.y / cell)
        guard (0..<8).contains(col), (0..<8).contains(row) else { return nil }
        return boardSquare(column: col, row: row)
    }
}

private struct LiveEngineArrow: View {
    @EnvironmentObject private var engine: StockfishService
    let flipped: Bool
    let cell: CGFloat

    var body: some View {
        EngineTelemetryArrow(telemetry: engine.telemetry, flipped: flipped, cell: cell)
    }
}

private struct EngineTelemetryArrow: View {
    @ObservedObject var telemetry: EngineTelemetry
    let flipped: Bool
    let cell: CGFloat

    var body: some View {
        if let uci = telemetry.snapshot.lines.first?.uciMoves.first,
           let move = ChessMove.fromUCI(uci) {
            EngineArrow(from: move.from, to: move.to, flipped: flipped, cell: cell)
        }
    }
}

private struct PieceGlyph: View {
    let piece: ChessPiece
    let cell: CGFloat
    @ObservedObject var settings: AppearanceSettings

    var body: some View {
        Group {
            if let image = ThemeAssetStore.pieceImage(set: settings.pieceSet, piece: piece) {
                if settings.pieceSet.monochrome {
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: cell * settings.pieceScale, height: cell * settings.pieceScale)
                        .foregroundStyle(piece.color == .white ? .white : .black)
                        .shadow(color: .black.opacity(0.18), radius: min(1.4, cell * 0.016), y: min(1, cell * 0.012))
                } else {
                    vectorImage(image)
                }
            } else {
                Text(piece.unicode)
                    .font(.custom("Apple Symbols", size: cell * settings.pieceScale))
                    .foregroundStyle(piece.color == .white ? Color(red: 0.98, green: 0.96, blue: 0.89) : Color(red: 0.10, green: 0.09, blue: 0.085))
                    .shadow(color: piece.color == .white ? .black.opacity(0.62) : .white.opacity(0.42), radius: 0.7, x: 0, y: 0.7)
            }
        }
        .frame(width: cell, height: cell)
    }

    private func vectorImage(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: cell * settings.pieceScale, height: cell * settings.pieceScale)
            .shadow(color: .black.opacity(0.16), radius: min(1.2, cell * 0.014), y: min(0.9, cell * 0.011))
    }
}

private struct EngineArrow: View {
    let from: Square
    let to: Square
    let flipped: Bool
    let cell: CGFloat

    var body: some View {
        Canvas { context, _ in
            let start = point(from), end = point(to)
            var shaft = Path(); shaft.move(to: start); shaft.addLine(to: end)
            context.stroke(shaft, with: .color(LucentTheme.Board.engineArrowShaft), style: StrokeStyle(lineWidth: cell * 0.12, lineCap: .round))
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length = cell * 0.30
            var head = Path(); head.move(to: end)
            head.addLine(to: CGPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6)))
            head.addLine(to: CGPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6)))
            head.closeSubpath()
            context.fill(head, with: .color(LucentTheme.Board.engineArrowHead))
        }
        .allowsHitTesting(false)
    }

    private func point(_ square: Square) -> CGPoint {
        let col = flipped ? 7 - square.file : square.file
        let row = flipped ? square.rank : 7 - square.rank
        return CGPoint(x: CGFloat(col) * cell + cell / 2, y: CGFloat(row) * cell + cell / 2)
    }
}
