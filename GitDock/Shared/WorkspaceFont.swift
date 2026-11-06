import AppKit
import SwiftUI

private struct WorkspaceTextScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

extension EnvironmentValues {
    var workspaceTextScale: Double {
        get { self[WorkspaceTextScaleKey.self] }
        set { self[WorkspaceTextScaleKey.self] = newValue }
    }
}

/// Keeps semantic styles, weights and code fonts in step without scaling hit targets.
@MainActor
struct WorkspaceFont {
    private var size: CGFloat
    private var fontWeight: Font.Weight = .regular
    private var design: Font.Design = .default

    static var body: Self { preferred(.body) }
    static var caption: Self { preferred(.caption1) }
    static var caption2: Self { preferred(.caption2) }
    static var headline: Self { preferred(.headline).weight(.semibold) }
    static var subheadline: Self { preferred(.subheadline) }
    static var largeTitle: Self { preferred(.largeTitle) }
    static var title2: Self { preferred(.title2) }
    static var title3: Self { preferred(.title3) }

    static func system(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Self {
        Self(size: size, fontWeight: weight, design: design)
    }
    static func system(_ style: Self, design: Font.Design) -> Self {
        var value = style; value.design = design; return value
    }
    func weight(_ weight: Font.Weight) -> Self { var value = self; value.fontWeight = weight; return value }
    func bold() -> Self { weight(.bold) }
    func monospaced() -> Self { var value = self; value.design = .monospaced; return value }
    func font(scale: Double) -> Font { .system(size: size * scale, weight: fontWeight, design: design) }
    private static func preferred(_ style: NSFont.TextStyle) -> Self {
        Self(size: NSFont.preferredFont(forTextStyle: style, options: [:]).pointSize)
    }
}

private struct WorkspaceFontModifier: ViewModifier {
    let font: WorkspaceFont
    @Environment(\.workspaceTextScale) private var scale
    func body(content: Content) -> some View { content.font(font.font(scale: scale)) }
}

extension View {
    @MainActor func workspaceFont(_ font: WorkspaceFont) -> some View { modifier(WorkspaceFontModifier(font: font)) }
    func workspaceTextSizing(_ scale: Double) -> some View {
        environment(\.workspaceTextScale, scale).font(.system(size: NSFont.systemFontSize * scale))
    }
}
