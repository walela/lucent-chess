import Foundation
import UniformTypeIdentifiers

struct ChessBaseImportBatch: @unchecked Sendable {
    // The worker hands ownership of these games to the main actor once parsing ends.
    let games: [ChessStudy]
    let skipped: Int
}

enum ChessBaseImportService {
    static let fileExtensions = ["pgn", "cbh", "cbv"]
    static var contentTypes: [UTType] {
        fileExtensions.map { UTType(filenameExtension: $0) ?? UTType(importedAs: "local.lucent.chess.\($0)", conformingTo: .data) }
    }

    static func read(_ url: URL, readerURL: URL? = nil) throws -> ChessBaseImportBatch {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LucentChessImport-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databases: [URL]
        switch url.pathExtension.lowercased() {
        case "cbv":
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= CBVArchive.maximumSize else { throw ChessBaseImportError.tooLarge }
            let files = try CBVArchive.extract(Data(contentsOf: url), to: directory.appendingPathComponent("archive"))
            guard !files.contains(where: { $0.pathExtension.lowercased() == "2cbh" }) else { throw ChessBaseImportError.unsupportedFormat }
            databases = files.filter { $0.pathExtension.lowercased() == "cbh" }
            guard !databases.isEmpty else { throw ChessBaseImportError.unsupportedFormat }
        case "cbh": databases = [url]
        default: throw ChessBaseImportError.unsupportedFormat
        }
        var games: [ChessStudy] = []
        var skipped = 0
        var totalBytes = 0
        var totalMoves = 0
        for (index, database) in databases.enumerated() {
            let staged = try stage(database, in: directory.appendingPathComponent("database-\(index)"), totalBytes: &totalBytes)
            let output = directory.appendingPathComponent("games-\(index).json")
            try runReader(at: readerURL ?? bundledReader(), database: staged, output: output)
            let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= CBVArchive.maximumSize else { throw ChessBaseImportError.tooLarge }
            let decoded = try JSONDecoder().decode(DecodedDatabase.self, from: Data(contentsOf: output))
            skipped += decoded.skipped
            guard games.count + decoded.games.count + skipped <= 10000 else { throw ChessBaseImportError.tooLarge }
            for game in decoded.games {
                totalMoves += game.moves.count
                guard totalMoves <= 500000 else { throw ChessBaseImportError.tooLarge }
                do { games.append(try game.makeStudy()) }
                catch { skipped += 1 }
            }
        }
        guard !games.isEmpty else {
            throw ChessBaseImportError.readerFailed("No supported games were found; \(skipped) records could not be imported.")
        }
        return ChessBaseImportBatch(games: games, skipped: skipped)
    }

