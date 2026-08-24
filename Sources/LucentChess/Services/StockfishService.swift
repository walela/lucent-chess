import AppKit
import Combine
import Foundation

private struct EngineOutputBatch: Sendable {
    var controlLines: [String]
    var latestInfoLine: String?
    var latestPVLines: [String]
}

private final class EngineOutputCoalescer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.lucent.chess.engine-output", qos: .userInitiated)
    private var pending = ""
    private var lineBuffer = ""
    private var scheduled = false
    private var generation = 0

    func enqueue(_ text: String, deliver: @escaping @Sendable (EngineOutputBatch) -> Void) {
        queue.async { [self] in
            pending += text
            guard !scheduled else { return }
            scheduled = true
            let scheduledGeneration = generation
            queue.asyncAfter(deadline: .now() + 0.08) { [self] in
                guard scheduledGeneration == generation else { return }
                lineBuffer += pending
                pending = ""
                scheduled = false
                let chunks = lineBuffer.components(separatedBy: .newlines)
                lineBuffer = chunks.last ?? ""

                var controls: [String] = []
                var latestInfo: String?
                var latestPVByLine: [Int: String] = [:]
                for line in chunks.dropLast() {
                    guard line.hasPrefix("info ") else {
                        controls.append(line)
                        continue
                    }
                    latestInfo = line
                    guard line.contains(" pv ") else { continue }
                    latestPVByLine[Self.multiPVNumber(in: line)] = line
                }
                let batch = EngineOutputBatch(
                    controlLines: controls,
                    latestInfoLine: latestInfo,
                    latestPVLines: latestPVByLine.keys.sorted().compactMap { latestPVByLine[$0] }
                )
                if !controls.isEmpty || latestInfo != nil { deliver(batch) }
            }
        }
    }

    func discard() {
        queue.async { [self] in
            generation &+= 1
            pending = ""
            lineBuffer = ""
            scheduled = false
        }
    }

    private static func multiPVNumber(in line: String) -> Int {
        let parts = line.split(separator: " ")
        guard let index = parts.firstIndex(of: "multipv"), index + 1 < parts.count else { return 1 }
        return Int(parts[index + 1]) ?? 1
    }
}

struct EngineLine: Identifiable, Equatable {
    var multipv: Int
    var depth: Int
    var score: String
    var moves: [String]
    var uciMoves: [String]
    var id: Int { multipv }
}

struct EngineWDL: Equatable {
    var wins: Int
    var draws: Int
    var losses: Int
}

struct EngineAnalysisSnapshot: Equatable {
    var lines: [EngineLine] = []
    var currentDepth = 0
    var selectedDepth = 0
    var nodes = 0
    var nodesPerSecond = 0
    var hashFullPermill = 0
    var elapsedMilliseconds = 0
    var wdl: EngineWDL?
}

@MainActor
final class EngineTelemetry: ObservableObject {
    @Published fileprivate(set) var snapshot = EngineAnalysisSnapshot()
}

enum UCIOptionKind: String, Equatable {
    case check, spin, combo, string, button
}

struct UCIEngineOption: Identifiable, Equatable {
    var name: String
    var kind: UCIOptionKind
    var defaultValue: String
    var value: String
    var minimum: Int?
    var maximum: Int?
    var choices: [String]

    var id: String { name }
}

enum EngineAnalysisMode: String, CaseIterable, Identifiable {
    case infinite = "Infinite"
    case depth = "Fixed depth"
    case time = "Fixed time"
    case nodes = "Fixed nodes"

    var id: String { rawValue }
}

enum EngineResourcePreset: String, CaseIterable, Identifiable {
    case quiet = "Quiet"
    case balanced = "Balanced"
    case maximum = "Maximum"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .quiet: return "Low heat and background use"
        case .balanced: return "Recommended for study"
        case .maximum: return "Deepest single-line search"
        }
    }
}

@MainActor
final class StockfishService: ObservableObject {
    enum State: Equatable {
        case unavailable
        case stopped
        case starting
        case ready
        case analyzing

