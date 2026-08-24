import AppKit
import Combine
import Foundation

@main
struct ArchitectureChecks {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("LucentArchitectureChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let archive = temporary.appendingPathComponent("Library.json")
        try FileManager.default.copyItem(at: source, to: archive)

        let loadStart = ContinuousClock.now
        let library = LibraryStore(archiveURL: archive)
        let loadDuration = ContinuousClock.now - loadStart
        try check("full production-sized library loads") { library.studies.count >= 250 }

        var libraryInvalidations = 0
        var studyInvalidations = 0
        let librarySubscription = library.objectWillChange.sink { libraryInvalidations += 1 }
        guard let study = library.selectedStudy else { throw Failure("selected production game missing") }
        let studySubscription = study.objectWillChange.sink { studyInvalidations += 1 }
        library.selectionChanged()
        try check("move navigation invalidates only the selected game") {
            libraryInvalidations == 0 && studyInvalidations == 1
        }

        let snapshotStart = ContinuousClock.now
        let snapshot = LibraryPersistenceSnapshot(
            studies: library.studies,
            selectedStudyID: library.selectedStudyID,
            folders: library.folders,
            seedVersion: 1
        )
        let snapshotDuration = ContinuousClock.now - snapshotStart

        let encoded = try encodeOffMain(snapshot)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decodedSnapshot = try decoder.decode(LibraryPersistenceSnapshot.self, from: encoded)
        let rebuilt = try decodedSnapshot.makeStudies()
        try check("immutable flat snapshot round-trip preserves the library") {
            rebuilt.count == library.studies.count
                && decodedSnapshot.selectedStudyID == library.selectedStudyID
                && decodedSnapshot.folders?.count == library.folders.count
        }

        let longGame = makeLongGame(length: 5_000)
        let lookupStart = ContinuousClock.now
        var checksum = 0
        for _ in 0..<100_000 {
            checksum &+= longGame.currentNode.id.hashValue
            checksum &+= longGame.currentPosition.halfmoveClock
        }
        let lookupDuration = ContinuousClock.now - lookupStart
        try check("indexed current-node and cached-position access stay constant-time") {
            checksum != 0 && lookupDuration < .milliseconds(150)
        }
        try check("parent index reconstructs a 5,000-ply path") { longGame.path().count == 5_000 }

        librarySubscription.cancel()
        studySubscription.cancel()
        print("✓ full-library load \(loadDuration)")
        print("✓ main-thread immutable snapshot capture \(snapshotDuration); encoded size \(encoded.count) bytes")
        print("✓ 200,000 indexed/cached reads \(lookupDuration)")
        print("All architecture checks passed.")
    }

    private static func makeLongGame(length: Int) -> ChessStudy {
        let study = ChessStudy(title: "Index stress test")
        var parent = study.root
        for ply in 1...length {
            let child = MoveNode(
                parentID: parent.id,
                moveUCI: "a1a1",
                moveSAN: "move\(ply)",
                positionFEN: ChessPosition.startFEN
            )
            parent.children.append(child)
            parent = child
        }
        study.lastNodeID = parent.id
        study.rebuildNodeIndex()
        return study
    }

    private static func encodeOffMain(_ snapshot: LibraryPersistenceSnapshot) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Result<Data, Error>?
        DispatchQueue.global(qos: .utility).async {
            let encoded: Result<Data, Error> = Result {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                return try encoder.encode(snapshot)
            }
            lock.lock(); result = encoded; lock.unlock()
            semaphore.signal()
        }
        semaphore.wait()
        lock.lock(); defer { lock.unlock() }
        return try result!.get()
    }

    private static func check(_ name: String, _ test: () -> Bool) throws {
        guard test() else { throw Failure(name) }
        print("✓ \(name)")
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { "Check failed: \(message)" }
    }
}
