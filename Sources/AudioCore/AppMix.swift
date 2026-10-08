import CoreAudio
import Foundation

/// Per-application volume and mute.
///
/// Kept out of `DSPParameters` deliberately. That value is the master chain and
/// becomes a preset in Phase 5; "Safari at 40%" is a property of this Mac right
/// now, not of a sound you want to save and share. Mixing the two would mean
/// loading a preset silently reassigning application volumes.
public struct AppMix: Equatable, Sendable, Codable {
    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// One application under individual control.
    public struct Entry: Equatable, Sendable, Codable, Identifiable {
        /// The durable identity. Process IDs and Core Audio object IDs both
        /// change when an app restarts; the bundle ID does not, which is what
        /// lets a setting survive quitting and reopening the app.
        public var bundleID: String?

        /// The fallback identity for processes with no bundle — command-line
        /// tools and some helpers. Not durable, and deliberately so: the brief
        /// calls for exposing the raw process list when the mapping is not one
        /// to one rather than inventing an identity.
        public var processID: pid_t

        public var displayName: String

        /// 0…1, applied before the mix.
        public var volume: Double

        public var isMuted: Bool

        public var id: String { bundleID ?? "pid:\(processID)" }

        public init(
            bundleID: String?,
            processID: pid_t,
            displayName: String,
            volume: Double = 1,
            isMuted: Bool = false
        ) {
            self.bundleID = bundleID
            self.processID = processID
            self.displayName = displayName
            self.volume = volume
            self.isMuted = isMuted
        }

        /// Square-law, matching the master volume control so the two faders
        /// behave the same way under the hand.
        public var gain: Double {
            guard !isMuted, volume > 0 else { return 0 }
            let clamped = min(max(volume, 0), 1)
            return clamped * clamped
        }
    }

    // MARK: - Lookup

    public func entry(forBundleID bundleID: String?, processID: pid_t) -> Entry? {
        if let bundleID, let match = entries.first(where: { $0.bundleID == bundleID }) {
            return match
        }
        return entries.first { $0.bundleID == nil && $0.processID == processID }
    }

    /// The gain for a live Core Audio process object.
    ///
    /// Resolves the object back to its bundle ID so that a setting made before
    /// the app restarted still applies. Unknown processes play at unity — an
    /// app nobody has touched should sound exactly as it would without Rack.
    public func gain(forProcessObject objectID: AudioObjectID) -> Double {
        guard let info = AudioProcesses.info(for: objectID) else { return 1 }
        return entry(forBundleID: info.bundleID, processID: info.processID)?.gain ?? 1
    }

    /// The process objects that need their own tap: everything with an entry
    /// and a live process behind it.
    ///
    /// Order is stable — entry order — because it becomes the aggregate's tap
    /// order, and the render path matches streams to applications by position.
    public func controlledProcessObjects(
        among processes: [AudioProcessInfo]
    ) -> [AudioObjectID] {
        entries.compactMap { entry in
            processes.first {
                if let bundleID = entry.bundleID { return $0.bundleID == bundleID }
                return $0.processID == entry.processID
            }?.objectID
        }
    }

    // MARK: - Editing

    public mutating func upsert(_ entry: Entry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    public mutating func remove(id: String) {
        entries.removeAll { $0.id == id }
    }
}
