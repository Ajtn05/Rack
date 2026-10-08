import AudioCore
import Foundation
import os

/// Reads and writes Rack's library as JSON under Application Support.
///
/// JSON rather than `UserDefaults` because the brief is explicit that people
/// will want to edit and share these. That has consequences beyond the file
/// format, and they shape everything here:
///
/// - Output is pretty-printed with sorted keys, so a preset is readable and
///   two versions of one diff sensibly.
/// - Writes are atomic. A crash partway through a save must not leave a
///   truncated file where a library used to be.
/// - A file that fails to decode is **moved aside, never overwritten**. Someone
///   hand-editing a preset will eventually produce invalid JSON, and losing
///   their work as a punishment for a missing comma is not acceptable.
public final class PresetStore: @unchecked Sendable {
    public let directory: URL

    private static let log = Logger(subsystem: "dev.rack.Rack", category: "presets")

    private static let presetsFile = "presets.json"
    private static let rulesFile = "rules.json"
    private static let stateFile = "state.json"

    /// - Parameter directory: overridden by tests. Defaults to
    ///   `~/Library/Application Support/Rack`.
    public init(directory: URL? = nil) {
        self.directory =
            directory
            ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Rack", directoryHint: .isDirectory)
    }

    /// Where the files live, for a "Reveal in Finder" button and for anyone
    /// wondering where their presets went.
    public var directoryPath: String { directory.path(percentEncoded: false) }

    // MARK: - Presets

    public func loadPresets() -> [Preset] {
        load([Preset].self, from: Self.presetsFile) ?? []
    }

    public func save(presets: [Preset]) {
        save(presets, to: Self.presetsFile)
    }

    // MARK: - Rules

    public func loadRules() -> [AutoSwitchRule] {
        load([AutoSwitchRule].self, from: Self.rulesFile) ?? []
    }

    public func save(rules: [AutoSwitchRule]) {
        save(rules, to: Self.rulesFile)
    }

    // MARK: - Session state

    /// The things that are neither a preset nor a rule but should survive a
    /// relaunch: which preset was active, and the per-application mix.
    ///
    /// Separate from presets on purpose. A preset is a sound worth sharing;
    /// "Safari at 40% on this Mac" is not, and loading someone else's preset
    /// must not reassign local application volumes.
    public struct SessionState: Equatable, Sendable, Codable {
        public var activePresetID: UUID?
        public var appMix: AppMix
        public var parameters: DSPParameters

        /// Which skin. Decoded leniently — a theme that no longer exists falls
        /// back rather than failing the whole file.
        public var themeID: String?

        /// Which display the equalizer was showing. Optional for the same
        /// reason `themeID` is: a state file written before this existed must
        /// still decode, and an unrecognised value must fall back rather than
        /// quarantine the whole session.
        public var analyzerMode: String?

        /// Whether the monitor dims itself after a period of no interaction.
        /// Optional, and absent means on: a state file written before this
        /// existed came from a build where dimming always happened, so that
        /// is the behaviour it should still decode to.
        public var isIdleTimeoutEnabled: Bool?

        /// Which panel sits where, as raw `RackPanelKind` values — a `String`
        /// here rather than the enum itself because `AudioCore`-facing
        /// `PresetStore` has no reason to import the screen's own vocabulary,
        /// and because a raw string is what survives a case being renamed or
        /// removed in a later version without failing decode. Optional, and
        /// absent means the rack's own default order: a state file written
        /// before panels could be rearranged had no order to remember.
        public var panelOrder: [String]?

        /// Which panels the user has set to take a full row, as raw
        /// `RackPanelKind` values — same reasoning as `panelOrder`. Optional,
        /// and absent means each panel's own built-in default: a state file
        /// written before the width toggle existed had no preference to
        /// remember.
        public var fullWidthPanels: [String]?

        /// Which panels the user has set to match the tallest panel in their
        /// own row, as raw `RackPanelKind` values — same reasoning as
        /// `fullWidthPanels`. Optional, and absent means no panel does: a
        /// state file written before the height toggle existed had no
        /// preference to remember, and there is no built-in default to fall
        /// back to the way `fullWidthPanels` falls back to
        /// `defaultIsFullWidth`.
        public var fullHeightPanels: [String]?

