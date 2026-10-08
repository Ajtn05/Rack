import AppCore
import Foundation

/// The correlation coefficient itself is pure arithmetic and needs no
/// ballistic testing of its own — what needs proving here is the filter
/// riding on top of it and the linear scale it is drawn against.
func runCorrelationMeterTests() {
    Check.suite("CorrelationMeter — scale") {
        Check.close(
            CorrelationMeter.position(forCorrelation: -1), 0, tolerance: 0.001,
            "fully out of phase is the left stop"
        )
        Check.close(
            CorrelationMeter.position(forCorrelation: 0), 0.5, tolerance: 0.001,
            "unrelated channels sit at center"
        )
        Check.close(
            CorrelationMeter.position(forCorrelation: 1), 1, tolerance: 0.001,
            "fully in phase is the right stop"
        )
        Check.close(
            CorrelationMeter.position(forCorrelation: 0.5), 0.75, tolerance: 0.001,
            "the scale is a straight line, not compressed at either end"
        )
        Check.close(
            CorrelationMeter.position(forCorrelation: -2), 0, tolerance: 0.001,
            "below the floor clamps"
        )
        Check.close(
            CorrelationMeter.position(forCorrelation: 2), 1, tolerance: 0.001,
            "above the ceiling clamps"
        )
    }

    Check.suite("CorrelationMeter — one-pole settling") {
        // A single one-pole low-pass reaches 1 − 1/e of a step after one
        // time constant — the textbook figure, checked numerically rather
        // than trusted from the formula it was typed from.
        var meter = CorrelationMeter()
        meter.update(rawCorrelation: 1, elapsed: CorrelationMeter.timeConstant)
        Check.close(
            meter.value, 1 - 1 / M_E, tolerance: 0.01,
            "reaches 1 − 1/e of the step after one time constant"
        )
    }

    Check.suite("CorrelationMeter — settles to the target") {
        var meter = CorrelationMeter()
        for _ in 0..<200 {
            meter.update(rawCorrelation: -0.6, elapsed: 0.02)
        }
        Check.close(meter.value, -0.6, tolerance: 0.001, "converges to a steady input")
        Check.close(
            meter.position, CorrelationMeter.position(forCorrelation: -0.6), tolerance: 0.001,
            "and the drawn position agrees"
        )
    }

    Check.suite("CorrelationMeter — symmetric rise and fall") {
        // One filter runs both directions, so there is no VU-style attack
        // versus decay distinction to prove — a rise to +1 and a fall to −1
        // over the same elapsed time should be mirror images.
        var rising = CorrelationMeter()
        var falling = CorrelationMeter()
        let steps = 100
        let dt = 0.3 / Double(steps)
        for _ in 0..<steps {
            rising.update(rawCorrelation: 1, elapsed: dt)
            falling.update(rawCorrelation: -1, elapsed: dt)
        }
        Check.close(rising.value, -falling.value, tolerance: 0.001, "mirror images of each other")
    }

    Check.suite("CorrelationMeter — clamps its input") {
        // The formula this filters cannot itself produce a value outside
        // [-1, 1], but the filter does not trust that and clamps anyway —
        // the same defensiveness VUMeter applies to its own raw input.
        var meter = CorrelationMeter()
        meter.update(rawCorrelation: 5, elapsed: 5.0)
        Check.close(meter.value, 1, tolerance: 0.001, "an out-of-range reading clamps to the ceiling")

        var negative = CorrelationMeter()
        negative.update(rawCorrelation: -5, elapsed: 5.0)
        Check.close(negative.value, -1, tolerance: 0.001, "and to the floor on the other side")
    }

    Check.suite("CorrelationMeter — reset") {
        var meter = CorrelationMeter()
        meter.update(rawCorrelation: 1, elapsed: 5.0)
        meter.reset()
        Check.close(meter.value, 0, tolerance: 0.001, "reset returns to center")
        Check.close(meter.position, 0.5, tolerance: 0.001, "and its drawn position")
    }
}
