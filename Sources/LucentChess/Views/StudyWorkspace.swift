import AppKit
import SwiftUI

struct StudyWorkspace: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var training: TrainingSession
    @State private var showsTrainingSetup = false
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var engine: StockfishService
    @EnvironmentObject private var appearance: AppearanceSettings
    let study: ChessStudy
    @Binding var inspectorTab: RootView.InspectorTab
    let showDashboard: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            GameWorkspaceHeader(study: study, inspectorTab: $inspectorTab, showDashboard: showDashboard, playFromHere: { showsTrainingSetup = true })
            Divider()
            WorkspaceSplitView(
                board: AnyView(inject(BoardPane(study: study))),
                notation: AnyView(inject(NotationPane(study: study))),
                inspector: AnyView(inject(InspectorView(study: study, tab: $inspectorTab)))
            )
        }
        .background(colorScheme == .light ? LucentTheme.Surface.workspace : Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showsTrainingSetup) {
            TrainingSetupView(position: study.currentPosition)
                .environmentObject(training).environmentObject(library).environmentObject(engine)
        }
    }

    // Each pane becomes the root of its own NSHostingView, which starts a
    // fresh SwiftUI hierarchy, so the environment objects must be re-injected.
    private func inject(_ view: some View) -> some View {
        view
            .environmentObject(library)
            .environmentObject(engine)
            .environmentObject(appearance)
    }
}

