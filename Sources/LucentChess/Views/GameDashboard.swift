import AppKit
import SwiftUI

struct GameDashboard: View {
    private enum Selection: Hashable {
        case all, recent, unfiled, folder(UUID)
    }

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.openWindow) private var openWindow
    let collectionID: UUID?
    let referenceMode: Bool
    @AppStorage("referenceCollectionID") private var referenceCollectionID = ""
    @State private var filter = CatalogFilter()
    @State private var showingFilters = false
    @State private var searchProgress = ""
    @State private var searchTask: Task<Void,Never>?
    let openGame: (ChessStudy) -> Void
    let newGame: (UUID?) -> Void
    let importPGN: (UUID?) -> Void
    let importSource: (UUID?) -> Void
    @State private var selection = Selection.all
    @State private var folderEditor: FolderEditor?
    @State private var resultFilter = GameResultFilter.all
    @State private var fileFilter = GameFileFilter.all
    @State private var sortField = GameSortField.date
    @State private var sortAscending = false

    @State private var searchText = ""

    init(collectionID: UUID? = nil, referenceMode: Bool = false, openGame: @escaping (ChessStudy) -> Void, newGame: @escaping (UUID?) -> Void, importPGN: @escaping (UUID?) -> Void, importSource: @escaping (UUID?) -> Void) {
        self.collectionID = collectionID;self.referenceMode=referenceMode
        self.openGame = openGame; self.newGame = newGame
        self.importPGN = importPGN; self.importSource = importSource
        _selection = State(initialValue: collectionID.map(Selection.folder) ?? .all)
    }

    @State private var displayedGames: [ChessStudy] = []
    @State private var displayedCount = 0
    @State private var pageCursors: [CatalogCursor?] = [nil]
    @State private var nextCursor: CatalogCursor?
    @State private var loadingPage = false
    @State private var searchAttempt = 0

    private var request: CatalogRequest {
        var value = CatalogRequest()
        value.revision = (selectedFolderID == nil ? library.catalogRevision : 0) &+ searchAttempt
        value.contentRevision = selectedFolderID.flatMap {library.collectionVersions[$0.uuidString]} ?? ""
        value.folder = selectedFolderID?.uuidString
        value.unfiled = selection == .unfiled
        value.recent = selection == .recent
        value.search = searchText
        value.filter = filter
        value.result = resultFilter.rawValue; value.file = fileFilter.rawValue
        value.sort = sortField.rawValue; value.ascending = sortAscending
        value.cursor = pageCursors.last ?? nil
        return value
    }

    private var query: GameLibraryQuery {
        GameLibraryQuery(result: resultFilter, file: fileFilter, sort: sortField, ascending: sortAscending)
    }

    private var selectedFolderID: UUID? {
        if case let .folder(id) = selection { return id }
        return nil
    }

    private var sectionTitle: String {
        switch selection {
        case .all: return "All games"
        case .recent: return "Recently edited"
        case .unfiled: return "Unfiled"
        case let .folder(id): return library.folders.first(where: { $0.id == id })?.name ?? "Folder"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            dashboardToolbar
            if library.isOpeningGame { ProgressView("Opening game…").controlSize(.small).padding(6) }
            Divider()
            if collectionID != nil || referenceMode {
                librarySection(displayedGames).padding(20)
            } else {
                HSplitView {
                    librarySidebar
                    VSplitView {
                        collectionBrowser
                            .frame(minHeight: 210, idealHeight: 340, maxHeight: .infinity)
                        librarySection(displayedGames)
                            .padding(20)
                            .frame(minHeight: 300, maxHeight: .infinity)
                    }
                    .frame(minWidth: 680)
                }
            }
        }
        .background(
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LucentTheme.dashboardWash
            }
        )
        .task(id: request) {
            searchTask?.cancel()
            if referenceMode && selectedFolderID == nil { displayedGames=[];displayedCount=0;loadingPage=false;nextCursor=nil;searchProgress="Choose a reference collection to begin.";return }
            let captured=request
            let task = Task { @MainActor in
                loadingPage=true;searchProgress="";displayedGames=[];displayedCount=0;nextCursor=nil
                do {
                    if !captured.search.isEmpty { try await Task.sleep(for:.milliseconds(180)) }
                    let page=try await library.page(captured) { message in
                        Task { @MainActor in if request == captured { searchProgress=message } }
                    }
                    try Task.checkCancellation()
                    displayedGames=page.games;displayedCount=page.count;nextCursor=page.next;loadingPage=false
                } catch is CancellationError { }
                catch { library.lastError=error.localizedDescription;loadingPage=false }
            }
            searchTask=task
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        }
        .onAppear {
            if referenceMode {
                selection=UUID(uuidString:referenceCollectionID).map(Selection.folder) ?? .all
                filter=library.referenceFilter
                resultFilter=GameResultFilter(rawValue:library.referenceResult) ?? .all
            }
        }
        .onChange(of: referenceCollectionID) { _, value in
            if referenceMode { selection=UUID(uuidString:value).map(Selection.folder) ?? .all;pageCursors=[nil] }
        }
        .onChange(of: library.referenceSearchRevision) { _, _ in
            if referenceMode { filter=library.referenceFilter;resultFilter=GameResultFilter(rawValue:library.referenceResult) ?? .all;pageCursors=[nil];searchAttempt &+= 1 }
        }
        .sheet(isPresented:$showingFilters) {
            DatabaseFilterView(filter:filter,result:resultFilter.rawValue) { value,result in
                filter=value;resultFilter=GameResultFilter(rawValue:result) ?? .all;pageCursors=[nil]
            }
        }
        .onChange(of: selection) { _, _ in pageCursors = [nil] }
        .onChange(of: searchText) { _, _ in pageCursors = [nil] }
        .onChange(of: resultFilter) { _, _ in
            pageCursors = [nil]
            if referenceMode { library.referenceResult=resultFilter.rawValue }
        }
        .onChange(of: filter) { _, value in
            if referenceMode { library.referenceFilter=value;library.referencePositionFEN=value.boardFEN }
        }
        .onChange(of: fileFilter) { _, _ in pageCursors = [nil] }
        .onChange(of: sortField) { _, _ in pageCursors = [nil] }
        .onChange(of: sortAscending) { _, _ in pageCursors = [nil] }
        .onChange(of: library.lastImportedFolderID) { _, id in
            guard collectionID == nil && !referenceMode else { return }
            if let id { selectCollection(.folder(id)); pageCursors = [nil] }
        }
        .sheet(item: $folderEditor) { editor in
            FolderEditorSheet(editor: editor) { name in
                if let folder = editor.folder {
                    library.renameFolder(folder, to: name)
                } else if let folder = library.createFolder(name: name) {
                    selection = .folder(folder.id)
                }
            }
        }
    }

    private func selectCollection(_ value: Selection) {
        if case let .folder(id) = value,
           let folder = library.folders.first(where: { $0.id == id }),
           library.gameCount(in: folder) > 100 {
            openWindow(id: AppWindowID.collection, value: id)
        } else { selection = value }
    }

    private var dashboardToolbar: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("LUCENT").font(LucentTheme.Fonts.wordmark).tracking(2.2)
                HStack(spacing: 5) {
                    Circle().fill(LucentTheme.Status.saved).frame(width: 5, height: 5)
                    Text("OFFLINE CHESS ARCHIVE")
                        .font(LucentTheme.Fonts.microLabel)
                        .tracking(0.65)
                        .foregroundStyle(.secondary)
                }
            }
            if collectionID != nil || referenceMode {
                Button { openWindow(id: AppWindowID.library) } label: {
                    Label("Library", systemImage: "square.grid.2x2")
                }.help("Return to the library")
            }
            Divider().frame(height: 28).padding(.leading, 4)
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search players, events, or games", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear Search")
                    .accessibilityLabel("Clear Search")
                }
            }
            .padding(.horizontal, 11)
            .frame(width: 320, height: 34)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
            appearanceSwitcher
            if !referenceMode {
                Menu {
                    Button("Open Reference Database") {library.requestReferencePosition("");openWindow(id:AppWindowID.reference)}
                    Divider()
                    ForEach(library.folders) { folder in
                        Button { referenceCollectionID=folder.id.uuidString;library.requestReferencePosition("");openWindow(id:AppWindowID.reference) } label: {
                            Label(folder.name,systemImage:referenceCollectionID==folder.id.uuidString ? "checkmark" : "folder")
                        }
                    }
                } label: {Label("Reference",systemImage:"books.vertical")}
            }
            Menu {
                Button { importSource(selectedFolderID) } label: {
                    Label("TWIC or Lichess…", systemImage: "network")
                }
                Button { importPGN(selectedFolderID) } label: {
                    Label("PGN or ChessBase…", systemImage: "square.and.arrow.down")
                }
            } label: {
                Label("Import", systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(library.isImportingFiles)
            Button { newGame(nil) } label: { Label("New Game", systemImage: "doc.badge.plus") }
                .buttonStyle(.borderedProminent).tint(LucentTheme.accent)
                .disabled(library.isImportingFiles)
        }
        .padding(.horizontal, 22)
        .frame(height: 66)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [LucentTheme.accent.opacity(0.055), .clear, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
    }

    private var appearanceSwitcher: some View {
        Menu {
            ForEach(InterfaceAppearance.allCases) { option in
                Button {
                    appearance.interfaceAppearance = option
                } label: {
                    Label(option.label, systemImage: appearance.interfaceAppearance == option ? "checkmark" : option.symbol)
                }
            }
        } label: {
            Image(systemName: appearance.interfaceAppearance.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.quaternary.opacity(0.65), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .frame(width: 30)
        .help("Interface appearance: \(appearance.interfaceAppearance.label)")
        .accessibilityLabel("Interface appearance")
        .accessibilityValue(appearance.interfaceAppearance.label)
    }

    private var librarySidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LIBRARY")
                .font(.caption2.bold()).tracking(0.7).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.top, 18).padding(.bottom, 5)
            sidebarRow("All Games", systemImage: "books.vertical", count: library.totalGameCount, value: .all)
            sidebarRow("Recently Edited", systemImage: "clock.arrow.circlepath", count: recentCount, value: .recent)

            Divider().padding(.vertical, 10).padding(.horizontal, 12)
            HStack {
                Text("COLLECTIONS").font(.caption2.bold()).tracking(0.7).foregroundStyle(.secondary)
                Spacer()
                Button {
                    folderEditor = FolderEditor(folder: nil)
                } label: {
                    Image(systemName: "folder.badge.plus").font(.caption.bold())
                }
                .buttonStyle(.plain)
                .help("New Collection")
                .accessibilityLabel("New Collection")
            }
            .padding(.horizontal, 14).padding(.bottom, 5)

            sidebarRow(
                "Unfiled",
                systemImage: "tray.full",
                count: library.unfiledGameCount,
                value: .unfiled,
                acceptsDrop: true,
                dropFolderID: nil
            )

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(library.folders) { folder in
                        sidebarRow(
                            folder.name,
                            systemImage: "folder",
                            count: library.gameCount(in: folder),
                            value: .folder(folder.id),
                            acceptsDrop: true,
                            dropFolderID: folder.id
                        )
                        .contextMenu { collectionActions(folder).disabled(library.isImportingFiles) }
                    }
                }
            }

            Spacer(minLength: 12)
            Label("Drag games into collections", systemImage: "hand.draw")
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.horizontal, 14).padding(.bottom, 14)
        }
        .frame(minWidth: 220, idealWidth: 240, maxWidth: 380)
        .background(.ultraThinMaterial.opacity(0.42))
    }

    private func sidebarRow(
        _ title: String,
        systemImage: String,
        count: Int,
        value: Selection,
        acceptsDrop: Bool = false,
        dropFolderID: UUID? = nil
    ) -> some View {
        Button { selectCollection(value) } label: {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .symbolVariant(selection == value ? .fill : .none)
                    .foregroundStyle(selection == value ? Color.accentColor : .secondary)
                    .frame(width: 17)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if case .folder = value, count > 100 {
                    Image(systemName: "arrow.up.forward.square").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(selection == value ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .dropDestination(for: String.self) { ids, _ in
            guard acceptsDrop && !library.isImportingFiles else { return false }
            return moveGames(ids, to: dropFolderID)
        }
    }

    private var recentCount: Int {
        library.recentGameCount
    }

    private var collectionBrowser: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Collections").font(LucentTheme.Fonts.sectionTitle)
                Text("\(library.folders.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { folderEditor = FolderEditor(folder: nil) } label: {
                    Label("New collection", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 180), spacing: 12)], alignment: .leading, spacing: 12) {
                    collectionTile("Unfiled", symbol: "tray.full.fill",
                                   count: library.unfiledGameCount,
                                   value: .unfiled, folderID: nil)
                    ForEach(library.folders) { folder in
                        collectionTile(folder.name, symbol: "folder.fill", count: library.gameCount(in: folder),
                                       value: .folder(folder.id), folderID: folder.id)
                            .contextMenu { collectionActions(folder).disabled(library.isImportingFiles) }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Collection browser")
    }

    private func collectionTile(_ title: String, symbol: String, count: Int,
                                value: Selection, folderID: UUID?) -> some View {
        CollectionTile(title: title, symbol: symbol, count: count, selected: selection == value) {
            selectCollection(value)
        }
        .help(count > 100 && folderID != nil ? "Open \(title) in its own window" : "Show \(title)")
        .dropDestination(for: String.self) { ids, _ in
            moveGames(ids, to: folderID)
        }
    }

    @ViewBuilder
    private func collectionActions(_ folder: GameFolder) -> some View {
        Button(referenceCollectionID == folder.id.uuidString ? "Reference database ✓" : "Use as Reference Database") {
            referenceCollectionID=folder.id.uuidString
        }
        Divider()
        Button("Rename Collection…") { folderEditor = FolderEditor(folder: folder) }
        Button("Remove Collection", role: .destructive) {
            library.deleteFolder(folder)
            if selection == .folder(folder.id) { selection = .unfiled }
        }
        Divider()
        Text("Removing a collection keeps its games in Unfiled.")
    }

    private func moveGames(_ ids: [String], to folderID: UUID?) -> Bool {
        guard !library.isImportingFiles else { return false }
        var moved = false
        for id in ids.compactMap(UUID.init(uuidString:)) {
            library.move(studyID: id, to: folderID)
            moved = true
        }
        return moved
    }

    private func librarySection(_ games: [ChessStudy]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if referenceMode {
                HStack {
                    Picker("Reference database",selection:$referenceCollectionID) {
                        Text("Choose a collection…").tag("")
                        ForEach(library.folders) { folder in Text("\(folder.name) (\(library.gameCount(in:folder).formatted()))").tag(folder.id.uuidString) }
                    }
                    Button("Use current board") { filter.boardFEN=library.selectedStudy?.currentPosition.fen ?? "";pageCursors=[nil] }.disabled(library.selectedStudy==nil)
                }
                Text("Reference results open in a separate preview. Your working game stays open.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.quaternary.opacity(0.55))
                    Image(systemName: sectionSymbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 27, height: 27)
                VStack(alignment: .leading, spacing: 1) {
                    Text(sectionTitle).font(LucentTheme.Fonts.sectionTitle)
                    if selection == .recent {
                        Text("Games changed in the last 14 days.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(displayedCount.formatted()).font(.caption.bold()).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: Capsule())
                Spacer()
                if case .folder = selection {
                    Button {
                        folderEditor = library.folders.first(where: { $0.id == selectedFolderID }).map(FolderEditor.init)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                }
            }

            libraryControls(shownCount: displayedCount)
            HStack {
                if loadingPage {
                    ProgressView().controlSize(.small)
                    Text(searchProgress.isEmpty ? "Loading games…" : searchProgress).lineLimit(2)
                    Button("Cancel") { searchTask?.cancel();loadingPage=false;searchProgress="Search cancelled." }
                }
                else if displayedCount > 0 {
                    Text("\(((pageCursors.count-1)*DatabaseCatalog.pageSize+1).formatted())–\(min(pageCursors.count*DatabaseCatalog.pageSize,displayedCount).formatted()) of \(displayedCount.formatted())")
                }
                Spacer()
                Button("Previous") { pageCursors.removeLast() }.disabled(pageCursors.count == 1 || loadingPage)
                Button("Next") { if let nextCursor { pageCursors.append(nextCursor) } }.disabled(nextCursor == nil || loadingPage)
            }.font(.caption).foregroundStyle(.secondary)

            if !loadingPage && !searchProgress.isEmpty {
                HStack {
                    Text(searchProgress).font(.caption).foregroundStyle(.secondary)
                    if searchProgress == "Search cancelled." { Button("Retry search") { searchAttempt += 1 } }
                }
            }
            if !filter.boardFEN.isEmpty { Text("Board filter: exact pieces and side to move · main line only").font(.caption).foregroundStyle(.secondary) }
            let tableShape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    libraryHeader
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if games.isEmpty && !loadingPage {
                                ContentUnavailableView(
                                    hasActiveFilters ? "No matching games" : "No games here",
                                    systemImage: "doc.text.magnifyingglass",
                                    description: Text(emptyLibraryDescription)
                                )
                                .frame(maxWidth: .infinity, minHeight: 220)
                            } else {
                                ForEach(games) { game in
                                    GameLibraryRow(
                                        game: game,
                                        folderName: selectedFolderID == game.folderID ? nil : folderName(for: game)
                                    ) { openResult(game) }
                                        .draggable(game.id.uuidString)
                                        .contextMenu {
                                            Button("Open") { openResult(game) }
                                            if !referenceMode {
                                            Button("Save PGN") { Task { if await library.openGame(game) { library.saveSelected() } } }
                                            Button("Export PGN…") { Task { if await library.openGame(game) { library.saveSelectedAs() } } }
                                            moveToFolderMenu(for: game).disabled(library.isImportingFiles)
                                            Divider()
                                            Button("Duplicate") { Task { if await library.openGame(game) { library.duplicateSelected() } } }.disabled(library.isImportingFiles)
                                            Button("Delete from Library", role: .destructive) { library.delete(game) }.disabled(library.isImportingFiles)
                                            }
                                        }
                                    if game.id != games.last?.id { Divider().padding(.leading, 20) }
                                }
                            }
                        }
                    }
                    .id(selection)
                }
                .frame(width: max(geometry.size.width, 1_100), height: geometry.size.height, alignment: .top)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.background.opacity(0.68))
            .clipShape(tableShape)
            .overlay(tableShape.stroke(.separator.opacity(0.42), lineWidth: 1))
        }
    }

    private func openResult(_ game: ChessStudy) {
        if referenceMode { library.referencePreviewFEN=filter.boardFEN }
        openGame(game)
    }

    private func libraryControls(shownCount: Int) -> some View {
        HStack(spacing: 10) {
            Button { showingFilters=true } label: { Label(filter.isActive ? "Edit filters" : "Filter games…",systemImage:"line.3.horizontal.decrease.circle") }
            if filter.isActive { Button("Clear filters") { filter=CatalogFilter();resultFilter = .all;pageCursors=[nil] } }
            Menu {
                ForEach(GameResultFilter.allCases) { option in
                    Button {
                        resultFilter = option
                    } label: {
                        Label(option.label, systemImage: option == resultFilter ? "checkmark" : option.symbol)
                    }
                }
            } label: {
                Label(resultFilter.label, systemImage: resultFilter.symbol)
            }
            .help("Filter by game result")

            Menu {
                ForEach(GameFileFilter.allCases) { option in
                    Button {
                        fileFilter = option
                    } label: {
                        Label(option.label, systemImage: option == fileFilter ? "checkmark" : option.symbol)
                    }
                }
            } label: {
                Label(fileFilter.label, systemImage: fileFilter.symbol)
            }
            .help("Filter by file state")

            Spacer()

            if hasActiveFilters {
                Text("\(shownCount) shown")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button {
                    clearFilters()
                } label: {
                    Label("Clear", systemImage: "xmark.circle.fill")
                }
                .help("Clear search and filters")
            }

            Menu {
                ForEach(GameSortField.allCases) { field in
                    Button {
                        chooseSort(field)
                    } label: {
                        Label(field.label, systemImage: field == sortField ? "checkmark" : "arrow.up.arrow.down")
                    }
                }
                Divider()
                Button {
                    sortAscending.toggle()
                } label: {
                    Label(sortAscending ? "Ascending" : "Descending", systemImage: sortAscending ? "arrow.up" : "arrow.down")
                }
            } label: {
                Label("Sort: \(sortField.label)", systemImage: sortAscending ? "arrow.up" : "arrow.down")
            }
            .help("Choose game order")
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private var hasActiveFilters: Bool {
        filter.isActive || query.isFiltered || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func clearFilters() {
        resultFilter = .all
        fileFilter = .all
        searchText = ""
    }

    private func chooseSort(_ field: GameSortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = field.defaultAscending
        }
    }

    private var emptyLibraryDescription: String {
        if hasActiveFilters { return "Try clearing the search or one of the filters." }
        if selection == .recent { return "Games you edit will appear here for 14 days." }
        if case .folder = selection { return "Drag a game here or create a new game in this collection." }
        return "Create a game or open a PGN to begin."
    }

    @ViewBuilder
    private func moveToFolderMenu(for game: ChessStudy) -> some View {
        Menu("Move to Collection") {
            Button {
                library.move(game, to: nil)
            } label: {
                Label("Unfiled", systemImage: game.folderID == nil ? "checkmark" : "tray")
            }
            if !library.folders.isEmpty { Divider() }
            ForEach(library.folders) { folder in
                Button {
                    library.move(game, to: folder.id)
                } label: {
                    Label(folder.name, systemImage: game.folderID == folder.id ? "checkmark" : "folder")
                }
            }
        }
    }

    private func folderName(for game: ChessStudy) -> String? {
        guard let folderID = game.folderID else { return nil }
        return library.folders.first(where: { $0.id == folderID })?.name
    }

    private var libraryHeader: some View {
        HStack(spacing: 14) {
            sortableHeader("GAME", field: .players)
            sortableHeader("WHITE ELO", field: .whiteElo, width: 82, alignment: .trailing)
            sortableHeader("BLACK ELO", field: .blackElo, width: 82, alignment: .trailing)
            sortableHeader("RESULT", field: .result, width: 68)
            sortableHeader("TOURNAMENT", field: .event, width: 160)
            sortableHeader("DATE", field: .date, width: 92)
            sortableHeader("MOVES", field: .moves, width: 56, alignment: .trailing)
            sortableHeader("ROUND", field: .round, width: 70)
            Image(systemName: "chevron.right").hidden().frame(width: 12)
        }
        .font(.caption2.bold()).tracking(0.45).foregroundStyle(.secondary)
        .padding(.horizontal, 18).frame(height: 38)
        .background(
            .quaternary.opacity(0.35),
            in: UnevenRoundedRectangle(
                topLeadingRadius: 12,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 12,
                style: .continuous
            )
        )
    }

    private func sortableHeader(
        _ title: String,
        field: GameSortField,
        width: CGFloat? = nil,
        alignment: Alignment = .leading
    ) -> some View {
        Button {
            chooseSort(field)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if sortField == field {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .black))
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: alignment)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
        .contentShape(Rectangle())
        .help("Sort by \(field.label)")
        .accessibilityLabel("Sort by \(field.label)")
    }

    private var sectionSymbol: String {
        switch selection {
        case .all: return "books.vertical.fill"
        case .recent: return "clock.arrow.circlepath"
        case .unfiled: return "tray.full.fill"
        case .folder: return "folder.fill"
        }
    }

}

private struct FolderEditor: Identifiable {
    let id = UUID()
    let folder: GameFolder?
}

private struct FolderEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let editor: FolderEditor
    let save: (String) -> Void
    @State private var name: String

    init(editor: FolderEditor, save: @escaping (String) -> Void) {
        self.editor = editor
        self.save = save
        _name = State(initialValue: editor.folder?.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: editor.folder == nil ? "folder.badge.plus" : "folder.fill")
                    .font(.title).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(editor.folder == nil ? "New Collection" : "Rename Collection").font(.title2.bold())
                    Text("Collections group games in your library.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            TextField("Collection name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(editor.folder == nil ? "Create" : "Rename", action: commit)
                    .buttonStyle(.borderedProminent).tint(LucentTheme.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 410)
    }

    private func commit() {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        save(cleaned)
        dismiss()
    }
}

private struct CollectionTile: View {
    let title: String
    let symbol: String
    let count: Int
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 46, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(height: 50)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 30, alignment: .top)
                Text("\(count) games")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(hovering ? 0.04 : 0),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show \(title) · \(count) games")
        .accessibilityLabel("\(title), \(count) games")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct GameLibraryRow: View {
    let game: ChessStudy
    let folderName: String?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                HStack(spacing: 11) {
                    ZStack {
                        Circle().fill(rowAccent.opacity(0.12))
                        Image(systemName: "checkerboard.rectangle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(rowAccent)
                    }
                    .frame(width: 31, height: 31)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(game.playerDescription).font(.body.weight(.semibold)).lineLimit(1)
                        HStack(spacing: 7) {
                            Text(game.title).lineLimit(1)
                            if let folderName {
                                Label(folderName, systemImage: "folder.fill").lineLimit(1)
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(rating(game.whiteElo)).monospacedDigit().frame(width: 82, alignment: .trailing)
                Text(rating(game.blackElo)).monospacedDigit().frame(width: 82, alignment: .trailing)
                Text(game.result).monospacedDigit().frame(width: 68, alignment: .leading)
                Text(game.event.isEmpty ? "—" : game.event).lineLimit(1).frame(width: 160, alignment: .leading)
                Text(game.date, format: .dateTime.day().month(.abbreviated).year())
                    .monospacedDigit().frame(width: 92, alignment: .leading)
                Text("\((game.mainLinePlyCount + 1) / 2)").monospacedDigit().frame(width: 56, alignment: .trailing)
                Text(game.round ?? "—").monospacedDigit().frame(width: 70, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary).frame(width: 12)
            }
            .font(.callout)
            .padding(.horizontal, 18).frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func rating(_ value: String?) -> String {
        guard let value, let number = Int(value), number > 0 else { return "—" }
        return String(number)
    }

    private var rowAccent: Color {
        if game.hasUnsavedChanges { return LucentTheme.Status.edited }
        if game.starterCollectionID != nil { return LucentTheme.Status.starter }
        if game.sourceName != nil { return LucentTheme.Status.imported }
        if game.filePath == nil { return LucentTheme.Status.unsaved }
        return LucentTheme.Status.saved
    }
}
