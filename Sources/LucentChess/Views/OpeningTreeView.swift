import SwiftUI

/// The continuation table for the current board: every move played from this
/// position in the listed games, with game count, White's score and average
/// rating. Clicking a row plays that move on the main board.
struct OpeningTreeTable: View {
    @EnvironmentObject private var appearance: AppearanceSettings
    let tree: OpeningTree?
    let loading: Bool
    let position: ChessPosition
    let play: (OpeningTreeRow) -> Void
    @State private var selection: OpeningTreeRow.ID?

    private var rows: [OpeningTreeRow] { tree?.rows ?? [] }
    private var numberPrefix: String {
        position.sideToMove == .white ? "\(position.fullmoveNumber)." : "\(position.fullmoveNumber)…"
    }

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("Move") { row in
                HStack(spacing: 3) {
                    Text(numberPrefix)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                    FigurineRenderer.text(for: row.san, size: 12, set: appearance.figurineSet, tinted: appearance.figurineTinted)
                        .font(.system(size: 12, weight: .semibold))
                }
                .accessibilityLabel("\(numberPrefix) \(row.san)")
            }
            .width(min: 64, ideal: 72)
            TableColumn("Games") { row in
                Text(row.games.formatted())
                    .font(.system(size: 11).monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 42, ideal: 48, max: 64)
            .alignment(.trailing)
            TableColumn("Score") { row in ScoreCell(row: row) }
                .width(min: 78, ideal: 92)
            TableColumn("Elo Ø") { row in
                Text(row.averageElo.map { String($0) } ?? "—")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(row.averageElo == nil ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 44, ideal: 50, max: 60)
            .alignment(.trailing)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
        .overlay { placeholder }
        .onChange(of: selection) { _, id in
            guard let id, let row = rows.first(where: { $0.id == id }) else { return }
            selection = nil
            play(row)
        }
        .accessibilityLabel("Moves played from this position")
    }

    @ViewBuilder private var placeholder: some View {
        if rows.isEmpty {
            VStack(spacing: 6) {
                if loading {
                    ProgressView().controlSize(.small)
                    Text("Counting continuations across the database…")
                        } else if let tree, tree.ended > 0 {
                            Text("Every game that reaches this position ends here.")
                        } else if tree != nil {
                            Text("No games continue from this position.")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.top, 34)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
        }
    }
}

/// White's score as a percentage over a win / draw / loss bar.
private struct ScoreCell: View {
    let row: OpeningTreeRow

    var body: some View {
        let decided = max(1, row.whiteWins + row.draws + row.blackWins)
        HStack(spacing: 7) {
            Text("\(Int(row.score.rounded()))%")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .frame(width: 32, alignment: .trailing)
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    segment(row.whiteWins, of: decided, width: geometry.size.width, color: Color(white: 0.96))
                    segment(row.draws, of: decided, width: geometry.size.width, color: Color(white: 0.62))
                    segment(row.blackWins, of: decided, width: geometry.size.width, color: Color(white: 0.24))
                }
                .clipShape(Capsule())
                .overlay(Capsule().stroke(.primary.opacity(0.18), lineWidth: 0.5))
            }
            .frame(height: 6)
        }
        .help("White wins \(row.whiteWins), draws \(row.draws), Black wins \(row.blackWins)")
        .accessibilityLabel("White scores \(Int(row.score.rounded())) percent")
    }

    private func segment(_ value: Int, of total: Int, width: CGFloat, color: Color) -> some View {
        color.frame(width: max(0, width * CGFloat(value) / CGFloat(total)))
    }
}
