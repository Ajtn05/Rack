import Darwin

@testable import AudioCore

/// The limiter's own maths: the coefficients compiled from a ceiling and a
/// release, and the gain rule those coefficients drive.
///
/// The property that matters is the one in the name — *brickwall*. A limiter
/// that is usually under the ceiling is not a limiter, so the tests below are
/// mostly about the guarantee holding at the edges rather than about the
/// typical case looking right.
func runLimiterTests() {
    Check.suite("LimiterCoefficients — the ceiling compiles to a linear amplitude") {
        let unity = LimiterCoefficients.compile(
            ceilingDecibels: 0, releaseMilliseconds: 100, isEnabled: true, sampleRate: 48_000
        )
        Check.close(Double(unity.ceiling), 1, tolerance: 0.0001, "0 dBFS is amplitude 1")

        let minusSix = LimiterCoefficients.compile(
            ceilingDecibels: -6, releaseMilliseconds: 100, isEnabled: true, sampleRate: 48_000
        )
        Check.close(
            Double(minusSix.ceiling), pow(10, -6.0 / 20),
            tolerance: 0.0001, "−6 dBFS is half amplitude, near enough"
        )
    }

    Check.suite("LimiterCoefficients — the ceiling and release clamp to their ranges") {
        let high = LimiterCoefficients.compile(
            ceilingDecibels: 24, releaseMilliseconds: 100_000, isEnabled: true, sampleRate: 48_000
        )
        Check.close(
            Double(high.ceiling), pow(10, Limiter.ceilingRangeDecibels.upperBound / 20),
            tolerance: 0.0001, "a ceiling above full scale clamps to full scale"
        )

        let low = LimiterCoefficients.compile(
            ceilingDecibels: -200, releaseMilliseconds: 0, isEnabled: true, sampleRate: 48_000
        )
        Check.close(
            Double(low.ceiling), pow(10, Limiter.ceilingRangeDecibels.lowerBound / 20),
            tolerance: 0.0001, "a ceiling below the range clamps to its floor"
        )
    }

    Check.suite("Limiter — a signal under the ceiling is bit-identical") {
        // The whole reason a limiter can be left switched on: below the
        // ceiling the gain is *exactly* one, not approximately one, so it
        // cannot colour anything it is not actually catching.
        let ceiling: Float = 0.9
        for level: Float in [0, 0.1, 0.5, 0.89, 0.9] {
            Check.equal(
                rackLimiterRequiredGain(peak: level, ceiling: ceiling), 1,
                "gain is exactly 1 at \(level), under a \(ceiling) ceiling"
            )
        }
    }

    Check.suite("Limiter — the ceiling is a guarantee, not a target") {
        let ceiling: Float = 0.5
        // Every one of these is over the ceiling; applying the returned gain
        // must land exactly on it, never above.
        for peak: Float in [0.5001, 0.7, 1, 2, 8, 100] {
            let gain = rackLimiterRequiredGain(peak: peak, ceiling: ceiling)
            let limited = peak * gain
            Check.close(
                Double(limited), Double(ceiling), tolerance: 0.0001,
                "a peak of \(peak) lands on the ceiling"
            )
            Check.isTrue(limited <= ceiling * 1.0001, "a peak of \(peak) never exceeds the ceiling")
        }
    }

    Check.suite("Limiter — silence and zero are not a division") {
        // `ceiling / peak` with peak 0 is the one input that could produce an
        // infinity and poison the chain. It must read as "no limiting".
        Check.equal(rackLimiterRequiredGain(peak: 0, ceiling: 0.5), 1, "a silent peak needs no gain")
        Check.isTrue(
            rackLimiterRequiredGain(peak: 0, ceiling: 0.5).isFinite,
            "a silent peak produces a finite gain"
        )
    }

    Check.suite("Limiter — disabled is not compiled as active") {
        let off = LimiterCoefficients.compile(
            ceilingDecibels: -6, releaseMilliseconds: 100, isEnabled: false, sampleRate: 48_000
        )
        Check.isTrue(!off.isActive, "the enable switch folds into the coefficients")
    }

    Check.suite("Limiter — the release coefficient is a sane one-pole") {
        let fast = Limiter.releaseCoefficient(milliseconds: 10, sampleRate: 48_000)
        let slow = Limiter.releaseCoefficient(milliseconds: 500, sampleRate: 48_000)
        Check.isTrue(fast > slow, "a shorter release chases its target harder")
        Check.isTrue(fast > 0 && fast <= 1, "a one-pole coefficient stays in 0…1")
        Check.isTrue(slow > 0 && slow <= 1, "a one-pole coefficient stays in 0…1")

        // A nonsense rate must not produce a NaN that would reach the chain.
        Check.equal(
            Limiter.releaseCoefficient(milliseconds: 100, sampleRate: 0), 1,
            "a zero sample rate degrades to an immediate release"
        )
    }
}
