import Foundation

/// Every theme Rack ships.
///
/// **This is the one line that adding a theme changes.** Write the theme as a
/// single file in this directory, add it to `all`, and it appears in the
/// picker and in every component preview. See `README.md`.
public enum ThemeRegistry {
    public static let all: [any Theme] = [
        TechnicsTheme(),
        SystemTheme(),
        BlueMeter(),
        SilverFace(),
        Bauhaus(),
        Champagne(),
        RackSteel(),
        ConsoleBlue(),
        TapeMachine(),
        Bakelite(),
        BauhausDark(),
        RackSteelDark(),
        TapeMachineDark()
    ]

    /// Used when nothing is stored yet, and when a stored id no longer exists
    /// because a theme was removed.
    public static let fallback: any Theme = SystemTheme()

    public static func theme(id: String?) -> any Theme {
        guard let id, let match = all.first(where: { $0.id == id }) else {
            return fallback
        }
        return match
    }
}
