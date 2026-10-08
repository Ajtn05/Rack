import CoreAudio
import Darwin
import Foundation

@testable import AudioCore

/// The two feedback defences, both tested without a room to howl in.
///
/// The device rule is pure by construction. The detector is pure apart from the
/// state handed to it, which is deliberate: what it has to get right is not how
/// the mix loop is written but whether a rising tone is caught, whether speech
/// survives, and whether a quiet room is left alone — and all three are
/// properties of `rackFeedbackDuck`.
func runFeedbackTests() {
    let sampleRate: Float = 48_000
    let frameCount = 512
    let bufferSeconds = Float(frameCount) / sampleRate

    func guardCoefficients(enabled: Bool = true) -> FeedbackCoefficients {
        FeedbackCoefficients.compile(
            isEnabled: enabled, micStreamIndex: 0, sampleRate: Double(sampleRate)
        )
    }

    /// Push `buffers` buffers of a signal through the detector and hand back
    /// the gain it settled on, plus the lowest it ever reached.
    ///
    /// `shape` returns (rms, peak) for a buffer index, which is all the
    /// detector ever sees — so a howl, a voice and a silent room are each just
    /// a different pair of curves.
    func run(
        buffers: Int,
        coefficients: FeedbackCoefficients,
        shape: (Int) -> (rms: Float, peak: Float)
    ) -> (final: Float, lowest: Float) {
        var state = FeedbackGuardState()
        var lowest: Float = 1
        var gain: Float = 1
        for buffer in 0..<buffers {
            let (rms, peak) = shape(buffer)
            gain = rackFeedbackDuck(
                state: &state, coefficients: coefficients,
                rms: rms, peak: peak, elapsed: bufferSeconds
            )
            lowest = min(lowest, gain)
        }
        return (gain, lowest)
    }

    Check.suite("FeedbackRisk — what macOS will tell us outright") {
        // The four-character codes are measured on real hardware, not taken
        // from a header: Core Audio documents the property and not the
        // vocabulary of its values.
        Check.equal(
            FeedbackRisk.decide(dataSource: 0x6864_706E),  // 'hdpn'
            .none,
            "headphones cannot close a loop"
        )
        Check.equal(
            FeedbackRisk.decide(dataSource: 0x6973_706B),  // 'ispk'
            .loudspeaker,
            "the internal speaker is in the same room as the microphone"
        )
        Check.equal(
            FeedbackRisk.decide(dataSource: 0x6573_706B),  // 'espk'
            .loudspeaker,
            "so is an external speaker source"
        )

        // Most interfaces have exactly one output and do not describe it. The
        // answer must be `unknown` rather than `loudspeaker`: blocking every
        // USB DAC and every pair of AirPods to catch the one Bluetooth speaker
        // would make the feature useless far more often than it would help.
        Check.equal(
            FeedbackRisk.decide(dataSource: nil),
            .unknown,
            "a device with no data source is not assumed dangerous"
        )
        Check.equal(
            FeedbackRisk.decide(dataSource: 0x7573_6220),  // 'usb '
            .unknown,
            "nor is one whose source we do not recognise"
        )
    }

    Check.suite("FeedbackGuard — a howl is caught") {
        // Exponential growth from just above the floor, and tonal throughout:
        // a sine's crest factor is √2, which is what a sustained howl collapses
        // toward.
        let (final, lowest) = run(buffers: 60, coefficients: guardCoefficients()) { buffer in
            let rms = min(0.01 * powf(1.12, Float(buffer)), 1)
            return (rms, rms * 1.414)
        }
        Check.isTrue(lowest < 0.5, "a rising tone is ducked, and hard")
        Check.isTrue(
            final <= lowest + 0.001,
            "and stays ducked while it is still growing, rather than recovering into it"
        )
    }

    Check.suite("FeedbackGuard — speech is not") {
        // Loud, and varying the way a voice does — syllables rise and fall, so
        // the fast envelope crosses the slow one constantly. What separates it
        // from a howl is the crest factor: speech runs 3–10, never √2.
        let (final, lowest) = run(buffers: 400, coefficients: guardCoefficients()) { buffer in
            let syllable = 0.5 + 0.5 * sinf(Float(buffer) * 0.4)
            let rms = 0.05 + 0.2 * syllable
            return (rms, rms * 6)
        }
        Check.close(
            Double(lowest), 1, tolerance: 0.001,
            "a voice is never ducked, however loud it gets"
        )
        Check.close(Double(final), 1, tolerance: 0.001, "and the gain is left at unity")
    }

    Check.suite("FeedbackGuard — a quiet room is left alone") {
        // Room tone can double in relative terms and still be inaudible, which
        // is exactly why the floor exists: growth alone is not evidence.
        let (_, lowest) = run(buffers: 200, coefficients: guardCoefficients()) { buffer in
            let rms = min(0.00002 * powf(1.05, Float(buffer)), 0.001)
            return (rms, rms * 1.414)
        }
        Check.close(
            Double(lowest), 1, tolerance: 0.001,
            "growth below the floor is not worth chasing"
        )
    }

    Check.suite("FeedbackGuard — it lets go again") {
        var state = FeedbackGuardState()
        let coefficients = guardCoefficients()

        // Howl until it ducks…
        var gain: Float = 1
        for buffer in 0..<60 {
            let rms = min(0.01 * powf(1.12, Float(buffer)), 1)
            gain = rackFeedbackDuck(
                state: &state, coefficients: coefficients,
                rms: rms, peak: rms * 1.414, elapsed: bufferSeconds
            )
        }
        Check.isTrue(gain < 0.5, "ducked while howling")

        // …then the room goes quiet, as it does once the loop is broken. Ten
        // seconds or so: recovery is deliberately slow, because coming back up
        // fast into a loop that is still there just produces a stutter of
        // howls.
        for _ in 0..<1_000 {
            gain = rackFeedbackDuck(
                state: &state, coefficients: coefficients,
                rms: 0.0001, peak: 0.0004, elapsed: bufferSeconds
            )
        }
        // Exactly one, not merely close — see `recoveredThreshold`. A one-pole
        // never arrives, and a microphone left a hair down for the rest of the
        // session is a bug nobody would ever manage to report.
        Check.equal(gain, 1, "and back to exactly unity once it stops")
    }

    Check.suite("FeedbackGuard — switched off is untouched") {
        // Not merely "does not duck": the disabled path must return exactly 1,
        // the same bit-transparent-when-off guarantee saturation and crossfeed
        // keep.
        let (final, lowest) = run(
            buffers: 60, coefficients: guardCoefficients(enabled: false)
        ) { buffer in
            let rms = min(0.01 * powf(1.12, Float(buffer)), 1)
            return (rms, rms * 1.414)
        }
        Check.equal(final, 1, "a disabled guard multiplies by exactly one")
        Check.equal(lowest, 1, "and never touches the gain at any point")
    }

    Check.suite("FeedbackGuard — no microphone, no guard") {
        // The guard watches one input stream. A session with no microphone has
        // no stream for it to watch, and compiling it active would point it at
        // stream −1.
        let none = FeedbackCoefficients.compile(
            isEnabled: true, micStreamIndex: nil, sampleRate: 48_000
        )
        Check.isTrue(!none.isActive, "a session without a microphone compiles inactive")
        Check.equal(none.micStream, -1, "and names no stream")
    }

    Check.suite("MicMonitor — the guard survives a state file that predates it") {
        // The mirror image of `isEnabled`, which defaults to *off* because a
        // saved file must never switch a microphone on by saying nothing. A
        // guard must never be switched *off* by the same silence.
        let json = Data(
            #"{"isEnabled":true,"volume":0.5,"isMuted":false}"#.utf8
        )
        let decoded = try? JSONDecoder().decode(MicMonitor.self, from: json)
        Check.equal(
            decoded?.isFeedbackGuardEnabled, true,
            "an absent guard key decodes to on"
        )
        Check.equal(decoded?.isEnabled, true, "without disturbing the rest of the file")
    }

    Check.suite("MicMonitor — switching the guard costs a rebuild") {
        // Held, the microphone is left out of the aggregate entirely rather
        // than included at a gain of zero — so the switch changes the shape of
        // the session, not just a number in it.
        let on = MicMonitor(isEnabled: true, isFeedbackGuardEnabled: true)
        let off = MicMonitor(isEnabled: true, isFeedbackGuardEnabled: false)
        Check.isTrue(
            off.needsRebuild(comparedTo: on),
            "the guard is structural, like the device itself"
        )
    }
}