        var label: String {
            switch self {
            case .unavailable: return "Engine not found"
            case .stopped: return "Engine off"
            case .starting: return "Starting…"
            case .ready: return "Ready"
            case .analyzing: return "Analyzing"
            }
        }
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var engineName = "Stockfish"
    @Published private(set) var options: [UCIEngineOption] = []
    @Published var lastError: String?
    @Published var threads: Int
    @Published var hashMB: Int
    @Published var multiPV: Int
    @Published var showWDL: Bool
    @Published var enginePath: String
    @Published var analysisMode: EngineAnalysisMode
    @Published var analysisDepth: Int
    @Published var analysisTimeSeconds: Double
    @Published var analysisNodes: Int

    let telemetry = EngineTelemetry()
    var lines: [EngineLine] { telemetry.snapshot.lines }
    var currentDepth: Int { telemetry.snapshot.currentDepth }
    var selectedDepth: Int { telemetry.snapshot.selectedDepth }
    var nodes: Int { telemetry.snapshot.nodes }
    var nodesPerSecond: Int { telemetry.snapshot.nodesPerSecond }
    var hashFullPermill: Int { telemetry.snapshot.hashFullPermill }
    var elapsedMilliseconds: Int { telemetry.snapshot.elapsedMilliseconds }
    var wdl: EngineWDL? { telemetry.snapshot.wdl }

    var maximumThreads: Int { max(1, ProcessInfo.processInfo.processorCount) }
    var recommendedThreads: Int { Self.recommendedThreadCount(for: maximumThreads) }
    var recommendedHashMB: Int { Self.recommendedHashSize(for: ProcessInfo.processInfo.physicalMemory) }
    var maximumPresetHashMB: Int { min(8192, recommendedHashMB * 2) }
    var physicalMemoryGB: Int {
        max(1, Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()))
    }
    var recommendedConfigurationSummary: String {
        "\(recommendedThreads) threads · \(recommendedHashMB >= 1024 ? "\(recommendedHashMB / 1024) GB" : "\(recommendedHashMB) MB") hash · 3 study lines"
    }
    var isAnalysisActive: Bool { wantsAnalysis }

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private let outputCoalescer = EngineOutputCoalescer()
    private var position = ChessPosition.starting
    private var wantsAnalysis = false
    private var optionOverrides: [String: String]
    private var pendingButtons: [String] = []

    init() {
        let defaults = UserDefaults.standard
        let cores = max(1, ProcessInfo.processInfo.processorCount)
        let recommendedThreads = Self.recommendedThreadCount(for: cores)
        let recommendedHash = Self.recommendedHashSize(for: ProcessInfo.processInfo.physicalMemory)
        let savedThreads = defaults.object(forKey: "engineThreads") as? Int
        let savedHash = defaults.object(forKey: "engineHash") as? Int
        let savedMultiPV = defaults.object(forKey: "engineMultiPV") as? Int
        let savedWDL = defaults.object(forKey: "engineShowWDL") as? Bool
        let hasSavedConfiguration = savedThreads != nil || savedHash != nil || savedMultiPV != nil || savedWDL != nil
        let matchesLegacyDefaults = savedThreads == max(1, cores - 2)
            && savedHash == 512
            && savedMultiPV == 3
            && savedWDL == true
        let recommendationVersion = defaults.integer(forKey: "engineRecommendedDefaultsVersion")
        let installsRecommendedDefaults = recommendationVersion < 1
            && (!hasSavedConfiguration || matchesLegacyDefaults)

        threads = installsRecommendedDefaults ? recommendedThreads : (savedThreads ?? recommendedThreads)
        hashMB = installsRecommendedDefaults ? recommendedHash : (savedHash ?? recommendedHash)
        multiPV = installsRecommendedDefaults ? 3 : (savedMultiPV ?? 3)
        showWDL = installsRecommendedDefaults ? true : (savedWDL ?? true)
        enginePath = defaults.string(forKey: "enginePath") ?? Self.detectEngine() ?? ""
        analysisMode = EngineAnalysisMode(rawValue: defaults.string(forKey: "engineAnalysisMode") ?? "") ?? .infinite
        analysisDepth = defaults.object(forKey: "engineAnalysisDepth") as? Int ?? 28
        analysisTimeSeconds = defaults.object(forKey: "engineAnalysisTime") as? Double ?? 10
        analysisNodes = defaults.object(forKey: "engineAnalysisNodes") as? Int ?? 10_000_000
        optionOverrides = defaults.dictionary(forKey: "engineUCIOverrides") as? [String: String] ?? [:]
        if recommendationVersion < 1 {
            if installsRecommendedDefaults {
                defaults.set(threads, forKey: "engineThreads")
                defaults.set(hashMB, forKey: "engineHash")
                defaults.set(multiPV, forKey: "engineMultiPV")
                defaults.set(showWDL, forKey: "engineShowWDL")
            }
            defaults.set(1, forKey: "engineRecommendedDefaultsVersion")
        }
        if enginePath.isEmpty { state = .unavailable }
    }

