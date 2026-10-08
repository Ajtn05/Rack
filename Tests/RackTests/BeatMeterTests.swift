import AppCore

/// The Pulse meter's own maths: which bands count as "bass", the onset
/// detector built on their running average, and the attack/release needle
/// that turns a hit into something worth looking at.
func runBeatMeterTests() {
    Check.suite("BeatMeter.bassLevel — averages only the bands in range") {
        // Third-octave centres spanning well below, inside, and above the
        // default 60...250 Hz bass range, with one silent band mixed in.
        let frequencies: [Double] = [20, 63, 100, 200, 400, 1000]
        let bands: [Float] = [0, -10, -20, -30, 0, 0]
        let level = BeatMeter.bassLevel(bandsDecibels: bands, bandFrequencies: frequencies)
        // 63, 100 and 200 Hz are the in-range bands: (-10 + -20 + -30) / 3.
        Check.close(level, -20, tolerance: 0.001, "averages exactly the in-range bands, nothing else")
    }

    Check.suite("BeatMeter.bassLevel — a silent in-range band is left out, not averaged in") {
        let frequencies: [Double] = [63, 100, 200]
        let bands: [Float] = [-10, -.infinity, -30]
        let level = BeatMeter.bassLevel(bandsDecibels: bands, bandFrequencies: frequencies)
        // (-10 + -30) / 2 — the silent band would drag this to -infinity if
        // it were included instead of skipped.
        Check.close(level, -20, tolerance: 0.001, "a -infinity band is excluded from the average")
    }

    Check.suite("BeatMeter.bassLevel — nothing in range reads as silence") {
        let level = BeatMeter.bassLevel(bandsDecibels: [0, 0], bandFrequencies: [20, 1000])
        Check.isTrue(level < -60, "no band in range settles to the silence floor, not zero")
    }

    Check.suite("BeatMeter — a steady level never triggers a hit") {
        var meter = BeatMeter()
        for _ in 0..<300 {
            meter.update(bassDecibels: -30, elapsed: 0.05)
        }
        Check.close(meter.position, 0, tolerance: 0.02, "a bassline sitting at its own average never snaps the needle")
    }

    Check.suite("BeatMeter — a jump past the running average snaps the needle") {
        var meter = BeatMeter()
        for _ in 0..<300 {
            meter.update(bassDecibels: -30, elapsed: 0.05)
        }
        meter.update(bassDecibels: -30 + BeatMeter.onsetMarginDecibels + 6, elapsed: 0.016)
        Check.isTrue(meter.position > 0.3, "a level well past the onset margin registers as a hit")
    }

    Check.suite("BeatMeter — a margin too small to count is not a hit") {
        var meter = BeatMeter()
        for _ in 0..<300 {
            meter.update(bassDecibels: -30, elapsed: 0.05)
        }
        meter.update(bassDecibels: -30 + BeatMeter.onsetMarginDecibels - 1, elapsed: 0.016)
        Check.close(meter.position, 0, tolerance: 0.02, "a jump short of the margin does not trigger")
    }

    Check.suite("BeatMeter — the refractory period suppresses an immediate re-trigger") {
        var meter = BeatMeter()
        for _ in 0..<300 {
            meter.update(bassDecibels: -30, elapsed: 0.05)
        }
        meter.update(bassDecibels: -10, elapsed: 0.016)
        let afterHit = meter.position
        Check.isTrue(afterHit > 0.3, "the initial hit registers")

        // Same loud level, but still inside the refractory window — this
        // must read as the release phase, not a second attack, or a
        // sustained loud passage would pin the needle at 1 forever.
        meter.update(bassDecibels: -10, elapsed: 0.01)
        Check.isTrue(
            meter.position < afterHit,
            "within the refractory period the needle starts falling even though the level is still loud"
        )
    }

    Check.suite("BeatMeter — decays back to rest once the hit passes") {
        var meter = BeatMeter()
        for _ in 0..<300 {
            meter.update(bassDecibels: -30, elapsed: 0.05)
        }
        meter.update(bassDecibels: -10, elapsed: 0.016)
        Check.isTrue(meter.position > 0.3, "the hit registers")

        // Well past both the refractory window and several release time
        // constants, back at the baseline level.
        for _ in 0..<20 {
            meter.update(bassDecibels: -30, elapsed: 0.1)
        }
        Check.close(meter.position, 0, tolerance: 0.02, "settles back to rest")
    }

    Check.suite("BeatMeter — reset") {
        var meter = BeatMeter()
        for _ in 0..<300 {
            meter.update(bassDecibels: -30, elapsed: 0.05)
        }
        meter.update(bassDecibels: -10, elapsed: 0.016)
        meter.reset()
        Check.close(meter.position, 0, tolerance: 0.0001, "reset drops the needle")
    }
}
