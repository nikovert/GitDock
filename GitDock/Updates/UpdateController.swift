import AppKit
import Observation

enum UpdatePresentation: Equatable {
    case manualDownload
    case ready
    case checking
    case failed(message: String)
}

@MainActor
protocol UpdateControlling: AnyObject {
    var presentation: UpdatePresentation { get }
    var canCheckForUpdates: Bool { get }
    var actionTitle: String { get }
    var onStateChange: ((UpdatePresentation, Bool) -> Void)? { get set }
    func checkForUpdates()
}

@MainActor
final class ManualDownloadUpdateController: UpdateControlling {
    private static let releasesURL = URL(string: "https://github.com/nikovert/GitDock/releases")!
    private let openURL: (URL) -> Bool
    private(set) var presentation: UpdatePresentation = .manualDownload
    let canCheckForUpdates = true
    let actionTitle = "Download Updates…"
    var onStateChange: ((UpdatePresentation, Bool) -> Void)?

    init(openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.openURL = openURL
    }

    func checkForUpdates() {
        presentation = openURL(Self.releasesURL) ? .manualDownload : .failed(
            message: "Could not open your browser. Visit \(Self.releasesURL.absoluteString) to download updates."
        )
        onStateChange?(presentation, canCheckForUpdates)
    }
}

@MainActor
@Observable
final class UpdateModel {
    private(set) var presentation: UpdatePresentation
    private(set) var canCheckForUpdates: Bool
    @ObservationIgnored private let controller: any UpdateControlling

    var actionTitle: String { controller.actionTitle }

    init(controller: any UpdateControlling) {
        self.controller = controller
        presentation = controller.presentation
        canCheckForUpdates = controller.canCheckForUpdates
        controller.onStateChange = { [weak self] presentation, canCheckForUpdates in
            self?.presentation = presentation
            self?.canCheckForUpdates = canCheckForUpdates
        }
    }

    func checkForUpdates() {
        guard controller.canCheckForUpdates else { return }
        controller.checkForUpdates()
        presentation = controller.presentation
        canCheckForUpdates = controller.canCheckForUpdates
    }
}

@MainActor
enum UpdateControllerFactory {
    static func make() -> any UpdateControlling {
        #if GITHUBBAR_STABLE
        if let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
           !feed.isEmpty,
           let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
           !key.isEmpty {
            return SparkleUpdateController()
        }
        #endif
        return ManualDownloadUpdateController()
    }
}
