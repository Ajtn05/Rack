import SwiftUI

/// Injects the theme. Every view reads `@Environment(\.theme)`; nothing is
/// passed one explicitly.
private struct ThemeKey: EnvironmentKey {
    // The default is the system theme rather than a fatalError, so a preview
    // or a detached view renders something sensible instead of trapping.
    static let defaultValue: any Theme = SystemTheme()
}

extension EnvironmentValues {
    public var theme: any Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension View {
    /// Apply a theme to this view and everything below it.
    public func theme(_ theme: any Theme) -> some View {
        environment(\.theme, theme)
    }
}

/// Renders `content` once per registered theme, labelled.
///
/// Every component preview uses this, so adding a theme automatically shows it
/// under every component without anyone writing a new preview. That is the
/// point: a skin nobody has looked at is a skin nobody has checked.
public struct ThemeGallery<Content: View>: View {
    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(ThemeRegistry.all, id: \.id) { theme in
                VStack(alignment: .leading, spacing: theme.metrics.tightSpacing) {
                    Text(theme.displayName)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.labelSecondary)
                    content()
                }
                .padding(theme.metrics.panelPadding)
                .background(theme.colors.windowBackground)
                .theme(theme)
            }
        }
    }
}
