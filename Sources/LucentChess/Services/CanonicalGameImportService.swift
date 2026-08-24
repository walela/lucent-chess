import Foundation

enum CanonicalGameSource: String, CaseIterable, Identifiable {
    case twic = "TWIC"
    case lichess = "Lichess"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .twic: return "newspaper"
        case .lichess: return "checkerboard.rectangle"
        }
    }
}

enum CanonicalImportRequest: Sendable {
    case twicLatest
    case twicIssue(Int)
    case lichess(input: String, maxGames: Int, includeAnnotations: Bool)
}

struct CanonicalImportPayload: @unchecked Sendable {
    let games: [ChessStudy]
    let sourceName: String
    let sourceURL: URL
    let collectionName: String
    let detail: String
    let rejectedCount: Int
}

enum LichessImportTarget: Equatable, Sendable {
    case game(String)
    case user(String)
    case study(id: String, chapterID: String?)
    case broadcastRound(String)
}

enum CanonicalImportError: LocalizedError {
    case invalidTWICIssue
    case latestTWICIssueNotFound
    case invalidLichessInput
    case unsupportedLichessURL
    case noPGNInArchive
    case archiveExtraction(String)
    case responseTooLarge
    case notFound(String)
    case rateLimited
    case accessDenied
    case serverStatus(Int)
    case unreadableResponse

    var errorDescription: String? {
        switch self {
        case .invalidTWICIssue:
            return "Enter a valid TWIC issue number."
        case .latestTWICIssueNotFound:
            return "Lucent could not find the latest issue in the TWIC archive."
        case .invalidLichessInput:
            return "Enter a Lichess username or paste a public game, study, or broadcast-round URL."
        case .unsupportedLichessURL:
            return "That is not a supported Lichess game, player, study, or broadcast-round URL."
        case .noPGNInArchive:
            return "The downloaded TWIC archive did not contain a PGN file."
        case let .archiveExtraction(message):
            return "The TWIC archive could not be opened. \(message)"
        case .responseTooLarge:
            return "The source returned more data than Lucent can safely import at once."
        case let .notFound(source):
            return "\(source) could not be found or is not public."
        case .rateLimited:
            return "Lichess is receiving too many requests. Wait a minute, then try again."
        case .accessDenied:
            return "This source is not public or does not allow export."
        case let .serverStatus(status):
            return "The source server returned HTTP \(status)."
        case .unreadableResponse:
            return "The source returned data Lucent could not read as PGN."
        }
    }
}

enum CanonicalGameImportService {
    private static let twicArchiveURL = URL(string: "https://theweekinchess.com/twic")!
    private static let maximumDownloadSize = 120 * 1_024 * 1_024

    static func fetch(_ request: CanonicalImportRequest) async throws -> CanonicalImportPayload {
        switch request {
        case .twicLatest:
            let htmlData = try await download(twicArchiveURL, accept: "text/html")
            guard let html = decodeText(htmlData), let issue = latestTWICIssue(in: html) else {
                throw CanonicalImportError.latestTWICIssueNotFound
            }
            return try await fetchTWIC(issue: issue)
        case let .twicIssue(issue):
            guard issue > 0 else { throw CanonicalImportError.invalidTWICIssue }
            return try await fetchTWIC(issue: issue)
        case let .lichess(input, maxGames, includeAnnotations):
            let target = try resolveLichessTarget(input)
            return try await fetchLichess(
                target: target,
                maxGames: min(max(maxGames, 1), 500),
                includeAnnotations: includeAnnotations
            )
        }
    }

    static func twicIssueURL(_ issue: Int) -> URL? {
        guard issue > 0 else { return nil }
        return URL(string: "https://theweekinchess.com/zips/twic\(issue)g.zip")
    }

