import Darwin

@testable import AudioCore

/// The saturator's own maths: the coefficients compiled from drive and mix,
/// and the `tanh` waveshaper those coefficients drive.
func runSaturationTests() {
    Check.suite("SaturationCoefficients — disabled folds to a true no-op") {
        let disabled = SaturationCoefficients.compile(driveDecibels: 12, mix: 0.8, isEnabled: false)
        Check.close(Double(disabled.mixWet), 0, tolerance: 0.0001, "mix folds to zero while disabled")

        // At mixWet 0, the waveshaper must be bit-identical passthrough —
        // the same guarantee `DSPChainTests`' null test checks for a flat EQ.
        for level: Float in [-1, -0.5, 0, 0.3, 1] {
            let output = rackSaturate(level, coefficients: disabled)
            Check.equal(output, level, "disabled is bit-identical passthrough at \(level)")
        }
    }

    Check.suite("SaturationCoefficients — knobs clamp to their ranges") {
        let extreme = SaturationCoefficients.compile(driveDecibels: 100, mix: 5, isEnabled: true)
        Check.close(
            Double(extreme.driveGain), pow(10, Saturation.driveRangeDecibels.upperBound / 20),
            tolerance: 0.0001, "drive clamps to its own ceiling"
        )
        Check.close(
            Double(extreme.mixWet), Saturation.mixRange.upperBound,
            tolerance: 0.0001, "mix clamps to its own ceiling"
        )

        let low = SaturationCoefficients.compile(driveDecibels: -20, mix: -5, isEnabled: true)
        Check.close(
            Double(low.driveGain), pow(10, Saturation.driveRangeDecibels.lowerBound / 20),
            tolerance: 0.0001, "drive clamps to its own floor"
        )
        Check.close(Double(low.mixWet), 0, tolerance: 0.0001, "mix clamps to its own floor")
    }

    Check.suite("SaturationCoefficients — makeup gain compensates the tanh curve") {
        // At 0 dB drive, driveGain is 1, so makeup is exactly 1 / tanh(1) —
        // checked against the textbook value rather than trusted from the
        // formula alone.
        let coefficients = SaturationCoefficients.compile(driveDecibels: 0, mix: 1, isEnabled: true)
        Check.close(Double(coefficients.makeupGain), 1 / tanh(1), tolerance: 0.0001, "makeup matches 1/tanh(1) at 0 dB drive")
    }

    Check.suite("rackSaturate — odd symmetry") {
        // A waveshaper with no DC offset must treat a negative sample exactly
        // as it does the positive one, mirrored — real saturation curves
        // (tape, tube) are odd functions, and an asymmetric one would add
        // even-harmonic buzz nothing in this design intends.
        let coefficients = SaturationCoefficients.compile(driveDecibels: 12, mix: 1, isEnabled: true)
        for level: Float in stride(from: 0.05, through: 1, by: 0.1) {
            let positive = rackSaturate(level, coefficients: coefficients)
            let negative = rackSaturate(-level, coefficients: coefficients)
            Check.close(Double(negative), Double(-positive), tolerance: 0.0001, "process(-\(level)) mirrors process(\(level))")
        }
    }

    Check.suite("rackSaturate — monotonic across the drive range") {
        // A saturator that folds back on itself would reintroduce quiet
        // samples as loud ones — never true of `tanh`, checked directly
        // rather than assumed from its shape.
        let coefficients = SaturationCoefficients.compile(driveDecibels: 18, mix: 1, isEnabled: true)
        var previous: Float = -1
        var previousOutput = rackSaturate(previous, coefficients: coefficients)
        for level in stride(from: Float(-0.95), through: 1, by: 0.05) {
            let output = rackSaturate(level, coefficients: coefficients)
            Check.isTrue(output >= previousOutput, "output is non-decreasing from \(previous) to \(level)")
            previous = level
            previousOutput = output
        }
    }

    Check.suite("rackSaturate — partial mix blends toward the driven signal") {
        let full = SaturationCoefficients.compile(driveDecibels: 12, mix: 1, isEnabled: true)
        let half = SaturationCoefficients.compile(driveDecibels: 12, mix: 0.5, isEnabled: true)
        let level: Float = 0.7
        let dry = level
        let wet = rackSaturate(level, coefficients: full)
        let blended = rackSaturate(level, coefficients: half)
        Check.close(
            Double(blended), Double(dry + (wet - dry) * 0.5), tolerance: 0.0001,
            "mix 0.5 sits exactly halfway between dry and fully saturated"
        )
    }
}
