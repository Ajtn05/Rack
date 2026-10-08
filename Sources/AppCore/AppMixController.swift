import AudioCore
import Foundation

/// One application as a screen needs it: a name, a level, and whether it is
/// currently making a sound.
///
/// Restated from `AudioProcessInfo` and `AppMix` so that a view never names an
/// AudioCore type — the same reason `EQBandInfo` exists.
public struct AppMixRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String

    /// Nil for processes with no bundle. Shown so the raw process list stays
    /// visible when the mapping is not one to one, rather than being hidden
    /// behind a guessed name.
    public let bundleID: String?
    public let processID: Int32

    /// Whether it is sending audio right now, as opposed to merely being open.
    public let isPlaying: Bool

    /// True once the app has its own tap and its own fader.
    public let isControlled: Bool

    /// Asked for a tap of its own and did not get one.
    ///
    /// The application is still playing — through the global tap, at its own
    /// level — so it stays in the list. Hiding it would be the worst of both:
    /// the sound is audible and the row that explains it is not.
    public let isGlobalOnly: Bool

    public let volume: Double
    public let isMuted: Bool
}

extension EngineController {
    /// The applications worth showing: everything currently playing, plus
    /// anything already under control so its fader does not vanish the moment
    /// it goes quiet.
    public var appRows: [AppMixRow] {
        let processes = audioProcesses
        var rows: [AppMixRow] = []
        var seen = Set<String>()

        for process in processes {
            // Rack's own process, and the system's audio plumbing, are not
            // things anyone wants a fader for.
            guard AppIdentity.isPresentable(process) else { continue }

            let entry = appMix.entry(
                forBundleID: process.bundleID, processID: process.processID
            )
            guard process.isPlaying || entry != nil else { continue }

            let id = entry?.id ?? process.bundleID ?? "pid:\(process.processID)"
            guard seen.insert(id).inserted else { continue }

            // Asked for is not the same as got. A per-process tap can fail, and
            // when it does the application keeps playing through the global tap
            // — so the row is shown with its fader disabled and labelled,
            // rather than shown with a fader that would do nothing.
            let wanted = entry != nil
            let hasOwnTap = controlledApplicationIDs.contains(id)

            rows.append(
                AppMixRow(
                    id: id,
                    displayName: AppIdentity.displayName(for: process),
                    bundleID: process.bundleID,
                    processID: process.processID,
                    isPlaying: process.isPlaying,
                    isControlled: wanted && hasOwnTap,
                    isGlobalOnly: wanted && !hasOwnTap && status.isRunning,
                    volume: entry?.volume ?? 1,
                    isMuted: entry?.isMuted ?? false
                )
            )
        }

        return rows.sorted {
            if $0.isControlled != $1.isControlled { return $0.isControlled }
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                == .orderedAscending
        }
    }

    /// Give an application its own fader.
    ///
    /// This is the expensive one: it changes the set of taps, which means a new
    /// aggregate device and a brief gap. Changing the volume afterwards is
    /// free.
    public func takeControl(of row: AppMixRow) {
        var mix = appMix
        mix.upsert(
            AppMix.Entry(
                bundleID: row.bundleID,
                processID: row.processID,
                displayName: row.displayName
            )
        )
        applyAppMix(mix)
    }

    /// Hand an application back to the global tap. Also a rebuild.
    public func releaseControl(of row: AppMixRow) {
        var mix = appMix
        mix.remove(id: row.id)
        applyAppMix(mix)
    }

    public func setVolume(_ volume: Double, forApp row: AppMixRow) {
        updateEntry(row) { $0.volume = volume }
    }

    public func setMuted(_ muted: Bool, forApp row: AppMixRow) {
        updateEntry(row) { $0.isMuted = muted }
    }

    private func updateEntry(_ row: AppMixRow, _ transform: (inout AppMix.Entry) -> Void) {
        var mix = appMix
        var entry =
            mix.entry(forBundleID: row.bundleID, processID: row.processID)
            ?? AppMix.Entry(
                bundleID: row.bundleID,
                processID: row.processID,
                displayName: row.displayName
            )
        transform(&entry)
        mix.upsert(entry)
        applyAppMix(mix)
    }
}
