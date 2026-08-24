import AppKit
import Combine
import Foundation

@main
struct EngineChecks {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)

        try checkParser()
        try checkRecommendations()
        try checkOutputCoalescing()

        let stockfish = ["/opt/homebrew/bin/stockfish", "/usr/local/bin/stockfish"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let stockfish else {
            print("– Stockfish integration check skipped: no executable found")
            return
        }

        let engine = StockfishService()
        engine.applyPreset(.balanced)
        try check("Balanced uses the Mac-aware study recommendation") {
            engine.threads == engine.recommendedThreads
                && engine.hashMB == engine.recommendedHashMB
                && engine.multiPV == 3
                && engine.showWDL
        }
        engine.applyPreset(.maximum)
        try check("Maximum spends all cores on the strongest single line") {
            engine.threads == engine.maximumThreads
                && engine.hashMB == engine.maximumPresetHashMB
                && engine.multiPV == 1
        }
        engine.enginePath = stockfish
        engine.loadOptions()
        try wait(until: { engine.state == .ready }, timeout: 8, message: "engine did not become ready")

        try check("engine exposes its UCI options") {
            engine.options.count >= 10 && engine.option(named: "Threads") != nil && engine.option(named: "Clear Hash")?.kind == .button
        }

        engine.analysisMode = .depth
        engine.analysisDepth = 6
        engine.toggle(for: .starting)
        try wait(until: { engine.state == .ready && !engine.lines.isEmpty }, timeout: 8, message: "idle loaded engine did not start analysis")
        try check("Analyze starts an engine that was loaded only for configuration") { engine.isAnalysisActive }
        engine.toggle(for: .starting)
        try check("Stop disables the configured analysis session") { engine.state == .stopped && !engine.isAnalysisActive }
        engine.loadOptions()
        try wait(until: { engine.state == .ready }, timeout: 8, message: "engine did not reload after stop")

        engine.setOption(named: "Threads", value: "1")
        engine.setOption(named: "MultiPV", value: "2")
        engine.analysisMode = .depth
        engine.analysisDepth = 8
        engine.restartWithSettings()
        try wait(until: { engine.state == .ready }, timeout: 8, message: "configured engine did not restart")
        engine.startAndAnalyze(.starting)
        try wait(until: { engine.state == .ready && engine.lines.count == 2 }, timeout: 12, message: "fixed-depth MultiPV analysis did not finish")
        try check("configured fixed-depth MultiPV analysis completes") {
            engine.lines.count == 2 && engine.lines.allSatisfy { $0.depth >= 8 }
        }

        engine.stopEngine()
        print("All engine checks passed.")
    }

    @MainActor
    private static func checkOutputCoalescing() throws {
        let engine = StockfishService()
        var publications = 0
        let subscription = engine.telemetry.$snapshot.dropFirst().sink { _ in publications += 1 }
        let output = (1...3_000).map { depth in
            let line = (depth % 3) + 1
            return "info depth \(depth) seldepth \(depth + 2) multipv \(line) score cp \(line * 10) nodes \(depth * 1_000) nps 500000 pv e2e4 e7e5 g1f3 b8c6"
        }.joined(separator: "\n") + "\n"

        let enqueueStart = ContinuousClock.now
        engine.ingestEngineOutputForTesting(output)
        let enqueueDuration = ContinuousClock.now - enqueueStart
        try wait(until: { engine.lines.count == 3 }, timeout: 2, message: "coalesced synthetic output was not delivered")
        try check("engine output ingestion never blocks the UI thread") { enqueueDuration < .milliseconds(20) }
        try check("3,000 engine messages collapse into one telemetry publication") { publications == 1 }
        try check("coalescing preserves the newest line for every MultiPV slot") {
            engine.lines.map(\.multipv) == [1, 2, 3] && engine.currentDepth == 3_000
        }
        subscription.cancel()
    }

    @MainActor
    private static func checkParser() throws {
        let spin = StockfishService.parseOptionLine("option name UCI Elo type spin default 1320 min 1320 max 3190")
        try check("UCI spin option parser keeps a spaced name and bounds") {
            spin?.name == "UCI Elo" && spin?.kind == .spin && spin?.minimum == 1320 && spin?.maximum == 3190
        }

        let combo = StockfishService.parseOptionLine("option name Style type combo default Normal var Solid var Normal var Very Aggressive")
        try check("UCI combo parser keeps multiword choices") {
            combo?.choices == ["Solid", "Normal", "Very Aggressive"]
        }

        let string = StockfishService.parseOptionLine("option name SyzygyPath type string default <empty>")
        try check("UCI empty strings normalize correctly") { string?.defaultValue == "" }
    }

    private static func checkRecommendations() throws {
        try check("8-core Macs reserve two logical cores for responsiveness") {
            StockfishService.recommendedThreadCount(for: 8) == 6
        }
        try check("smaller Macs still reserve one logical core") {
            StockfishService.recommendedThreadCount(for: 4) == 3
                && StockfishService.recommendedThreadCount(for: 1) == 1
        }
        try check("16 GB Macs receive a 1 GB Stockfish hash") {
            StockfishService.recommendedHashSize(for: 16 * 1_073_741_824) == 1024
        }
    }

    @MainActor
    private static func wait(until condition: () -> Bool, timeout: TimeInterval, message: String) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        }
        guard condition() else { throw Failure(message) }
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
