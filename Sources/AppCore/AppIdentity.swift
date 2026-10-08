import AppKit
import AudioCore
import Foundation
import SwiftUI

/// Turns a Core Audio process object into something worth showing a person.
///
/// `AudioProcesses` deliberately reports the raw truth — a PID, maybe a bundle
/// ID — because that is what the audio layer can honestly know. Everything
/// here is presentation: which processes are worth listing at all, what to
/// call them, and what icon to draw.
enum AppIdentity {
    /// Rack's own bundle. Tapping ourselves is meaningless and listing
    /// ourselves is worse: the panel is for choosing what to turn down, and we
    /// are not one of the options.
    static let ownBundleID = Bundle.main.bundleIdentifier ?? "dev.rack.Rack"
    static let ownProcessID = ProcessInfo.processInfo.processIdentifier

    /// System audio plumbing. These have process objects and sometimes claim
    /// to be playing, but they are not applications and a volume fader for
    /// them means nothing.
    private static let systemBundlePrefixes = [
        "com.apple.audio.",
        "com.apple.coreaudio",
        "com.apple.cmio",
        "com.apple.avconferenced"
    ]

    private static let systemProcessNames: Set<String> = [
        "coreaudiod", "audiomxd", "AudioComponentRegistrar", "avconferenced"
    ]

    /// Whether a process is worth showing in the applications panel.
    static func isPresentable(_ process: AudioProcessInfo) -> Bool {
        if process.processID == ownProcessID { return false }
        if let bundleID = process.bundleID {
            if bundleID == ownBundleID { return false }
            if systemBundlePrefixes.contains(where: bundleID.hasPrefix) { return false }
        }
        if let name = runningApplication(for: process)?.localizedName,
           systemProcessNames.contains(name) {
            return false
        }
        // A process with no bundle and no resolvable name is almost always a
        // helper. Showing "PID 4312" beside a fader is not useful, and the
        // brief's "expose the raw process list" is about not *inventing*
        // names, not about listing every daemon on the machine.
        if process.bundleID == nil, runningApplication(for: process) == nil {
            return false
        }
        return true
    }

    /// The name a person would recognise.
    ///
    /// `NSRunningApplication` knows the real localised name — "Google Chrome"
    /// rather than "Chrome", "Music" rather than "Music". Falling back to the
    /// bundle ID's last component is what produced "helper" on screen.
    static func displayName(for process: AudioProcessInfo) -> String {
        if let name = runningApplication(for: process)?.localizedName, !name.isEmpty {
            return name
        }
        return process.displayName
    }

    /// The application's icon, if it has one.
    static func icon(for process: AudioProcessInfo) -> Image? {
        guard let nsImage = runningApplication(for: process)?.icon else { return nil }
        return Image(nsImage: nsImage)
    }

    static func icon(forProcessID processID: pid_t) -> Image? {
        guard let nsImage = NSRunningApplication(processIdentifier: processID)?.icon
        else { return nil }
        return Image(nsImage: nsImage)
    }

    private static func runningApplication(
        for process: AudioProcessInfo
    ) -> NSRunningApplication? {
        // By PID first, because a helper's PID resolves to the helper while
        // its bundle ID may resolve to nothing at all.
        if let byPID = NSRunningApplication(processIdentifier: process.processID) {
            return byPID
        }
        guard let bundleID = process.bundleID else { return nil }
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first
    }
}