    private static func bundledReader() throws -> URL {
        if let url = Bundle.main.url(forAuxiliaryExecutable: "LucentChessCBH") { return url }
        if let executable = Bundle.main.executableURL {
            let sibling = executable.deletingLastPathComponent().appendingPathComponent("LucentChessCBH")
            if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        throw ChessBaseImportError.readerUnavailable
    }

    // Normalize case for the upstream reader without renaming the user's files.
    private static func stage(_ database: URL, in directory: URL, totalBytes: inout Int) throws -> URL {
        let parent = database.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        let stem = database.deletingPathExtension().lastPathComponent.lowercased()
        var companions: [(URL, String)] = []
        var missing: [String] = []
        for ext in ["cbh", "cbg", "cba", "cbp", "cbt", "cbc", "cbs"] {
            let matches = files.filter { $0.lastPathComponent.lowercased() == "\(stem).\(ext)" }
            guard matches.count == 1, let file = matches.first,
                  FileManager.default.isReadableFile(atPath: file.path) else {
                missing.append(".\(ext)"); continue
            }
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { throw ChessBaseImportError.missingFiles(file.lastPathComponent) }
            let size = values.fileSize ?? 0
            guard size <= CBVArchive.maximumSize - totalBytes else { throw ChessBaseImportError.tooLarge }
            totalBytes += size
            companions.append((file, ext))
        }
        guard missing.isEmpty else { throw ChessBaseImportError.missingFiles(missing.joined(separator: ", ")) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (file, ext) in companions {
            try FileManager.default.copyItem(at: file, to: directory.appendingPathComponent("database.\(ext)"))
        }
        return directory.appendingPathComponent("database.cbh")
    }

    private static func runReader(at executable: URL, database: URL, output: URL) throws {
        let log = output.appendingPathExtension("log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let errors = try FileHandle(forWritingTo: log)
        defer { try? errors.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = [database.path, output.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = errors
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let handle = try FileHandle(forReadingFrom: log)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 4096) ?? Data()
            let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ChessBaseImportError.readerFailed(detail.isEmpty ? "The reader stopped or exceeded the import time limit." : detail)
        }
    }
}

private struct DecodedDatabase: Decodable {
    let games: [DecodedChessBaseGame]
    let skipped: Int
}

struct DecodedChessBaseGame: Decodable {
    let white: String
    let black: String
    let event: String
    let site: String
    let year: Int
    let month: Int
    let day: Int
    let round: String
    let whiteElo: Int
    let blackElo: Int
    let eco: String
    let result: String
    let fen: String
    let moves: [DecodedChessBaseMove]

    func makeStudy() throws -> ChessStudy {
        guard ChessPosition(fen: fen) != nil else { throw ChessBaseImportError.unsupportedGame }
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: max(year, 1), month: max(month, 1), day: max(day, 1))) ?? Date(timeIntervalSince1970: 0)
        let study = ChessStudy(title: event.isEmpty ? "Imported game" : event, white: white, black: black,
                               event: event, site: site, round: round,
                               whiteElo: whiteElo > 0 ? String(whiteElo) : nil,
                               blackElo: blackElo > 0 ? String(blackElo) : nil,
                               eco: eco.isEmpty ? nil : eco, date: date, result: result, startFEN: fen)
        var current = study.root
        var stack: [MoveNode] = []
        var ended = false
        for encoded in moves {
            guard !ended || encoded.promote == 253 else { throw ChessBaseImportError.unsupportedGame }
            switch encoded.promote {
            case 255:
                guard stack.count < 128 else { throw ChessBaseImportError.unsupportedGame }
                // CBH saves the branch point before the main line, then returns for each alternative.
                stack.append(current)
            case 254:
                if let branch = stack.popLast() { current = branch }
                else { ended = true }
            case 253: continue
            default:
                guard (0..<64).contains(encoded.from), (0..<64).contains(encoded.to),
                      let position = ChessPosition(fen: current.positionFEN) else { throw ChessBaseImportError.unsupportedGame }
                let promotion: String
                switch encoded.promote {
                case 1, 7: promotion = ""
                case 2: promotion = "q"
                case 3: promotion = "r"
                case 4: promotion = "b"
                case 5: promotion = "n"
                default: throw ChessBaseImportError.unsupportedGame
                }
                func square(_ value: Int) -> String { "\(String(UnicodeScalar(97 + value % 8)!))\(value / 8 + 1)" }
                let uci = square(encoded.from) + square(encoded.to) + promotion
                guard let move = position.legalMove(uci: uci) else { throw ChessBaseImportError.unsupportedGame }
                if !encoded.before.isEmpty {
                    current.comment += (current.comment.isEmpty ? "" : "\n") + encoded.before
                }
                let child = MoveNode(parentID: current.id, moveUCI: move.uci, moveSAN: position.san(for: move),
                                     positionFEN: position.applyingUnchecked(move).fen, comment: encoded.after, nags: encoded.nags)
                current.children.append(child)
                current = child
            }
        }
        guard stack.isEmpty else { throw ChessBaseImportError.unsupportedGame }
        study.rebuildNodeIndex()
        study.dirtyState = false
        return study
    }
}

struct DecodedChessBaseMove: Decodable {
    let from: Int
    let to: Int
    let promote: Int
    let before: String
    let after: String
    let nags: [Int]
}
