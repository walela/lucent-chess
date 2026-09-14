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
                // One results view outlives position changes: the previous table stays
                // on screen, dimmed, until the next position's data replaces it.
                ReferencePositionResults(query: query, study: study, sortField: $sortField, ascending: $ascending)
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

/// One listed game as a table row, laid out like a database list: player, rating,
/// player, rating, result, event, year.
private struct ReferenceGameRow: Identifiable {
    let game: ChessStudy
    var id: UUID { game.id }
    var white: String { game.white.isEmpty ? "Unknown" : game.white }
    var black: String { game.black.isEmpty ? "Unknown" : game.black }
    var whiteElo: Int { Int(game.whiteElo ?? "") ?? 0 }
    var blackElo: Int { Int(game.blackElo ?? "") ?? 0 }
    var result: String { game.result == "1/2-1/2" ? "½" : game.result == "*" ? "∗" : game.result.replacingOccurrences(of: "-", with: "–") }
    var event: String { game.event.trimmingCharacters(in: .whitespaces) }
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
    @State private var nextCursor: CatalogCursor?
    /// Nothing has been shown yet for any position.
    @State private var loading = true
    /// A newer position is being searched while the previous results stay visible.
    @State private var refreshing = false
    /// The running search has taken long enough that its progress is worth showing.
    @State private var slow = false
    @State private var loadingMore = false
    @State private var message = ""
    @State private var error: String?
    @State private var cancelled = false
    @State private var retry = 0
    @State private var searchTask: Task<Void, Never>?
    @State private var activeSearch: UUID?
    @State private var tree: OpeningTree?
    @State private var treeLoading = false
    @State private var treeTasks: [Task<Void, Never>] = []
    @State private var treeError: String?
    @State private var tableSort: [KeyPathComparator<ReferenceGameRow>]
    /// Recently visited positions, so stepping back and forth is instant.
    @State private var cache: [ReferencePositionQuery: CachedResults] = [:]
    @State private var cacheOrder: [ReferencePositionQuery] = []

    private struct CachedResults { var games: [ChessStudy] = []; var count = 0; var next: CatalogCursor?; var tree: OpeningTree?; var loaded = false }

    init(query: ReferencePositionQuery, study: ChessStudy, sortField: Binding<GameSortField>, ascending: Binding<Bool>) {
        self.query = query
        _study = ObservedObject(wrappedValue: study)
        _sortField = sortField
        _ascending = ascending
        _tableSort = State(initialValue: Self.comparators(for: query.sort, ascending: query.ascending))
    }

    /// The first page. Further pages reuse it with the last cursor.
    private var request: CatalogRequest {
        var request = CatalogRequest()
        request.folder = query.folder
        request.contentRevision = query.version
        request.filter.boardFEN = query.fen
        request.revision = retry
        request.sort = query.sort.rawValue
        request.ascending = query.ascending
        // Library header filters never silently restrict the position browser.
        return request
    }