    static func latestTWICIssue(in html: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: #"twic(\d+)g\.zip"#, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return expression.matches(in: html, range: range).compactMap { match in
            guard let issueRange = Range(match.range(at: 1), in: html) else { return nil }
            return Int(html[issueRange])
        }.max()
    }

    static func parseTWICArchive(_ archive: Data) throws -> PGNBatchParseResult {
        try PGNService.parseBestEffort(extractPGN(fromZIP: archive))
    }

    static func resolveLichessTarget(_ rawInput: String) throws -> LichessImportTarget {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw CanonicalImportError.invalidLichessInput }

        if !input.contains("/") && !input.contains(":") && !input.contains(".") {
            let username = input.hasPrefix("@") ? String(input.dropFirst()) : input
            guard isValidLichessName(username) else { throw CanonicalImportError.invalidLichessInput }
            return .user(username)
        }

        let normalized = input.contains("://") ? input : "https://\(input)"
        guard let url = URL(string: normalized),
              let host = url.host?.lowercased(),
              host == "lichess.org" || host == "www.lichess.org" else {
            throw CanonicalImportError.invalidLichessInput
        }

        let components = url.pathComponents.filter { $0 != "/" }.map {
            $0.removingPercentEncoding ?? $0
        }
        guard let first = components.first else { throw CanonicalImportError.unsupportedLichessURL }

        if first == "@", components.count >= 2, isValidLichessName(components[1]) {
            return .user(components[1])
        }
        if first == "game", components.count >= 3, components[1] == "export",
           let id = normalizedGameID(components[2]) {
            return .game(id)
        }
        if first == "study", components.count >= 2, isLichessID(components[1]) {
            let chapterID = components.count >= 3 && isLichessID(components[2]) ? components[2] : nil
            return .study(id: components[1], chapterID: chapterID)
        }
        if first == "broadcast", components.count >= 4,
           let id = components.reversed().first(where: isLichessID) {
            return .broadcastRound(id)
        }
        if let id = normalizedGameID(first) { return .game(id) }
        throw CanonicalImportError.unsupportedLichessURL
    }

    static func lichessURL(
        for target: LichessImportTarget,
        maxGames: Int,
        includeAnnotations: Bool
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lichess.org"

        switch target {
        case let .game(id):
            components.path = "/game/export/\(id)"
            components.queryItems = commonLichessQuery(includeAnnotations: includeAnnotations)
        case let .user(username):
            components.path = "/api/games/user/\(username)"
            components.queryItems = [
                URLQueryItem(name: "max", value: String(min(max(maxGames, 1), 500))),
                URLQueryItem(
                    name: "perfType",
                    value: "ultraBullet,bullet,blitz,rapid,classical,correspondence"
                ),
                URLQueryItem(name: "moves", value: "true"),
                URLQueryItem(name: "tags", value: "true"),
                URLQueryItem(name: "clocks", value: "false"),
                URLQueryItem(name: "evals", value: includeAnnotations ? "true" : "false"),
                URLQueryItem(name: "opening", value: "true"),
                URLQueryItem(name: "literate", value: "false")
            ]
        case let .study(id, chapterID):
            components.path = chapterID.map { "/api/study/\(id)/\($0).pgn" } ?? "/api/study/\(id).pgn"
            components.queryItems = [
                URLQueryItem(name: "clocks", value: "false"),
                URLQueryItem(name: "comments", value: includeAnnotations ? "true" : "false"),
                URLQueryItem(name: "variations", value: "true")
            ]
        case let .broadcastRound(id):
            components.path = "/api/broadcast/round/\(id).pgn"
            components.queryItems = [
                URLQueryItem(name: "clocks", value: "false"),
                URLQueryItem(name: "comments", value: includeAnnotations ? "true" : "false")
            ]
        }
        return components.url
    }

    private static func fetchTWIC(issue: Int) async throws -> CanonicalImportPayload {
        guard let url = twicIssueURL(issue) else { throw CanonicalImportError.invalidTWICIssue }
        let archive = try await download(url, accept: "application/zip")
        let parsed = try await Task.detached(priority: .userInitiated) {
            ParsedGamesBox(try parseTWICArchive(archive))
        }.value
        return CanonicalImportPayload(
            games: parsed.games,
            sourceName: "TWIC",
            sourceURL: url,
            collectionName: "TWIC \(issue)",
            detail: "TWIC \(issue)",
            rejectedCount: parsed.rejectedCount
        )
    }

    private static func fetchLichess(
        target: LichessImportTarget,
        maxGames: Int,
        includeAnnotations: Bool
    ) async throws -> CanonicalImportPayload {
        guard let url = lichessURL(for: target, maxGames: maxGames, includeAnnotations: includeAnnotations) else {
            throw CanonicalImportError.invalidLichessInput
        }
        let data = try await download(url, accept: "application/x-chess-pgn")
        let parsed = try await Task.detached(priority: .userInitiated) {
            guard let text = decodeText(data) else { throw CanonicalImportError.unreadableResponse }
            return ParsedGamesBox(try PGNService.parseBestEffort(text))
        }.value

        let collectionName: String
        let detail: String
        switch target {
        case .game:
            collectionName = "Lichess imports"
            detail = "Lichess game"
        case let .user(username):
            collectionName = "Lichess — \(username)"
            detail = "Recent games by \(username)"
        case let .study(id, _):
            let event = parsed.games.first?.event.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            collectionName = event.isEmpty || event == "?" ? "Lichess Study \(id)" : event
            detail = "Lichess study"
        case let .broadcastRound(id):
            let event = parsed.games.first?.event.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            collectionName = event.isEmpty || event == "?" ? "Lichess Broadcast \(id)" : event
            detail = "Lichess broadcast round"
        }
        return CanonicalImportPayload(
            games: parsed.games,
            sourceName: "Lichess",
            sourceURL: url,
            collectionName: collectionName,
            detail: detail,
            rejectedCount: parsed.rejectedCount
        )
    }

    private static func download(_ url: URL, accept: String) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        request.setValue("LucentChess/\(version) (+https://github.com/walela/lucent-chess)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CanonicalImportError.unreadableResponse }
        switch http.statusCode {
        case 200...299: break
        case 403: throw CanonicalImportError.accessDenied
        case 404: throw CanonicalImportError.notFound(url.host == "lichess.org" ? "The Lichess source" : "That TWIC issue")
        case 429: throw CanonicalImportError.rateLimited
        default: throw CanonicalImportError.serverStatus(http.statusCode)
        }
        guard data.count <= maximumDownloadSize else { throw CanonicalImportError.responseTooLarge }
        return data
    }

    private static func extractPGN(fromZIP archive: Data) throws -> String {
        let fileManager = FileManager.default
        let workingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("Lucent-TWIC-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = workingDirectory.appendingPathComponent("issue.zip")
        let expandedURL = workingDirectory.appendingPathComponent("Expanded", isDirectory: true)
        try fileManager.createDirectory(at: expandedURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workingDirectory) }
        try archive.write(to: archiveURL, options: .atomic)

        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, expandedURL.path]
        process.standardError = errors
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CanonicalImportError.archiveExtraction(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let message = decodeText(errors.fileHandleForReading.readDataToEndOfFile()) ?? ""
            throw CanonicalImportError.archiveExtraction(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let files = fileManager.enumerator(at: expandedURL, includingPropertiesForKeys: keys)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "pgn" }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending } ?? []
        guard !files.isEmpty else { throw CanonicalImportError.noPGNInArchive }

        var totalSize = 0
        var texts: [String] = []
        texts.reserveCapacity(files.count)
        for file in files {
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            totalSize += values.fileSize ?? 0
            guard totalSize <= maximumDownloadSize * 3 else { throw CanonicalImportError.responseTooLarge }
            let data = try Data(contentsOf: file)
            guard let text = decodeText(data) else { throw CanonicalImportError.unreadableResponse }
            texts.append(text)
        }
        guard !texts.isEmpty else { throw CanonicalImportError.noPGNInArchive }
        return texts.joined(separator: "\n\n")
    }

    private static func commonLichessQuery(includeAnnotations: Bool) -> [URLQueryItem] {
        [
            URLQueryItem(name: "moves", value: "true"),
            URLQueryItem(name: "tags", value: "true"),
            URLQueryItem(name: "clocks", value: "false"),
            URLQueryItem(name: "evals", value: includeAnnotations ? "true" : "false"),
            URLQueryItem(name: "opening", value: "true"),
            URLQueryItem(name: "literate", value: "false")
        ]
    }

    private static func isValidLichessName(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{1,30}$"#, options: .regularExpression) != nil
    }

    private static func isLichessID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9]{8}$"#, options: .regularExpression) != nil
    }

    private static func normalizedGameID(_ value: String) -> String? {
        let candidate = String(value.prefix(8))
        return isLichessID(candidate) ? candidate : nil
    }

    private static func decodeText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}

private struct ParsedGamesBox: @unchecked Sendable {
    let games: [ChessStudy]
    let rejectedCount: Int

    init(_ result: PGNBatchParseResult) {
        games = result.games
        rejectedCount = result.rejectedCount
    }
}
