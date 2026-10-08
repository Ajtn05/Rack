import Darwin

/// The combined magnitude response of the whole signal chain.
///
/// What the amplifier's curve display draws: the two tone shelves, the ten
/// equalizer bands, the two boost shelves, and the preamp trim, summed into
/// one line. It is evaluated from `DSPChain.sections` — the same description
/// the audio thread's block is compiled from — so the curve on screen cannot
/// claim a shape the filters are not producing.
///
/// A value, not a service: constructed from parameters, then asked for
/// magnitudes. Nothing here is realtime, and nothing here should ever be called
/// from an IOProc — every method below is `pow`, `sin` and `cos`.
///
/// It is cheap enough to rebuild whenever a control moves and far too expensive
/// to rebuild per frame: fourteen sections at 120 points is about seventeen
/// hundred evaluations. Callers cache it against the parameters, which is the
/// whole reason it is a value they can hold.
public struct FrequencyResponse: Equatable, Sendable {
    /// The rate the sections were designed at, and the rate they are evaluated
    /// at. Both must be the same one or the curve describes a different filter
    /// from the one running.
    public let sampleRate: Double

    /// A flat offset applied across the whole curve: the preamp trim.
    ///
    /// Volume is deliberately *not* part of this. It is an attenuator rather
    /// than a shape, and folding up to 48 dB of it into a plot a few tens of
    /// decibels tall would drag the curve off the bottom of the display the
    /// moment anyone turned it down. Volume still reaches the curve where it
    /// genuinely changes the response — through the boost contour, whose
    /// depth tracks how far the control has attenuated.
    public let offsetDecibels: Double

    /// The designed cascade, in `DSPChain.sections` order.
    ///
    /// Module-internal rather than private so `DSPBlock.compile` can install
    /// these directly instead of calling `DSPChain.sections` a second time for
    /// the same parameters. Not public: outside AudioCore a response is a
    /// curve, and a caller that wants coefficients wants `DSPChain`.
    let sections: [BiquadCoefficients]

    /// Used when there is no running engine to ask for a rate.
    ///
    /// The curve is drawn dimmed in that state, but it is still drawn — a panel
    /// that goes blank when the power is off tells you less than one that shows
    /// what it would do.
    public static let nominalSampleRate: Double = 48_000

    /// Where a non-finite result is pinned, far below any plot range.
    ///
    /// None of the shapes this chain uses can reach zero magnitude, so this is
    /// unreachable in practice. It exists so that a curve can never carry a
    /// value a drawing layer cannot turn into a coordinate.
    public static let floorDecibels: Double = -120

    public init(
        parameters: DSPParameters,
        sampleRate: Double = FrequencyResponse.nominalSampleRate
    ) {
        let rate = sampleRate > 0 ? sampleRate : Self.nominalSampleRate
        let parameters = parameters.normalised()

        self.sampleRate = rate
        self.offsetDecibels = parameters.preampDecibels
        self.sections = DSPChain.sections(for: parameters, sampleRate: rate)
    }

    /// Magnitude at each frequency, in decibels. One output per input, in order.
    ///
    /// Sections cascade, so their decibel responses add — which is the whole
    /// reason a graphic equalizer can be drawn as a single line at all.
    public func magnitudeResponse(at frequencies: [Double]) -> [Double] {
        // Evaluating at or above Nyquist asks the transfer function about a
        // frequency the filters were not designed in; the curve wanders instead
        // of ending. Pinning to just below it makes the top of the plot flatten
        // out, which is what a band-limited system actually does.
        let ceiling = sampleRate / 2 * 0.999

        return frequencies.map { frequency in
            let bounded = min(max(frequency, 0), ceiling)
            let w = 2 * .pi * bounded / sampleRate

            // Computed once per frequency and shared across every section.
            let cos1 = cos(w), cos2 = cos(2 * w)
            let sin1 = sin(w), sin2 = sin(2 * w)

            // Sections cascade, so their magnitudes *multiply* and only the
            // combined result needs a logarithm. Taking one per section — which
            // is what adding decibels term by term does — spends fourteen
            // `log10` calls and fourteen square roots per point to compute a
            // number that one of each would give, and this sweep runs on every
            // frame of a slider drag.
            //
            // Squared magnitudes rather than magnitudes, so the square root
            // goes too: `20·log₁₀(∏|H|) = 10·log₁₀(∏|H|²)`.
            //
            // The product cannot overflow: `normalised()` clamps every gain to
            // ±12 dB, so each section's magnitude lies in [0.25, 4] and each
            // squared magnitude in [0.0625, 16]. Fourteen of them span
            // 3.7e-17 to 7.2e16 — the middle of Double's range, nowhere near
            // either end of it.
            var squaredProduct = 1.0
            for section in sections {
                let squared = section.squaredMagnitude(
                    cos1: cos1, cos2: cos2, sin1: sin1, sin2: sin2
                )
                guard squared > 0 else { return Self.floorDecibels }
                squaredProduct *= squared
            }
            let decibels = offsetDecibels + 10 * log10(squaredProduct)
            return decibels.isFinite ? decibels : Self.floorDecibels
        }
    }