private struct GameWorkspaceHeader: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var engine: StockfishService
    @EnvironmentObject private var appearance: AppearanceSettings
    @ObservedObject var study: ChessStudy
    @Binding var inspectorTab: RootView.InspectorTab
    let showDashboard: () -> Void
    let playFromHere: () -> Void
    @State private var showsEngineSettings = false

    var body: some View {
        HStack(spacing: 16) {
            Button(action: showDashboard) { Image(systemName: "square.grid.2x2") }
                .buttonStyle(.borderless).help("Game library").accessibilityLabel("Game library")
            VStack(alignment: .leading, spacing: 3) {
                TextField("Game title", text: Binding(get: { study.title }, set: { study.title = $0; library.changed() }))
                    .textFieldStyle(.plain).font(.headline)
                Text(study.playerDescription).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width: 210, alignment: .leading)
            Divider().frame(height: 26)
            Menu("Game") {
                Button("New game") { library.newStudy() }
                Divider()
                Button("Save") { library.saveSelected() }
                Button("Save as…") { library.saveSelectedAs() }
                if let path = study.filePath {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                Divider()
                Button("Game library", action: showDashboard)
            }
            Menu("Analysis") {
                Button(engine.isAnalysisActive ? "Stop analysis" : "Analyze position") { engine.toggle(for: study.currentPosition) }
                Button("Engine settings…") { showsEngineSettings = true }
                Divider()
                Button("Play from this position…", action: playFromHere)
            }
            Menu("View") {
                Picker("Inspector", selection: $inspectorTab) {
                    Text("Engine analysis").tag(RootView.InspectorTab.analysis)
                    Text("Game details").tag(RootView.InspectorTab.notes)
                    Text("Board and notation style").tag(RootView.InspectorTab.style)
                }
                Divider()
                Button("Flip board") { appearance.boardFlipped.toggle() }
                Picker("Appearance", selection: $appearance.interfaceAppearanceRaw) {
                    ForEach(InterfaceAppearance.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }
            Spacer(minLength: 12)
            saveStatus
            Button { engine.toggle(for: study.currentPosition) } label: {
                Label(engine.isAnalysisActive ? "Stop analysis" : "Analyze", systemImage: engine.isAnalysisActive ? "stop.fill" : "bolt")
            }.buttonStyle(.bordered)
            Button("Play from here", action: playFromHere)
                .buttonStyle(.borderedProminent).tint(LucentTheme.accent)
                .disabled(study.currentPosition.legalMoves().isEmpty)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showsEngineSettings) { EngineConfigurationView().environmentObject(engine) }
    }

    private var saveStatus: some View {
        HStack(spacing: 5) {
            Circle().fill(statusColor).frame(width: 6, height: 6)
            Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(study.filePath ?? study.sourceURL ?? "This game is recoverable in Lucent but has not been saved as a PGN file.")
    }

    private var statusText: String {
        if study.starterCollectionID != nil, study.hasUnsavedChanges { return "Edited · Save as PGN" }
        if study.starterCollectionID != nil, !study.hasUnsavedChanges { return "Included game" }
        if let source = study.sourceName, study.hasUnsavedChanges { return "Edited · \(source) import" }
        if let source = study.sourceName { return "Imported · \(source)" }
        if study.filePath == nil { return "Not yet a PGN" }
        if study.hasUnsavedChanges { return "Edited" }
        return study.fileURL?.lastPathComponent ?? "Saved"
    }

    private var statusColor: Color {
        if study.starterCollectionID != nil, study.hasUnsavedChanges { return LucentTheme.Status.edited }
        if study.starterCollectionID != nil, !study.hasUnsavedChanges { return LucentTheme.Status.starter }
        if study.sourceName != nil { return study.hasUnsavedChanges ? LucentTheme.Status.edited : LucentTheme.Status.imported }
        if study.filePath == nil { return LucentTheme.Status.unsaved }
        return study.hasUnsavedChanges ? LucentTheme.Status.edited : LucentTheme.Status.saved
    }
}

private struct BoardPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var engine: StockfishService
    @ObservedObject var study: ChessStudy

    var body: some View {
        GeometryReader { proxy in
            let boardSize = max(260, min(proxy.size.width - 30, proxy.size.height - 108))
            VStack(spacing: 0) {
                Spacer(minLength: 12)
                HStack {
                    Spacer(minLength: 12)
                    VStack(spacing: 8) {
                        MaterialBalanceBar(position: study.currentPosition)
                            .frame(width: boardSize)
                        ChessBoardView(
                            position: study.currentPosition,
                            lastMoveUCI: study.currentNode.moveUCI,
                            moveHandler: play
                        )
                        .frame(width: boardSize, height: boardSize)
                        NavigatorBar(study: study)
                            .frame(width: boardSize)
                    }
                    Spacer(minLength: 12)
                }
                Spacer(minLength: 10)
            }
        }
        .background(colorScheme == .light ? LucentTheme.Surface.workspace : Color(nsColor: .controlBackgroundColor).opacity(0.28))
    }

    private func play(_ move: ChessMove) {
        guard study.play(move) != nil else { return }
        library.changed(notation: true)
        engine.updatePosition(study.currentPosition)
    }
}

private struct MaterialBalanceBar: View {
    let position: ChessPosition

    private var balance: MaterialBalance { position.materialBalance }

    var body: some View {
        HStack(spacing: 8) {
            Label("Material", systemImage: "scalemass.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            HStack(spacing: 7) {
                if !balance.whiteExtraPieces.isEmpty {
                    materialPieces(balance.whiteExtraPieces, color: .white)
                }
                if !balance.whiteExtraPieces.isEmpty, !balance.blackExtraPieces.isEmpty {
                    Text("vs")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if !balance.blackExtraPieces.isEmpty {
                    materialPieces(balance.blackExtraPieces, color: .black)
                }
                Text(advantageLabel)
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(balance.score == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.primary.opacity(0.055), in: Capsule())
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.primary.opacity(0.10), lineWidth: 0.75)
        }
        .help(accessibilitySummary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func materialPieces(_ kinds: [PieceKind], color: PieceColor) -> some View {
        HStack(spacing: -3) {
            ForEach(Array(kinds.enumerated()), id: \.offset) { _, kind in
                MaterialPieceIcon(piece: ChessPiece(color: color, kind: kind))
            }
        }
    }

    private var advantageLabel: String {
        if balance.score > 0 { return "White +\(balance.score)" }
        if balance.score < 0 { return "Black +\(-balance.score)" }
        return "Even"
    }

    private var accessibilitySummary: String {
        if balance.score > 0 { return "White is ahead by \(balance.score) material points" }
        if balance.score < 0 { return "Black is ahead by \(-balance.score) material points" }
        return "Material is even"
    }
}

private struct MaterialPieceIcon: View {
    @EnvironmentObject private var appearance: AppearanceSettings
    let piece: ChessPiece

    var body: some View {
        Group {
            if let image = ThemeAssetStore.pieceImage(set: appearance.pieceSet, piece: piece) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Text(piece.unicode)
                    .font(.custom("Apple Symbols", size: 14))
            }
        }
        .frame(width: 16, height: 18)
        .accessibilityHidden(true)
    }
}

private struct NotationPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject var study: ChessStudy

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("Notation", systemImage: "list.number")
                        .font(LucentTheme.Fonts.panelTitle)
                    Spacer()
                    Text("Ply \(study.currentPly) / \(study.mainLinePlyCount)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.7), in: Capsule())
                }

                VStack(spacing: 0) {
                    playerRow(
                        "White",
                        isWhite: true,
                        name: binding(\.white),
                        rating: optionalBinding(\.whiteElo)
                    )
                    Divider().padding(.leading, 42)
                    playerRow(
                        "Black",
                        isWhite: false,
                        name: binding(\.black),
                        rating: optionalBinding(\.blackElo)
                    )
                }
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.primary.opacity(0.09), lineWidth: 0.75)
                }

                HStack(spacing: 7) {
                    HStack(spacing: 7) {
                        Image(systemName: "trophy.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Event", text: binding(\.event))
                            .textFieldStyle(.plain)
                            .font(.callout.weight(.medium))
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(.primary.opacity(0.09), lineWidth: 0.75)
                    }
                    Picker("Result", selection: binding(\.result, notation: true)) {
                        ForEach(["*", "1-0", "0-1", "1/2-1/2"], id: \.self, content: Text.init)
                    }
                    .labelsHidden()
                    .frame(width: 94)
                }
            }
            .padding(12)

            Divider()
            MoveTreeView(study: study)
            Divider()

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label(commentEditorTitle, systemImage: "text.quote")
                        .font(.caption.bold())
                    Text("Shown inline as {…}")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if study.currentNode.id != study.root.id {
                        Menu {
                            Button("Promote variation") { study.promoteCurrentVariation(); library.changed(notation: true) }
                            Button("Delete variation", role: .destructive) { study.deleteCurrentVariation(); library.changed(notation: true) }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                    }
                }
                ZStack(alignment: .topLeading) {
                    if study.currentNode.comment.isEmpty {
                        Text("Add a comment to the PGN…")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: commentBinding)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                }
                .background(.background.opacity(0.52), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.separator.opacity(0.38)))
            }
            .padding(10)
            .frame(height: 126)
            .background(.background.opacity(0.28))
        }
        .background(colorScheme == .light ? AnyShapeStyle(LucentTheme.Surface.panel) : AnyShapeStyle(.background.opacity(0.48)))
    }

    private func playerRow(
        _ label: String,
        isWhite: Bool,
        name: Binding<String>,
        rating: Binding<String>
    ) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(isWhite ? Color.white : Color(nsColor: .labelColor).opacity(0.88))
                .frame(width: 13, height: 13)
                .overlay {
                    Circle().stroke(.primary.opacity(isWhite ? 0.38 : 0.16), lineWidth: 1)
                }
                .shadow(color: .black.opacity(isWhite ? 0.08 : 0), radius: 1, y: 0.5)

            VStack(alignment: .leading, spacing: 1) {
                Text(label.uppercased())
                    .font(LucentTheme.Fonts.microLabel)
                    .tracking(0.65)
                    .foregroundStyle(.secondary)
                TextField("Player", text: name)
                    .textFieldStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }

            Spacer(minLength: 5)

            VStack(alignment: .trailing, spacing: 1) {
                Text("ELO")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.55)
                    .foregroundStyle(.tertiary)
                TextField("—", text: rating)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .rounded, weight: .semibold).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.primary.opacity(rating.wrappedValue.isEmpty ? 0.03 : 0.055), in: Capsule())
                    .overlay {
                        Capsule().stroke(.primary.opacity(rating.wrappedValue.isEmpty ? 0.08 : 0.14), lineWidth: 0.75)
                    }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var commentEditorTitle: String {
        study.currentNode.id == study.root.id
            ? "PGN position comment"
            : "PGN comment after \(study.currentNode.moveSAN ?? "move")"
    }

    private var commentBinding: Binding<String> {
        Binding(
            get: { study.currentNode.comment },
            set: {
                study.currentNode.comment = $0
                library.changed(notation: true)
            }
        )
    }

    private func binding(
        _ keyPath: ReferenceWritableKeyPath<ChessStudy, String>,
        notation: Bool = false
    ) -> Binding<String> {
        Binding(
            get: { study[keyPath: keyPath] },
            set: { study[keyPath: keyPath] = $0; library.changed(notation: notation) }
        )
    }

    private func optionalBinding(
        _ keyPath: ReferenceWritableKeyPath<ChessStudy, String?>
    ) -> Binding<String> {
        Binding(
            get: { study[keyPath: keyPath] ?? "" },
            set: {
                let cleaned = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                study[keyPath: keyPath] = cleaned.isEmpty ? nil : cleaned
                library.changed()
            }
        )
    }
}

