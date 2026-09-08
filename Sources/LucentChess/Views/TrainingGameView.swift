import SwiftUI

private struct TrainingWindowFocusKey: FocusedValueKey { typealias Value = Bool }
extension FocusedValues {
    var isTrainingWindow: Bool? {
        get { self[TrainingWindowFocusKey.self] }
        set { self[TrainingWindowFocusKey.self] = newValue }
    }
}

struct TrainingSetupView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var training: TrainingSession
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var engine: StockfishService
    let position: ChessPosition
    @State private var humanColor = PieceColor.white
    @State private var strength = TrainingStrength.club
    @State private var seconds = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Play from this position").font(.title2.bold())
            Text("Start a separate training game against Stockfish. Your study stays intact.")
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
                GridRow {
                    Text("Play as")
                    Picker("Play as", selection: $humanColor) {
                        Text("White").tag(PieceColor.white)
                        Text("Black").tag(PieceColor.black)
                    }.pickerStyle(.segmented).labelsHidden()
                }
                GridRow {
                    Text("Strength")
                    Picker("Strength", selection: $strength) {
                        ForEach(TrainingStrength.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden()
                }
                GridRow {
                    Text("Thinking time")
                    Picker("Thinking time", selection: $seconds) {
                        Text("Quick · 0.5 seconds").tag(0.5)
                        Text("1 second per move").tag(1.0)
                        Text("3 seconds per move").tag(3.0)
                        Text("5 seconds per move").tag(5.0)
                    }.labelsHidden()
                }
            }
            Text("Strength is an approximate engine target, not a FIDE rating. There is no clock for your moves.")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(position.sideToMove == .white ? "White" : "Black") to move · moves are saved in your library.")
                .font(.callout)
            if training.isActive {
                Text("Starting a new game will stop your current training game. Its moves will stay in the library.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start game") {
                    training.start(from: position, humanColor: humanColor, strength: strength,
                                   seconds: seconds, enginePath: engine.enginePath, library: library)
                    dismiss()
                    openWindow(id: AppWindowID.training)
                }
                .buttonStyle(.borderedProminent).tint(LucentTheme.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 460)
        .background(colorScheme == .light ? LucentTheme.Surface.panel : Color(nsColor: .windowBackgroundColor))
        .onAppear { humanColor = position.sideToMove }
    }
}

struct TrainingGameView: View {
    @EnvironmentObject private var training: TrainingSession
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var engine: StockfishService
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let study = training.study {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Play Stockfish").font(.headline)
                            Text("You play \(training.humanColor.rawValue) · \(training.strength.rawValue)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if training.isActive {
                            Button("Resign") { training.resign() }
                            Button("Stop game") { training.stop() }
                        }
                        Button("Open in study") {
                            training.stop()
                            library.select(study)
                            openWindow(id: AppWindowID.game)
                            dismissWindow(id: AppWindowID.training)
                        }
                    }.padding(16)
                    Divider()
                    HStack(spacing: 0) {
                        GeometryReader { geometry in
                            let size = min(geometry.size.width - 32, geometry.size.height - 32)
                            ChessBoardView(position: study.currentPosition, lastMoveUCI: study.currentNode.moveUCI,
                                           allowsInteraction: training.canPlay, showsEngineArrow: false,
                                           flipped: training.humanColor == .black, moveHandler: training.play)
                                .frame(width: size, height: size)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                if training.isThinking { ProgressView().controlSize(.small) }
                                Text(training.status).font(.headline)
                            }
                            Text(study.playerDescription).font(.caption).foregroundStyle(.secondary)
                            Divider()
                            // Read-only during training; open the saved game in Study to browse or analyze it.
                            MoveTreeView(study: study).allowsHitTesting(false)
                            Text("Saved in your library").font(.caption).foregroundStyle(.secondary)
                        }.padding(16).frame(width: 280)
                    }
                }
                .background(colorScheme == .light ? LucentTheme.Surface.workspace : Color(nsColor: .windowBackgroundColor))
            } else {
                ContentUnavailableView("Choose a position to play", systemImage: "checkerboard.rectangle",
                    description: Text("Open a study and choose Play from here."))
            }
        }
        .frame(minWidth: 900, minHeight: 660)
        .focusedSceneValue(\.isTrainingWindow, true)
        .onDisappear { training.stop() }
    }
}
