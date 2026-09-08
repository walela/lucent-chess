import AppKit
import SwiftUI

// Run with the production WorkspaceSplitView.swift; this check needs no XCTest.
@main
struct WorkspaceLayoutChecks {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let defaults = UserDefaults.standard
        let key = WorkspaceSplitView.Coordinator.widthsKey
        let previous = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        func content(_ title: String = "Notation") -> some View {
            VStack(spacing: 0) {
                Text("Header").frame(height: 58)
                WorkspaceSplitView(
                    board: AnyView(GeometryReader { _ in Color.gray }),
                    notation: AnyView(VStack { Text(title); Spacer() }.frame(maxWidth: .infinity)),
                    inspector: AnyView(VStack { Text("Inspector"); Spacer() }.frame(maxWidth: .infinity))
                )
            }
        }
        let host = NSHostingView(rootView: content())
        let window = NSWindow(
            contentRect: NSRect(x: -3_000, y: -3_000, width: 1_800, height: 1_000),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.contentView = host
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        guard let split = findSplit(host) else { throw Failure("Split view missing") }
        func widths() -> [CGFloat] { split.arrangedSubviews.map { $0.frame.width } }
        let initial = widths()
        try check("three panes fill the workspace") {
            initial.count == 3 && abs(initial.reduce(0, +) + 2 * split.dividerThickness - split.bounds.width) < 1
        }

        split.setPosition(initial[0] - 160, ofDividerAt: 0)
        settle()
        let firstDrag = widths()
        try check("board divider resizes only board and notation") {
            abs(firstDrag[0] - initial[0] + 160) < 1
                && abs(firstDrag[1] - initial[1] - 160) < 1
                && abs(firstDrag[2] - initial[2]) < 1
        }
        split.setPosition(split.arrangedSubviews[2].frame.minX - split.dividerThickness - 100, ofDividerAt: 1)
        settle()
        let secondDrag = widths()
        try check("inspector divider resizes only notation and inspector") {
            abs(secondDrag[0] - firstDrag[0]) < 1
                && abs(secondDrag[1] - firstDrag[1] + 100) < 1
                && abs(secondDrag[2] - firstDrag[2] - 100) < 1
        }
        host.rootView = content("Updated notation and analysis")
        settle()
        try check("SwiftUI content updates preserve dragged widths") { close(widths(), secondDrag) }

        window.setContentSize(NSSize(width: 1_950, height: 900))
        settle()
        let expanded = widths()
        try check("window growth preserves both side-pane widths") {
            abs(expanded[0] - secondDrag[0] - 150) < 1
                && abs(expanded[1] - secondDrag[1]) < 1
                && abs(expanded[2] - secondDrag[2]) < 1
        }
        window.setContentSize(NSSize(width: 1_180, height: 720))
        settle()
        try check("smaller windows keep all panes above their minimums") {
            zip(widths(), WorkspaceSplitView.Coordinator.minimumWidths).allSatisfy { $0 + 0.5 >= $1 }
        }
        let saved = widths()
        window.contentView = nil
        window.contentView = NSHostingView(rootView: content("Reopened game"))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        window.contentView?.layoutSubtreeIfNeeded()
        guard let restored = window.contentView.flatMap(findSplit) else { throw Failure("Restored split missing") }
        try check("reopening restores the saved pane widths") {
            close(restored.arrangedSubviews.map { $0.frame.width }, saved)
        }
        print("All workspace layout checks passed.")
    }

    @MainActor private static func findSplit(_ view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for child in view.subviews { if let split = findSplit(child) { return split } }
        return nil
    }
    private static func close(_ lhs: [CGFloat], _ rhs: [CGFloat]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0 - $1) < 1 }
    }
    private static func check(_ name: String, _ test: () -> Bool) throws {
        guard test() else { throw Failure(name) }
        print("✓ \(name)")
    }
    private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