    private var rows: [ReferenceGameRow] { games.map(ReferenceGameRow.init) }

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
        .onDisappear { activeSearch = nil; searchTask?.cancel(); treeTasks.forEach { $0.cancel() } }
        .onChange(of: query) { _, query in
            // The sort menu and the table header must agree; the view now outlives sort changes.
            let order = Self.comparators(for: query.sort, ascending: query.ascending)
            if !order.isEmpty, order != tableSort { tableSort = order }
        }
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
                if let tree, !treeLoading {
                    Text("\(tree.analysed.formatted()) games")
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                        .help(treeSummary(tree))
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 2)
                if let treeError {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(.orange).help(treeError)
                        .accessibilityLabel("Moves could not be computed: \(treeError)")
                }
                if treeLoading { ProgressView().controlSize(.mini).transition(.opacity) }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            if loading && (error != nil || cancelled) {
                Color.clear
            } else {
                // The previous position's table stays put, dimmed, until its
                // replacement lands; clicks are ignored so a stale row is never played.
                OpeningTreeTable(tree: tree, loading: treeLoading && tree == nil, position: study.currentPosition, play: play)
                    .opacity(treeLoading ? 0.45 : 1)
                    .allowsHitTesting(!treeLoading)
                    .animation(.easeOut(duration: 0.15), value: treeLoading)
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
                        .opacity(refreshing ? 0.45 : 1)
                        .contentTransition(.numericText())
                        .accessibilityLabel("\(count.formatted()) matching games")
                }
                Spacer(minLength: 2)
                if refreshing { ProgressView().controlSize(.mini).transition(.opacity) }
                sortMenu
            }
            .padding(.horizontal, 14).padding(.vertical, 8)

            if loading {
                // Only the very first search has nothing to show. Later positions keep
                // the previous list visible, dimmed, until the new one arrives.
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 24)
                Spacer()
            } else if let error {
                status(error, retry: true)
            } else if cancelled {
                status("Search cancelled.", retry: true)
            } else if games.isEmpty {
                status("No games match this board position.", retry: false)
            } else {
                gamesTable
                    .opacity(refreshing ? 0.45 : 1)
                    .allowsHitTesting(!refreshing)
                    .animation(.easeOut(duration: 0.15), value: refreshing)
            }

            if !loading && !refreshing && error == nil && !cancelled && games.count < count {
                Divider()
                HStack(spacing: 6) {
                    if loadingMore { ProgressView().controlSize(.mini) }
                    Text("\(games.count.formatted()) of \(count.formatted()) loaded")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    if !loadingMore, nextCursor != nil {
                        Button("Load more") { loadMore() }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var gamesTable: some View {
        Table(rows, selection: $selectedGameID, sortOrder: $tableSort) {
            TableColumn("White", value: \.white) { row in
                PlayerCell(name: row.white)
                    // Rows are created lazily; reaching one of the last rows fetches the next page.
                    .onAppear { if games.suffix(40).contains(where: { $0.id == row.id }) { loadMore() } }
            }
            .width(min: 90, ideal: 150)
            TableColumn("Elo", value: \.whiteElo) { row in EloCell(rating: row.whiteElo) }
                .width(min: 38, ideal: 44, max: 52)
                .alignment(.trailing)
            TableColumn("Black", value: \.black) { row in
                PlayerCell(name: row.black)
            }
            .width(min: 90, ideal: 150)
            TableColumn("Elo", value: \.blackElo) { row in EloCell(rating: row.blackElo) }
                .width(min: 38, ideal: 44, max: 52)
                .alignment(.trailing)
            TableColumn("Res", value: \.result) { row in
                Text(row.result)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(row.game.result == "*" ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .width(min: 34, ideal: 38, max: 44)
            .alignment(.center)
            TableColumn("Event", value: \.event) { row in
                Text(row.event.isEmpty ? "—" : row.event)
                    .font(.system(size: 11))
                    .foregroundStyle(row.event.isEmpty ? .tertiary : .secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .help(row.event)
            }
            .width(min: 80, ideal: 140)
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
            if slow && (loading || refreshing) {
                // Preparation of a database is the only search worth narrating; a
                // routine position lookup finishes before this line would appear.
                HStack(spacing: 6) {
                    Text(message.isEmpty ? "Still searching…" : message)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Cancel", action: cancel).buttonStyle(.borderless).font(.system(size: 10))
                }
                .transition(.opacity)
            } else if !loading && error == nil && !cancelled && message.contains("coverage") {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 5) {
                Image(systemName: "checkerboard.rectangle")
                Text("Exact position · Main line")
                Spacer(minLength: 0)
                Image(systemName: "info.circle")
                    .help("Matches pieces and side to move, including transpositions. Castling rights, en passant and move clocks are ignored; variations are excluded. The Moves table counts every game in the database that continues from this position.")
                    .accessibilityLabel("Position matching includes transpositions; castling rights, en passant, move clocks and variations are excluded. The moves table counts every database game continuing from this position.")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.horizontal, 14).padding(.vertical, 9)
        .animation(.easeOut(duration: 0.2), value: slow)
    }

    private func status(_ text: String, retry canRetry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text).font(.callout).foregroundStyle(.secondary)
            if canRetry { Button("Retry search") { cache.removeValue(forKey: query); cacheOrder.removeAll { $0 == query }; retry &+= 1 } }
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
        case .whiteElo: return [KeyPathComparator(\.whiteElo, order: order)]
        case .blackElo: return [KeyPathComparator(\.blackElo, order: order)]
        case .result: return [KeyPathComparator(\.result, order: order)]
        case .event: return [KeyPathComparator(\.event, order: order)]
        case .date: return [KeyPathComparator(\.year, order: order)]
        default: return []
        }
    }

    private static func field(for comparator: KeyPathComparator<ReferenceGameRow>) -> GameSortField? {
        let keyPath: AnyKeyPath = comparator.keyPath
        if keyPath == \ReferenceGameRow.white || keyPath == \ReferenceGameRow.black { return .players }
        if keyPath == \ReferenceGameRow.whiteElo { return .whiteElo }
        if keyPath == \ReferenceGameRow.blackElo { return .blackElo }
        if keyPath == \ReferenceGameRow.result { return .result }
        if keyPath == \ReferenceGameRow.event { return .event }
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
        treeTasks.forEach { $0.cancel() }; treeTasks = []
        loading = false; refreshing = false; slow = false; loadingMore = false; treeLoading = false
        cancelled = true
    }

    private func remember(_ key: ReferencePositionQuery, _ update: (inout CachedResults) -> Void) {
        var entry = cache[key] ?? CachedResults()
        update(&entry)
        if cache.updateValue(entry, forKey: key) == nil {
            cacheOrder.append(key)
            if cacheOrder.count > 64 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        }
    }

    @MainActor private func search() async {
        searchTask?.cancel()
        treeTasks.forEach { $0.cancel() }; treeTasks = []
        let captured = request
        let key = query
        let token = UUID()
        activeSearch = token
        error = nil; cancelled = false; loadingMore = false; treeError = nil; slow = false; message = ""
        let hit = cache[key]
        if let hit, hit.loaded {
            // A position seen moments ago comes straight back; the tree may still be pending.
            games = hit.games; count = hit.count; nextCursor = hit.next; tree = hit.tree
            loading = false; refreshing = false
            treeLoading = hit.tree == nil
            if hit.tree == nil { loadTree(request: captured, key: key, token: token) }
            return
        }
        if loading { games = []; count = 0; nextCursor = nil; tree = nil } else { refreshing = true }
        if let cached = hit?.tree { tree = cached; treeLoading = false } else { treeLoading = true }
        let work = Task { @MainActor in
            do {
                // Scrubbing notation searches the position where the user pauses.
                try await Task.sleep(for: .milliseconds(90))
                let slowTimer = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1500))
                    if !Task.isCancelled, activeSearch == token { slow = true }
                }
                defer { slowTimer.cancel() }
                if hit?.tree == nil { loadTree(request: captured, key: key, token: token) }
                let page = try await library.page(captured) { progress in
                    Task { @MainActor in if activeSearch == token { message = progress } }
                }
                try Task.checkCancellation()
                guard activeSearch == token else { return }
                games = page.games; count = page.count; nextCursor = page.next
                remember(key) { $0.games = page.games; $0.count = page.count; $0.next = page.next; $0.loaded = true }
                loading = false; refreshing = false; slow = false
            } catch is CancellationError { }
            catch {
                guard activeSearch == token else { return }
                self.error = error.localizedDescription
                loading = false; refreshing = false; slow = false
                treeTasks.forEach { $0.cancel() }; treeTasks = []; treeLoading = false
            }
        }
        searchTask = work
        await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    /// Appends the next page in the same order; the list scrolls continuously.
    @MainActor private func loadMore() {
        guard !loading, !refreshing, !loadingMore, error == nil, !cancelled, let cursor = nextCursor, let token = activeSearch else { return }
        loadingMore = true
        var captured = request
        captured.cursor = cursor
        let key = query
        Task { @MainActor in
            do {
                let page = try await library.page(captured)
                guard activeSearch == token else { return }
                let known = Set(games.map(\.id))
                let fresh = page.games.filter { !known.contains($0.id) }
                games += fresh; nextCursor = page.next
                remember(key) { $0.games = games; $0.next = page.next }
                loadingMore = false
            } catch is CancellationError { }
            catch {
                guard activeSearch == token else { return }
                loadingMore = false
                nextCursor = nil
                message = error.localizedDescription
            }
        }
    }

    /// Builds the Moves table over every game in scope, off the main thread. The
    /// imported part is a handful of exact position-index lookups, so it does not
    /// depend on how far the games list has been scrolled.
    @MainActor private func loadTree(request: CatalogRequest, key: ReferencePositionQuery, token: UUID) {
        guard let catalog = library.catalog else { tree = OpeningTree(); treeLoading = false; return }
        treeLoading = true
        let task = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                try LoadedTree(tree: OpeningTreeService.buildFull(catalog: catalog, request: request))
            }
            do {
                let loaded = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard activeSearch == token else { return }
                tree = loaded.tree
                remember(key) { $0.tree = loaded.tree }
            } catch is CancellationError { }
            catch {
                guard activeSearch == token else { return }
                tree = OpeningTree()
                treeError = error.localizedDescription
            }
            guard activeSearch == token else { return }
            treeLoading = false
        }
        treeTasks.append(task)
    }
}

private struct PlayerCell: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1).truncationMode(.tail)
            .help(name)
    }
}

private struct EloCell: View {
    let rating: Int

    var body: some View {
        Text(rating > 0 ? String(rating) : "")
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel(rating > 0 ? "Rating \(rating)" : "Unrated")
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
