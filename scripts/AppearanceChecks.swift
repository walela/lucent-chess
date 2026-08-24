import Foundation

@main
struct AppearanceChecks {
    static func main() throws {
        let suiteName = "LucentAppearanceChecks-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw Failure("could not create defaults suite") }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = AppearanceSettings(defaults: defaults)
        try check("new installs follow the Mac appearance") {
            initial.interfaceAppearance == .system
        }
        initial.interfaceAppearance = .light
        let restored = AppearanceSettings(defaults: defaults)
        try check("the selected interface appearance persists") {
            restored.interfaceAppearance == .light
        }
        restored.interfaceAppearance = .dark
        try check("all explicit appearance modes round-trip") {
            AppearanceSettings(defaults: defaults).interfaceAppearance == .dark
        }
        print("All appearance checks passed.")
    }

    private static func check(_ name: String, _ test: () -> Bool) throws {
        guard test() else { throw Failure(name) }
        print("✓ \(name)")
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