private struct NavigatorBar: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var engine: StockfishService
    @EnvironmentObject private var appearance: AppearanceSettings
    @ObservedObject var study: ChessStudy

    var body: some View {
        ZStack {
            HStack(spacing: 7) {
                Spacer()
                Text(study.currentPosition.sideToMove == .white ? "White to move" : "Black to move")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                if study.currentPosition.isKingInCheck(study.currentPosition.sideToMove) {
                    Text("CHECK").font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.red, in: Capsule()).foregroundStyle(.white)
                }
            }

            HStack(spacing: 3) {
                navigationButton("backward.end.fill", help: "First position", disabled: isAtStart) {
                    navigate { $0.goToStart() }
                }
                navigationButton("arrow.left", help: "Previous move", disabled: isAtStart) {
                    navigate { $0.goBack() }
                }
                navigationButton("arrow.triangle.2.circlepath", help: "Flip board", emphasized: true) {
                    appearance.boardFlipped.toggle()
                }
                navigationButton("arrow.right", help: "Next move", disabled: !canAdvance) {
                    navigate { $0.goForward() }
                }
                navigationButton("forward.end.fill", help: "Last main-line move", disabled: !canAdvance) {
                    navigate { $0.goToEnd() }
                }
            }
            .padding(4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.13), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
        }
        .frame(height: 38)
    }

    private var isAtStart: Bool { study.currentNode.id == study.root.id }
    private var canAdvance: Bool { !study.currentNode.children.isEmpty }

    private func navigationButton(
        _ symbol: String,
        help: String,
        disabled: Bool = false,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 27, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(NavigationButtonStyle(emphasized: emphasized))
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private func navigate(_ action: (ChessStudy) -> Void) {
        action(study)
        library.selectionChanged()
        engine.updatePosition(study.currentPosition)
    }
}