    deinit { process?.terminate() }

    func toggle(for position: ChessPosition) {
        if wantsAnalysis { stopEngine() }
        else { startAndAnalyze(position) }
    }

    func startAndAnalyze(_ newPosition: ChessPosition) {
        position = newPosition
        wantsAnalysis = true
        if process?.isRunning == true {
            if state != .starting { analyze(newPosition) }
            return
        }
        startEngine()
    }

    func loadOptions() {
        guard process?.isRunning != true else { return }
        wantsAnalysis = false
        startEngine()
    }

    func unloadIfIdle() {
        if !wantsAnalysis { stopEngine() }
    }

    func updatePosition(_ newPosition: ChessPosition) {
        position = newPosition
        guard state == .analyzing || wantsAnalysis else { return }
        analyze(newPosition)
    }

    func restartWithSettings() {
        persistSettings()
        let resume = wantsAnalysis || state == .analyzing
        let current = position
        stopEngine()
        if resume { startAndAnalyze(current) }
        else { loadOptions() }
    }

    func applyPreset(_ preset: EngineResourcePreset) {
        let cores = maximumThreads
        switch preset {
        case .quiet:
            threads = min(2, cores)
            hashMB = 256
            multiPV = 1
        case .balanced:
            threads = recommendedThreads
            hashMB = recommendedHashMB
            multiPV = 3
        case .maximum:
            threads = cores
            hashMB = maximumPresetHashMB
            multiPV = 1
        }
        showWDL = true
        synchronizeBasicOptionValues()
    }

    func applyRecommendedDefaults() {
        applyPreset(.balanced)
        analysisMode = .infinite
        persistSettings()
    }

    func chooseEngine() {
        let panel = NSOpenPanel()
        panel.message = "Choose a UCI chess engine executable (Stockfish recommended)."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if process?.isRunning == true { stopEngine() }
        enginePath = url.path
        engineName = url.deletingPathExtension().lastPathComponent
        options = []
        optionOverrides = [:]
        persistSettings()
        state = .stopped
        loadOptions()
    }

    func chooseSyzygyFolder() {
        let panel = NSOpenPanel()
        panel.message = "Choose a folder containing offline Syzygy tablebases."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setOption(named: "SyzygyPath", value: url.path)
    }

    func option(named name: String) -> UCIEngineOption? {
        options.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func optionValue(named name: String) -> String {
        option(named: name)?.value ?? optionOverrides[name] ?? ""
    }

    func setOption(named name: String, value: String) {
        guard let index = options.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            switch name.lowercased() {
            case "threads": threads = max(1, Int(value) ?? threads)
            case "hash": hashMB = max(1, Int(value) ?? hashMB)
            case "multipv": multiPV = max(1, Int(value) ?? multiPV)
            case "uci_showwdl": showWDL = Self.bool(from: value)
            default: optionOverrides[name] = value
            }
            persistSettings()
            return
        }

        let canonicalName = options[index].name
        options[index].value = value
        switch canonicalName.lowercased() {
        case "threads": threads = max(1, Int(value) ?? threads)
        case "hash": hashMB = max(1, Int(value) ?? hashMB)
        case "multipv": multiPV = max(1, Int(value) ?? multiPV)
        case "uci_showwdl": showWDL = Self.bool(from: value)
        default:
            if value == options[index].defaultValue { optionOverrides.removeValue(forKey: canonicalName) }
            else { optionOverrides[canonicalName] = value }
        }
        persistSettings()
    }

    func pressOption(named name: String) {
        guard let canonical = canonicalOptionName(name), option(named: canonical)?.kind == .button else { return }
        if process?.isRunning == true {
            let resume = wantsAnalysis || state == .analyzing
            send("stop")
            send("setoption name \(canonical)")
            send("isready")
            wantsAnalysis = resume
        } else {
            pendingButtons.append(canonical)
            loadOptions()
        }
    }

