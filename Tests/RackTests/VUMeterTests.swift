import AppCore
import Foundation

/// The whole claim of this ballistic is "300 ms to 99%, roughly the same
/// return" — these suites check that claim numerically rather than by
/// reading the code and believing it.
func runVUMeterTests() {
    Check.suite("VUMeter — scale anchors") {
        // The five points NeedleMeter.vuMarks prints its labels at. A signal
        // sitting exactly on a marked level must land exactly on that tick.
        Check.close(VUMeter.position(forDecibels: -20), 0.00, tolerance: 0.001, "−20 is the left stop")
        Check.close(VUMeter.position(forDecibels: -10), 0.26, tolerance: 0.001, "−10")
        Check.close(VUMeter.position(forDecibels: -5), 0.50, tolerance: 0.001, "−5")
        Check.close(VUMeter.position(forDecibels: 0), 0.75, tolerance: 0.001, "0 VU")
        Check.close(VUMeter.position(forDecibels: 3), 1.00, tolerance: 0.001, "+3 is the right stop")

        Check.close(VUMeter.position(forDecibels: -30), 0, tolerance: 0.001, "below the floor clamps")
        Check.close(VUMeter.position(forDecibels: 10), 1, tolerance: 0.001, "above the ceiling clamps")
        Check.isTrue(
            VUMeter.position(forDecibels: -.infinity) == 0,
            "silence pins the needle at the bottom"
        )
    }

    // `decibels` is VU — relative to `alignmentLevelDecibels`, not to digital
    // full scale — so every check below that needs the underlying dBFS value
    // back (to reconstruct a linear amplitude, say) has to re-add the
    // alignment offset first.
    func dbfs(_ meter: VUMeter) -> Double {
        meter.decibels > -.infinity ? meter.decibels + VUMeter.alignmentLevelDecibels : -.infinity
    }

    Check.suite("VUMeter — calibration") {
        // mean(|sin|) over a cycle is 2/π; feeding that raw average in must
        // read 0 dBFS — a full-scale sine reads full scale, the same
        // convention PeakMeter and SpectrumAnalyzer already use — which is
        // `-alignmentLevelDecibels` once expressed in VU.
        var meter = VUMeter()
        meter.update(linearAverage: Float(2 / Double.pi), elapsed: 5.0)
        Check.close(
            dbfs(meter), 0, tolerance: 0.01,
            "a rectified full-scale sine's mean magnitude reads 0 dBFS"
        )
        Check.close(
            meter.decibels, -VUMeter.alignmentLevelDecibels, tolerance: 0.01,
            "which is +18 VU at the −18 dBFS alignment level — pinned near the top, as a full-scale tone should be"
        )
    }

    Check.suite("VUMeter — 300 ms to 99%") {
        // Step the filter in fine increments summing to exactly the
        // integration time, and check the settled value is where a
        // critically damped 2nd-order system reaching 99% of a step lands:
        // 20·log10(0.99) dBFS, not merely "close to 0".
        var meter = VUMeter()
        let target = Float(2 / Double.pi)
        let steps = 300
        let dt = VUMeter.integrationSeconds / Double(steps)
        for _ in 0..<steps {
            meter.update(linearAverage: target, elapsed: dt)
        }
        let expected = 20 * log10(0.99)
        Check.close(
            dbfs(meter), expected, tolerance: 0.05,
            "reaches 99% of the step at 300 ms, not merely somewhere near it"
        )
    }

    Check.suite("VUMeter — no overshoot") {
        // A critically damped system approaches its target monotonically.
        // An underdamped one would sail past 0 dBFS before settling, which is
        // exactly the failure "proper ballistics" was asked to avoid.
        var meter = VUMeter()
        let target = Float(2 / Double.pi)
        var maxLinear = 0.0
        for _ in 0..<2000 {
            meter.update(linearAverage: target, elapsed: 0.001)
            let level = dbfs(meter)
            let linear = level > -.infinity ? pow(10, level / 20) : 0
            maxLinear = max(maxLinear, linear)
        }
        Check.isTrue(
            maxLinear <= 1.0001,
            "the response never exceeds the level it is chasing"
        )
    }

    Check.suite("VUMeter — symmetric attack and release") {
        // The same filter runs both directions, so a rise and a fall over
        // the same elapsed time from opposite ends must be complementary:
        // together they always add back up to the step height.
        var rising = VUMeter()
        var falling = VUMeter()
        let target = Float(2 / Double.pi)
        falling.update(linearAverage: target, elapsed: 5.0)

        let steps = 150
        let dt = 0.15 / Double(steps)
        for _ in 0..<steps {
            rising.update(linearAverage: target, elapsed: dt)
            falling.update(linearAverage: 0, elapsed: dt)
        }

        let risingLinear = pow(10, dbfs(rising) / 20)
        let fallingLinear = dbfs(falling) > -.infinity ? pow(10, dbfs(falling) / 20) : 0
        Check.close(
            risingLinear + fallingLinear, 1.0, tolerance: 0.01,
            "one time constant governs both directions, so their deficits from the step sum to it"
        )
    }

    Check.suite("VUMeter — silence settles instead of hanging") {
        var meter = VUMeter()
        meter.update(linearAverage: Float(2 / Double.pi), elapsed: 5.0)

        for _ in 0..<50 {
            meter.update(linearAverage: 0, elapsed: 0.1)
        }

        Check.isTrue(
            meter.decibels == -.infinity,
            "settles all the way to silence rather than resting at a small nonzero level"
        )
        Check.close(meter.position, 0, tolerance: 0.001, "and the needle rests at the bottom")
    }

    Check.suite("VUMeter — reset") {
        var meter = VUMeter()
        meter.update(linearAverage: Float(2 / Double.pi), elapsed: 5.0)
        meter.reset()
        Check.isTrue(meter.decibels == -.infinity, "reset silences the needle")
        Check.close(meter.position, 0, tolerance: 0.001, "and its drawn position")
    }
}
