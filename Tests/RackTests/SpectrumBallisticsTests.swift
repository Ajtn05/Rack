import AppCore

/// How the bars move, which is presentation rather than measurement — and the
/// half of an analyzer that makes it either readable or a flickering mess.
func runSpectrumBallisticsTests() {
    Check.suite("SpectrumBallistics — the scale") {
        Check.close(
            SpectrumBallistics.position(forDecibels: 0), 1, tolerance: 0.001,
            "full scale fills the bar"
        )
        Check.close(
            SpectrumBallistics.position(forDecibels: SpectrumBallistics.floorDecibels),
            0, tolerance: 0.001,
            "the floor is empty"
        )
        Check.close(
            SpectrumBallistics.position(forDecibels: -36), 0.5, tolerance: 0.001,
            "half way down the range is half way up the bar"
        )
        Check.close(
            SpectrumBallistics.position(forDecibels: -200), 0, tolerance: 0.001,
            "below the floor clamps rather than going negative"
        )
        Check.close(
            SpectrumBallistics.position(forDecibels: -.infinity), 0, tolerance: 0.001,
            "and silence is the bottom, not a crash"
        )
    }

    Check.suite("SpectrumBallistics — attack and decay") {
        var bars = SpectrumBallistics()
        bars.update(bandsDecibels: [0, -36, -.infinity], elapsed: 0.033)

        Check.equal(bars.levels.count, 3, "one level per band")
        Check.close(bars.levels[0], 1, tolerance: 0.001, "attack is instantaneous")
        Check.close(bars.levels[1], 0.5, tolerance: 0.001, "for every band")
        Check.close(bars.levels[2], 0, tolerance: 0.001, "and silence is the floor")

        // Fall is timed. The rate is in dB per second over the display range.
        bars.update(bandsDecibels: [-.infinity, -.infinity, -.infinity], elapsed: 0.5)
        let expected = 1 - SpectrumBallistics.decayPerSecond / -SpectrumBallistics.floorDecibels * 0.5
        Check.close(bars.levels[0], expected, tolerance: 0.001, "and falls at its rate")

        // A louder reading wins immediately, mid-fall.
        bars.update(bandsDecibels: [-18, -.infinity, -.infinity], elapsed: 0.033)
        Check.close(bars.levels[0], 0.75, tolerance: 0.001, "a new peak overrides the decay")

        // It reaches the bottom and stays there rather than going through it.
        for _ in 0..<200 {
            bars.update(bandsDecibels: [-.infinity, -.infinity, -.infinity], elapsed: 0.033)
        }
        Check.close(bars.levels[0], 0, tolerance: 0.001, "and settles at the floor")
    }

    Check.suite("SpectrumBallistics — the peak marker") {
        var bars = SpectrumBallistics()
        bars.update(bandsDecibels: [0], elapsed: 0.033)
        Check.close(bars.holds[0], 1, tolerance: 0.001, "the marker captures the peak")

        // Through its window it does not move, while the bar underneath falls.
        bars.update(bandsDecibels: [-.infinity], elapsed: 0.5)
        Check.close(bars.holds[0], 1, tolerance: 0.001, "and holds")
        Check.isTrue(bars.levels[0] < 1, "while the bar falls away from it")

        // Past the window it follows, more slowly — which is the point of it.
        bars.update(bandsDecibels: [-.infinity], elapsed: 0.6)
        bars.update(bandsDecibels: [-.infinity], elapsed: 0.5)
        Check.isTrue(bars.holds[0] < 1, "then starts to fall")
        Check.isTrue(
            bars.holds[0] >= bars.levels[0],
            "but never below the bar it marks"
        )
        Check.isTrue(
            SpectrumBallistics.holdDecayPerSecond < SpectrumBallistics.decayPerSecond,
            "and falls more slowly than the bar, or there would be no marker"
        )
    }

    Check.suite("SpectrumBallistics — an empty frame clears the display") {
        var bars = SpectrumBallistics()
        bars.update(bandsDecibels: [0, 0, 0], elapsed: 0.033)
        Check.equal(bars.levels.count, 3, "three bands")

        // What the engine publishes when it is switched off. The display must
        // empty rather than freeze on the last thing that was playing.
        bars.update(bandsDecibels: [], elapsed: 0.033)
        Check.equal(bars.levels.count, 0, "an empty frame empties the display")
        Check.equal(bars.holds.count, 0, "markers included")
    }

    Check.suite("SpectrumBallistics — a changed band count is adopted") {
        // Nothing changes the count today, but a display that traps on one is
        // a landmine for whoever makes the band count configurable.
        var bars = SpectrumBallistics()
        bars.update(bandsDecibels: Array(repeating: -20, count: 31), elapsed: 0.033)
        Check.equal(bars.levels.count, 31, "thirty-one")
        bars.update(bandsDecibels: Array(repeating: -20, count: 10), elapsed: 0.033)
        Check.equal(bars.levels.count, 10, "then ten, without trapping")
    }

    Check.suite("AnalyzerMode — one word per mode") {
        Check.equal(
            AnalyzerMode.allCases.count, 8,
            "spectrum, vu, response, overlay, pulse, goniometer, oscilloscope, off"
        )
        Check.equal(AnalyzerMode.spectrum.displayName, "SPECTRUM", "named")
        Check.equal(AnalyzerMode.vu.displayName, "VU", "named")
        Check.equal(AnalyzerMode.response.displayName, "RESPONSE", "named")
        Check.equal(AnalyzerMode.overlay.displayName, "MIX", "named")
        Check.equal(AnalyzerMode.pulse.displayName, "PULSE", "named")
        Check.equal(AnalyzerMode.goniometer.displayName, "SCOPE", "named")
        Check.equal(AnalyzerMode.oscilloscope.displayName, "WAVE", "named")
        Check.equal(AnalyzerMode.off.displayName, "OFF", "and off says the same word the engine does")

        // Spectrum, overlay and pulse all need a live spectrum; VU reads the
        // peak/VU accumulators the audio thread always maintains, response is
        // drawn from the filter coefficients, the goniometer and oscilloscope
        // both read the raw stereo ring instead, and off draws nothing.
        Check.isTrue(AnalyzerMode.spectrum.needsSpectrumCapture, "spectrum captures")
        Check.isTrue(AnalyzerMode.overlay.needsSpectrumCapture, "overlay captures too")
        Check.isTrue(AnalyzerMode.pulse.needsSpectrumCapture, "and so does pulse, reading the same bands")
        Check.isTrue(!AnalyzerMode.vu.needsSpectrumCapture, "VU does not")
        Check.isTrue(!AnalyzerMode.response.needsSpectrumCapture, "response does not")
        Check.isTrue(!AnalyzerMode.goniometer.needsSpectrumCapture, "neither does the goniometer")
        Check.isTrue(!AnalyzerMode.oscilloscope.needsSpectrumCapture, "nor the oscilloscope")
        Check.isTrue(!AnalyzerMode.off.needsSpectrumCapture, "and neither does off")

        // The goniometer and the oscilloscope share the same raw stereo ring.
        Check.isTrue(AnalyzerMode.goniometer.needsGoniometerCapture, "the goniometer captures")
        Check.isTrue(AnalyzerMode.oscilloscope.needsGoniometerCapture, "so does the oscilloscope")
        Check.isTrue(!AnalyzerMode.spectrum.needsGoniometerCapture, "spectrum does not")
        Check.isTrue(!AnalyzerMode.vu.needsGoniometerCapture, "VU does not")
        Check.isTrue(!AnalyzerMode.response.needsGoniometerCapture, "response does not")
        Check.isTrue(!AnalyzerMode.overlay.needsGoniometerCapture, "overlay does not")
        Check.isTrue(!AnalyzerMode.off.needsGoniometerCapture, "and off does not")

        // Round-trips through the session file.
        for mode in AnalyzerMode.allCases {
            Check.equal(
                AnalyzerMode(rawValue: mode.rawValue), mode,
                "\(mode.rawValue) survives being written down"
            )
        }
        Check.isTrue(
            AnalyzerMode(rawValue: "nonsense") == nil,
            "and an unrecognised one is refused rather than guessed"
        )
    }
}
