import AppKit
import SwiftUI

@main
struct DragChecks {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let settings = AppearanceSettings()
        let engine = StockfishService()
        var receivedMove: ChessMove?
        let board = ChessBoardView(
            position: .starting,
            lastMoveUCI: nil,
            moveHandler: { receivedMove = $0 }
        )
        .environmentObject(settings)
        .environmentObject(engine)
        .frame(width: 400, height: 400)

        let hosting = NSHostingView(rootView: board)
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        let window = NSWindow(
            contentRect: NSRect(x: -2_000, y: -2_000, width: 400, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        runLoopTick()

        // e2 → e4 on a 400 pt white-oriented board.
        send(.leftMouseDown, at: CGPoint(x: 225, y: 75), window: window, clickCount: 1)
        send(.leftMouseDragged, at: CGPoint(x: 225, y: 125), window: window)
        send(.leftMouseDragged, at: CGPoint(x: 225, y: 175), window: window)
        send(.leftMouseUp, at: CGPoint(x: 225, y: 175), window: window, clickCount: 1)
        runLoopTick()
        window.orderOut(nil)

        guard receivedMove?.uci == "e2e4" else {
            throw NSError(domain: "DragChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected e2e4, received \(receivedMove?.uci ?? "no move")"])
        }
        print("✓ board-level mouse drag produced e2e4")
    }

    @MainActor
    private static func send(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        window: NSWindow,
        clickCount: Int = 0
    ) {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: clickCount,
            pressure: type == .leftMouseUp ? 0 : 1
        ) else { return }
        window.sendEvent(event)
        runLoopTick()
    }

    private static func runLoopTick() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
    }
}
