import SwiftUI

struct InspectorView: View {
    @ObservedObject var study: ChessStudy
    @Binding var tab: RootView.InspectorTab

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $tab) {
                ForEach(RootView.InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(12)

            Divider()
            Group {
                switch tab {
                case .analysis: AnalysisInspector(study: study)
                case .notes: NotesInspector(study: study)
                case .style: StyleInspector()
                }
            }
        }
        .background(.ultraThinMaterial)
    }
}

private struct AnalysisInspector: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var engine: StockfishService
    let study: ChessStudy
    @State private var showingEngineConfiguration = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.engineName)
                        .font(.headline)
                    Text(engine.state.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { showingEngineConfiguration = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Configure engine")
                Button {
                    engine.toggle(for: study.currentPosition)
                } label: {
                    Image(systemName: engine.isAnalysisActive ? "stop.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(engine.isAnalysisActive ? Color.primary : Color.white)
                        .frame(width: 40, height: 40)
                        .background(
                            engine.isAnalysisActive ? Color.secondary.opacity(0.18) : LucentTheme.accent,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(.primary.opacity(engine.isAnalysisActive ? 0.10 : 0), lineWidth: 0.75)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(engine.isAnalysisActive ? "Stop engine" : "Analyze this position")
                .accessibilityLabel(engine.isAnalysisActive ? "Stop engine" : "Analyze this position")
            }
            .padding(14)

            Divider()
            EngineTelemetryPanel(
                telemetry: engine.telemetry,
                state: engine.state,
                position: study.currentPosition,
                showWDL: engine.showWDL,
                threads: engine.threads,
                hashMB: engine.hashMB,
                multiPV: engine.multiPV,
                add: add
            )
        }
        .sheet(isPresented: $showingEngineConfiguration) {
            EngineConfigurationView().environmentObject(engine)
        }
    }

    private func add(_ line: EngineLine) {
        for uci in line.uciMoves {
            guard let move = study.currentPosition.legalMove(uci: uci) else { break }
            _ = study.play(move)
        }
        library.changed(notation: true)
        engine.updatePosition(study.currentPosition)
    }
}

private struct EngineTelemetryPanel: View {
    @ObservedObject var telemetry: EngineTelemetry
    let state: StockfishService.State
    let position: ChessPosition
    let showWDL: Bool
    let threads: Int
    let hashMB: Int
    let multiPV: Int
    let add: (EngineLine) -> Void
    @State private var expandedLineID: Int?

    private var snapshot: EngineAnalysisSnapshot { telemetry.snapshot }

    var body: some View {
        if showWDL, let wdl = snapshot.wdl {
            WDLBar(wdl: wdl)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            Divider()
        }
        if snapshot.lines.isEmpty {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: state == .analyzing ? "waveform.path.ecg" : "bolt.circle")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(state == .analyzing ? .green : .secondary)
                Text(state == .analyzing ? "Thinking locally…" : "Start Stockfish for live analysis")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("No position or game data leaves your Mac.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(snapshot.lines) { line in
                        EngineLineRow(
                            line: line,
                            startPosition: position,
                            isExpanded: expandedLineID == line.id,
                            togglePreview: {
                                expandedLineID = expandedLineID == line.id ? nil : line.id
                            },
                            add: { add(line) }
                        )
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .onChange(of: position.fen) { _, _ in expandedLineID = nil }
        }

        Divider()
        VStack(spacing: 5) {
            HStack {
                Label("\(threads) threads", systemImage: "cpu")
                Spacer()
                Text("\(hashMB) MB · \(multiPV) lines")
            }
            if snapshot.currentDepth > 0 {
                HStack {
                    Text("depth \(snapshot.currentDepth) / \(snapshot.selectedDepth)")
                    Spacer()
                    Text("\(compact(snapshot.nodes)) nodes · \(compact(snapshot.nodesPerSecond))/s")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(12)
    }

    private func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }
}

private struct WDLBar: View {
    let wdl: EngineWDL

    var body: some View {
        let total = max(1, wdl.wins + wdl.draws + wdl.losses)
        GeometryReader { geometry in
            HStack(spacing: 1) {
                segment("W \(percent(wdl.wins, total))%", value: wdl.wins, total: total, width: geometry.size.width, color: .green)
                segment("D \(percent(wdl.draws, total))%", value: wdl.draws, total: total, width: geometry.size.width, color: .gray)
                segment("L \(percent(wdl.losses, total))%", value: wdl.losses, total: total, width: geometry.size.width, color: .red.opacity(0.75))
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .frame(height: 22)
        .help("Win / draw / loss estimate for the side to move")
    }

    private func segment(_ text: String, value: Int, total: Int, width: CGFloat, color: Color) -> some View {
        Text(text)
            .font(.caption2.bold()).foregroundStyle(.white)
            .frame(width: max(1, width * CGFloat(value) / CGFloat(total)))
            .frame(maxHeight: .infinity)
            .background(color)
            .clipped()
    }

    private func percent(_ value: Int, _ total: Int) -> Int {
        Int((Double(value) / Double(total) * 100).rounded())
    }
}

struct EngineLineRow: View {
    let line: EngineLine
    let startPosition: ChessPosition
    let isExpanded: Bool
    let togglePreview: () -> Void
    let add: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Button(action: togglePreview) {
                    HStack(alignment: .top, spacing: 9) {
                        Text("\(line.multipv)")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel("Engine line \(line.multipv)")
                        Text(line.score)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 55, alignment: .leading)
                            .foregroundStyle(scoreColor)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(line.moves.joined(separator: " "))
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                            Text("depth \(line.depth) · \(line.uciMoves.count) ply")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 2)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .padding(.top, 5)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Close variation board" : "Preview this variation on its own board")

                Button(action: add) { Image(systemName: "plus.circle") }
                    .buttonStyle(.borderless)
                    .help("Add this entire variation to the study")
                    .padding(.top, 3)
            }
            .padding(14)

            if isExpanded {
                EngineLinePreview(line: line, startPosition: startPosition)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
    }

    private var scoreColor: Color {
        line.score.hasPrefix("+") || line.score.hasPrefix("M") ? .green : .primary
    }
}

private struct EngineLinePreview: View {
    let line: EngineLine
    let startPosition: ChessPosition
    @State private var previewMoves: [String]
    @State private var previewSAN: [String]
    @State private var ply: Int

    init(line: EngineLine, startPosition: ChessPosition) {
        self.line = line
        self.startPosition = startPosition
        _previewMoves = State(initialValue: line.uciMoves)
        _previewSAN = State(initialValue: line.moves)
        _ply = State(initialValue: min(1, line.uciMoves.count))
    }

    var body: some View {
        VStack(spacing: 9) {
            ChessBoardView(
                position: previewPosition,
                lastMoveUCI: currentMove,
                allowsInteraction: false,
                showsEngineArrow: false,
                showsCoordinates: false,
                moveHandler: { _ in }
            )
            .frame(maxWidth: 360)
            .aspectRatio(1, contentMode: .fit)
            .accessibilityLabel("Preview board for engine line \(line.multipv)")

            HStack(spacing: 5) {
                previewButton("backward.end.fill", help: "Start", disabled: ply == 0) { ply = 0 }
                previewButton("chevron.left", help: "Previous move", disabled: ply == 0) { ply -= 1 }
                Text(previewCaption)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 92)
                previewButton("chevron.right", help: "Next move", disabled: ply >= previewMoves.count) { ply += 1 }
                previewButton("forward.end.fill", help: "End", disabled: ply >= previewMoves.count) { ply = previewMoves.count }
            }
            Text("Preview only · the main board is unchanged")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(.background.opacity(0.38), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.separator.opacity(0.35)))
    }

    private var previewPosition: ChessPosition {
        var position = startPosition
        for uci in previewMoves.prefix(ply) {
            guard let move = position.legalMove(uci: uci) else { break }
            position = position.applyingUnchecked(move)
        }
        return position
    }

    private var currentMove: String? {
        ply > 0 && ply <= previewMoves.count ? previewMoves[ply - 1] : nil
    }

    private var previewCaption: String {
        guard ply > 0 else { return "Start" }
        let move = ply <= previewSAN.count ? previewSAN[ply - 1] : "Move"
        return "\(ply)/\(previewMoves.count) · \(move)"
    }

    private func previewButton(
        _ systemName: String,
        help: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName).frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(help)
    }
}

private struct NotesInspector: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject var study: ChessStudy

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Label(study.currentNode.id == study.root.id ? "Starting position" : (study.currentNode.moveSAN ?? "Move"), systemImage: "text.bubble")
                            .font(.headline)
                        TextEditor(text: Binding(
                            get: { study.currentNode.comment },
                            set: { study.currentNode.comment = $0; library.changed(notation: true) }
                        ))
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 145)
                        .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.55)))
                    }

                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Game details").font(.headline)
                        LabeledContent("White") { metadataField(study, keyPath: \.white) }
                        LabeledContent("White Elo") { optionalMetadataField(study, keyPath: \.whiteElo) }
                        LabeledContent("Black") { metadataField(study, keyPath: \.black) }
                        LabeledContent("Black Elo") { optionalMetadataField(study, keyPath: \.blackElo) }
                        LabeledContent("Event") { metadataField(study, keyPath: \.event) }
                        LabeledContent("Site") { optionalMetadataField(study, keyPath: \.site) }
                        LabeledContent("Round") { optionalMetadataField(study, keyPath: \.round) }
                        LabeledContent("ECO") { optionalMetadataField(study, keyPath: \.eco) }
                        LabeledContent("Date") {
                            DatePicker("Date", selection: Binding(
                                get: { study.date }, set: { study.date = $0; library.changed() }
                            ), displayedComponents: .date)
                            .labelsHidden().frame(width: 170)
                        }
                        LabeledContent("Result") {
                            Picker("Result", selection: Binding(
                                get: { study.result }, set: { study.result = $0; library.changed(notation: true) }
                            )) {
                                ForEach(["*", "1-0", "0-1", "1/2-1/2"], id: \.self, content: Text.init)
                            }
                            .labelsHidden().frame(width: 110)
                        }
                        LabeledContent("PGN file") {
                            Text(study.fileURL?.lastPathComponent ?? "Not saved")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 170, alignment: .trailing)
                        }
                    }

                    Divider()
                    Text("FEN").font(.headline)
                    Text(study.currentPosition.fen)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))

                    HStack {
                        Button("Promote variation") { study.promoteCurrentVariation(); library.changed(notation: true) }
                            .disabled(study.currentNode.id == study.root.id)
                        Button("Delete variation", role: .destructive) { study.deleteCurrentVariation(); library.changed(notation: true) }
                            .disabled(study.currentNode.id == study.root.id)
                    }
                }
            }
            .padding(14)
        }
    private func metadataField(_ study: ChessStudy, keyPath: ReferenceWritableKeyPath<ChessStudy, String>) -> some View {
        TextField("", text: Binding(
            get: { study[keyPath: keyPath] },
            set: { study[keyPath: keyPath] = $0; library.changed() }
        ))
        .textFieldStyle(.roundedBorder)
        .frame(width: 170)
    }

    private func optionalMetadataField(_ study: ChessStudy, keyPath: ReferenceWritableKeyPath<ChessStudy, String?>) -> some View {
        TextField("", text: Binding(
            get: { study[keyPath: keyPath] ?? "" },
            set: { study[keyPath: keyPath] = $0.isEmpty ? nil : $0; library.changed() }
        ))
        .textFieldStyle(.roundedBorder)
        .frame(width: 170)
    }
}