private struct NavigationButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var emphasized: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(foregroundColor)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(backgroundColor(pressed: configuration.isPressed))
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        if !isEnabled { return .secondary.opacity(0.3) }
        return emphasized ? LucentTheme.accent : .primary.opacity(0.82)
    }

    private func backgroundColor(pressed: Bool) -> Color {
        if !isEnabled { return .primary.opacity(0.025) }
        if pressed { return LucentTheme.accent.opacity(0.20) }
        return emphasized ? LucentTheme.accent.opacity(0.11) : .primary.opacity(0.065)
    }
}

struct MoveTreeView: NSViewRepresentable {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var engine: StockfishService
    @EnvironmentObject private var appearance: AppearanceSettings
    @ObservedObject var study: ChessStudy

    private var styleSignature: String {
        "\(appearance.figurineSetRaw)|\(appearance.figurineTinted)|\(appearance.notationFontDesignRaw)|\(appearance.notationFontSize)"
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NotationTextView(frame: scrollView.contentView.bounds)
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.linkTextAttributes = [:]
        textView.delegate = context.coordinator
        textView.contextMenuProvider = { [weak coordinator = context.coordinator] nodeID in
            coordinator?.contextMenu(for: nodeID)
        }
        textView.setAccessibilityLabel("Game notation")
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if context.coordinator.notationRevision != study.notationRevision
            || context.coordinator.styleSignature != styleSignature {
            let rendered = attributedNotation()
            textView.textStorage?.setAttributedString(rendered.text)
            context.coordinator.moveStyles = rendered.moveStyles
            context.coordinator.notationRevision = study.notationRevision
            context.coordinator.styleSignature = styleSignature
            context.coordinator.lastSelectedNodeID = nil
            textView.window?.invalidateCursorRects(for: textView)
        }
        context.coordinator.updateSelection(to: study.lastNodeID)
    }

