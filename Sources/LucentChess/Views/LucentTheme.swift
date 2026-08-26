import AppKit
import SwiftUI

/// Central design tokens for Lucent Chess.
///
/// Amber is the identity color and has exactly two jobs: primary actions and
/// the currently active thing (selected move, chosen theme, resume card).
/// Everything else is either neutral or a semantic status color. If you find
/// yourself reaching for `accent` to decorate something informational, use a
/// neutral instead.
enum LucentTheme {
    /// The single brand accent.
    static let accent = Color.orange
    static let accentNS = NSColor.systemOrange

    /// File-state colors used by library rows and the workspace save status.
    enum Status {
        static let saved = Color.green
        static let edited = Color.yellow
        static let starter = Color.blue
        static let imported = Color.teal
        static let unsaved = Color.orange
    }

    enum Fonts {
        /// The large serif page heading ("Your chess archive").
        static let display = Font.system(size: 33, weight: .semibold, design: .serif)
        /// Serif section headings inside a page.
        static let sectionTitle = Font.system(.title2, design: .serif, weight: .semibold)
        /// Serif headings for side panels (notation pane).
        static let panelTitle = Font.system(.headline, design: .serif, weight: .semibold)
        /// The LUCENT wordmark in the toolbar.
        static let wordmark = Font.system(size: 13, weight: .black, design: .rounded)
        /// Tracked small-caps style micro labels. Use sparingly.
        static let microLabel = Font.system(size: 8.5, weight: .semibold, design: .rounded)
    }

    enum Board {
        /// Conventional yellow wash on the last move's squares.
        static let lastMoveHighlight = Color.yellow.opacity(0.30)
        static let engineArrowShaft = accent.opacity(0.72)
        static let engineArrowHead = accent.opacity(0.78)
    }

    /// The subtle brand wash behind the dashboard.
    static let dashboardWash = RadialGradient(
        colors: [accent.opacity(0.075), accent.opacity(0.018), .clear],
        center: .topLeading,
        startRadius: 12,
        endRadius: 760
    )
}
