import AppKit
import Foundation

@main
struct SeedChecks {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let cacheOutput = URL(fileURLWithPath: CommandLine.arguments[2])
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("LucentSeedChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let archive = temporary.appendingPathComponent("Library.json")

        let library = LibraryStore(archiveURL: archive, starterGamesURL: resources)
        let starters = library.studies.filter { $0.starterCollectionID != nil }
        try check("all 256 validated starter games install") { starters.count == 256 }
        try check("starter games are organized into seven collections") { library.folders.count == 7 }
        try check("both 2026 Candidates tournaments contain 56 games") {
            count(in: "Candidates 2026", library: library) == 56
                && count(in: "Women’s Candidates 2026", library: library) == 56
        }
        try check("all five Kasparov–Karpov matches are complete") {
            count(in: "Kasparov–Karpov 1984", library: library) == 48
                && count(in: "Kasparov–Karpov 1985", library: library) == 24
                && count(in: "Kasparov–Karpov 1986", library: library) == 24
                && count(in: "Kasparov–Karpov 1987", library: library) == 24
                && count(in: "Kasparov–Karpov 1990", library: library) == 24
        }
        try check("included reference games do not need saving") {
            starters.allSatisfy { !$0.hasUnsavedChanges && $0.filePath == nil }
        }
        try check("the current Candidates winner is represented") {
            starters.contains { $0.white.contains("Sindarov") || $0.black.contains("Sindarov") }
        }

        if let error = library.lastError { print("Seed cache diagnostic: \(error)") }
        let snapshot = LibraryArchive(
            studies: library.studies,
            selectedStudyID: library.selectedStudyID,
            folders: library.folders,
            seedVersion: 1
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: cacheOutput, options: .atomic)
        let reloaded = LibraryStore(archiveURL: cacheOutput, starterGamesURL: resources)
        try check("relaunching does not duplicate starter games or folders") {
            reloaded.studies.filter { $0.starterCollectionID != nil }.count == 256
                && reloaded.folders.count == 7
        }
        if let removed = reloaded.studies.first(where: { $0.starterCollectionID != nil }) {
            reloaded.delete(removed)
            reloaded.saveNow()
            let afterDeletion = LibraryStore(archiveURL: cacheOutput, starterGamesURL: resources)
            try check("deleted starter games stay deleted after relaunch") {
                afterDeletion.studies.filter { $0.starterCollectionID != nil }.count == 255
            }
        }

        print("All bundled starter game checks passed.")
    }

    @MainActor
    private static func count(in folderName: String, library: LibraryStore) -> Int {
        guard let folder = library.folders.first(where: { $0.name == folderName }) else { return 0 }
        return library.studies.count { $0.folderID == folder.id }
    }

    private static func check(_ name: String, _ test: () -> Bool) throws {
        guard test() else { throw Failure(name) }
        print("✓ \(name)")
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
