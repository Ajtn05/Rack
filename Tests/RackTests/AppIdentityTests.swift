import AudioCore
import Foundation

@testable import AppCore

/// Which processes belong in the applications panel.
///
/// Added after the panel shipped listing Rack itself and a nameless helper,
/// which made a working feature look broken.
func runAppIdentityTests() {
    func process(
        objectID: UInt32 = 1,
        pid: Int32 = 4242,
        bundleID: String?
    ) -> AudioProcessInfo {
        AudioProcessInfo(
            objectID: objectID,
            processID: pid,
            bundleID: bundleID,
            displayName: bundleID.map { String($0.split(separator: ".").last ?? "") }
                ?? "PID \(pid)",
            isPlaying: true
        )
    }

    Check.suite("AppIdentity — what to hide") {
        // Ourselves, by PID. We are not one of the things you might want to
        // turn down.
        Check.isTrue(
            !AppIdentity.isPresentable(
                process(pid: AppIdentity.ownProcessID, bundleID: "dev.rack.Rack")
            ),
            "our own process is hidden"
        )
        // And by bundle, in case the PID does not match — a helper of ours
        // would still not belong in the list.
        Check.isTrue(
            !AppIdentity.isPresentable(process(bundleID: AppIdentity.ownBundleID)),
            "our own bundle is hidden"
        )

        // System audio plumbing has process objects and sometimes reports as
        // playing, but a volume fader for it means nothing.
        for bundleID in [
            "com.apple.audio.coreaudiod",
            "com.apple.coreaudio.something",
            "com.apple.cmio.registerassistant",
            "com.apple.avconferenced"
        ] {
            Check.isTrue(
                !AppIdentity.isPresentable(process(bundleID: bundleID)),
                "\(bundleID) is hidden"
            )
        }

        // A process with neither a bundle nor a resolvable running application
        // is a helper. "PID 4312" beside a fader helps nobody — the brief's
        // "expose the raw process list" is about not inventing names, not
        // about listing every daemon on the machine.
        Check.isTrue(
            !AppIdentity.isPresentable(process(pid: 999_999, bundleID: nil)),
            "an unresolvable bare process is hidden"
        )
    }

    Check.suite("AppIdentity — what to show") {
        // An ordinary application survives the filter. Checked against a real
        // running process so the test exercises the resolution path rather
        // than a hypothetical.
        let ourselves = process(
            pid: AppIdentity.ownProcessID, bundleID: "com.example.NotRack"
        )
        // Same PID resolves to a real NSRunningApplication, but the bundle is
        // not ours — the PID check still wins, which is the safer order.
        Check.isTrue(
            !AppIdentity.isPresentable(ourselves),
            "the PID check is not bypassed by an unfamiliar bundle ID"
        )

        Check.isTrue(
            AppIdentity.isPresentable(
                process(pid: 1, bundleID: "com.apple.Music")
            ),
            "a normal application is shown"
        )
        Check.isTrue(
            AppIdentity.isPresentable(
                process(pid: 1, bundleID: "com.google.Chrome.helper")
            ),
            "an app helper with a bundle is shown — it is what actually plays"
        )
    }
}
