import SwiftUI

struct ReferenceFilterInspector: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject var study: ChessStudy
    @AppStorage("referenceCollectionID") private var referenceCollectionID = ""

    private var query: ReferencePositionQuery? {
        guard library.folders.contains(where: { $0.id.uuidString == referenceCollectionID }) else { return nil }
        // Clocks and castling changes must not restart an identical board search.
        let board = study.currentPosition.fen.split(separator: " ").prefix(2).joined(separator: " ")
        return ReferencePositionQuery(folder: referenceCollectionID, fen: board + " - - 0 1",
                                      version: library.collectionVersions[referenceCollectionID] ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Reference database").font(.headline)
                Picker("Reference database", selection: $referenceCollectionID) {
                    Text("Choose a collection…").tag("")
                    ForEach(library.folders) { folder in Text(folder.name).tag(folder.id.uuidString) }
                }
                .labelsHidden().frame(maxWidth: .infinity)
                Label("Follows the current board", systemImage: "checkerboard.rectangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            Divider()
            if let query {
                // A new position owns fresh paging state and cancels the old task.
                ReferencePositionResults(query: query).id(query)
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
}

private struct ReferencePositionResults: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.openWindow) private var openWindow
    let query: ReferencePositionQuery
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
        // Library header filters never silently restrict the position browser.
        return request
    }

    private var pageLabel: String {
        let start = (cursors.count - 1) * DatabaseCatalog.pageSize + 1
        return "\(start.formatted())–\((start + games.count - 1).formatted()) of \(count.formatted())"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Matching games").font(.subheadline.weight(.semibold))
                Spacer()
                if !loading && error == nil && !cancelled {
                    Text(count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }.padding(14)

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
                                openWindow(id: AppWindowID.referenceGame,
                                           value: ReferenceGameSelection(gameID: game.id, boardFEN: query.fen))
                            } label: {
                                ReferencePositionRow(game: game)
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help("Preview this game at the matching position")
                            Divider().padding(.horizontal, 14)
                        }
                    }
                }
                .id(cursors.count)
                .accessibilityLabel("Games matching the current board")
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if !loading && !games.isEmpty {
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
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Text("Exact board + side to move · main line").font(.caption2).foregroundStyle(.secondary)
            }.padding(14)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            player(game.white, elo: game.whiteElo, symbol: "circle")
            player(game.black, elo: game.blackElo, symbol: "circle.fill")
            HStack(spacing: 8) {
                Text(game.result).fontWeight(.medium)
                Text(game.event.isEmpty ? "—" : game.event).lineLimit(1)
                Spacer(minLength: 0)
                Text(game.date, format: .dateTime.year())
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func player(_ name: String, elo: String?, symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 8)).foregroundStyle(.secondary)
            Text(name.isEmpty ? "Unknown player" : name).lineLimit(1)
            Spacer(minLength: 4)
            Text(elo ?? "—").monospacedDigit().foregroundStyle(.secondary)
        }.font(.system(size: 12, weight: .medium))
    }
}
