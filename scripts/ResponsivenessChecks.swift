import AppKit
import Foundation

@main
struct ResponsivenessChecks {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("LucentResponsivenessChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let archive = temporary.appendingPathComponent("Library.json")
        try FileManager.default.copyItem(at: source, to: archive)

        let library = LibraryStore(archiveURL: archive)
        try check("performance fixture contains the full library") { library.studies.count >= 250 }
        library.saveNow()
        let compactBaseline = try Data(contentsOf: archive)
        let persistedSelection = library.selectedStudyID
        guard let target = library.studies.first(where: { $0.id != persistedSelection }) else {
            throw Failure("a second game was not available")
        }

        let selectionStart = ContinuousClock.now
        library.select(target)
        let selectionDuration = ContinuousClock.now - selectionStart
        try check("selecting a game returns immediately") { selectionDuration < .milliseconds(20) }

        runLoop(for: 1.5)
        let afterSelection = try decodedArchive(at: archive)
        try check("pure game selection does not rewrite the full archive") {
            afterSelection.selectedStudyID == persistedSelection
        }

        let navigationStart = ContinuousClock.now
        library.selectionChanged()
        let navigationDuration = ContinuousClock.now - navigationStart
        try check("move navigation returns immediately") { navigationDuration < .milliseconds(20) }
        runLoop(for: 1.5)
        try check("pure move navigation does not rewrite the full archive") {
            try Data(contentsOf: archive) == compactBaseline
        }

        let editStart = ContinuousClock.now
        library.changed()
        let editDuration = ContinuousClock.now - editStart
        try check("editing schedules persistence without blocking") { editDuration < .milliseconds(20) }
        try waitUntil(timeout: 5) { (try? Data(contentsOf: archive)) != compactBaseline }
        try check("real edits still persist after the debounce") {
            (try decodedArchive(at: archive)).studies.first(where: { $0.id == target.id })?.hasUnsavedChanges == true
        }

        target.title += " saved-now"
        library.changed()
        library.saveNow()
        let immediateSave = try Data(contentsOf: archive)
        runLoop(for: 1.5)
        try check("a cancelled deferred save cannot overwrite a newer save") {
            try Data(contentsOf: archive) == immediateSave
        }

        let originalSize = try Data(contentsOf: source).count
        print("✓ selection \(selectionDuration), navigation \(navigationDuration), edit scheduling \(editDuration)")
        print("✓ archive compacted from \(originalSize) to \(compactBaseline.count) bytes")
        print("All responsiveness checks passed.")
    }

    private static func decodedArchive(at url: URL) throws -> LibraryArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LibraryArchive.self, from: Data(contentsOf: url))
    }

    @MainActor
    private static func runLoop(for seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: min(end, Date().addingTimeInterval(0.04))) }
    }

    @MainActor
    private static func waitUntil(timeout: TimeInterval, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        }
        throw Failure("deferred edit was not persisted")
    }

    private static func check(_ name: String, _ test: () throws -> Bool) throws {
        guard try test() else { throw Failure(name) }
        print("✓ \(name)")
    }

    private struct Failure: LocalizedError {
        let name: String
        init(_ name: String) { self.name = name }
        var errorDescription: String? { "Check failed: \(name)" }
    }
}
