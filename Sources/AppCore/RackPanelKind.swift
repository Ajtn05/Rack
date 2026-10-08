import Foundation

/// Identifies one panel on the rack, independent of where it currently sits.
///
/// Panel order is user-controlled — see `EngineController.panelOrder` — so a
/// panel needs an identity that survives being dragged somewhere else and
/// being written to `PresetStore.SessionState`. A `String` raw value is what
/// that state stores; the case itself is what `RackScreen` switches on to
/// build the actual view.
public enum RackPanelKind: String, CaseIterable, Hashable, Sendable {
    case amplifier
    case saturation
    case compressor
    case soundFieldProcessor
    case limiter
    case input
    case output
    case analyzer
    case equalizer
    case applications
    case presets
    case diagnostics
    case appearance

    /// The rack's own order — what a fresh install shows, and what a saved
    /// order falls back to for any kind it does not name (an older save file,
    /// or a kind that did not exist yet when it was written).
    public static let defaultOrder: [RackPanelKind] = [
        .amplifier, .saturation, .compressor, .soundFieldProcessor, .limiter,
        // Input sits immediately before Output: the two are the same kind of
        // question — where sound comes from, where it goes — and reading them
        // in signal order is how the back of an amplifier is labelled.
        .input, .output, .analyzer,
        .equalizer, .applications, .presets, .diagnostics, .appearance
    ]

    /// Whether this panel takes a full row by default, before the user has
    /// ever touched its width toggle — see `EngineController.fullWidthPanels`,
    /// which is what actually governs the rack once one has been touched.
    ///
    /// True only for the two panels whose content is the widest thing on the
    /// rack at any width worth using — the amplifier's knob and readout rows,
    /// and the analyzer's meters and graphs. Left at its default, tiling
    /// either of those beside a second panel would mean the second panel
    /// getting whatever the first one left over, which is never enough to be
    /// worth drawing — but it is the user's call, not a rule enforced here,
    /// which is the entire reason the toggle exists.
    public var defaultIsFullWidth: Bool {
        switch self {
        case .amplifier, .analyzer: true
        default: false
        }
    }
}

/// Layout numbers shared between a panel's own view and the width `RackScreen`
/// computes for it, so the two cannot silently drift apart.
public enum RackLayoutConstants {
    /// `PresetsPanel`'s name field. Fixed rather than flexible — a preset
    /// name is typed once and read rarely, and a field that grew with the
    /// window would just be empty most of the time.
    public static let presetNameFieldWidth: CGFloat = 140
}
