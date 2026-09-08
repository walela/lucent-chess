import AppKit
import SwiftUI
import Darwin

// Compile alongside the app sources, excluding LucentChessApp.swift.
// Sheet checks require native macOS window-service access.
@main
struct NotationMenuChecks {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let study = try PGNService.parse("1. e4 e5 (1... c5 2. Nf3 d6 (2... Nc6)) 2. Nf3 Nc6 *")[0]
        study.goToEnd()
        let initialID = study.lastNodeID
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("NotationMenuChecks-\(UUID().uuidString).json")
        let library = LibraryStore(archiveURL: archive)
        library.studies = [study]
        library.selectedStudyID = study.id
        let engine = StockfishService()
        let suite = "NotationMenuChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = AppearanceSettings(defaults: defaults)
        let host = NSHostingView(rootView: MoveTreeView(study: study)
            .environmentObject(library).environmentObject(engine).environmentObject(appearance))
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 500, height: 440),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        func settle() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        func findText(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { findText($0) }.first
        }
        guard let text = findText(host), let layout = text.layoutManager,
              let container = text.textContainer,
              let coordinator = text.delegate as? MoveTreeView.Coordinator else { throw Failure("Missing notation") }
        let tokens = ChessNotationFormatter.document(for: study).tokens
        let nestedID = tokens.first { $0.kind == .move && $0.variationDepth == 2 }!.nodeID!
        func range(for id: UUID) -> NSRange {
            var result: NSRange?
            let storage = text.textStorage!
            storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if (value as? URL)?.lastPathComponent == id.uuidString { result = range }
            }
            return result!
        }
        func menu(at point: NSPoint) -> NSMenu {
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: text.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            return text.menu(for: event)!
        }
        func moveMenu(_ id: UUID) -> NSMenu {
            layout.ensureLayout(for: container)
            let glyph = layout.glyphRange(forCharacterRange: NSRange(location: range(for: id).location, length: 1), actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyph, in: container)
            return menu(at: NSPoint(x: rect.midX + text.textContainerOrigin.x, y: rect.midY + text.textContainerOrigin.y))
        }
        func invoke(_ title: String, in menu: NSMenu) throws {
            guard let item = menu.item(withTitle: title), item.isEnabled, let action = item.action else { throw Failure("Missing action: \(title)") }
            guard NSApp.sendAction(action, to: item.target, from: item) else { throw Failure("Unhandled action: \(title)") }
            settle()
        }
        let nestedMenu = moveMenu(nestedID)
        try check("figurine right-click offers only chess actions without selecting the move") {
            nestedMenu.items.filter { !$0.isSeparatorItem }.map(\.title) == [
                "Promote variation", "Delete variation", "Copy position (FEN)", "Copy game (PGN)"
            ] && study.lastNodeID == initialID
        }
        try check("blank-space right-click cannot target the nearest move") {
            menu(at: NSPoint(x: 480, y: 20)).items.map(\.title) == ["Copy game (PGN)"]
        }
        try check("promotion is disabled on main-line moves") {
            moveMenu(initialID).item(withTitle: "Promote variation")?.isEnabled == false
        }
        let link = URL(string: "lucent-move://move/\(nestedID.uuidString)")!
        let handled = coordinator.textView(text, clickedOnLink: link, at: range(for: nestedID).location)
        try check("ordinary move clicks still navigate directly") { handled && study.lastNodeID == nestedID }
        let nestedParent = study.parent(of: nestedID)!
        study.select(study.node(withID: initialID)!)
        try invoke("Promote variation", in: nestedMenu)
        try check("promotion targets the clicked branch even after selection changes") {
            nestedParent.children.first?.id == nestedID && study.lastNodeID == nestedID
        }
        let deleteMenu = coordinator.contextMenu(for: nestedID)
        try invoke("Delete variation", in: deleteMenu)
        try check("delete asks for confirmation before changing the tree") {
            window.attachedSheet != nil && study.node(withID: nestedID) != nil
        }
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        settle()
        try check("cancel preserves the move") { study.node(withID: nestedID) != nil }
        try invoke("Delete variation", in: deleteMenu)
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        settle()
        try check("confirmed deletion removes the clicked continuation and selects its parent") {
            study.node(withID: nestedID) == nil && study.lastNodeID == nestedParent.id
        }
        try invoke("Promote variation", in: nestedMenu)
        try check("stale menu actions ignore removed moves") { study.lastNodeID == nestedParent.id }
        library.saveNow()
        engine.stopEngine()
        window.orderOut(nil)
        print("All notation menu checks passed.")
    }

    private static func check(_ name: String, _ test: () -> Bool) throws {
        guard test() else { throw Failure(name) }
        print("✓ \(name)")
    }
    private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