    // MARK: - Headroom

    /// How many points the peak search sweeps. Coarser than the on-screen
    /// curve would need to be is not the goal here — reusing the same count
    /// the curve itself is drawn from is: what headroom compensation
    /// subtracts should never disagree with the peak the curve on screen
    /// appears to reach.
    private static let peakSweepPointCount = 120

    /// The sweep's own axis, built once.
    ///
    /// It depends on nothing but three constants, and rebuilding it costs 120
    /// `pow` calls — which is not much next to the sweep itself, but this runs
    /// on every parameter publication and the answer is the same every time.
    /// A `static let` is initialised exactly once and thread-safely, which is
    /// the whole of what is needed here.
    private static let peakSweepFrequencies: [Double] = logSpacedFrequencies(
        count: peakSweepPointCount
    )

    /// Highest point the combined filter response reaches, excluding the
    /// preamp trim — a flat offset the listener sets on purpose, not
    /// something Boost's headroom compensation should be fighting.
    ///
    /// What `DSPParameters.headroomCompensationDecibels(sampleRate:)`
    /// subtracts from the output stage so that raising Boost, or any shelf
    /// or band that reinforces it, can never raise the level leaving the
    /// engine.
    public var maximumGainDecibels: Double {
        guard let peak = magnitudeResponse(at: Self.peakSweepFrequencies).max() else {
            return 0
        }
        return peak - offsetDecibels
    }

    /// `headroomCompensationDecibels` for a response already built.
    ///
    /// The same number `DSPParameters.headroomCompensationDecibels(sampleRate:)`
    /// returns, for a caller that has a `FrequencyResponse` in hand — which
    /// both hot callers do. Going through the `DSPParameters` entry point
    /// there builds a second, identical `FrequencyResponse` and sweeps it a
    /// second time, and that duplicate sweep was the single most expensive
    /// thing on the parameter-publish path.
    ///
    /// - Parameter isEnabled: `DSPParameters.isHeadroomCompensationEnabled`.
    ///   Taken as an argument rather than read here because a response does not
    ///   carry the parameters it was built from.
    public func headroomCompensationDecibels(isEnabled: Bool) -> Double {
        guard isEnabled else { return 0 }
        return max(0, maximumGainDecibels)
    }

    // MARK: - The axis
    //
    // Hearing is logarithmic in frequency — the distance from 100 Hz to 200 Hz
    // is the same musical distance as 1 kHz to 2 kHz — so a response curve on a
    // linear axis squeezes nine tenths of what anyone can hear into the left
    // fifth of the plot. Both helpers below exist so that the layer doing the
    // drawing never has to know that.

    /// The lowest frequency worth plotting, and the highest.
    public static let lowestPlottedFrequency: Double = 20
    public static let highestPlottedFrequency: Double = 20_000

    /// `count` frequencies spaced evenly on a logarithmic axis.
    public static func logSpacedFrequencies(
        count: Int,
        from lowest: Double = FrequencyResponse.lowestPlottedFrequency,
        to highest: Double = FrequencyResponse.highestPlottedFrequency
    ) -> [Double] {
        guard count > 1, lowest > 0, highest > lowest else { return [] }
        let low = log10(lowest)
        let high = log10(highest)
        return (0..<count).map { index in
            pow(10, low + (high - low) * Double(index) / Double(count - 1))
        }
    }

    /// Where `frequency` sits on that axis, 0 at the left edge and 1 at the
    /// right. Outside the range it keeps going, so a caller can decide whether
    /// to clamp or to drop the point.
    public static func axisPosition(
        of frequency: Double,
        from lowest: Double = FrequencyResponse.lowestPlottedFrequency,
        to highest: Double = FrequencyResponse.highestPlottedFrequency
    ) -> Double {
        guard frequency > 0, lowest > 0, highest > lowest else { return 0 }
        return (log10(frequency) - log10(lowest)) / (log10(highest) - log10(lowest))
    }
}

// MARK: - Headroom compensation

extension DSPParameters {
    /// What Boost's headroom compensation subtracts from the output stage, in
    /// decibels.
    ///
    /// Bass boost is the most common cause of clipping in a chain like this
    /// one, so rather than trust the user to ride the preamp trim by hand,
    /// the output stage looks at the combined response of every shaping
    /// section — the tone shelves, the graphic EQ, and the boost shelves —
    /// and cuts by whatever its highest point is. Raising Boost, or any
    /// other control, can then never raise the level that leaves the engine;
    /// it can only spend headroom that was already there.
    ///
    /// Zero when defeated, or when the combined response never rises above
    /// unity — there is nothing positive left to compensate for.
    ///
    /// Off the audio thread only: building a `FrequencyResponse` calls `pow`,
    /// `sin` and `cos`.
    public func headroomCompensationDecibels(sampleRate: Double) -> Double {
        guard isHeadroomCompensationEnabled else { return 0 }
        let response = FrequencyResponse(parameters: self, sampleRate: sampleRate)
        return response.headroomCompensationDecibels(isEnabled: true)
    }
}
