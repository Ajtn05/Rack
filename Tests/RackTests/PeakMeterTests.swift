import AppCore

/// The ballistics are the difference between a meter that reads correctly and
/// one that feels broken, and "looks right to me" is not a measurement.
func runPeakMeterTests() {
    Check.suite("PeakMeter — decibel conversion") {
        Check.close(
            PeakMeter.decibels(fromLinear: 1.0), 0, tolerance: 0.001,
            "full scale is 0 dBFS"
        )
        Check.close(
            PeakMeter.decibels(fromLinear: 0.5), -6.0206, tolerance: 0.001,
            "half amplitude is about −6 dB"
        )
        Check.close(
            PeakMeter.decibels(fromLinear: 0.1), -20, tolerance: 0.001,
            "a tenth is −20 dB"
        )
        Check.isTrue(
            PeakMeter.decibels(fromLinear: 0) == -.infinity,
            "silence is negative infinity, not a very small number"
        )
    }

    Check.suite("PeakMeter — bar position") {
        // The whole point of the dB scale: half amplitude sits near the middle
        // of the bar rather than in the bottom half-inch.
        Check.close(
            PeakMeter.position(forDecibels: 0), 1, tolerance: 0.001,
            "0 dBFS fills the bar"
        )
        Check.close(
            PeakMeter.position(forDecibels: -30), 0.5, tolerance: 0.001,
            "−30 dB is half way"
        )
        Check.close(
            PeakMeter.position(forDecibels: -60), 0, tolerance: 0.001,
            "the floor is empty"
        )
        Check.close(
            PeakMeter.position(forDecibels: -90), 0, tolerance: 0.001,
            "below the floor clamps rather than going negative"
        )
        Check.close(
            PeakMeter.position(forDecibels: 6), 1, tolerance: 0.001,
            "above full scale clamps"
        )
    }

    Check.suite("PeakMeter — attack and decay") {
        var meter = PeakMeter()

        // Attack is instantaneous: a transient must not be smoothed away.
        meter.update(linearPeak: 1.0, elapsed: 0.016)
        Check.close(meter.decibels, 0, tolerance: 0.001, "rises immediately to the peak")

        // Decay is timed. One second of silence at 30 dB/s from 0 dBFS.
        meter.update(linearPeak: 0, elapsed: 1.0)
        Check.close(
            meter.decibels, -PeakMeter.decayPerSecond, tolerance: 0.001,
            "falls at the decay rate"
        )

        // And it keeps falling rather than sticking.
        meter.update(linearPeak: 0, elapsed: 1.0)
        Check.close(
            meter.decibels, -2 * PeakMeter.decayPerSecond, tolerance: 0.001,
            "keeps falling"
        )

        // A louder reading wins immediately even mid-decay.
        meter.update(linearPeak: 0.5, elapsed: 0.016)
        Check.close(
            meter.decibels, -6.0206, tolerance: 0.001,
            "a new peak overrides the decay"
        )
    }

    Check.suite("PeakMeter — hold") {
        var meter = PeakMeter()
        meter.update(linearPeak: 1.0, elapsed: 0.016)
        Check.close(meter.holdDecibels, 0, tolerance: 0.001, "hold captures the peak")

        // Through the hold window the marker must not move, even as the bar falls.
        meter.update(linearPeak: 0, elapsed: 0.5)
        Check.close(meter.holdDecibels, 0, tolerance: 0.001, "hold stays during the window")
        Check.isTrue(meter.decibels < 0, "while the bar itself falls")

        // Past the window it starts falling, more slowly than the bar.
        meter.update(linearPeak: 0, elapsed: 0.8)
        meter.update(linearPeak: 0, elapsed: 1.0)
        Check.isTrue(meter.holdDecibels < 0, "hold falls once the window expires")
        Check.isTrue(
            meter.holdDecibels >= meter.decibels,
            "hold never falls below the bar"
        )
    }

    Check.suite("PeakMeter — silence settles instead of falling forever") {
        // The decay is bounded by the incoming reading, and in real silence
        // that reading is −∞ — so nothing stopped the fall. It ran past the
        // floor at 30 dB/s indefinitely: the bar looked right because its
        // position clamps at zero, while the readout beside it counted down
        // through −200 and −400 and grew out of its field.
        var meter = PeakMeter()
        meter.update(linearPeak: 1.0, elapsed: 0.016)

        for _ in 0..<600 {
            meter.update(linearPeak: 0, elapsed: 0.1)
        }

        Check.isTrue(
            meter.decibels == -.infinity,
            "a minute of silence reads as silence, not as a large negative number"
        )
        Check.isTrue(
            meter.holdDecibels == -.infinity,
            "and so does the hold marker"
        )
        Check.close(meter.position, 0, tolerance: 0.001, "the bar is empty")
        Check.close(meter.holdPosition, 0, tolerance: 0.001, "and so is the hold")
        Check.equal(meter.formattedDecibels, "−∞ dB", "the readout says so")

        // Never below the floor at any point on the way down, which is the
        // property that keeps the readout inside its field.
        var falling = PeakMeter()
        falling.update(linearPeak: 1.0, elapsed: 0.016)
        var everBelowFloor = false
        for _ in 0..<200 {
            falling.update(linearPeak: 0, elapsed: 0.05)
            let level = falling.decibels
            if level > -.infinity, level < PeakMeter.floorDecibels {
                everBelowFloor = true
            }
        }
        Check.isTrue(everBelowFloor == false, "no finite reading ever sits under the floor")
    }

    Check.suite("PeakMeter — reset") {
        var meter = PeakMeter()
        meter.update(linearPeak: 1.0, elapsed: 0.016)
        meter.reset()
        Check.isTrue(meter.decibels == -.infinity, "reset silences the bar")
        Check.isTrue(meter.holdDecibels == -.infinity, "reset clears the hold")
        Check.close(meter.position, 0, tolerance: 0.001, "and the drawn position")
    }
}
