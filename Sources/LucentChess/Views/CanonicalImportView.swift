import SwiftUI

struct CanonicalImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    let destinationFolderID: UUID?

    @State private var source = CanonicalGameSource.twic
    @State private var latestTWIC = true
    @State private var twicIssue = ""
    @State private var lichessInput = ""
    @State private var maximumLichessGames = 100
    @State private var includeAnnotations = true
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var summary: CanonicalImportMergeSummary?
    @State private var importedDetail = ""
    @State private var rejectedGameCount = 0
    @State private var importTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                Picker("Source", selection: $source) {
                    ForEach(CanonicalGameSource.allCases) { option in
                        Label(option.rawValue, systemImage: option.symbol).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(isImporting)
                .onChange(of: source) { _, _ in clearOutcome() }

                GroupBox {
                    sourceForm
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }

                destinationRow

                if isImporting {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(progressText).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                } else if let summary {
                    resultView(summary)
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.075), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
            .padding(22)

            Divider()
            HStack {
                Button(summary == nil ? "Cancel" : "Close") {
                    importTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if summary == nil {
                    Button("Import", action: beginImport)
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isImporting || !canImport)
                }
            }
            .padding(.horizontal, 22)
            .frame(height: 58)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { importTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.orange.gradient)
                Image(systemName: "square.and.arrow.down.on.square.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text("Import from Source").font(.title2.bold())
                Text("Bring public games straight into your local library.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(22)
    }

    @ViewBuilder
    private var sourceForm: some View {
        switch source {
        case .twic:
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("The Week in Chess", systemImage: "newspaper.fill")
                        .font(.headline)
                    Spacer()
                    Picker("Issue", selection: $latestTWIC) {
                        Text("Latest").tag(true)
                        Text("Issue number").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 205)
                }
                if !latestTWIC {
                    TextField("Issue number, e.g. 1658", text: $twicIssue)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: twicIssue) { _, newValue in
                            twicIssue = String(newValue.filter(\.isNumber).prefix(5))
                        }
                }
                Label(
                    "A weekly issue may contain several thousand games. Download and PGN parsing happen in the background.",
                    systemImage: "externaldrive.badge.timemachine"
                )
                .font(.caption).foregroundStyle(.secondary)
                Text("TWIC downloads are offered for personal use; the source’s terms still apply.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        case .lichess:
            VStack(alignment: .leading, spacing: 14) {
                Label("Public Lichess games", systemImage: "checkerboard.rectangle")
                    .font(.headline)
                TextField("Username or public game, study, or broadcast-round URL", text: $lichessInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("Player game limit")
                    Spacer()
                    Picker("Player game limit", selection: $maximumLichessGames) {
                        ForEach([25, 50, 100, 250, 500], id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
                Toggle("Include available comments and evaluations", isOn: $includeAnnotations)
                Text("No account or token is used. Player imports include standard chess games only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var destinationRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Destination").font(.caption).foregroundStyle(.secondary)
                Text(destinationName).font(.callout.weight(.medium))
            }
            Spacer()
            Text(destinationFolderID == nil ? "Automatic" : "Selected collection")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
    }

    private func resultView(_ result: CanonicalImportMergeSummary) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: result.importedCount > 0 ? "checkmark.circle.fill" : "checkmark.seal.fill")
                .font(.title3).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text(resultHeadline(result)).font(.callout.weight(.semibold))
                Text(resultDetail(result)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var destinationName: String {
        guard let id = destinationFolderID,
              let folder = library.folders.first(where: { $0.id == id }) else {
            return "A source-named collection"
        }
        return folder.name
    }

    private var canImport: Bool {
        switch source {
        case .twic: return latestTWIC || Int(twicIssue).map { $0 > 0 } == true
        case .lichess: return !lichessInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var progressText: String {
        switch source {
        case .twic: return "Downloading and indexing TWIC…"
        case .lichess: return "Downloading and indexing Lichess games…"
        }
    }

    private func request() throws -> CanonicalImportRequest {
        switch source {
        case .twic:
            if latestTWIC { return .twicLatest }
            guard let issue = Int(twicIssue), issue > 0 else { throw CanonicalImportError.invalidTWICIssue }
            return .twicIssue(issue)
        case .lichess:
            return .lichess(
                input: lichessInput,
                maxGames: maximumLichessGames,
                includeAnnotations: includeAnnotations
            )
        }
    }

    private func beginImport() {
        clearOutcome()
        isImporting = true
        importTask = Task { await performImport() }
    }

    @MainActor
    private func performImport() async {
        do {
            let payload = try await CanonicalGameImportService.fetch(try request())
            try Task.checkCancellation()
            summary = library.importCanonicalGames(
                payload.games,
                sourceName: payload.sourceName,
                sourceURL: payload.sourceURL,
                collectionName: payload.collectionName,
                folderID: destinationFolderID
            )
            importedDetail = payload.detail
            rejectedGameCount = payload.rejectedCount
        } catch is CancellationError {
            // Closing the sheet cancels an in-flight import without surfacing an error.
        } catch {
            errorMessage = error.localizedDescription
        }
        isImporting = false
    }

    private func clearOutcome() {
        errorMessage = nil
        summary = nil
        importedDetail = ""
        rejectedGameCount = 0
    }

    private func resultHeadline(_ result: CanonicalImportMergeSummary) -> String {
        if result.importedCount == 0 { return "Library already up to date" }
        return "Imported \(result.importedCount) \(result.importedCount == 1 ? "game" : "games")"
    }

    private func resultDetail(_ result: CanonicalImportMergeSummary) -> String {
        var details = ["\(importedDetail) · \(result.folderName)"]
        if result.duplicateCount > 0 {
            details.append("Skipped \(result.duplicateCount) duplicate\(result.duplicateCount == 1 ? "" : "s")")
        }
        if rejectedGameCount > 0 {
            details.append("Ignored \(rejectedGameCount) unreadable score\(rejectedGameCount == 1 ? "" : "s")")
        }
        return details.joined(separator: " · ")
    }
}
