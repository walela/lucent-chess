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
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Reference").font(LucentTheme.Fonts.panelTitle)
                    Spacer()
                    if selectedFolder != nil {
                        Label("Live board", systemImage: "checkerboard.rectangle")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .help("Matches update automatically as you move through the game")
                    }
                }
                Button { choosingDatabase.toggle() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "books.vertical")
                            .font(.system(size: 17, weight: .regular)).foregroundStyle(.secondary)
                            .frame(width: 30, height: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedFolder?.name ?? "Choose a database")
                                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(selectedFolder.map { "\(library.gameCount(in: $0).formatted()) games" }
                                 ?? "Search your collections by position")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.primary.opacity(0.09), lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
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
                    }.padding(8).frame(width: 290)
                }
                .accessibilityLabel("Reference database")
                .accessibilityValue(selectedFolder?.name ?? "Choose a database")
                .help("Choose the collection to search")
            }
            .padding(14)
            Divider()
            if let query {
                // A new position owns fresh paging state and cancels the old task.
                ReferencePositionResults(query: query, sortField: $sortField, ascending: $ascending).id(query)
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
}

private struct ReferencePositionQuery: Hashable {
    let folder: String
    let fen: String
    let version: String
    let sort: GameSortField
    let ascending: Bool
}

private struct ReferencePositionResults: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.openWindow) private var openWindow
    let query: ReferencePositionQuery
    @Binding var sortField: GameSortField
    @Binding var ascending: Bool
    @State private var previewedGameID: UUID?
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

    private var pageLabel: String {
        let start = (cursors.count - 1) * DatabaseCatalog.pageSize + 1
        return "\(start.formatted())–\((start + games.count - 1).formatted()) of \(count.formatted())"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text("Matching games").font(.system(size: 12, weight: .semibold))
                if !loading && error == nil && !cancelled {
                    Text(count.formatted()).font(.system(size: 10, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.primary.opacity(0.055), in: Capsule())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(count.formatted()) matching games")
                }
                Spacer(minLength: 2)
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
            }.padding(.horizontal, 14).padding(.vertical, 12)

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
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(games) { game in
                            Button {
                                previewedGameID = game.id
                                openWindow(id: AppWindowID.referenceGame,
                                           value: ReferenceGameSelection(gameID: game.id, boardFEN: query.fen))
                            } label: {
                                ReferencePositionRow(game: game)
                                    .padding(11)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(ReferenceRowButtonStyle(selected: previewedGameID == game.id))
                            .help("Preview this game at the matching position")
                            .accessibilityLabel("\(game.white), \(game.whiteElo ?? "unrated"), \(game.black), \(game.blackElo ?? "unrated"), \(game.result), \(game.event), \(game.date.formatted(.dateTime.year()))")
                            Divider().padding(.horizontal, 11)
                        }
                    }.padding(.horizontal, 7)
                }
                .id(cursors.count)
                .accessibilityLabel("Games matching the current board")
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if !loading && count > DatabaseCatalog.pageSize {
                    HStack {
                        Button { cursors.removeLast() } label: { Image(systemName: "chevron.left") }
                            .disabled(cursors.count == 1).accessibilityLabel("Previous matching games")
                        Spacer()
                        Text(pageLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        Button { if let nextCursor { cursors.append(nextCursor) } } label: { Image(systemName: "chevron.right") }
                            .disabled(nextCursor == nil).accessibilityLabel("Next matching games")
                    }
                }
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
                        .help("Matches pieces and side to move, including transpositions. Castling rights, en passant and move clocks are ignored; variations are excluded.")
                        .accessibilityLabel("Position matching includes transpositions; castling rights, en passant, move clocks and variations are excluded")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 14).padding(.vertical, 11)
        }
        .task(id: request) { await search() }
        .onDisappear { activeSearch = nil; searchTask?.cancel() }
    }

    private func status(_ text: String, retry canRetry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text).font(.callout).foregroundStyle(.secondary)
            if canRetry { Button("Retry search") { retry &+= 1 } }
            Spacer()
        }.padding(.horizontal, 14).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cancel() {
        activeSearch = nil
        searchTask?.cancel()
        loading = false
        cancelled = true
    }

    @MainActor private func search() async {
        searchTask?.cancel()
        let captured = request
        let token = UUID()
        activeSearch = token
        games = []; count = 0; nextCursor = nil
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
}

private struct ReferencePositionRow: View {
    let game: ChessStudy

    private var resultLabel: String { game.result == "1/2-1/2" ? "½–½" : game.result }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 5) {
                player(game.white, elo: game.whiteElo, white: true)
                player(game.black, elo: game.blackElo, white: false)
            }
            HStack(spacing: 7) {
                Text(resultLabel)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary.opacity(0.75))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 4))
                Text(game.event.isEmpty ? "Unknown tournament" : game.event)
                    .lineLimit(1).help(game.event)
                Spacer(minLength: 0)
                Text(game.date, format: .dateTime.year()).monospacedDigit().fixedSize()
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func player(_ name: String, elo: String?, white: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .foregroundStyle(white ? Color.white : Color(white: 0.22))
                .overlay { Image(systemName: "circle").foregroundStyle(.gray.opacity(0.7)) }
                .font(.system(size: 8)).accessibilityHidden(true)
            Text(name.isEmpty ? "Unknown player" : name)
                .font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Text(elo ?? "—").font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary).frame(minWidth: 32, alignment: .trailing)
        }
    }
}

private struct ReferenceRowButtonStyle: ButtonStyle {
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
