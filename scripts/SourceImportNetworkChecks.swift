import Foundation

@main
struct SourceImportNetworkChecks {
    static func main() async throws {
        let lichess = try await CanonicalGameImportService.fetch(
            .lichess(input: "https://lichess.org/8fuPHGyu", maxGames: 1, includeAnnotations: false)
        )
        guard lichess.games.count == 1, lichess.games[0].mainLinePlyCount > 0 else {
            throw Failure("The live Lichess game export was empty.")
        }
        print("✓ Live Lichess game export parsed \(lichess.games[0].mainLinePlyCount) plies")

        let twic = try await CanonicalGameImportService.fetch(.twicIssue(1658))
        guard !twic.games.isEmpty, twic.games.allSatisfy({ $0.mainLinePlyCount > 0 }) else {
            throw Failure("The live TWIC archive was empty or contained an empty game.")
        }
        print("✓ Live TWIC 1658 archive parsed \(twic.games.count) games")
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
