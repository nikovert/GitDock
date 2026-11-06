import AppKit
import Observation

@MainActor @Observable
final class WorkspaceTextSize {
    private(set) var workspaceStep: Int { didSet { defaults.set(workspaceStep, forKey: "workspace.text.workspaceStep") } }
    private(set) var chatStep: Int { didSet { defaults.set(chatStep, forKey: "workspace.text.chatStep") } }
    @ObservationIgnored private let defaults: UserDefaults
    var workspaceScale: Double { 1 + Double(workspaceStep) / 10 }
    var chatScale: Double { 1 + Double(chatStep) / 10 }
    var workspacePercent: Int { 100 + workspaceStep * 10 }
    var chatPercent: Int { 100 + chatStep * 10 }
    var canIncrease: Bool { workspaceStep < 10 || chatStep < 10 }
    var canDecrease: Bool { workspaceStep > -2 || chatStep > -2 }
    var canIncreaseChat: Bool { chatStep < 10 }
    var canDecreaseChat: Bool { chatStep > -2 }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        workspaceStep = Self.clamp(defaults.integer(forKey: "workspace.text.workspaceStep"))
        chatStep = Self.clamp(defaults.integer(forKey: "workspace.text.chatStep"))
    }
    func increase() { workspaceStep = Self.clamp(workspaceStep + 1); increaseChat() }
    func decrease() { workspaceStep = Self.clamp(workspaceStep - 1); decreaseChat() }
    func reset() { workspaceStep = 0; chatStep = 0 }
    func increaseChat() { chatStep = Self.clamp(chatStep + 1) }
    func decreaseChat() { chatStep = Self.clamp(chatStep - 1) }
    func resetChat() { chatStep = 0 }
    private static func clamp(_ step: Int) -> Int { min(10, max(-2, step)) }
}
