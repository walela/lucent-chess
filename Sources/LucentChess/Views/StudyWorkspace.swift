import AppKit
import SwiftUI

struct StudyWorkspace: View {
    let study: ChessStudy
    @Binding var inspectorTab: RootView.InspectorTab
    let showDashboard: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            GameWorkspaceHeader(study: study, showDashboard: showDashboard)
            Divider()
            HSplitView {
                BoardPane(study: study)
                    .frame(minWidth: 520, idealWidth: 700, maxWidth: .infinity)
                NotationPane(study: study)
                    .frame(minWidth: 290, idealWidth: 340, maxWidth: 400)
                InspectorView(study: study, tab: $inspectorTab)
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 450)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct GameWorkspaceHeader: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var engine: StockfishService
    @ObservedObject var study: ChessStudy
    let showDashboard: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Button(action: showDashboard) {
                Label("Library", systemImage: "square.grid.2x2")
            }
            .buttonStyle(.borderless)
            .help("Back to game library")
            Divider().frame(height: 22)

            VStack(alignment: .leading, spacing: 2) {
                TextField("Game title", text: Binding(
                    get: { study.title },
                    set: { study.title = $0; library.changed() }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: 330)
                Text(study.playerDescription)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer()
            saveStatus
            Button { library.saveSelected() } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            Menu {
                Button("Save") { library.saveSelected() }
                Button("Save As…") { library.saveSelectedAs() }
                if let path = study.filePath {
                    Divider()
                    Text(path)
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)

            Divider().frame(height: 22)
            HStack(spacing: 6) {
                Circle().fill(engine.isAnalysisActive ? Color.green : Color.secondary.opacity(0.45)).frame(width: 7, height: 7)
                Text(engine.state.label).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                engine.toggle(for: study.currentPosition)
            } label: {
                Label(engine.isAnalysisActive ? "Stop" : "Analyze", systemImage: engine.isAnalysisActive ? "stop.fill" : "bolt.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.isAnalysisActive ? .secondary : .orange)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(.ultraThinMaterial)
    }

    private var saveStatus: some View {
        HStack(spacing: 5) {
            Circle().fill(statusColor).frame(width: 6, height: 6)
            Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(study.filePath ?? "This game is recoverable in Lucent but has not been saved as a PGN file.")
    }

    private var statusText: String {
        if study.starterCollectionID != nil, study.hasUnsavedChanges { return "Edited · Save as PGN" }
        if study.starterCollectionID != nil, !study.hasUnsavedChanges { return "Included game" }
        if study.filePath == nil { return "Not yet a PGN" }
        if study.hasUnsavedChanges { return "Edited" }
        return study.fileURL?.lastPathComponent ?? "Saved"
    }

    private var statusColor: Color {
        if study.starterCollectionID != nil, study.hasUnsavedChanges { return .yellow }
        if study.starterCollectionID != nil, !study.hasUnsavedChanges { return .blue }
        if study.filePath == nil { return .orange }
        return study.hasUnsavedChanges ? .yellow : .green
    }
}

private struct BoardPane: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var engine: StockfishService
    @ObservedObject var study: ChessStudy

    var body: some View {
        GeometryReader { proxy in
            let boardSize = max(260, min(proxy.size.width - 30, proxy.size.height - 70))
            VStack(spacing: 0) {
                Spacer(minLength: 12)
                HStack {
                    Spacer(minLength: 12)
                    VStack(spacing: 8) {
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
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.28))
    }

    private func play(_ move: ChessMove) {
        guard study.play(move) != nil else { return }
        library.changed(notation: true)
        engine.updatePosition(study.currentPosition)
    }
}

private struct NotationPane: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject var study: ChessStudy

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("Notation", systemImage: "list.number")
                        .font(.system(.headline, design: .serif, weight: .semibold))
                    Spacer()
                    Text("Ply \(study.currentPly) / \(study.mainLinePlyCount)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.7), in: Capsule())
                }
                playerField("White", text: binding(\.white))
                playerField("Black", text: binding(\.black))
                HStack(spacing: 7) {
                    TextField("Event", text: binding(\.event)).textFieldStyle(.roundedBorder)
                    Picker("Result", selection: binding(\.result, notation: true)) {
                        ForEach(["*", "1-0", "0-1", "1/2-1/2"], id: \.self, content: Text.init)
                    }
                    .labelsHidden().frame(width: 94)
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
        .background(.background.opacity(0.48))
    }

    private func playerField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .tracking(0.55)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            TextField(label, text: text).textFieldStyle(.roundedBorder)
        }
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
        return emphasized ? .orange : .primary.opacity(0.82)
    }

    private func backgroundColor(pressed: Bool) -> Color {
        if !isEnabled { return .primary.opacity(0.025) }
        if pressed { return .orange.opacity(0.20) }
        return emphasized ? .orange.opacity(0.11) : .primary.opacity(0.065)
    }
}

struct MoveTreeView: NSViewRepresentable {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var engine: StockfishService
    @ObservedObject var study: ChessStudy

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
        textView.setAccessibilityLabel("Game notation")
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if context.coordinator.notationRevision != study.notationRevision {
            let rendered = attributedNotation()
            textView.textStorage?.setAttributedString(rendered.text)
            context.coordinator.moveStyles = rendered.moveStyles
            context.coordinator.notationRevision = study.notationRevision
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

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7
        paragraph.paragraphSpacing = 4
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.hyphenationFactor = 0
        let output = NSMutableAttributedString()
        var moveStyles: [UUID: MoveStyle] = [:]
        for token in ChessNotationFormatter.document(for: study).tokens {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(for: token),
                .foregroundColor: color(for: token),
                .paragraphStyle: paragraph
            ]
            if let nodeID = token.nodeID, token.kind == .move || token.kind == .comment {
                attributes[.link] = URL(string: "lucent-move://move/\(nodeID.uuidString)")!
                if token.kind == .move {
                    moveStyles[nodeID] = MoveStyle(
                        range: NSRange(location: output.length, length: (token.text as NSString).length),
                        foregroundColor: attributes[.foregroundColor] as? NSColor ?? .labelColor,
                        font: attributes[.font] as? NSFont ?? .systemFont(ofSize: 14)
                    )
                }
            }
            output.append(NSAttributedString(string: token.text, attributes: attributes))
        }
        return RenderedNotation(text: output, moveStyles: moveStyles)
    }

    private func font(for token: ChessNotationToken) -> NSFont {
        let depth = token.variationDepth
        switch token.kind {
        case .move:
            if depth == 0 { return NSFont.systemFont(ofSize: 14.25, weight: .medium) }
            return NSFont.systemFont(ofSize: max(11.75, 13.15 - CGFloat(depth - 1) * 0.45), weight: .regular)
        case .moveNumber:
            return NSFont.monospacedDigitSystemFont(
                ofSize: depth == 0 ? 11.75 : 11.25,
                weight: depth == 0 ? .medium : .regular
            )
        case .comment:
            let base = NSFont.systemFont(ofSize: depth == 0 ? 12.35 : 11.7)
            return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        case .annotation:
            return NSFont.systemFont(ofSize: 12.25, weight: .semibold)
        case .result:
            return NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        case .punctuation:
            return NSFont.systemFont(ofSize: depth == 0 ? 13.4 : 12.35, weight: .regular)
        }
    }

    private func color(for token: ChessNotationToken) -> NSColor {
        switch token.kind {
        case .move:
            if token.variationDepth >= 2 { return .tertiaryLabelColor }
            if token.variationDepth == 1 { return .secondaryLabelColor }
            return NSColor.labelColor.withAlphaComponent(0.94)
        case .moveNumber:
            return NSColor.secondaryLabelColor.withAlphaComponent(token.variationDepth == 0 ? 0.82 : 0.68)
        case .punctuation:
            return token.variationDepth > 0
                ? NSColor.systemOrange.withAlphaComponent(0.82)
                : NSColor.secondaryLabelColor.withAlphaComponent(0.72)
        case .comment:
            return token.variationDepth == 0
                ? NSColor.systemOrange.withAlphaComponent(0.78)
                : .tertiaryLabelColor
        case .annotation:
            return .systemOrange
        case .result:
            return .systemOrange
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MoveTreeView
        fileprivate weak var textView: NotationTextView?
        var lastSelectedNodeID: UUID?
        var notationRevision: Int?
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

        func updateSelection(to nodeID: UUID) {
            guard lastSelectedNodeID != nodeID, let textView, let storage = textView.textStorage else { return }
            if let previousID = lastSelectedNodeID, let previous = moveStyles[previousID] {
                storage.addAttribute(.foregroundColor, value: previous.foregroundColor, range: previous.range)
                storage.addAttribute(.font, value: previous.font, range: previous.range)
            }
            textView.currentMoveRange = nil
            if let selected = moveStyles[nodeID] {
                storage.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: selected.range)
                storage.addAttribute(
                    .font,
                    value: NSFont.systemFont(ofSize: selected.font.pointSize, weight: .semibold),
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
        NSColor.systemOrange.withAlphaComponent(0.14).setFill()
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
