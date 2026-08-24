import SwiftUI

struct EngineConfigurationView: View {
    @EnvironmentObject private var engine: StockfishService
    @Environment(\.dismiss) private var dismiss
    @State private var showsAllOptions = false

    private var hashChoices: [Int] {
        Array(Set([64, 128, 256, 512, 1024, 2048, 4096, 8192, engine.hashMB])).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.orange.gradient)
                    Image(systemName: "cpu.fill").font(.title2).foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Engine configuration").font(.title2.bold())
                    Text("\(engine.engineName) · local UCI engine")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    engineSection
                    presetSection
                    hardwareSection
                    analysisSection
                    if hasStrengthControls { strengthSection }
                    if hasTablebaseControls { tablebaseSection }
                    allOptionsSection
                }
                .padding(20)
            }

            Divider()
            HStack {
                Button("Use recommended settings") { engine.applyRecommendedDefaults() }
                Spacer()
                Text("Changes are stored on this Mac")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Apply & Restart") {
                    engine.restartWithSettings()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 660, idealWidth: 720, minHeight: 640, idealHeight: 790)
        .onAppear { engine.loadOptions() }
        .onDisappear { engine.unloadIfIdle() }
    }

    private var engineSection: some View {
        GroupBox {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(engine.enginePath.isEmpty ? "No engine selected" : engine.enginePath)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2).textSelection(.enabled)
                    Text("You can use Stockfish or any macOS UCI-compatible engine.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose Engine…") { engine.chooseEngine() }
            }
            if let error = engine.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).padding(.top, 8)
            }
        } label: {
            Label("Engine", systemImage: "memorychip")
        }
    }

    private var presetSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(EngineResourcePreset.allCases) { preset in
                        Button { engine.applyPreset(preset) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.rawValue).font(.headline)
                                Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Label("For this Mac: \(engine.recommendedConfigurationSummary)", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Label("Mac resource presets", systemImage: "gauge.with.dots.needle.50percent")
        }
    }

    private var hardwareSection: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 12) {
                GridRow {
                    settingLabel("CPU threads", detail: "\(engine.recommendedThreads) recommended; leaves macOS headroom")
                    Stepper(value: threadsBinding, in: 1...engine.maximumThreads) {
                        Text("\(engine.threads) of \(engine.maximumThreads)")
                            .monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                }
                GridRow {
                    settingLabel("Hash memory", detail: "\(engine.recommendedHashMB) MB recommended for \(engine.physicalMemoryGB) GB RAM")
                    Picker("Hash memory", selection: hashBinding) {
                        ForEach(hashChoices, id: \.self) { Text("\($0) MB").tag($0) }
                    }
                    .labelsHidden().frame(width: 130)
                }
                GridRow {
                    settingLabel("Analysis lines", detail: "3 for study; 1 gives the strongest best line")
                    Stepper(value: multiPVBinding, in: 1...min(32, engine.option(named: "MultiPV")?.maximum ?? 32)) {
                        Text("\(engine.multiPV)").monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                }
            }
        } label: {
            Label("Hardware", systemImage: "cpu")
        }
    }

    private var analysisSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Search limit", selection: $engine.analysisMode) {
                    ForEach(EngineAnalysisMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch engine.analysisMode {
                case .infinite:
                    Text("Keeps improving the position until you stop it or make another move.")
                        .font(.caption).foregroundStyle(.secondary)
                case .depth:
                    Stepper(value: $engine.analysisDepth, in: 1...99) {
                        LabeledContent("Stop at depth") { Text("\(engine.analysisDepth) ply").monospacedDigit() }
                    }
                case .time:
                    Stepper(value: $engine.analysisTimeSeconds, in: 0.5...600, step: 0.5) {
                        LabeledContent("Time per position") { Text(engine.analysisTimeSeconds.formatted(.number.precision(.fractionLength(1))) + " s").monospacedDigit() }
                    }
                case .nodes:
                    Stepper(value: $engine.analysisNodes, in: 1_000...1_000_000_000, step: 100_000) {
                        LabeledContent("Nodes per position") { Text(engine.analysisNodes.formatted()).monospacedDigit() }
                    }
                }

                Toggle("Show win / draw / loss estimates", isOn: showWDLBinding)
                    .disabled(engine.option(named: "UCI_ShowWDL") == nil && !engine.options.isEmpty)
            }
        } label: {
            Label("Analysis behavior", systemImage: "scope")
        }
    }

    private var strengthSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if let limit = engine.option(named: "UCI_LimitStrength") {
                    optionControl(limit)
                }
                if let elo = engine.option(named: "UCI_Elo") {
                    optionControl(elo)
                }
                if let skill = engine.option(named: "Skill Level") {
                    optionControl(skill)
                }
                Text("Strength limits are useful when playing training positions against the engine; they do not improve analysis quality.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            Label("Playing strength", systemImage: "figure.chess")
        }
    }

    private var tablebaseSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let path = engine.option(named: "SyzygyPath") {
                    HStack {
                        optionControl(path)
                        Button("Choose Folder…") { engine.chooseSyzygyFolder() }
                    }
                }
                if let limit = engine.option(named: "SyzygyProbeLimit") { optionControl(limit) }
                if let depth = engine.option(named: "SyzygyProbeDepth") { optionControl(depth) }
                if let rule = engine.option(named: "Syzygy50MoveRule") { optionControl(rule) }
                Text("Lucent never downloads tablebases. Point this at tablebase files already stored on your Mac or external drive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            Label("Offline Syzygy tablebases", systemImage: "externaldrive")
        }
    }

    private var allOptionsSection: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $showsAllOptions) {
                if engine.options.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Reading options from the engine…") }
                        .font(.caption).foregroundStyle(.secondary).padding(.vertical, 10)
                } else {
                    VStack(spacing: 0) {
                        ForEach(engine.options) { option in
                            optionControl(option).padding(.vertical, 7)
                            if option.id != engine.options.last?.id { Divider() }
                        }
                    }
                    .padding(.top, 6)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("All UCI options").font(.headline)
                    Text("\(engine.options.count) controls reported by \(engine.engineName)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var hasStrengthControls: Bool {
        ["UCI_LimitStrength", "UCI_Elo", "Skill Level"].contains { engine.option(named: $0) != nil }
    }

    private var hasTablebaseControls: Bool {
        engine.options.contains { $0.name.lowercased().hasPrefix("syzygy") }
    }

    @ViewBuilder
    private func optionControl(_ option: UCIEngineOption) -> some View {
        switch option.kind {
        case .check:
            Toggle(option.name, isOn: boolBinding(option.name))
        case .spin:
            HStack {
                Text(option.name)
                Spacer()
                TextField(option.name, value: integerBinding(option.name), format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 88)
                Stepper("", value: integerBinding(option.name), in: (option.minimum ?? 0)...(option.maximum ?? 1_000_000))
                    .labelsHidden()
            }
        case .combo:
            HStack {
                Text(option.name)
                Spacer()
                Picker(option.name, selection: stringBinding(option.name)) {
                    ForEach(option.choices, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 230)
            }
        case .string:
            HStack {
                Text(option.name)
                TextField("Default", text: stringBinding(option.name))
                    .textFieldStyle(.roundedBorder)
            }
        case .button:
            HStack {
                Text(option.name)
                Spacer()
                Button(option.name == "Clear Hash" ? "Clear now" : "Run") { engine.pressOption(named: option.name) }
            }
        }
    }

    private func settingLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var threadsBinding: Binding<Int> {
        Binding(get: { engine.threads }, set: { engine.setOption(named: "Threads", value: String($0)) })
    }

    private var hashBinding: Binding<Int> {
        Binding(get: { engine.hashMB }, set: { engine.setOption(named: "Hash", value: String($0)) })
    }

    private var multiPVBinding: Binding<Int> {
        Binding(get: { engine.multiPV }, set: { engine.setOption(named: "MultiPV", value: String($0)) })
    }

    private var showWDLBinding: Binding<Bool> {
        Binding(get: { engine.showWDL }, set: { engine.setOption(named: "UCI_ShowWDL", value: $0 ? "true" : "false") })
    }

    private func stringBinding(_ name: String) -> Binding<String> {
        Binding(get: { engine.optionValue(named: name) }, set: { engine.setOption(named: name, value: $0) })
    }

    private func boolBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { ["true", "1", "yes", "on"].contains(engine.optionValue(named: name).lowercased()) },
            set: { engine.setOption(named: name, value: $0 ? "true" : "false") }
        )
    }

    private func integerBinding(_ name: String) -> Binding<Int> {
        Binding(
            get: { Int(engine.optionValue(named: name)) ?? 0 },
            set: { engine.setOption(named: name, value: String($0)) }
        )
    }
}
