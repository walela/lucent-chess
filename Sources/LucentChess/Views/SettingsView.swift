import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var engine: StockfishService
    @EnvironmentObject private var appearance: AppearanceSettings
    @State private var showingEngineConfiguration = false

    var body: some View {
        TabView {
            Form {
                Section("Stockfish") {
                    LabeledContent("Engine") {
                        HStack {
                            Text(engine.enginePath.isEmpty ? "Not selected" : URL(fileURLWithPath: engine.enginePath).lastPathComponent)
                                .foregroundStyle(.secondary)
                            Button("Choose…") { engine.chooseEngine() }
                        }
                    }
                    LabeledContent("CPU threads") {
                        Stepper(value: $engine.threads, in: 1...max(1, ProcessInfo.processInfo.processorCount)) {
                            Text("\(engine.threads)").monospacedDigit().frame(width: 30)
                        }
                    }
                    LabeledContent("Hash memory") {
                        Picker("Hash", selection: $engine.hashMB) {
                            ForEach([64, 128, 256, 512, 1024, 2048, 4096], id: \.self) { Text("\($0) MB").tag($0) }
                        }.labelsHidden().frame(width: 110)
                    }
                    LabeledContent("Analysis lines") {
                        Stepper(value: $engine.multiPV, in: 1...8) { Text("\(engine.multiPV)").monospacedDigit().frame(width: 30) }
                    }
                    Toggle("Request win/draw/loss statistics", isOn: $engine.showWDL)
                    Button {
                        showingEngineConfiguration = true
                    } label: {
                        Label("Open Full Engine Configuration…", systemImage: "slider.horizontal.3")
                    }
                    Text("Changes take effect when you apply them. Higher hash and thread counts analyze faster, but leave less capacity for other Mac apps.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack { Spacer(); Button("Apply & Restart Engine") { engine.restartWithSettings() }.buttonStyle(.borderedProminent) }
                }
            }
            .padding(20)
            .tabItem { Label("Engine", systemImage: "cpu") }

            Form {
                Picker("Interface", selection: Binding(
                    get: { appearance.interfaceAppearance }, set: { appearance.interfaceAppearance = $0 }
                )) {
                    ForEach(InterfaceAppearance.allCases) { option in
                        Label(option.label, systemImage: option.symbol).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Default board", selection: Binding(
                    get: { appearance.boardTheme }, set: { appearance.boardTheme = $0 }
                )) {
                    ForEach(BoardThemeOption.all) { Text($0.name).tag($0) }
                }
                Picker("Piece design", selection: Binding(
                    get: { appearance.pieceSet }, set: { appearance.pieceSet = $0 }
                )) {
                    ForEach(PieceSetOption.all) { Text($0.name).tag($0) }
                }
                Toggle("Show coordinates", isOn: $appearance.showCoordinates)
                Toggle("Show legal move hints", isOn: $appearance.showLegalMoves)
            }
            .padding(20)
            .tabItem { Label("Appearance", systemImage: "paintpalette") }
        }
        .padding(8)
        .sheet(isPresented: $showingEngineConfiguration) {
            EngineConfigurationView().environmentObject(engine)
        }
    }
}
