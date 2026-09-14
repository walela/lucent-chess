import SwiftUI

struct ReferenceFilterInspector: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject var study: ChessStudy
    @AppStorage("referenceCollectionID") private var referenceCollectionID = ""
    @State private var sortField = GameSortField.date
    @State private var ascending = false
    @State private var choosingDatabase = false

    private var selectedFolder: GameFolder? {
        library.folders.first { $0.id.uuidString == referenceCollectionID }
    }

    private var query: ReferencePositionQuery? {
        guard library.folders.contains(where: { $0.id.uuidString == referenceCollectionID }) else { return nil }
        // Clocks and castling changes must not restart an identical board search.
        let board = study.currentPosition.fen.split(separator: " ").prefix(2).joined(separator: " ")
        return ReferencePositionQuery(folder: referenceCollectionID, fen: board + " - - 0 1",
                                      version: library.collectionVersions[referenceCollectionID] ?? "",
                                      sort: sortField, ascending: ascending)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Reference").font(LucentTheme.Fonts.panelTitle)
                Spacer(minLength: 4)
                databaseChooser
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            Divider()
            if let query {
                // A new position owns fresh paging state and cancels the old task.
                ReferencePositionResults(query: query, study: study, sortField: $sortField, ascending: $ascending).id(query)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "books.vertical").font(.title2)
                    Text(library.folders.isEmpty
                         ? "Import a database from the library to find matching games."
                         : "Choose a reference database to see games matching this position.")
                        .multilineTextAlignment(.center)
                }
                .font(.callout).foregroundStyle(.secondary)
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Compact source picker. The database name is the control; the game count
    /// is its tooltip so the row stays one line tall.
    private var databaseChooser: some View {
        Button { choosingDatabase.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(selectedFolder?.name ?? "Choose a database")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9).frame(height: 28)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.primary.opacity(0.09), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 240, alignment: .trailing)
        .popover(isPresented: $choosingDatabase, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Reference database").font(.headline).padding(.horizontal, 8).padding(.top, 8)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(library.folders) { folder in
                            Button {
                                referenceCollectionID = folder.id.uuidString
                                choosingDatabase = false
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "books.vertical").foregroundStyle(.secondary)
                                    Text(folder.name).lineLimit(1)
                                    Spacer(minLength: 2)
                                    Text(library.gameCount(in: folder).formatted())
                                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                                    if folder.id.uuidString == referenceCollectionID {
                                        Image(systemName: "checkmark").foregroundStyle(LucentTheme.accent)
                                    }
                                }.font(.system(size: 12)).padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(ReferenceRowButtonStyle(selected: folder.id.uuidString == referenceCollectionID))
                            .accessibilityAddTraits(folder.id.uuidString == referenceCollectionID ? .isSelected : [])
                        }
                    }
                }.frame(maxHeight: 340)
            }.padding(8).frame(width: 300)
        }
        .accessibilityLabel("Reference database")
        .accessibilityValue(selectedFolder?.name ?? "Choose a database")
        .help(selectedFolder.map { "\(library.gameCount(in: $0).formatted()) games · choose another collection" } ?? "Choose the collection to search")
    }
}

private struct ReferencePositionQuery: Hashable {
    let folder: String
    let fen: String
    let version: String
    let sort: GameSortField
    let ascending: Bool
}

/// One listed game as a table row. Names carry their rating so four columns fit
/// a narrow inspector; rating sorts remain available from the sort menu.
private struct ReferenceGameRow: Identifiable {
    let game: ChessStudy
    var id: UUID { game.id }
    var white: String { game.white.isEmpty ? "Unknown" : game.white }
    var black: String { game.black.isEmpty ? "Unknown" : game.black }
    var result: String { game.result == "1/2-1/2" ? "½" : game.result == "*" ? "∗" : game.result.replacingOccurrences(of: "-", with: "–") }
    var year: Int { Calendar(identifier: .gregorian).component(.year, from: game.date) }
    var moves: Int { (game.mainLinePlyCount + 1) / 2 }
}

// A decoded tree is transferred from its worker to the view once.
private struct LoadedTree: @unchecked Sendable { let tree: OpeningTree }

