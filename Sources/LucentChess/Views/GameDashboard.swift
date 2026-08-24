import AppKit
import SwiftUI

struct GameDashboard: View {
    private enum Selection: Hashable {
        case all, autosave, recent, unsaved, unfiled, folder(UUID)
    }

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var appearance: AppearanceSettings
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

    private var scopedGames: [ChessStudy] {
        let source = library.filteredStudies
        switch selection {
        case .all:
            return source
        case .autosave:
            return source.filter(\.isAutosaved)
        case .recent:
            return source.filter { $0.modifiedAt > Date().addingTimeInterval(-14 * 86_400) }
        case .unsaved:
            return source.filter(\.hasUnsavedChanges)
        case .unfiled:
            return source.filter { $0.folderID == nil }
        case let .folder(id):
            return source.filter { $0.folderID == id }
        }
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
        case .autosave: return "Autosave"
        case .recent: return "Recent games"
        case .unsaved: return "Needs PGN save"
        case .unfiled: return "Unfiled"
        case let .folder(id): return library.folders.first(where: { $0.id == id })?.name ?? "Folder"
        }
    }

    var body: some View {
        let displayedGames = query.apply(to: scopedGames)
        VStack(spacing: 0) {
            dashboardToolbar
            Divider()
            HSplitView {
                librarySidebar
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        welcomeHeader
                        quickActions
                        librarySection(displayedGames)
                    }
                    .frame(maxWidth: 1_260, alignment: .leading)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 30)
                    .frame(maxWidth: .infinity)
                }
                .frame(minWidth: 680)
            }
        }
        .background(
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                RadialGradient(
                    colors: [.orange.opacity(0.075), .orange.opacity(0.018), .clear],
                    center: .topLeading,
                    startRadius: 12,
                    endRadius: 760
                )
                RadialGradient(
                    colors: [.blue.opacity(0.026), .clear],
                    center: .bottomTrailing,
                    startRadius: 30,
                    endRadius: 620
                )
            }
        )
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

    private var dashboardToolbar: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("LUCENT").font(.system(size: 13, weight: .black, design: .rounded)).tracking(2.2)
                HStack(spacing: 5) {
                    Circle().fill(.green).frame(width: 5, height: 5)
                    Text("OFFLINE CHESS ARCHIVE")
                        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        .tracking(0.65)
                        .foregroundStyle(.secondary)
                }
            }
            Divider().frame(height: 28).padding(.leading, 4)
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search players, events, or games", text: $library.searchText)
                    .textFieldStyle(.plain)
                if !library.searchText.isEmpty {
                    Button { library.searchText = "" } label: {
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
            Menu {
                Button { importSource(selectedFolderID) } label: {
                    Label("TWIC or Lichess…", systemImage: "network")
                }
                Button { importPGN(selectedFolderID) } label: {
                    Label("PGN from Disk…", systemImage: "square.and.arrow.down")
                }
            } label: {
                Label("Import", systemImage: "square.and.arrow.down.on.square")
            }
            Button { newGame(selectedFolderID) } label: { Label("New Game", systemImage: "doc.badge.plus") }
                .buttonStyle(.borderedProminent).tint(.orange)
        }
        .padding(.horizontal, 22)
        .frame(height: 66)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [.orange.opacity(0.055), .clear, .clear],
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
                .foregroundStyle(appearance.interfaceAppearance == .light ? Color.orange : .secondary)
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
            sidebarRow("All Games", systemImage: "books.vertical", count: library.studies.count, value: .all)
            sidebarRow("Autosave", systemImage: "archivebox", count: library.autosavedGameCount, value: .autosave)
            sidebarRow("Recent", systemImage: "clock.arrow.circlepath", count: recentCount, value: .recent)
            sidebarRow("Needs Saving", systemImage: "square.and.arrow.down", count: library.unsavedGameCount, value: .unsaved)

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
                .help("New Folder")
                .accessibilityLabel("New Folder")
            }
            .padding(.horizontal, 14).padding(.bottom, 5)

            sidebarRow(
                "Unfiled",
                systemImage: "tray.full",
                count: library.studies.filter { $0.folderID == nil }.count,
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
                        .contextMenu {
                            Button("Rename Folder…") { folderEditor = FolderEditor(folder: folder) }
                            Button("Remove Folder", role: .destructive) {
                                library.deleteFolder(folder)
                                if selection == .folder(folder.id) { selection = .unfiled }
                            }
                            Divider()
                            Text("Removing a folder keeps its games in Unfiled.")
                        }
                    }
                }
            }

            Spacer(minLength: 12)
            Label("Drag games onto folders", systemImage: "hand.draw")
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.horizontal, 14).padding(.bottom, 14)
        }
        .frame(minWidth: 190, idealWidth: 218, maxWidth: 380)
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
        Button { selection = value } label: {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .symbolVariant(selection == value ? .fill : .none)
                    .foregroundStyle(selection == value ? Color.accentColor : .secondary)
                    .frame(width: 17)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(selection == value ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .dropDestination(for: String.self) { ids, _ in
            guard acceptsDrop else { return false }
            var moved = false
            for id in ids.compactMap(UUID.init(uuidString:)) {
                library.move(studyID: id, to: dropFolderID)
                moved = true
            }
            return moved
        }
    }

    private var recentCount: Int {
        library.studies.count { $0.modifiedAt > Date().addingTimeInterval(-14 * 86_400) }
    }

    private var welcomeHeader: some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Label("LUCENT · LOCAL STUDY DESK", systemImage: "checkerboard.rectangle")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.25)
                    .foregroundStyle(.orange)
                Text("Your chess archive")
                    .font(.system(size: 33, weight: .semibold, design: .serif))
                Text("Games, ideas, and engine analysis—kept private on this Mac.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                metric("\(library.studies.count)", "games", systemImage: "checkerboard.rectangle")
                metric("\(library.folders.count)", "collections", systemImage: "folder")
            }
        }
    }

    private var quickActions: some View {
        HStack(spacing: 14) {
            DashboardActionCard(
                title: "Continue",
                detail: library.selectedStudy?.playerDescription ?? "Open your latest game",
                systemImage: "play.fill",
                accent: .orange,
                prominent: true,
                enabled: library.selectedStudy != nil
            ) {
                if let study = library.selectedStudy { openGame(study) }
            }
            DashboardActionCard(
                title: selectedFolderID == nil ? "New game" : "New game here",
                detail: selectedFolderID == nil ? "Start from the initial position" : "Add it to \(sectionTitle)",
                systemImage: "doc.badge.plus",
                accent: .blue,
                prominent: false,
                enabled: true
            ) { newGame(selectedFolderID) }
            DashboardActionCard(
                title: "Import games",
                detail: "TWIC or Lichess",
                systemImage: "network",
                accent: .green,
                prominent: false,
                enabled: true,
            ) { importSource(selectedFolderID) }
        }
    }

    private func librarySection(_ games: [ChessStudy]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.orange.opacity(0.14))
                    Image(systemName: sectionSymbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                .frame(width: 27, height: 27)
                VStack(alignment: .leading, spacing: 1) {
                    Text(sectionTitle).font(.system(.title2, design: .serif, weight: .semibold))
                    if selection == .autosave {
                        Text("Recovered locally until you save each game as a PGN.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(games.count)").font(.caption.bold()).foregroundStyle(.secondary)
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

            libraryControls(shownCount: games.count)

            let tableShape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            LazyVStack(spacing: 0) {
                libraryHeader
                Divider()
                if games.isEmpty {
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
                        ) { openGame(game) }
                            .draggable(game.id.uuidString)
                            .contextMenu {
                                Button("Open") { openGame(game) }
                                Button("Save") { library.select(game); library.saveSelected() }
                                Button("Save As…") { library.select(game); library.saveSelectedAs() }
                                moveToFolderMenu(for: game)
                                Divider()
                                Button("Duplicate") { library.select(game); library.duplicateSelected() }
                                Button("Delete from Library", role: .destructive) { library.delete(game) }
                            }
                        if game.id != games.last?.id { Divider().padding(.leading, 20) }
                    }
                }
            }
            .background(.background.opacity(0.68))
            .clipShape(tableShape)
            .overlay(tableShape.stroke(.separator.opacity(0.42), lineWidth: 1))
        }
    }

    private func libraryControls(shownCount: Int) -> some View {
        HStack(spacing: 10) {
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
        query.isFiltered || !library.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func clearFilters() {
        resultFilter = .all
        fileFilter = .all
        library.searchText = ""
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
        if selection == .autosave { return "New and duplicated games appear here until you save them as PGN files." }
        if case .folder = selection { return "Drag a game here or create a new game in this folder." }
        return "Create a game or open a PGN to begin."
    }

    @ViewBuilder
    private func moveToFolderMenu(for game: ChessStudy) -> some View {
        Menu("Move to Folder") {
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
            sortableHeader("EVENT", field: .event, width: 160)
            sortableHeader("DATE", field: .date, width: 92)
            sortableHeader("RESULT", field: .result, width: 68)
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
        case .autosave: return "archivebox.fill"
        case .recent: return "clock.arrow.circlepath"
        case .unsaved: return "square.and.arrow.down.fill"
        case .unfiled: return "tray.full.fill"
        case .folder: return "folder.fill"
        }
    }

    private func metric(_ value: String, _ label: String, systemImage: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 24, height: 24)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.headline).monospacedDigit()
                Text(label.uppercased())
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(.background.opacity(0.48), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.separator.opacity(0.34)))
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
                    .font(.title).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(editor.folder == nil ? "New Folder" : "Rename Folder").font(.title2.bold())
                    Text("Folders organize the Lucent library; your PGN files stay where they are.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(editor.folder == nil ? "Create" : "Rename", action: commit)
                    .buttonStyle(.borderedProminent).tint(.orange)
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

private struct DashboardActionCard: View {
    let title: String
    let detail: String
    let systemImage: String
    let accent: Color
    let prominent: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(accent.opacity(prominent ? 0.22 : 0.13))
                    Image(systemName: systemImage)
                        .font(prominent ? .title2.weight(.bold) : .title3.weight(.semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 50, height: 50)
                VStack(alignment: .leading, spacing: 4) {
                    if prominent {
                        Text("RESUME STUDY")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .tracking(0.9)
                            .foregroundStyle(accent)
                    }
                    Text(title).font(prominent ? .title3.weight(.semibold) : .headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 5)
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 82)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.background.opacity(0.7))
                    .overlay {
                        if prominent {
                            LinearGradient(
                                colors: [accent.opacity(0.11), accent.opacity(0.025), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        prominent
                            ? accent.opacity(0.32)
                            : Color(nsColor: .separatorColor).opacity(0.34)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.48)
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
                                Label(folderName, systemImage: "folder.fill").foregroundStyle(.orange.opacity(0.9)).lineLimit(1)
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(game.event.isEmpty ? "—" : game.event).lineLimit(1).frame(width: 160, alignment: .leading)
                Text(game.date, format: .dateTime.year().month(.twoDigits).day(.twoDigits))
                    .monospacedDigit().frame(width: 92, alignment: .leading)
                Text(game.result).monospacedDigit().frame(width: 68, alignment: .leading)
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

    private var rowAccent: Color {
        if game.hasUnsavedChanges { return .yellow }
        if game.starterCollectionID != nil { return .blue }
        if game.sourceName != nil { return .teal }
        if game.filePath == nil { return .orange }
        return .green
    }
}
