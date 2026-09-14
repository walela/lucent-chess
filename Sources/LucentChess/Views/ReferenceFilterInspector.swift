import SwiftUI

struct ReferenceFilterInspector: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var study: ChessStudy
    @AppStorage("referenceCollectionID") private var referenceCollectionID = ""
    @State private var showingFilters = false

    private var hasDatabase: Bool {
        library.folders.contains { $0.id.uuidString == referenceCollectionID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Reference database").font(.headline)
                Picker("Database", selection: $referenceCollectionID) {
                    Text("Choose a collection…").tag("")
                    ForEach(library.folders) { folder in
                        Text(folder.name).tag(folder.id.uuidString)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                if library.folders.isEmpty {
                    Text("Import a ChessBase or PGN database from the library first.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button {
                    library.requestReferencePosition(study.currentPosition.fen)
                    openWindow(id: AppWindowID.reference)
                } label: {
                    Label("Search current position", systemImage: "checkerboard.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasDatabase)
                Text("Find this board anywhere in the main line. Results open in a separate window so you can keep working on this game.")
                    .font(.callout).foregroundStyle(.secondary)
                Divider()
                Text("Game filters").font(.headline)
                Text("Search by player, Elo, tournament, year, result or a board you set up.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Edit filters…") { showingFilters = true }
                    .disabled(!hasDatabase)
                Button("Browse reference database") {
                    library.requestReferencePosition("")
                    openWindow(id: AppWindowID.reference)
                }.disabled(!hasDatabase)
                if library.referenceFilter.isActive || library.referenceResult != "all" {
                    Text("Your reference filters also apply to current-position searches.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Clear reference filters") {
                        library.requestReferenceSearch(CatalogFilter(), result: "all")
                    }
                }
                Divider()
                Text("The first board search scans matching games. Narrowing the player or year first reduces that work; completed searches are cached.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .sheet(isPresented: $showingFilters) {
            DatabaseFilterView(filter: library.referenceFilter, result: library.referenceResult,
                               currentPositionFEN: study.currentPosition.fen) { filter, result in
                library.requestReferenceSearch(filter, result: result)
                openWindow(id: AppWindowID.reference)
            }
        }
    }
}