    private func select(_ node: MoveNode) {
        study.select(node)
        library.selectionChanged()
        engine.updatePosition(study.currentPosition)
    }

    private func attributedNotation() -> RenderedNotation {
        if study.root.children.isEmpty {
            return RenderedNotation(
                text: NSAttributedString(
                    string: "Make a move on the board to begin.",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 13),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                ),
                moveStyles: [:]
            )
        }

        let output = NSMutableAttributedString()
        var moveStyles: [UUID: MoveStyle] = [:]
        for token in ChessNotationFormatter.document(for: study, layout: .indented).tokens {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(for: token),
                .foregroundColor: color(for: token),
                .paragraphStyle: paragraphStyle(for: token.variationDepth)
            ]
            if let nodeID = token.nodeID, token.kind == .move || token.kind == .comment {
                attributes[.link] = URL(string: "lucent-move://move/\(nodeID.uuidString)")!
            }
            let rendered: NSAttributedString
            if token.kind == .move {
                rendered = figurineMove(token.text, attributes: attributes)
                if let nodeID = token.nodeID {
                    moveStyles[nodeID] = MoveStyle(
                        range: NSRange(location: output.length, length: rendered.length),
                        foregroundColor: attributes[.foregroundColor] as? NSColor ?? .labelColor,
                        font: attributes[.font] as? NSFont ?? .systemFont(ofSize: 14)
                    )
                }
            } else {
                // Keep move numbers with their move, including after a branch.
                let text = token.kind == .moveNumber ? token.text.replacingOccurrences(of: " ", with: "\u{00a0}") : token.text
                rendered = NSAttributedString(string: text, attributes: attributes)
            }
            output.append(rendered)
        }
        return RenderedNotation(text: output, moveStyles: moveStyles)
    }

    private func paragraphStyle(for depth: Int) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        let scale = CGFloat(appearance.notationFontSize) / 14
        // Cap indentation so deeply nested analysis remains usable in narrow panes.
        let indent = CGFloat(min(depth, 4)) * 18 * scale
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        paragraph.lineSpacing = (depth == 0 ? 6 : 4) * scale
        paragraph.paragraphSpacing = 8 * scale
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.hyphenationFactor = 0
        return paragraph
    }

    /// One SAN move with its piece letters (leading, and after '=' for
    /// promotions) replaced by figurine image attachments. The attachment run
    /// keeps the link and paragraph attributes so figurines stay clickable.
    private func figurineMove(
        _ san: String,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 14)
        let color = attributes[.foregroundColor] as? NSColor ?? .labelColor
        let output = NSMutableAttributedString()
        var pending = ""
        var previous: Character?
        for character in san {
            let isFigurinePosition = previous == nil || previous == "="
            if isFigurinePosition,
               FigurineRenderer.pieceLetters.contains(character),
               let attachment = FigurineRenderer.attachment(
                   for: character,
                   font: font,
                   color: color,
                   set: appearance.figurineSet,
                   tinted: appearance.figurineTinted
               ) {
                if !pending.isEmpty {
                    output.append(NSAttributedString(string: pending, attributes: attributes))
                    pending = ""
                }
                let run = NSMutableAttributedString(attachment: attachment)
                run.addAttributes(attributes, range: NSRange(location: 0, length: run.length))
                output.append(run)
            } else {
                pending.append(character)
            }
            previous = character
        }
        if !pending.isEmpty {
            output.append(NSAttributedString(string: pending, attributes: attributes))
        }
        return output
    }

    /// All notation sizes are expressed relative to a 14 pt main line, then
    /// scaled by the user's chosen size and rendered in their chosen design.
    private func notationFont(
        size: CGFloat,
        weight: NSFont.Weight,
        monospacedDigits: Bool = false,
        italic: Bool = false
    ) -> NSFont {
        let scaled = size * CGFloat(appearance.notationFontSize) / 14
        var font = NSFont.systemFont(ofSize: scaled, weight: weight)
        if let descriptor = font.fontDescriptor.withDesign(appearance.notationFontDesign.nsDesign),
           let designed = NSFont(descriptor: descriptor, size: scaled) {
            font = designed
        }
        if monospacedDigits {
            let descriptor = font.fontDescriptor.addingAttributes([
                .featureSettings: [[
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
                ]]
            ])
            font = NSFont(descriptor: descriptor, size: scaled) ?? font
        }
        if italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    /// Three clearly stepped tiers: main line, first variation, deeper nesting.
    private func moveSize(for depth: Int) -> CGFloat {
        switch depth {
        case 0: return 14
        case 1: return 13
        default: return 12.5
        }
    }

    private func font(for token: ChessNotationToken) -> NSFont {
        let depth = token.variationDepth
        switch token.kind {
        case .move:
            return notationFont(
                size: moveSize(for: depth),
                weight: depth == 0 ? .semibold : .regular
            )
        case .moveNumber:
            return notationFont(
                size: moveSize(for: depth) - 1,
                weight: depth == 0 ? .medium : .regular,
                monospacedDigits: true
            )
        case .comment:
            return notationFont(size: depth == 0 ? 12.35 : 11.25, weight: .regular, italic: true)
        case .annotation:
            return notationFont(size: 12.25, weight: .semibold)
        case .result:
            return notationFont(size: 13.5, weight: .semibold)
        case .punctuation:
            return notationFont(size: moveSize(for: max(depth, 1)), weight: .regular)
        }
    }

    // Indentation and weight carry the hierarchy. Variation moves must remain
    // readable at every depth, in both appearances; tertiary labels are too faint.
    private func color(for token: ChessNotationToken) -> NSColor {
        switch token.kind {
        case .move:
            return token.variationDepth == 0 ? .labelColor : LucentTheme.Notation.variation
        case .moveNumber, .punctuation, .comment:
            return LucentTheme.Notation.secondary
        case .annotation, .result:
            return .labelColor
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MoveTreeView
        fileprivate weak var textView: NotationTextView?
        var lastSelectedNodeID: UUID?
        var notationRevision: Int?
        var styleSignature: String?
        var moveStyles: [UUID: MoveStyle] = [:]

        init(parent: MoveTreeView) { self.parent = parent }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL,
                  url.scheme == "lucent-move",
                  let id = UUID(uuidString: url.lastPathComponent),
                  let node = parent.study.node(withID: id) else { return false }
            parent.select(node)
            return true
        }

        func contextMenu(for nodeID: UUID?) -> NSMenu {
            let menu = NSMenu(title: "Game notation")
            menu.autoenablesItems = false
            func add(_ title: String, action: Selector, node: MoveNode? = nil, enabled: Bool = true) {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = MenuTarget(studyID: parent.study.id, nodeID: node?.id)
                item.isEnabled = enabled
                menu.addItem(item)
            }
            if let nodeID, let node = parent.study.node(withID: nodeID) {
                add("Promote variation", action: #selector(promoteVariation(_:)), node: node,
                    enabled: parent.study.path(to: node).contains { candidate in
                        parent.study.parent(of: candidate.id)?.children.first?.id != candidate.id
                    })
                add("Delete variation", action: #selector(deleteFromMove(_:)), node: node)
                menu.addItem(.separator())
                add("Copy position (FEN)", action: #selector(copyPosition(_:)), node: node)
            }
            add("Copy game (PGN)", action: #selector(copyGame(_:)))
            return menu
        }

        private struct MenuTarget {
            let studyID: UUID
            let nodeID: UUID?
        }

        private func menuNode(_ item: NSMenuItem) -> MoveNode? {
            guard let target = item.representedObject as? MenuTarget,
                  target.studyID == parent.study.id, let id = target.nodeID else { return nil }
            return parent.study.node(withID: id)
        }

        @objc private func promoteVariation(_ item: NSMenuItem) {
            guard let node = menuNode(item) else { return }
            parent.study.select(node)
            parent.study.promoteCurrentVariation()
            parent.library.changed(notation: true)
            parent.engine.updatePosition(parent.study.currentPosition)
        }

        @objc private func deleteFromMove(_ item: NSMenuItem) {
            guard let node = menuNode(item), let window = textView?.window else { return }
            let studyID = parent.study.id
            let nodeID = node.id
            let alert = NSAlert()
            alert.messageText = "Delete variation?"
            alert.informativeText = "This removes the move and all of its continuations, including nested variations."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Delete")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertSecondButtonReturn, let self,
                      self.parent.study.id == studyID,
                      let node = self.parent.study.node(withID: nodeID) else { return }
                self.parent.study.select(node)
                self.parent.study.deleteCurrentVariation()
                self.parent.library.changed(notation: true)
                self.parent.engine.updatePosition(self.parent.study.currentPosition)
            }
        }

        @objc private func copyPosition(_ item: NSMenuItem) {
            guard let node = menuNode(item) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.positionFEN, forType: .string)
        }

        @objc private func copyGame(_ item: NSMenuItem) {
            guard let target = item.representedObject as? MenuTarget,
                  target.studyID == parent.study.id else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(PGNService.export(parent.study), forType: .string)
        }

        // Internal lucent-move:// links are navigation, not destinations; never
        // show their raw URLs as hover tooltips.
        func textView(
            _ textView: NSTextView,
            willDisplayToolTip tooltip: String,
            forCharacterAt characterIndex: Int
        ) -> String? {
            nil
        }

        func updateSelection(to nodeID: UUID) {
            guard lastSelectedNodeID != nodeID, let textView, let storage = textView.textStorage else { return }
            if let previousID = lastSelectedNodeID, let previous = moveStyles[previousID] {
                storage.addAttribute(.foregroundColor, value: previous.foregroundColor, range: previous.range)
                storage.addAttribute(.font, value: previous.font, range: previous.range)
            }
            textView.currentMoveRange = nil
            if let selected = moveStyles[nodeID] {
                storage.addAttribute(.foregroundColor, value: LucentTheme.accentNS, range: selected.range)
                // Embolden by trait so the user's chosen font design survives.
                let boldDescriptor = selected.font.fontDescriptor
                    .withSymbolicTraits(selected.font.fontDescriptor.symbolicTraits.union(.bold))
                storage.addAttribute(
                    .font,
                    value: NSFont(descriptor: boldDescriptor, size: selected.font.pointSize) ?? selected.font,
                    range: selected.range
                )
                textView.currentMoveRange = selected.range
                if let container = textView.textContainer {
                    textView.layoutManager?.ensureLayout(for: container)
                }
                textView.scrollRangeToVisible(selected.range)
            }
            lastSelectedNodeID = nodeID
        }
    }

    struct MoveStyle {
        var range: NSRange
        var foregroundColor: NSColor
        var font: NSFont
    }

    private struct RenderedNotation {
        var text: NSAttributedString
        var moveStyles: [UUID: MoveStyle]
    }
}

private final class NotationTextView: NSTextView {
    var contextMenuProvider: ((UUID?) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?(moveID(at: convert(event.locationInWindow, from: nil)))
    }

    private func moveID(at point: NSPoint) -> UUID? {
        guard let layoutManager, let textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs,
              layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                         in: textContainer).contains(local) else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard character < storage.length,
              let link = storage.attribute(.link, at: character, effectiveRange: nil) as? URL,
              link.scheme == "lucent-move" else { return nil }
        return UUID(uuidString: link.lastPathComponent)
    }

    var currentMoveRange: NSRange? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let range = currentMoveRange {
            drawCurrentMoveHighlight(for: range, dirtyRect: dirtyRect)
        }
        super.draw(dirtyRect)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let storage = textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            for rect in textRects(for: range) {
                addCursorRect(rect, cursor: .pointingHand)
            }
        }
    }

    private func drawCurrentMoveHighlight(for range: NSRange, dirtyRect: NSRect) {
        LucentTheme.accentNS.withAlphaComponent(0.14).setFill()
        for rect in textRects(for: range) {
            let pill = rect.insetBy(dx: -3.5, dy: -1.5)
            guard pill.intersects(dirtyRect) else { continue }
            NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        }
    }

    private func textRects(for characterRange: NSRange) -> [NSRect] {
        guard let layoutManager, let textContainer else { return [] }
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        let origin = textContainerOrigin
        var rects: [NSRect] = []
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: textContainer
        ) { rect, _ in
            rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
        }
        return rects
    }
}
