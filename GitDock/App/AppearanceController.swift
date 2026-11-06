import AppKit
import GitDockCore

@MainActor
enum AppearanceController {
    static let defaultsKey = "githubbar.appearance"

    static func apply(_ preference: AppearancePreference) {
        switch preference {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    static func applySavedPreference() {
        let rawValue = UserDefaults.standard.string(forKey: defaultsKey) ?? "system"
        apply(AppearancePreference(rawValue: rawValue) ?? .system)
    }
}
