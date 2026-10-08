import Darwin

@testable import AudioCore

/// The compressor's own maths: the soft-knee curve a detector reading maps
/// to, the coefficients compiled from it, and the attack/release ballistic
/// that turns the static curve into something that does not sound like
/// distortion.
func runCompressorTests() {
    let sampleRate = 48_000.0

    Check.suite("Compressor.timeCoefficient — one-pole settling") {
        // A single one-pole low-pass reaches 1 − 1/e of a step after one
        // time constant — the same textbook figure `CorrelationMeter`'s own
        // settling test checks, on the coefficient this compressor's
        // envelope actually uses.
        let coefficient = Compressor.timeCoefficient(milliseconds: 50, sampleRate: sampleRate)
        var value: Float = 0
        let samples = Int(0.050 * sampleRate)
        for _ in 0..<samples {
            value = rackSmooth(value, toward: 1, coefficient: coefficient)
        }
        Check.close(Double(value), 1 - 1 / M_E, tolerance: 0.01, "reaches 1 − 1/e after one time constant")
    }

    Check.suite("CompressorCoefficients — disabled folds to a true no-op") {
        let disabled = CompressorCoefficients.compile(
            thresholdDecibels: -18, ratio: 8, attackMilliseconds: 5,
            releaseMilliseconds: 50, makeupDecibels: 12,
            isEnabled: false, sampleRate: sampleRate
        )
        Check.close(Double(disabled.ratio), 1, tolerance: 0.0001, "ratio folds to 1:1 — the curve's own fixed point")
        Check.close(Double(disabled.makeupDecibels), 0, tolerance: 0.0001, "makeup gain folds to zero")

        // At ratio 1, the curve returns zero reduction for any detector
        // level at all — proving the fold, not just asserting the field.
        for level: Float in [-40, -18, 0, 12] {
            let reduction = rackCompressorTargetReduction(detectorDecibels: level, coefficients: disabled)
            Check.close(Double(reduction), 0, tolerance: 0.0001, "no reduction at \(level) dB while disabled")
        }
    }

    Check.suite("CompressorCoefficients — knobs clamp to their ranges") {
        let extreme = CompressorCoefficients.compile(
            thresholdDecibels: 100, ratio: 100, attackMilliseconds: -5,
            releaseMilliseconds: 100_000, makeupDecibels: 100,
            isEnabled: true, sampleRate: sampleRate
        )
        Check.close(
            Double(extreme.thresholdDecibels), Compressor.thresholdRangeDecibels.upperBound,
            tolerance: 0.0001, "threshold clamps to its own ceiling"
        )
        Check.close(
            Double(extreme.ratio), Compressor.ratioRange.upperBound,
            tolerance: 0.0001, "ratio clamps to its own ceiling"
        )
        Check.close(
            Double(extreme.makeupDecibels), Compressor.makeupRangeDecibels.upperBound,
            tolerance: 0.0001, "makeup clamps to its own ceiling"
        )
    }

    Check.suite("Compressor — the curve is silent below the knee") {
        let coefficients = CompressorCoefficients.compile(
            thresholdDecibels: -18, ratio: 4, attackMilliseconds: 5,
            releaseMilliseconds: 50, makeupDecibels: 0, isEnabled: true, sampleRate: sampleRate
        )
        // Comfortably below threshold minus half the knee (6 dB, so 3 dB
        // either side) — nothing should happen at all.
        let reduction = rackCompressorTargetReduction(detectorDecibels: -30, coefficients: coefficients)
        Check.close(Double(reduction), 0, tolerance: 0.0001, "well under threshold, no reduction")
    }

    Check.suite("Compressor — the curve matches the straight ratio line above the knee") {
        let threshold: Float = -18
        let ratio: Float = 4
        let coefficients = CompressorCoefficients.compile(
            thresholdDecibels: Double(threshold), ratio: Double(ratio), attackMilliseconds: 5,
            releaseMilliseconds: 50, makeupDecibels: 0, isEnabled: true, sampleRate: sampleRate
        )
        // Comfortably above threshold plus half the knee: the textbook
        // hard-knee formula, (overshoot) × (1 − 1/ratio).
        let detector: Float = 0
        let overshoot = detector - threshold
        let expected = overshoot * (1 - 1 / ratio)
        let reduction = rackCompressorTargetReduction(detectorDecibels: detector, coefficients: coefficients)
        Check.close(Double(reduction), Double(expected), tolerance: 0.01, "matches the straight ratio line well above the knee")
    }

    Check.suite("Compressor — the knee is continuous with both straight pieces") {
        // The whole reason a soft knee exists: no jump where the parabola
        // meets either straight line. Sampled just inside and just outside
        // each boundary, the reduction must agree to a fraction of a dB.
        let coefficients = CompressorCoefficients.compile(
            thresholdDecibels: -18, ratio: 4, attackMilliseconds: 5,
            releaseMilliseconds: 50, makeupDecibels: 0, isEnabled: true, sampleRate: sampleRate
        )
        let knee = Compressor.kneeDecibels
        let threshold: Float = -18
        let epsilon: Float = 0.001

        let belowInside = rackCompressorTargetReduction(
            detectorDecibels: threshold - knee / 2 - epsilon, coefficients: coefficients
        )
        let belowOutside = rackCompressorTargetReduction(
            detectorDecibels: threshold - knee / 2 + epsilon, coefficients: coefficients
        )
        Check.close(Double(belowInside), Double(belowOutside), tolerance: 0.01, "continuous at the lower knee boundary")

        let aboveInside = rackCompressorTargetReduction(
            detectorDecibels: threshold + knee / 2 - epsilon, coefficients: coefficients
        )
        let aboveOutside = rackCompressorTargetReduction(
            detectorDecibels: threshold + knee / 2 + epsilon, coefficients: coefficients
        )
        Check.close(Double(aboveInside), Double(aboveOutside), tolerance: 0.01, "continuous at the upper knee boundary")
    }

    Check.suite("Compressor — reduction never goes negative") {
        // (1 − 1/ratio) is always ≥ 0 for ratio ≥ 1, so the curve can only
        // ever ask for a cut, never a boost — checked across the full
        // knob ranges rather than trusted from the algebra.
        for ratio in stride(from: Compressor.ratioRange.lowerBound, through: Compressor.ratioRange.upperBound, by: 1) {
            let coefficients = CompressorCoefficients.compile(
                thresholdDecibels: -18, ratio: ratio, attackMilliseconds: 5,
                releaseMilliseconds: 50, makeupDecibels: 0, isEnabled: true, sampleRate: sampleRate
            )
            for level: Float in stride(from: -48, through: 0, by: 4) {
                let reduction = rackCompressorTargetReduction(detectorDecibels: level, coefficients: coefficients)
                Check.isTrue(reduction >= 0, "ratio \(ratio) at \(level) dB never reduces negatively (got \(reduction))")
            }
        }
    }
}