private struct StyleInspector: View {
    @EnvironmentObject private var appearance: AppearanceSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Board themes").font(.headline)
                        Spacer()
                        Text("\(BoardThemeOption.all.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
                        spacing: 7
                    ) {
                        ForEach(BoardThemeOption.all) { theme in
                            Button { appearance.boardTheme = theme } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    BoardThemePreview(theme: theme)
                                        .frame(height: 32)
                                        .clipped()
                                    HStack {
                                        Text(theme.name)
                                            .font(.caption2.weight(.medium))
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.72)
                                        Spacer(minLength: 1)
                                        if appearance.boardTheme.id == theme.id {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.caption2)
                                                .foregroundStyle(LucentTheme.accent)
                                        }
                                    }
                                }
                                .padding(4)
                                .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(appearance.boardTheme.id == theme.id ? LucentTheme.accent : Color.clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if appearance.boardTheme.id == "custom" {
                        HStack {
                            ColorPicker("Light", selection: Binding(
                                get: { Color(hex: appearance.customLight) },
                                set: { appearance.customLight = $0.hexString }
                            ))
                            ColorPicker("Dark", selection: Binding(
                                get: { Color(hex: appearance.customDark) },
                                set: { appearance.customDark = $0.hexString }
                            ))
                        }
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Piece sets").font(.headline)
                        Spacer()
                        Text("\(PieceSetOption.all.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(PieceSetOption.all) { set in
                            Button { appearance.pieceSet = set } label: {
                                VStack(spacing: 3) {
                                    PieceSetPreview(set: set)
                                        .frame(height: 54)
                                    Text(set.name)
                                        .font(.caption2.weight(.medium))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.72)
                                }
                                .padding(5)
                                .frame(maxWidth: .infinity)
                                .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(appearance.pieceSet.id == set.id ? LucentTheme.accent : Color.clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        Text("Size")
                        Slider(value: $appearance.pieceScale, in: 0.68...0.96)
                        Text("\(Int(appearance.pieceScale * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Board details").font(.headline)
                    Toggle("Show coordinates", isOn: $appearance.showCoordinates)
                    Toggle("Show legal moves", isOn: $appearance.showLegalMoves)
                    Toggle("Black at the bottom", isOn: $appearance.boardFlipped)
                }
            }
            .padding(14)
        }
    }
}

private struct PieceSetPreview: View {
    let set: PieceSetOption

    var body: some View {
        let knight = ChessPiece(color: .white, kind: .knight)
        Group {
            if let image = ThemeAssetStore.pieceImage(set: set, piece: knight) {
                Image(nsImage: image)
                    .renderingMode(set.monochrome ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(.primary)
            } else {
                Text("♘").font(.system(size: 36))
            }
        }
        .padding(2)
    }
}

private struct BoardThemePreview: View {
    let theme: BoardThemeOption

    var body: some View {
        Group {
            if let image = ThemeAssetStore.boardImage(theme: theme) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else {
                VStack(spacing: 0) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<4, id: \.self) { column in
                                Color(hex: (row + column).isMultiple(of: 2) ? theme.lightHex : theme.darkHex)
                            }
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

extension Color {
    var hexString: String {
        guard let color = NSColor(self).usingColorSpace(.deviceRGB) else { return "FFFFFF" }
        return String(format: "%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }
}