private struct ReferencePositionResults: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var engine: StockfishService
    @Environment(\.openWindow) private var openWindow
    let query: ReferencePositionQuery
    @ObservedObject var study: ChessStudy
    @Binding var sortField: GameSortField
    @Binding var ascending: Bool
    @State private var selectedGameID: UUID?
    @State private var games: [ChessStudy] = []
    @State private var count = 0
    @State private var cursors: [CatalogCursor?] = [nil]
    @State private var nextCursor: CatalogCursor?
    @State private var loading = true
    @State private var message = "Searching this position…"
    @State private var error: String?
    @State private var cancelled = false
    @State private var retry = 0
    @State private var searchTask: Task<Void, Never>?
    @State private var activeSearch: UUID?
    @State private var tree: OpeningTree?
    @State private var treeLoading = false
    @State private var treeTask: Task<Void, Never>?
    @State private var tableSort: [KeyPathComparator<ReferenceGameRow>]

    init(query: ReferencePositionQuery, study: ChessStudy, sortField: Binding<GameSortField>, ascending: Binding<Bool>) {
        self.query = query
        _study = ObservedObject(wrappedValue: study)
        _sortField = sortField
        _ascending = ascending
        _tableSort = State(initialValue: Self.comparators(for: query.sort, ascending: query.ascending))
    }

    private var request: CatalogRequest {
        var request = CatalogRequest()
        request.folder = query.folder
        request.contentRevision = query.version
        request.filter.boardFEN = query.fen
        request.cursor = cursors.last ?? nil
        request.revision = retry
        request.sort = query.sort.rawValue
        request.ascending = query.ascending
        // Library header filters never silently restrict the position browser.
        return request
    }

    private var rows: [ReferenceGameRow] { games.map(ReferenceGameRow.init) }

    private var pageLabel: String {
        let start = (cursors.count - 1) * DatabaseCatalog.pageSize + 1
        return "\(start.formatted())–\((start + games.count - 1).formatted()) of \(count.formatted())"
    }

    var body: some View {
        VStack(spacing: 0) {
            VSplitView {
                treeSection
                    .frame(minHeight: 120, idealHeight: 210)
                gamesSection
                    .frame(minHeight: 180)
            }
            Divider()
            footer
        }
        .task(id: request) { await search() }
        .onDisappear { activeSearch = nil; searchTask?.cancel(); treeTask?.cancel() }
        .onChange(of: tableSort) { _, order in
            guard let first = order.first, let field = Self.field(for: first) else { return }
            if sortField != field || ascending != (first.order == .forward) {
                sortField = field; ascending = first.order == .forward
            }
        }
        .onChange(of: selectedGameID) { _, id in
            guard let id else { return }
            openWindow(id: AppWindowID.referenceGame, value: ReferenceGameSelection(gameID: id, boardFEN: query.fen))
        }
    }

    // MARK: Sections

    private var treeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text("Moves").font(.system(size: 12, weight: .semibold))
                if let tree, !loading {
                    Text("\(tree.analysed.formatted()) of \(games.count.formatted()) listed")
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                        .help(treeSummary(tree))
                }
                Spacer(minLength: 2)
                if treeLoading { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            if loading || error != nil || cancelled {
                Color.clear
            } else {
                OpeningTreeTable(tree: tree, loading: treeLoading, position: study.currentPosition, play: play)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Continuations from this position")
    }

    private var gamesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text("Games").font(.system(size: 12, weight: .semibold))
                if !loading && error == nil && !cancelled {
                    Text(count.formatted()).font(.system(size: 10, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.primary.opacity(0.055), in: Capsule())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(count.formatted()) matching games")
                }
                Spacer(minLength: 2)
                sortMenu
            }
            .padding(.horizontal, 14).padding(.vertical, 8)

            if loading {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Searching this position…").font(.callout)
                        Spacer(minLength: 0)
                    }
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Button("Cancel search", action: cancel)
                }.padding(.horizontal, 14)
                Spacer()
            } else if let error {
                status(error, retry: true)
            } else if cancelled {
                status("Search cancelled.", retry: true)
            } else if games.isEmpty {
                status("No games match this board position.", retry: false)
            } else {
                gamesTable
            }

            if !loading && count > DatabaseCatalog.pageSize {
                Divider()
                HStack {
                    Button { cursors.removeLast() } label: { Image(systemName: "chevron.left") }
                        .disabled(cursors.count == 1).accessibilityLabel("Previous matching games")
                    Spacer()
                    Text(pageLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button { if let nextCursor { cursors.append(nextCursor) } } label: { Image(systemName: "chevron.right") }
                        .disabled(nextCursor == nil).accessibilityLabel("Next matching games")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14).padding(.vertical, 7)
            }
        }
    }

    private var gamesTable: some View {
        Table(rows, selection: $selectedGameID, sortOrder: $tableSort) {
            TableColumn("White", value: \.white) { row in
                PlayerCell(name: row.white, elo: row.game.whiteElo)
            }
            .width(min: 96)
            TableColumn("Black", value: \.black) { row in
                PlayerCell(name: row.black, elo: row.game.blackElo)
            }
            .width(min: 96)
            TableColumn("Res", value: \.result) { row in
                Text(row.result)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(row.game.result == "*" ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .width(min: 34, ideal: 38, max: 44)
            .alignment(.center)
            TableColumn("Year", value: \.year) { row in
                Text(row.year > 1 ? String(row.year) : "—")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(row.year > 1 ? .primary : .tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 40, ideal: 44, max: 52)
            .alignment(.trailing)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
        .id(cursors.count)
        .accessibilityLabel("Games matching the current board")
    }

    private var sortMenu: some View {
        Menu {
            ForEach(GameSortField.allCases) { field in
                Button {
                    if sortField == field { ascending.toggle() }
                    else { ascending = field.defaultAscending; sortField = field }
                } label: {
                    if sortField == field {
                        Label(field.label, systemImage: ascending ? "arrow.up" : "arrow.down")
                    } else { Text(field.label) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(sortField.label)
                Image(systemName: ascending ? "arrow.up" : "arrow.down")
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Sort matching games by \(sortField.label)")
        .help("Sort matching games; choose the same field to reverse order")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !loading && error == nil && !cancelled && message.contains("coverage") {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 5) {
                Image(systemName: "checkerboard.rectangle")
                Text("Exact position · Main line")
                Spacer(minLength: 0)
                Image(systemName: "info.circle")
                    .help("Matches pieces and side to move, including transpositions. Castling rights, en passant and move clocks are ignored; variations are excluded. The Moves table summarises the games currently listed.")
                    .accessibilityLabel("Position matching includes transpositions; castling rights, en passant, move clocks and variations are excluded. The moves table summarises the listed games.")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.horizontal, 14).padding(.vertical, 9)
    }

    private func status(_ text: String, retry canRetry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text).font(.callout).foregroundStyle(.secondary)
            if canRetry { Button("Retry search") { retry &+= 1 } }
            Spacer()
        }.padding(.horizontal, 14).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func treeSummary(_ tree: OpeningTree) -> String {
        var parts = ["\(tree.analysed.formatted()) games reached this position"]
        if tree.ended > 0 { parts.append("\(tree.ended.formatted()) end here") }
        if tree.unreadable > 0 { parts.append("\(tree.unreadable.formatted()) could not be read") }
        return parts.joined(separator: " · ")
    }

    // MARK: Sorting

    private static func comparators(for field: GameSortField, ascending: Bool) -> [KeyPathComparator<ReferenceGameRow>] {
        let order: SortOrder = ascending ? .forward : .reverse
        switch field {
        case .players: return [KeyPathComparator(\.white, order: order)]
        case .result: return [KeyPathComparator(\.result, order: order)]
        case .date: return [KeyPathComparator(\.year, order: order)]
        default: return []
        }
    }

    private static func field(for comparator: KeyPathComparator<ReferenceGameRow>) -> GameSortField? {
        let keyPath: AnyKeyPath = comparator.keyPath
        if keyPath == \ReferenceGameRow.white || keyPath == \ReferenceGameRow.black { return .players }
        if keyPath == \ReferenceGameRow.result { return .result }
        if keyPath == \ReferenceGameRow.year { return .date }
        return nil
    }

    // MARK: Actions

    private func play(_ row: OpeningTreeRow) {
        guard let move = study.currentPosition.legalMove(uci: row.uci), study.play(move) != nil else { return }
        library.changed(notation: true)
        engine.updatePosition(study.currentPosition)
    }

    private func cancel() {
        activeSearch = nil
        searchTask?.cancel()
        treeTask?.cancel()
        loading = false
        cancelled = true
    }

    @MainActor private func search() async {
        searchTask?.cancel()
        treeTask?.cancel()
        let captured = request
        let token = UUID()
        activeSearch = token
        games = []; count = 0; nextCursor = nil; tree = nil; treeLoading = false
        loading = true; error = nil; cancelled = false
        message = "Preparing the selected database, then finding this position."
        let work = Task { @MainActor in
            do {
                // Scrubbing notation searches the position where the user pauses.
                try await Task.sleep(for: .milliseconds(100))
                let page = try await library.page(captured) { progress in
                    Task { @MainActor in if activeSearch == token { message = progress } }
                }
                try Task.checkCancellation()
                guard activeSearch == token else { return }
                games = page.games; count = page.count; nextCursor = page.next
                loading = false
                buildTree(for: page.games, token: token)
            } catch is CancellationError { }
            catch {
                guard activeSearch == token else { return }
                self.error = error.localizedDescription
                loading = false
            }
        }
        searchTask = work
        await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    @MainActor private func buildTree(for listed: [ChessStudy], token: UUID) {
        guard let catalog = library.catalog, !listed.isEmpty else { tree = OpeningTree(); return }
        treeLoading = true
        let fen = query.fen
        let task = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                try LoadedTree(tree: OpeningTreeService.build(catalog: catalog, games: listed, boardFEN: fen))
            }
            do {
                let loaded = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard activeSearch == token else { return }
                tree = loaded.tree
            } catch is CancellationError { }
            catch {
                guard activeSearch == token else { return }
                tree = OpeningTree()
            }
            if activeSearch == token { treeLoading = false }
        }
        treeTask = task
    }
}

private struct PlayerCell: View {
    let name: String
    let elo: String?

    var body: some View {
        HStack(spacing: 5) {
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1).truncationMode(.tail)
            if let elo {
                Text(elo)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
            }
        }
        .help(elo.map { "\(name) · \($0)" } ?? name)
    }
}

struct ReferenceRowButtonStyle: ButtonStyle {
    let selected: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(selected ? LucentTheme.accent.opacity(0.10)
                        : Color.primary.opacity(configuration.isPressed ? 0.09 : (hovering ? 0.045 : 0)),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 1.5).fill(LucentTheme.accent)
                        .frame(width: 3).padding(.vertical, 10)
                }
            }
            .onHover { hovering = $0 }
    }
}