        /// Whether Rack hides its Dock icon and lives in the menu bar alone.
        /// Optional, and absent means no: a state file written before there
        /// was a menu bar to live in came from a build that always had a Dock
        /// icon, so that is what it should still decode to.
        ///
        /// Deliberately *not* where "open at login" is kept — that one is the
        /// system's own fact, read back from `SMAppService`, and a second copy
        /// here would disagree the moment someone changed it in System
        /// Settings instead of in Rack.
        public var isMenuBarOnly: Bool?

        /// Live microphone monitoring: which input, how loud, and whether it
        /// is in circuit at all. Optional for the same reason every field
        /// above it is — a state file written before the feature existed must
        /// still decode — and absent means the default, which is *off*. A
        /// saved session must never be able to switch a microphone on by
        /// having said nothing about it.
        ///
        /// Here rather than in a preset, deliberately, alongside `appMix`:
        /// which microphone is plugged into this Mac is not part of a sound
        /// worth sharing.
        public var micMonitor: MicMonitor?

        /// Whether the amplifier was left switched on. Optional, and absent
        /// means **on** — the opposite default to `micMonitor` above, and for
        /// the mirror-image reason. A microphone is a thing a saved file must
        /// never be able to switch on by saying nothing; the engine is the
        /// whole point of the program, and a state file that says nothing
        /// about it came from a build where launching Rack was expected to
        /// start it.
        public var isPoweredOn: Bool?

        public init(
            activePresetID: UUID? = nil,
            appMix: AppMix = AppMix(),
            parameters: DSPParameters = .flat,
            themeID: String? = nil,
            analyzerMode: String? = nil,
            isIdleTimeoutEnabled: Bool? = nil,
            panelOrder: [String]? = nil,
            fullWidthPanels: [String]? = nil,
            fullHeightPanels: [String]? = nil,
            isMenuBarOnly: Bool? = nil,
            micMonitor: MicMonitor? = nil,
            isPoweredOn: Bool? = nil
        ) {
            self.activePresetID = activePresetID
            self.appMix = appMix
            self.parameters = parameters
            self.themeID = themeID
            self.analyzerMode = analyzerMode
            self.isIdleTimeoutEnabled = isIdleTimeoutEnabled
            self.panelOrder = panelOrder
            self.fullWidthPanels = fullWidthPanels
            self.fullHeightPanels = fullHeightPanels
            self.isMenuBarOnly = isMenuBarOnly
            self.micMonitor = micMonitor
            self.isPoweredOn = isPoweredOn
        }
    }

    public func loadState() -> SessionState {
        load(SessionState.self, from: Self.stateFile) ?? SessionState()
    }

    public func save(state: SessionState) {
        save(state, to: Self.stateFile)
    }

    // MARK: - Files

    private func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = directory.appending(path: name)
        guard let data = try? Data(contentsOf: url) else { return nil }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            quarantine(url, reason: error)
            return nil
        }
    }

    private func save<T: Encodable>(_ value: T, to name: String) {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(value)

            // .atomic writes to a temporary file and renames, so a crash
            // partway through leaves the previous version intact rather than
            // half a file.
            try data.write(to: directory.appending(path: name), options: .atomic)
        } catch {
            Self.log.error(
                """
                could not save \(name, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
    }

    /// Move a file that will not decode out of the way instead of destroying it.
    ///
    /// The alternative — starting fresh and overwriting on the next save —
    /// silently eats hand-edited work. Renaming costs nothing and the original
    /// is recoverable.
    private func quarantine(_ url: URL, reason: Error) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let moved = url.appendingPathExtension("invalid-\(stamp)")
        try? FileManager.default.moveItem(at: url, to: moved)

        Self.log.error(
            """
            \(url.lastPathComponent, privacy: .public) could not be read \
            (\(reason.localizedDescription, privacy: .public)) — moved to \
            \(moved.lastPathComponent, privacy: .public)
            """
        )
    }
}
