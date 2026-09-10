import AppKit
import SwiftUI

/// Direct game actions; player and event identity lives with the notation and game details.
struct GameWorkspaceHeader: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var engine: StockfishService
    @ObservedObject var study: ChessStudy
    @Binding var inspectorTab: RootView.InspectorTab
    let showDashboard: () -> Void
    let playFromHere: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            actionIcon("Game library", label: "Library", symbol: "books.vertical", shortcut: "⇧⌘L", action: showDashboard)

            separator

            HStack(spacing: 4) {
                actionIcon("New game", label: "New game", symbol: "doc.badge.plus", shortcut: "⌘N") { library.newStudy() }
                actionIcon("Open PGN…", label: "Open", symbol: "folder", shortcut: "⌘O") {
                    NotificationCenter.default.post(name: .importPGN, object: nil)
                }
                actionIcon("Set up position…", label: "Set up", symbol: "checkerboard.rectangle", shortcut: "⌥⇧⌘S") {
                    openWindow(id: AppWindowID.positionSetup)
                }
                actionIcon(study.filePath == nil ? "Save as PGN…" : "Save PGN", label: "Save", symbol: "square.and.arrow.down", shortcut: "⌘S") {
                    library.saveSelected()
                }
            }
            .modifier(WorkspaceActionGroup())
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Game actions")

            Spacer(minLength: 24)

            HStack(spacing: 4) {
                actionIcon(engine.isAnalysisActive ? "Stop analysis" : "Analyze with Stockfish", label: engine.isAnalysisActive ? "Stop" : "Analyze", symbol: engine.isAnalysisActive ? "stop.fill" : "cpu", shortcut: "⌘E", active: engine.isAnalysisActive) {
                    if !engine.isAnalysisActive { inspectorTab = .analysis }
                    engine.toggle(for: study.currentPosition)
                }
                actionIcon("Practice this position against Stockfish", label: "Practice", symbol: "play", action: playFromHere)
                    .disabled(study.currentPosition.legalMoves().isEmpty)
            }
            .modifier(WorkspaceActionGroup())
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Engine actions")
        }
        .padding(.horizontal, 20)
        .frame(height: 80)
        .background(colorScheme == .light ? LucentTheme.Surface.panel : Color(nsColor: .windowBackgroundColor))
    }

    private var separator: some View {
        Rectangle().fill(.primary.opacity(0.10)).frame(width: 1, height: 28)
    }

    private func actionIcon(_ title: String, label: String, symbol: String, shortcut: String? = nil,
                            active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .medium))
                    .frame(height: 26)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
        }
        .buttonStyle(WorkspaceButtonStyle(active: active, quiet: true, toolbarAction: true))
        .help(title + (shortcut.map { " · \($0)" } ?? ""))
        .accessibilityLabel(title)
    }
}

/// Shared, quiet controls for workspace chrome. Amber identifies running analysis.
struct WorkspaceButtonStyle: ButtonStyle {
    var active = false
    var quiet = false
    var toolbarAction = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(active ? activeForeground : Color.primary.opacity(isEnabled ? 0.85 : 0.35))
            .padding(.horizontal, toolbarAction ? 0 : 12)
            .frame(width: toolbarAction ? 72 : nil, height: toolbarAction ? 56 : 34)
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(active ? LucentTheme.accent.opacity(0.30) : Color.primary.opacity(quiet ? 0 : 0.09), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
    }

    private var activeForeground: Color {
        colorScheme == .light ? Color(red: 0.48, green: 0.23, blue: 0.04) : Color(red: 1, green: 0.74, blue: 0.38)
    }

    private func background(pressed: Bool) -> Color {
        if active { return LucentTheme.accent.opacity(pressed ? 0.25 : 0.14) }
        return Color.primary.opacity(pressed ? 0.10 : (hovering && isEnabled ? 0.065 : (quiet ? 0 : 0.025)))
    }
}


private struct WorkspaceActionGroup: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(4)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.09), lineWidth: 1))
    }
}
