import Foundation
import CryptoKit

struct IndexedImportResult: Sendable {
    let folder: GameFolder
    let count: Int
    let existing: Bool
}

enum IndexedDatabaseImport {
    static func importFile(_ url: URL, catalog: DatabaseCatalog, folder: GameFolder,
                           progress: @escaping @Sendable (String) -> Void) throws -> IndexedImportResult {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if let existing = try catalog.source(url: url.absoluteString), existing.kind == "legacy", let id = existing.folder.flatMap(UUID.init(uuidString:)) {
            return IndexedImportResult(folder: GameFolder(id: id, name: existing.name), count: existing.count, existing: true)
        }
        progress("Checking \(url.lastPathComponent)…")
        var digest = SHA256()
        var hashFiles = [url]
        if url.pathExtension.lowercased() == "cbh" {
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            hashFiles = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                .filter { $0.deletingPathExtension().lastPathComponent.lowercased() == stem && ["cbh","cbg","cba","cbp","cbt","cbc","cbs"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.pathExtension.lowercased() < $1.pathExtension.lowercased() }
        }
        for file in hashFiles {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let data = try handle.read(upToCount: 4*1024*1024), !data.isEmpty {
                try Task.checkCancellation(); digest.update(data: data)
            }
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        if let existing = try catalog.source(hash: hash) {
            if existing.count > 0, let id = existing.folder.flatMap(UUID.init(uuidString:)) {
                return IndexedImportResult(folder: GameFolder(id: id, name: existing.name), count: existing.count, existing: true)
            }
            // A prior process may have quit before its index transaction committed.
            try catalog.removeSource(existing.id)
            let abandoned = catalog.sourcesURL.appendingPathComponent(existing.id)
            if UUID(uuidString: existing.id) != nil { try? FileManager.default.removeItem(at: abandoned) }
        }
        let sourceID = UUID().uuidString
        let directory = catalog.sourcesURL.appendingPathComponent(sourceID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var succeeded = false
        defer { if !succeeded { try? cleanupFailedImport(catalog:catalog,sourceID:sourceID,directory:directory) } }
        let databases: [URL]
        let isPGN = url.pathExtension.lowercased() == "pgn"
        if isPGN {
            progress("Copying \(url.lastPathComponent)…")
            let copy = directory.appendingPathComponent("database.pgn")
            try FileManager.default.copyItem(at: url, to: copy)
            databases = [copy]
        } else if url.pathExtension.lowercased() == "cbv" {
            databases = try CBVArchive.extractFile(url, to: directory, progress: progress).filter { $0.pathExtension.lowercased() == "cbh" }
            guard !databases.isEmpty else { throw ChessBaseImportError.unsupportedFormat }
        } else {
            let parent = url.deletingLastPathComponent(), stem = url.deletingPathExtension().lastPathComponent.lowercased()
            let files = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isRegularFileKey])
            for ext in ["cbh","cbg","cba","cbp","cbt","cbc","cbs"] {
                guard let file = files.first(where: { $0.lastPathComponent.lowercased() == stem + "." + ext }),
                      try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw ChessBaseImportError.missingFiles(".\(ext)") }
                try Task.checkCancellation()
                progress("Copying \(file.lastPathComponent)…")
                try FileManager.default.copyItem(at: file, to: directory.appendingPathComponent("database.\(ext)"))
            }
            databases = [directory.appendingPathComponent("database.cbh")]
        }
        // Normalize companion extensions in the private managed copy only.
        let database = databases[0]
        let parent = database.deletingLastPathComponent(), stem = database.deletingPathExtension().lastPathComponent
        let files = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
        for ext in (isPGN ? [] : ["cbh","cbg","cba","cbp","cbt","cbc","cbs"]) {
            let expected = parent.appendingPathComponent("\(stem).\(ext)")
            if let file = files.first(where: { $0.lastPathComponent.lowercased() == expected.lastPathComponent.lowercased() }), file.lastPathComponent != expected.lastPathComponent {
                try FileManager.default.moveItem(at: file, to: expected)
            }
        }
        guard databases.count == 1 else { throw CatalogError.message("This archive contains multiple databases. Open its CBH databases separately.") }
        let normalized = parent.appendingPathComponent(stem + (isPGN ? ".pgn" : ".cbh"))
        if !isPGN {
            let size=(try FileManager.default.attributesOfItem(atPath:normalized.path)[.size] as? NSNumber)?.int64Value ?? 0
            let available=(try FileManager.default.attributesOfFileSystem(forPath:catalog.url.deletingLastPathComponent().path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            try validateIndexSpace(gameCount:max(0,size/46-1),availableBytes:available)
        }
        try catalog.addSource(id: sourceID, path: normalized.path, kind: isPGN ? "pgn" : "cbh", name: folder.name, original: url.absoluteString, hash: hash, folder: folder.id)
        let log = directory.appendingPathComponent("index.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = try ChessBaseImportService.bundledReader()
        process.arguments = [isPGN ? "--index-pgn" : "--index",normalized.path,catalog.url.path,sourceID]
        process.standardOutput = output; process.standardError = output; process.standardInput = FileHandle.nullDevice
        try process.run()
        do {
            while process.isRunning {
                try Task.checkCancellation()
                if let data = try? Data(contentsOf: log), let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last {
                    let numbers = line.split(separator: " ").compactMap { Int($0) }
                    if numbers.count >= 2 {
                        if isPGN { progress("Indexing \(folder.name): \(Int(Double(numbers[0]) / Double(max(1,numbers[1])) * 100))%") }
                        else { progress("Indexing \(folder.name): \(numbers[0].formatted()) of \(numbers[1].formatted()) games") }
                    }
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
        } catch { process.terminate(); process.waitUntilExit(); throw error }
        process.waitUntilExit()
        guard process.terminationReason == .exit && process.terminationStatus == 0 else {
            let message = String(decoding: (try? Data(contentsOf: log)) ?? Data(), as: UTF8.self).split(separator: "\n").last.map(String.init)
            throw CatalogError.message(message ?? "The database indexer stopped unexpectedly.")
        }
        // The native transaction has committed. A later metadata/disk error must
        // never delete its move files or attempt to undo a successful import.
        succeeded = true
        guard let source = try catalog.source(id: sourceID), source.count > 0 else { throw CatalogError.message("No readable game headers were found.") }
        return IndexedImportResult(folder: folder, count: source.count, existing: false)
    }
    static func validateIndexSpace(gameCount: Int64, availableBytes: Int64) throws {
        // Conservative estimate from real large-library indexing, including WAL
        // checkpoint headroom. The native readers also monitor space while indexing.
        let required=Double(gameCount)*3072 + Double(512*1024*1024)
        guard Double(availableBytes)>=required else {
            let gib=1024.0*1024*1024
            throw CatalogError.message("This database contains \(gameCount.formatted()) records. Allow about \(Int(ceil(required/gib))) GB free for its index and temporary log; only \(String(format: "%.1f",Double(availableBytes)/gib)) GB is available. Free space and try again.")
        }
    }

    static func cleanupFailedImport(catalog: DatabaseCatalog, sourceID: String, directory: URL) throws {
        // Keep committed imports and retain move files if index cleanup fails.
        if let source=try catalog.source(id:sourceID), source.count>0 {return}
        try catalog.removeSource(sourceID)
        if FileManager.default.fileExists(atPath:directory.path) {try FileManager.default.removeItem(at:directory)}
    }

}