    func restoreEngineDefaults() {
        optionOverrides.removeAll()
        for index in options.indices {
            guard options[index].kind != .button else { continue }
            options[index].value = options[index].defaultValue
        }
        if let value = option(named: "Threads")?.defaultValue, let number = Int(value) { threads = number }
        if let value = option(named: "Hash")?.defaultValue, let number = Int(value) { hashMB = number }
        if let value = option(named: "MultiPV")?.defaultValue, let number = Int(value) { multiPV = number }
        if let value = option(named: "UCI_ShowWDL")?.defaultValue { showWDL = Self.bool(from: value) }
        persistSettings()
    }

    func stopEngine() {
        wantsAnalysis = false
        send("stop")
        send("quit")
        output?.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = nil
        resetStatistics()
        state = enginePath.isEmpty ? .unavailable : .stopped
    }

    static func parseOptionLine(_ line: String) -> UCIEngineOption? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 5,
              tokens[0] == "option", tokens[1] == "name",
              let typeIndex = tokens.firstIndex(of: "type"), typeIndex > 2,
              typeIndex + 1 < tokens.count,
              let kind = UCIOptionKind(rawValue: tokens[typeIndex + 1]) else { return nil }

        let name = tokens[2..<typeIndex].joined(separator: " ")
        let markers: Set<String> = ["default", "min", "max", "var"]
        var currentMarker: String?
        var currentTokens: [String] = []
        var defaultValue = ""
        var minimum: Int?
        var maximum: Int?
        var choices: [String] = []

        func normalized(_ text: String) -> String { text == "<empty>" ? "" : text }
        func consume(_ marker: String?, _ values: [String]) {
            guard let marker else { return }
            let value = normalized(values.joined(separator: " "))
            switch marker {
            case "default": defaultValue = value
            case "min": minimum = Int(value)
            case "max": maximum = Int(value)
            case "var": choices.append(value)
            default: break
            }
        }

        if typeIndex + 2 < tokens.count {
            for token in tokens[(typeIndex + 2)...] {
                if markers.contains(token) {
                    consume(currentMarker, currentTokens)
                    currentMarker = token
                    currentTokens = []
                } else {
                    currentTokens.append(token)
                }
            }
        }
        consume(currentMarker, currentTokens)

