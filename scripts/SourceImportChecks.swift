import Foundation

@main
struct SourceImportChecks {
    static func main() throws {
        let archiveHTML = """
        <a href="/zips/twic1656g.zip">TWIC 1656</a>
        <a href="https://theweekinchess.com/zips/twic1658g.zip">TWIC 1658</a>
        <a href="/zips/twic1657g.zip">TWIC 1657</a>
        """
        try check("TWIC archive discovery chooses the newest issue") {
            CanonicalGameImportService.latestTWICIssue(in: archiveHTML) == 1658
        }
        try check("TWIC issue URLs use the official ZIP pattern") {
            CanonicalGameImportService.twicIssueURL(1658)?.absoluteString
                == "https://theweekinchess.com/zips/twic1658g.zip"
        }
        try check("TWIC ZIP extraction feeds its PGN into the normal parser") {
            try CanonicalGameImportService.parseTWICArchive(makeTWICFixture()).games.first?.mainLinePlyCount == 4
        }
        try check("A malformed score does not discard the rest of a source archive") {
            let batch = try PGNService.parseBestEffort("""
            [Event "Valid"]
            [Result "*"]

            1. e4 e5 *

            [Event "Broken"]
            [Result "*"]

            1. DefinitelyNotAMove *
            """)
            return batch.games.count == 1 && batch.rejectedCount == 1
        }

        try check("A Lichess game URL resolves to the eight-character game ID") {
            try CanonicalGameImportService.resolveLichessTarget("https://lichess.org/8fuPHGyu/black") == .game("8fuPHGyu")
        }
        try check("A Lichess profile URL resolves to a player import") {
            try CanonicalGameImportService.resolveLichessTarget("lichess.org/@/DrNykterstein") == .user("DrNykterstein")
        }
        try check("A plain Lichess username resolves to a player import") {
            try CanonicalGameImportService.resolveLichessTarget("DrNykterstein") == .user("DrNykterstein")
        }
        try check("A username prefixed with an at-sign resolves to a player import") {
            try CanonicalGameImportService.resolveLichessTarget("@DrNykterstein") == .user("DrNykterstein")
        }
        try check("Lichess studies preserve an optional chapter ID") {
            try CanonicalGameImportService.resolveLichessTarget("https://lichess.org/study/abcdEF12/zYxWvu98")
                == .study(id: "abcdEF12", chapterID: "zYxWvu98")
        }
        try check("Lichess broadcast rounds resolve their public identifier") {
            try CanonicalGameImportService.resolveLichessTarget("https://lichess.org/broadcast/event/round/AbCd1234")
                == .broadcastRound("AbCd1234")
        }
        try check("Lichess broadcast rounds use the finite round PGN endpoint") {
            CanonicalGameImportService.lichessURL(
                for: .broadcastRound("AbCd1234"),
                playerFilters: LichessPlayerImportFilters(),
                includeAnnotations: true
            )?.path == "/api/broadcast/round/AbCd1234.pgn"
        }
        try check("Other hosts are rejected") {
            do {
                _ = try CanonicalGameImportService.resolveLichessTarget("https://example.com/game/8fuPHGyu")
                return false
            } catch { return true }
        }

        var filters = LichessPlayerImportFilters()
        filters.maximumGames = 100
        filters.speeds = [.blitz, .rapid]
        filters.color = .black
        filters.rated = .rated
        let userURL = try require(
            CanonicalGameImportService.lichessURL(
                for: .user("DrNykterstein"),
                playerFilters: filters,
                includeAnnotations: true
            )
        )
        let components = try require(URLComponents(url: userURL, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        try check("Player export maps speed, color, and rated filters to Lichess") {
            components.path == "/api/games/user/DrNykterstein"
                && query["max"] == "100"
                && query["perfType"] == "blitz,rapid"
                && query["color"] == "black"
                && query["rated"] == "true"
        }
        try check("Player export requests PGN metadata and optional evaluations") {
            query["moves"] == "true" && query["tags"] == "true"
                && query["evals"] == "true" && query["clocks"] == "false"
        }
        var defaultFilters = LichessPlayerImportFilters()
        defaultFilters.maximumGames = 999
        let defaultURL = try require(
            CanonicalGameImportService.lichessURL(
                for: .user("DrNykterstein"),
                playerFilters: defaultFilters,
                includeAnnotations: false
            )
        )
        let defaultQuery = Dictionary(uniqueKeysWithValues:
            (URLComponents(url: defaultURL, resolvingAgainstBaseURL: false)?.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            }
        )
        try check("Default player filters include every standard speed and retain the safety cap") {
            defaultQuery["max"] == "500"
                && defaultQuery["perfType"] == "ultraBullet,bullet,blitz,rapid,classical,correspondence"
                && defaultQuery["color"] == nil
                && defaultQuery["rated"] == nil
        }

        let win = study(white: "DrNykterstein", black: "Opponent", result: "1-0")
        let loss = study(white: "Opponent", black: "DrNykterstein", result: "1-0")
        let draw = study(white: "Opponent", black: "DrNykterstein", result: "1/2-1/2")
        try check("Result filtering is calculated from the requested player’s color") {
            CanonicalGameImportService.filterUserGames(
                [win, loss, draw], username: "drnykterstein", result: .wins
            ).map(\.id) == [win.id]
                && CanonicalGameImportService.filterUserGames(
                    [win, loss, draw], username: "DRNYKTERSTEIN", result: .losses
                ).map(\.id) == [loss.id]
                && CanonicalGameImportService.filterUserGames(
                    [win, loss, draw], username: "DrNykterstein", result: .draws
                ).map(\.id) == [draw.id]
        }

        print("All canonical source import checks passed.")
    }

    private static func check(_ name: String, _ test: () throws -> Bool) throws {
        guard try test() else { throw Failure(name) }
        print("✓ \(name)")
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure("Required value was nil") }
        return value
    }

    private static func makeTWICFixture() throws -> Data {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("Lucent-Source-Test-\(UUID().uuidString)", isDirectory: true)
        let input = folder.appendingPathComponent("twic-test", isDirectory: true)
        let archive = folder.appendingPathComponent("twic-test.zip")
        try manager.createDirectory(at: input, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        let pgn = """
        [Event "TWIC fixture"]
        [Date "2026.08.24"]
        [White "Alpha"]
        [Black "Beta"]
        [Result "1/2-1/2"]

        1. e4 e5 2. Nf3 Nc6 1/2-1/2
        """
        try pgn.write(to: input.appendingPathComponent("twic-test.pgn"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", input.path, archive.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure("Could not make the TWIC ZIP fixture") }
        return try Data(contentsOf: archive)
    }

    private static func study(white: String, black: String, result: String) -> ChessStudy {
        ChessStudy(white: white, black: black, result: result)
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
