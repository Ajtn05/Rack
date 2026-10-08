@testable import AudioCore

/// The crossfeed's own maths: the coefficients compiled from an amount and
/// an enable switch. The bleed actually reaching the output is covered by
/// `RenderPathTests`, which runs `rackRender` for real.
func runCrossfeedTests() {
    let sampleRate = 48_000.0

    Check.suite("CrossfeedCoefficients — disabled folds to a true no-op") {
        let disabled = CrossfeedCoefficients.compile(amount: 1, isEnabled: false, sampleRate: sampleRate)
        Check.close(Double(disabled.blendGain), 0, tolerance: 0.0001, "blend folds to zero while disabled")
        Check.close(Double(disabled.directGain), 1, tolerance: 0.0001, "direct gain folds to unity while disabled")
    }

    Check.suite("CrossfeedCoefficients — zero amount is also a true no-op") {
        let zero = CrossfeedCoefficients.compile(amount: 0, isEnabled: true, sampleRate: sampleRate)
        Check.close(Double(zero.blendGain), 0, tolerance: 0.0001, "blend is zero at zero amount")
        Check.close(Double(zero.directGain), 1, tolerance: 0.0001, "direct gain is unity at zero amount")
    }

    Check.suite("CrossfeedCoefficients — amount clamps to its own range") {
        let extreme = CrossfeedCoefficients.compile(amount: 5, isEnabled: true, sampleRate: sampleRate)
        Check.close(
            Double(extreme.blendGain), Crossfeed.amountRange.upperBound * Crossfeed.maximumBlendGain,
            tolerance: 0.0001, "amount clamps to its own ceiling before scaling to the blend"
        )

        let negative = CrossfeedCoefficients.compile(amount: -2, isEnabled: true, sampleRate: sampleRate)
        Check.close(Double(negative.blendGain), 0, tolerance: 0.0001, "amount clamps to its own floor")
    }

    Check.suite("CrossfeedCoefficients — direct gain compensates as blend rises") {
        let full = CrossfeedCoefficients.compile(amount: 1, isEnabled: true, sampleRate: sampleRate)
        Check.close(
            Double(full.directGain), Double(1 - full.blendGain * 0.5), tolerance: 0.0001,
            "direct gain is cut by exactly half the blend gain"
        )
        Check.isTrue(full.directGain < 1, "raising crossfeed cuts the direct path at all")
    }

    Check.suite("CrossfeedCoefficients — the filter is a stable, finite shelf") {
        // Reused directly from `BiquadCoefficients.highShelf`, so its own
        // stability guarantee already covers this — checked here as a
        // sanity backstop against the fixed corner and depth this type
        // hard-codes rather than trusting them silently.
        let coefficients = CrossfeedCoefficients.compile(amount: 1, isEnabled: true, sampleRate: sampleRate)
        Check.isTrue(coefficients.filter.isFinite, "the crossfeed shelf is finite")
        Check.isTrue(coefficients.filter.isStable, "the crossfeed shelf is stable")
    }
}
