// CBV decoding adapted from uncbv by Antoni Boucher (2016), GPL-3.0-or-later.
// https://github.com/antoyo/uncbv, commit 3c18e8a7c6a30c21f945a1ab5462521c306dca57
import Foundation

enum ChessBaseImportError: LocalizedError {
    case invalidArchive
    case unsupportedFormat
    case tooLarge
    case missingFiles(String)
    case readerUnavailable
    case readerFailed(String)
    case unsupportedGame

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "This CBV archive is damaged or uses an unsupported compression format."
        case .unsupportedFormat: return "Open a classic CBH database or an unencrypted CBV archive. Newer 2CBH databases and encrypted archives are not supported."
        case .tooLarge: return "This ChessBase database exceeds the supported size of 256 MB of database files."
        case let .missingFiles(names): return "Keep the CBH file and its companion files in the same folder. Missing or unreadable: \(names)."
        case .readerUnavailable: return "The ChessBase reader is missing from this Lucent Chess build. Rebuild the app with scripts/build_app.sh."
        case let .readerFailed(message): return "Could not import this ChessBase database. \(message)"
        case .unsupportedGame: return "This game contains unsupported or invalid moves."
        }
    }
}

enum CBVArchive {
    static let maximumSize = 256 * 1024 * 1024

    // Extract only into a fresh temporary directory owned by the importer.
    static func extract(_ data: Data, to directory: URL) throws -> [URL] {
        guard data.count <= maximumSize else { throw ChessBaseImportError.tooLarge }
        var input = ByteReader(bytes: Array(data))
        guard try input.take(2) == [8, 0] else { throw ChessBaseImportError.unsupportedFormat }
        let count = try input.little(2)
        let entrySize = try input.little(1)
        _ = try input.take(3)
        guard count > 0, count <= 1024, entrySize >= 140 else { throw ChessBaseImportError.invalidArchive }
        var entries: [(name: String, compressed: Int, expanded: Int)] = []
        var names = Set<String>()
        var total = 0
        for _ in 0..<count {
            var entry = ByteReader(bytes: try input.take(entrySize))
            let rawName = try entry.take(132).prefix { $0 != 0 }
            guard let decoded = String(data: Data(rawName), encoding: .windowsCP1252), !decoded.isEmpty else {
                throw ChessBaseImportError.invalidArchive
            }
            let name = decoded.replacingOccurrences(of: "\\", with: "/")
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.contains(":"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  names.insert(name.lowercased()).inserted else { throw ChessBaseImportError.invalidArchive }
            let compressed = try entry.little(4)
            let expanded = try entry.little(4)
            guard compressed <= maximumSize, expanded <= maximumSize, total <= maximumSize - expanded else {
                throw ChessBaseImportError.tooLarge
            }
            total += expanded
            entries.append((name, compressed, expanded))
        }
        var files: [URL] = []
        for entry in entries {
            var inputFile = ByteReader(bytes: try input.take(entry.compressed))
            var result: [UInt8] = []
            while inputFile.remaining > 0 {
                let length = try inputFile.little(2)
                _ = try inputFile.take(2)
                var block = ByteReader(bytes: try inputFile.take(length))
                let flags = try block.little(1)
                guard flags <= 3 else { throw ChessBaseImportError.invalidArchive }
                var bytes = try block.take(block.remaining)
                if flags & 2 != 0 { bytes = try decodeHuffman(bytes) }
                if flags & 1 != 0 { bytes = try decompress(bytes, limit: entry.expanded - result.count) }
                guard bytes.count <= entry.expanded - result.count else { throw ChessBaseImportError.invalidArchive }
                result.append(contentsOf: bytes)
            }
            guard result.count == entry.expanded else { throw ChessBaseImportError.invalidArchive }
            let file = directory.appendingPathComponent(entry.name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(result).write(to: file, options: .withoutOverwriting)
            files.append(file)
        }
        guard input.remaining == 0 else { throw ChessBaseImportError.invalidArchive }
        return files
    }

    private static func decompress(_ bytes: [UInt8], limit: Int) throws -> [UInt8] {
        var input = ByteReader(bytes: bytes)
        var result: [UInt8] = []
        while input.remaining > 0 {
            var flags = try input.little(2)
            for _ in 0..<16 {
                guard input.remaining > 0 else { break }
                if flags & 0x8000 == 0 {
                    guard result.count < limit else { throw ChessBaseImportError.invalidArchive }
                    result.append(UInt8(try input.little(1)))
                } else {
                    let code = try input.little(1)
                    let high = code >> 4, low = code & 15
                    var length: Int
                    if high <= 1 {
                        length = high == 0 ? low + 3 : low + (try input.little(1)) * 16 + 19
                        let value = UInt8(try input.little(1))
                        guard length <= limit - result.count else { throw ChessBaseImportError.invalidArchive }
                        result.append(contentsOf: repeatElement(value, count: length))
                    } else {
                        let distance = (try input.little(1)) * 16 + low + 3
                        length = high == 2 ? (try input.little(1)) + 16 : high
                        guard distance <= result.count, length <= limit - result.count else { throw ChessBaseImportError.invalidArchive }
                        for _ in 0..<length { result.append(result[result.count - distance]) }
                    }
                }
                flags = (flags << 1) & 0xffff
            }
        }
        return result
    }

    private struct HuffmanNode {
        var zero: Int?
        var one: Int?
        var value: UInt8?
    }

    private static func decodeHuffman(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count >= 2 else { throw ChessBaseImportError.invalidArchive }
        let size = Int(bytes[0]) * 256 + Int(bytes[1])
        var bits = BitReader(bytes: bytes, offset: 16)
        var tree = [HuffmanNode()]
        for value in 0..<256 {
            let length = try bits.read(4)
            guard length > 0 else { continue }
            let code = try bits.read(length)
            var node = 0
            for position in (0..<length).reversed() {
                guard tree[node].value == nil else { throw ChessBaseImportError.invalidArchive }
                let one = code & (1 << position) != 0
                if let next = one ? tree[node].one : tree[node].zero { node = next }
                else {
                    let next = tree.count
                    tree.append(HuffmanNode())
                    if one { tree[node].one = next } else { tree[node].zero = next }
                    node = next
                }
            }
            guard tree[node].value == nil, tree[node].zero == nil, tree[node].one == nil else {
                throw ChessBaseImportError.invalidArchive
            }
            tree[node].value = UInt8(value)
        }
        var result: [UInt8] = []
        for _ in 0..<size {
            var node = 0
            while tree[node].value == nil {
                let one = try bits.read(1) == 1
                guard let next = one ? tree[node].one : tree[node].zero else { throw ChessBaseImportError.invalidArchive }
                node = next
            }
            result.append(tree[node].value!)
        }
        return result
    }

    private struct ByteReader {
        let bytes: [UInt8]
        var offset = 0
        var remaining: Int { bytes.count - offset }

        mutating func take(_ count: Int) throws -> [UInt8] {
            guard count >= 0, count <= remaining else { throw ChessBaseImportError.invalidArchive }
            defer { offset += count }
            return Array(bytes[offset..<offset + count])
        }

        mutating func little(_ count: Int) throws -> Int {
            try take(count).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        }
    }

    private struct BitReader {
        let bytes: [UInt8]
        var offset: Int

        mutating func read(_ count: Int) throws -> Int {
            guard count >= 0, count <= bytes.count * 8 - offset else { throw ChessBaseImportError.invalidArchive }
            var value = 0
            for _ in 0..<count {
                value = value * 2 + Int((bytes[offset / 8] >> (7 - offset % 8)) & 1)
                offset += 1
            }
            return value
        }
    }
}
