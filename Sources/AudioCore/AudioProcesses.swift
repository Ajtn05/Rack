import CoreAudio
import Foundation

/// One process that Core Audio knows how to route audio for.
public struct AudioProcessInfo: Identifiable, Equatable, Sendable {
    /// The Core Audio object, which is what a tap description refers to. Not
    /// stable across launches — the process ID and bundle ID are the durable
    /// identifiers.
    public let objectID: AudioObjectID

    public let processID: pid_t

    /// Nil for processes that have no bundle — command-line tools, some helper
    /// executables. The brief for this phase is explicit that the mapping is
    /// not always one to one, so this has to be allowed to be missing rather
    /// than guessed at.
    public let bundleID: String?

    /// Best available display name: the bundle's name if we can resolve one,
    /// otherwise the bundle ID, otherwise the process ID.
    public let displayName: String

    /// Whether the process is currently sending audio to a device. A process
    /// object exists for anything that has *ever* played, so this is what
    /// separates "Music is playing" from "Music is open".
    public let isPlaying: Bool

    public var id: AudioObjectID { objectID }

    public init(
        objectID: AudioObjectID,
        processID: pid_t,
        bundleID: String?,
        displayName: String,
        isPlaying: Bool
    ) {
        self.objectID = objectID
        self.processID = processID
        self.bundleID = bundleID
        self.displayName = displayName
        self.isPlaying = isPlaying
    }
}

/// Enumerates the processes Core Audio can tap.
public enum AudioProcesses {
    /// Every process object the system currently knows about.
    ///
    /// Includes processes that are not making a sound right now; filter on
    /// `isPlaying` for the ones that are.
    public static func all() -> [AudioProcessInfo] {
        let objectIDs: [AudioObjectID]
        do {
            objectIDs = try AudioProperty.readArray(
                AudioDevices.systemObject,
                AudioProperty.address(kAudioHardwarePropertyProcessObjectList),
                of: AudioObjectID.self,
                context: "listing audio processes"
            )
        } catch {
            return []
        }

        return objectIDs.compactMap(info(for:))
    }

    /// Read what we can about one process object.
    ///
    /// Returns nil only when the process has no PID, which means the object is
    /// already stale — the list and the objects in it can disagree, because a
    /// process may exit between the two reads.
    public static func info(for objectID: AudioObjectID) -> AudioProcessInfo? {
        guard
            let processID: pid_t = try? AudioProperty.read(
                objectID,
                AudioProperty.address(kAudioProcessPropertyPID),
                context: "reading a process ID"
            )
        else { return nil }

        let bundleID = try? AudioProperty.readString(
            objectID,
            AudioProperty.address(kAudioProcessPropertyBundleID),
            context: "reading a process bundle ID"
        )

        let isPlaying: UInt32 = (try? AudioProperty.read(
            objectID,
            AudioProperty.address(kAudioProcessPropertyIsRunningOutput),
            context: "reading whether a process is playing"
        )) ?? 0

        return AudioProcessInfo(
            objectID: objectID,
            processID: processID,
            bundleID: bundleID.flatMap { $0.isEmpty ? nil : $0 },
            displayName: displayName(bundleID: bundleID, processID: processID),
            isPlaying: isPlaying != 0
        )
    }

    /// A name a person can recognise.
    ///
    /// Bundle IDs are reversed-DNS and the last component is usually the app
    /// name, which is good enough and needs no lookup. Falling back to the PID
    /// is deliberate: the brief calls for exposing the raw process list when
    /// the mapping is not one to one, and a bare PID is more honest than a
    /// guessed name.
    static func displayName(bundleID: String?, processID: pid_t) -> String {
        guard let bundleID, !bundleID.isEmpty else { return "PID \(processID)" }
        guard let last = bundleID.split(separator: ".").last, !last.isEmpty else {
            return bundleID
        }
        return String(last)
    }
}
