import AppKit

@main
enum GitDockMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let appDelegate = AppDelegate()
        application.delegate = appDelegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(appDelegate) {}
    }
}
