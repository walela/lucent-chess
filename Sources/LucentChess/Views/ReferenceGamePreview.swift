import SwiftUI

struct ReferenceGameSelection: Hashable, Codable {
    let gameID: UUID
    let boardFEN: String
    var mask: PositionSearchMask? = nil
}

struct ReferencePreviewActions {
    let first: () -> Void
    let previous: () -> Void
    let next: () -> Void
    let last: () -> Void
    let flip: () -> Void
}

private struct ReferencePreviewFocusKey: FocusedValueKey { typealias Value = ReferencePreviewActions }
extension FocusedValues {
    var referencePreviewActions: ReferencePreviewActions? {
        get { self[ReferencePreviewFocusKey.self] }
        set { self[ReferencePreviewFocusKey.self] = newValue }
    }
}

// A newly decoded game is exclusively transferred from its worker to this view.
private struct LoadedReferenceGame: @unchecked Sendable { let study: ChessStudy }

struct ReferenceGamePreview: View {
    let selection: ReferenceGameSelection
    @EnvironmentObject private var library: LibraryStore
    @State private var game: ChessStudy?
    @State private var matchedNodeID: UUID?
    @State private var error: String?

    var body: some View {
        Group {
            if let game { ReferencePreviewContent(study: game, matchedNodeID: matchedNodeID).id(selection) }
            else if let error {
                ContentUnavailableView("Could not open game", systemImage: "exclamationmark.triangle", description: Text(error))
            } else { ProgressView("Opening reference game…") }
        }
        .frame(minWidth: 860, minHeight: 620)
        .tint(LucentTheme.accent)
        .task(id: selection) {
            game = nil; error = nil; matchedNodeID = nil
            guard let catalog = library.catalog else { return }
            do {
                let gameID = selection.gameID
                let worker = Task.detached { try LoadedReferenceGame(study: catalog.load(gameID)) }
                let transfer = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                let loaded = transfer.study
                try Task.checkCancellation()
                if let mask = selection.mask {
                    // Jump to the first main-line ply where the fragment holds.
                    var nodes: [MoveNode] = []; var node: MoveNode? = loaded.root
                    while let current = node { nodes.append(current); node = current.children.first }
                    let positions = nodes.map { ChessPosition(fen: $0.positionFEN) ?? ChessPosition() }
                    if let ply = mask.firstMatch(in: positions), ply < nodes.count { loaded.select(nodes[ply]); matchedNodeID = nodes[ply].id }
                } else if let board = try? CatalogFilter.boardKey(selection.boardFEN) {
                    var node: MoveNode? = loaded.root
                    while let current = node {
                        if current.positionFEN.split(separator: " ").prefix(2).joined(separator: " ") == board {
                            loaded.select(current)
                            matchedNodeID = current.id
                            break
                        }
                        node = current.children.first
                    }
                }
                game = loaded
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct ReferencePreviewContent: View {
    @ObservedObject var study: ChessStudy
    let matchedNodeID: UUID?
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @State private var flipped: Bool?
    @State private var analysisError: String?

    private var isAtStart: Bool { study.currentNode.id == study.root.id }
    private var canAdvance: Bool { !study.currentNode.children.isEmpty }
    private var isAtMatch: Bool { study.currentNode.id == matchedNodeID }
    private var result: String { study.result == "1/2-1/2" ? "½–½" : study.result }
    private var positionLabel: String {
        guard !isAtStart, let san = study.currentNode.moveSAN else { return "Starting position" }
        let position = study.currentPosition
        let whiteMoved = position.sideToMove == .black
        let number = whiteMoved ? position.fullmoveNumber : max(1, position.fullmoveNumber - 1)
        return "After \(number)\(whiteMoved ? "." : "…") \(san)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Reference game", systemImage: "books.vertical")
                    .font(LucentTheme.Fonts.panelTitle)
                Spacer()
                if matchedNodeID != nil {
                    Button(action: returnToMatch) {
                        Label("Return to match", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(WorkspaceButtonStyle(quiet: true))
                    .disabled(isAtMatch)
                    .help("Return to the position you searched for")
                }
                Button(action: openForAnalysis) {
                    Label("Open for analysis", systemImage: "arrow.up.right")
                }
                .buttonStyle(WorkspaceButtonStyle(active: true))
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()

            GeometryReader { geometry in
                let notationWidth = min(440, max(320, geometry.size.width * 0.37))
                HStack(spacing: 0) {
                    boardPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    notationPane.frame(width: notationWidth)
                }
            }
        }
        .background(colorScheme == .light ? LucentTheme.Surface.workspace : Color(nsColor: .windowBackgroundColor))
        .alert("Could not open for analysis", isPresented: Binding(
            get: { analysisError != nil }, set: { if !$0 { analysisError = nil } }
        )) {
            Button("OK", role: .cancel) { analysisError = nil }
        } message: { Text(analysisError ?? "") }
        .focusedSceneValue(\.referencePreviewActions, ReferencePreviewActions(
            first: { navigate { $0.goToStart() } },
            previous: { navigate { $0.goBack() } },
            next: { navigate { $0.goForward() } },
            last: { navigate { $0.goToEnd() } },
            flip: flipBoard
        ))
    }

    private var boardPane: some View {
        GeometryReader { geometry in
            let boardSize = max(1, min(geometry.size.width - 40, geometry.size.height - 106))
            VStack(spacing: 14) {
                HStack {
                    Text(positionLabel).font(.system(size: 12, weight: .medium))
                    Spacer()
                    if isAtMatch {
                        Label("Matched position", systemImage: "checkmark.circle")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }
                }.frame(width: boardSize)

                ChessBoardView(position: study.currentPosition, lastMoveUCI: study.currentNode.moveUCI,
                               allowsInteraction: false, showsEngineArrow: false, flipped: flipped, moveHandler: { _ in })
                    .frame(width: boardSize, height: boardSize)

                HStack {
                    Text(study.currentPosition.sideToMove == .white ? "White to move" : "Black to move")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    HStack(spacing: 3) {
                        navigationButton("backward.end.fill", label: "First position", disabled: isAtStart) { navigate { $0.goToStart() } }
                        navigationButton("arrow.left", label: "Previous move", disabled: isAtStart) { navigate { $0.goBack() } }
                        navigationButton("arrow.triangle.2.circlepath", label: "Flip preview board", action: flipBoard)
                        navigationButton("arrow.right", label: "Next move", disabled: !canAdvance) { navigate { $0.goForward() } }
                        navigationButton("forward.end.fill", label: "Last main-line move", disabled: !canAdvance) { navigate { $0.goToEnd() } }
                    }
                    .padding(4)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.09), lineWidth: 1))
                }.frame(width: boardSize)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var notationPane: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Notation", systemImage: "list.number").font(LucentTheme.Fonts.panelTitle)
                    Spacer()
                    Text("Ply \(study.currentPly) / \(study.mainLinePlyCount)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                }
                VStack(spacing: 10) {
                    player(study.white, rating: study.whiteElo, white: true)
                    player(study.black, rating: study.blackElo, white: false)
                }
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(study.event.isEmpty ? "Unknown tournament" : study.event)
                            .font(.system(size: 12, weight: .medium)).lineLimit(2)
                        HStack(spacing: 8) {
                            Text(study.date, format: .dateTime.year())
                            if let round = study.round, !round.isEmpty { Text("Round \(round)").lineLimit(1) }
                            if let eco = study.eco, !eco.isEmpty { Text(eco) }
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text(result).font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
                }
            }.padding(18)
            Divider()
            MoveTreeView(study: study, isReadOnly: true)
            Divider()
            Label("Preview · your working game is unchanged", systemImage: "rectangle.on.rectangle")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }
        .background(colorScheme == .light ? LucentTheme.Surface.panel : Color.primary.opacity(0.015))
    }

    private func player(_ name: String, rating: String?, white: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "circle.fill")
                .foregroundStyle(white ? Color.white : Color(white: 0.22))
                .overlay { Image(systemName: "circle").foregroundStyle(.gray.opacity(0.7)) }
                .font(.system(size: 10)).accessibilityHidden(true)
            Text(name.isEmpty ? "Unknown player" : name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Text(rating ?? "—").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func navigationButton(_ symbol: String, label: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 28, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(NavigationButtonStyle(emphasized: false))
        .disabled(disabled).help(label).accessibilityLabel(label)
    }

    private func navigate(_ action: (ChessStudy) -> Void) {
        action(study)
        study.markSelectionChanged()
    }

    private func returnToMatch() {
        guard let id = matchedNodeID, let node = study.node(withID: id) else { return }
        navigate { $0.select(node) }
    }

    private func flipBoard() { flipped = !(flipped ?? appearance.boardFlipped) }

    private func openForAnalysis() {
        do {
            // The preview remains independent even after opening this game in the workspace.
            let copy = try StudyPersistenceSnapshot(study).makeStudy()
            copy.databaseReference = study.databaseReference
            library.select(copy)
            if let working = library.selectedStudy {
                if let sameNode = working.node(withID: study.currentNode.id) {
                    working.select(sameNode)
                } else {
                    // A previously opened imported game can have different generated move IDs.
                    var stack = [working.root]
                    while let node = stack.popLast() {
                        if node.positionFEN == study.currentNode.positionFEN { working.select(node); break }
                        stack.append(contentsOf: node.children.reversed())
                    }
                }
                library.selectionChanged()
            }
            openWindow(id: AppWindowID.game)
        } catch { analysisError = error.localizedDescription }
    }
}