        return UCIEngineOption(
            name: name,
            kind: kind,
            defaultValue: defaultValue,
            value: defaultValue,
            minimum: minimum,
            maximum: maximum,
            choices: choices
        )
    }

    // Kept internal so the performance harness can verify output throttling
    // without launching or instrumenting a user-selected engine process.
    func ingestEngineOutputForTesting(_ text: String) {
        outputCoalescer.enqueue(text) { [weak self] batch in
            DispatchQueue.main.async { self?.consume(batch) }
        }
    }

    private func startEngine() {
        guard !enginePath.isEmpty, FileManager.default.isExecutableFile(atPath: enginePath) else {
            state = .unavailable
            lastError = "Stockfish was not found. Install it with Homebrew (`brew install stockfish`) or choose another UCI engine."
            return
        }
        let task = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        task.executableURL = URL(fileURLWithPath: enginePath)
        task.standardInput = stdinPipe
        task.standardOutput = stdoutPipe
        task.standardError = stdoutPipe
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.engineTerminated() }
        }
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.outputCoalescer.enqueue(text) { [weak self] batch in
                DispatchQueue.main.async { self?.consume(batch) }
            }
        }
        do {
            options = []
            outputCoalescer.discard()
            lastError = nil
            try task.run()
            process = task
            state = .starting
            send("uci")
        } catch {
            lastError = error.localizedDescription
            state = .unavailable
        }
    }

    private func analyze(_ newPosition: ChessPosition) {
        guard process?.isRunning == true else { startAndAnalyze(newPosition); return }
        position = newPosition
        wantsAnalysis = true
        resetStatistics()
        send("stop")
        send("position fen \(newPosition.fen)")
        switch analysisMode {
        case .infinite:
            send("go infinite")
        case .depth:
            send("go depth \(max(1, analysisDepth))")
        case .time:
            send("go movetime \(max(100, Int(analysisTimeSeconds * 1_000)))")
        case .nodes:
            send("go nodes \(max(1, analysisNodes))")
        }
        state = .analyzing
    }

    private func configure() {
        sendOptionIfAvailable("Threads", value: String(max(1, threads)))
        sendOptionIfAvailable("Hash", value: String(max(1, hashMB)))
        sendOptionIfAvailable("MultiPV", value: String(max(1, multiPV)))
        sendOptionIfAvailable("UCI_ShowWDL", value: showWDL ? "true" : "false")

        let basicNames = Set(["threads", "hash", "multipv", "uci_showwdl"])
        for (name, value) in optionOverrides where !basicNames.contains(name.lowercased()) {
            sendOptionIfAvailable(name, value: value)
        }
        for button in pendingButtons { send("setoption name \(button)") }
        pendingButtons.removeAll()
        send("isready")
    }

    private func sendOptionIfAvailable(_ name: String, value: String) {
        guard let canonical = canonicalOptionName(name) else { return }
        send("setoption name \(canonical) value \(value)")
    }

    private func canonicalOptionName(_ name: String) -> String? {
        options.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.name
    }

    private func configuredValue(for option: UCIEngineOption) -> String {
        switch option.name.lowercased() {
        case "threads": return String(threads)
        case "hash": return String(hashMB)
        case "multipv": return String(multiPV)
        case "uci_showwdl": return showWDL ? "true" : "false"
        default:
            if let exact = optionOverrides[option.name] { return exact }
            if let match = optionOverrides.first(where: { $0.key.caseInsensitiveCompare(option.name) == .orderedSame }) { return match.value }
            return option.defaultValue
        }
    }

    private func synchronizeBasicOptionValues() {
        for (name, value) in [
            ("Threads", String(threads)),
            ("Hash", String(hashMB)),
            ("MultiPV", String(multiPV)),
            ("UCI_ShowWDL", showWDL ? "true" : "false")
        ] {
            if let index = options.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                options[index].value = value
            }
        }
    }

    private func consume(_ batch: EngineOutputBatch) {
        for line in batch.controlLines { consumeControlLine(line) }
        guard batch.latestInfoLine != nil || !batch.latestPVLines.isEmpty else { return }
        var snapshot = telemetry.snapshot
        for line in batch.latestPVLines { consumeInfoLine(line, into: &snapshot, includePV: true) }
        if let latestInfoLine = batch.latestInfoLine {
            consumeInfoLine(latestInfoLine, into: &snapshot, includePV: false)
        }
        if snapshot != telemetry.snapshot { telemetry.snapshot = snapshot }
    }

    private func consumeControlLine(_ line: String) {
        if line.hasPrefix("id name ") { engineName = String(line.dropFirst(8)); return }
        if line.hasPrefix("option "), var option = Self.parseOptionLine(line) {
            option.value = configuredValue(for: option)
            if let index = options.firstIndex(where: { $0.name == option.name }) { options[index] = option }
            else { options.append(option) }
            return
        }
        if line == "uciok" { configure(); return }
        if line == "readyok" {
            state = .ready
            if wantsAnalysis { analyze(position) }
            return
        }
        if line.hasPrefix("bestmove ") {
            state = .ready
            return
        }
    }

    private func consumeInfoLine(_ line: String, into snapshot: inout EngineAnalysisSnapshot, includePV: Bool) {
        let parts = line.split(separator: " ").map(String.init)
        func value(after key: String) -> String? {
            guard let index = parts.firstIndex(of: key), index + 1 < parts.count else { return nil }
            return parts[index + 1]
        }
        if let value = value(after: "depth").flatMap(Int.init) { snapshot.currentDepth = value }
        if let value = value(after: "seldepth").flatMap(Int.init) { snapshot.selectedDepth = value }
        if let value = value(after: "nodes").flatMap(Int.init) { snapshot.nodes = value }
        if let value = value(after: "nps").flatMap(Int.init) { snapshot.nodesPerSecond = value }
        if let value = value(after: "hashfull").flatMap(Int.init) { snapshot.hashFullPermill = value }
        if let value = value(after: "time").flatMap(Int.init) { snapshot.elapsedMilliseconds = value }
        if let index = parts.firstIndex(of: "wdl"), index + 3 < parts.count {
            snapshot.wdl = EngineWDL(
                wins: Int(parts[index + 1]) ?? 0,
                draws: Int(parts[index + 2]) ?? 0,
                losses: Int(parts[index + 3]) ?? 0
            )
        }

        guard includePV else { return }
        guard let pvIndex = parts.firstIndex(of: "pv"), pvIndex + 1 < parts.count else { return }
        let pv = Array(parts[(pvIndex + 1)...])
        let number = Int(value(after: "multipv") ?? "1") ?? 1
        let depth = Int(value(after: "depth") ?? "0") ?? 0
        let score: String
        if let scoreIndex = parts.firstIndex(of: "score"), scoreIndex + 2 < parts.count {
            let kind = parts[scoreIndex + 1]
            let sideScore = Int(parts[scoreIndex + 2]) ?? 0
            let raw = position.sideToMove == .white ? sideScore : -sideScore
            if kind == "mate" { score = raw > 0 ? "M\(raw)" : "−M\(abs(raw))" }
            else { score = String(format: "%+.2f", Double(raw) / 100) }
        } else { score = "—" }
        let sanMoves = sanSequence(from: pv, position: position)
        let newLine = EngineLine(multipv: number, depth: depth, score: score, moves: sanMoves, uciMoves: pv)
        if let index = snapshot.lines.firstIndex(where: { $0.multipv == number }) {
            snapshot.lines[index] = newLine
        } else {
            snapshot.lines.append(newLine)
            snapshot.lines.sort { $0.multipv < $1.multipv }
        }
    }

    private func resetStatistics() {
        outputCoalescer.discard()
        telemetry.snapshot = EngineAnalysisSnapshot()
    }

    private func sanSequence(from uciMoves: [String], position start: ChessPosition) -> [String] {
        var board = start
        var result: [String] = []
        for uci in uciMoves.prefix(16) {
            guard let move = board.legalMove(uci: uci) else { break }
            result.append(board.san(for: move))
            board = board.applyingUnchecked(move)
        }
        return result
    }

    private func send(_ command: String) {
        guard let data = (command + "\n").data(using: .utf8) else { return }
        do { try input?.write(contentsOf: data) }
        catch { lastError = error.localizedDescription }
    }

    private func persistSettings() {
        let defaults = UserDefaults.standard
        defaults.set(threads, forKey: "engineThreads")
        defaults.set(hashMB, forKey: "engineHash")
        defaults.set(multiPV, forKey: "engineMultiPV")
        defaults.set(showWDL, forKey: "engineShowWDL")
        defaults.set(enginePath, forKey: "enginePath")
        defaults.set(analysisMode.rawValue, forKey: "engineAnalysisMode")
        defaults.set(analysisDepth, forKey: "engineAnalysisDepth")
        defaults.set(analysisTimeSeconds, forKey: "engineAnalysisTime")
        defaults.set(analysisNodes, forKey: "engineAnalysisNodes")
        defaults.set(optionOverrides, forKey: "engineUCIOverrides")
    }

    private func engineTerminated() {
        guard process != nil else { return }
        process = nil
        if wantsAnalysis { lastError = "The chess engine stopped unexpectedly." }
        state = enginePath.isEmpty ? .unavailable : .stopped
    }

    private static func bool(from value: String) -> Bool {
        ["true", "1", "yes", "on"].contains(value.lowercased())
    }

    nonisolated static func recommendedThreadCount(for processorCount: Int) -> Int {
        let cores = max(1, processorCount)
        return cores >= 6 ? cores - 2 : max(1, cores - 1)
    }

    nonisolated static func recommendedHashSize(for physicalMemory: UInt64) -> Int {
        let gibibytes = Double(physicalMemory) / 1_073_741_824
        if gibibytes >= 64 { return 4096 }
        if gibibytes >= 32 { return 2048 }
        if gibibytes >= 16 { return 1024 }
        if gibibytes >= 8 { return 512 }
        return 256
    }

    private static func detectEngine() -> String? {
        let candidates = [
            Bundle.main.path(forResource: "stockfish", ofType: nil),
            "/opt/homebrew/bin/stockfish",
            "/usr/local/bin/stockfish",
            "/opt/local/bin/stockfish"
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
