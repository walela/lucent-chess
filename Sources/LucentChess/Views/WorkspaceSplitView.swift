import AppKit
import SwiftUI

/// AppKit owns the pane frames; SwiftUI only supplies their contents.
/// Keeping pane widths out of Auto Layout lets a divider resize its neighbors
/// without another pane's holding priority pulling it back.
struct WorkspaceSplitView: NSViewRepresentable {
    let board: AnyView
    let notation: AnyView
    let inspector: AnyView

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.autoresizesSubviews = false
        for content in [board, notation, inspector] {
            let host = NSHostingView(rootView: content)
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = []
            split.addArrangedSubview(host)
        }
        split.delegate = context.coordinator
        return split
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        for (host, content) in zip(split.arrangedSubviews, [board, notation, inspector]) {
            (host as? NSHostingView<AnyView>)?.rootView = content
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSplitView, context: Context) -> CGSize? {
        // Do not export the native split's current fitting width as a SwiftUI
        // minimum: that can compete with the next divider drag.
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 992, height: 720))
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        static let widthsKey = "StudyWorkspaceSplit.paneWidths"
        static let minimumWidths: [CGFloat] = [420, 270, 300]
        private var isLayingOut = false
        private var hasLaidOut = false

        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
            let panes = splitView.arrangedSubviews
            guard panes.count == 3, splitView.bounds.width > 0 else { return }
            let available = max(0, splitView.bounds.width - 2 * splitView.dividerThickness)
            var widths: [CGFloat]
            if hasLaidOut {
                widths = panes.map { $0.frame.width }
            } else if let saved = UserDefaults.standard.array(forKey: Self.widthsKey) as? [Double],
                      saved.count == 3, saved.allSatisfy({ $0.isFinite && $0 > 0 }) {
                widths = saved.map { CGFloat($0) }
            } else {
                widths = [available * 0.55, available * 0.25, available * 0.20]
            }
            widths = Self.fittedWidths(widths, available: available)
            isLayingOut = true
            var x: CGFloat = 0
            for (pane, width) in zip(panes, widths) {
                pane.frame = NSRect(x: x, y: 0, width: width, height: splitView.bounds.height)
                x += width + splitView.dividerThickness
            }
            hasLaidOut = true
            isLayingOut = false
            rememberWidths(splitView)
        }

        /// Window resizing uses spare board width first, then the side panes
        /// only when necessary to respect every pane's minimum width.
        static func fittedWidths(_ proposed: [CGFloat], available: CGFloat) -> [CGFloat] {
            let minimumTotal = minimumWidths.reduce(0, +)
            guard available >= minimumTotal else {
                return minimumWidths.map { $0 * available / minimumTotal }
            }
            var widths = zip(proposed, minimumWidths).map { max($0, $1) }
            let delta = available - widths.reduce(0, +)
            if delta >= 0 {
                widths[0] += delta
            } else {
                var shortage = -delta
                for index in widths.indices {
                    let reduction = min(shortage, widths[index] - minimumWidths[index])
                    widths[index] -= reduction
                    shortage -= reduction
                }
            }
            return widths
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            let pane = splitView.arrangedSubviews[dividerIndex]
            return pane.frame.minX + Self.minimumWidths[dividerIndex]
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            let next = splitView.arrangedSubviews[dividerIndex + 1]
            return next.frame.maxX - Self.minimumWidths[dividerIndex + 1] - splitView.dividerThickness
        }

        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard !isLayingOut, hasLaidOut, let split = notification.object as? NSSplitView else { return }
            rememberWidths(split)
        }

        private func rememberWidths(_ splitView: NSSplitView) {
            let widths = splitView.arrangedSubviews.map { Double($0.frame.width) }
            guard widths.count == 3, widths.allSatisfy({ $0.isFinite && $0 > 0 }) else { return }
            UserDefaults.standard.set(widths, forKey: Self.widthsKey)
        }
    }
}
