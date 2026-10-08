import Darwin

/// Coefficients for one second-order section, normalised so that `a0 == 1`.
///
/// Stored as `Float` because that is what the audio thread multiplies, but
/// every coefficient is *computed* in `Double`. The difference matters: the
/// design formulae subtract nearly-equal quantities at low frequencies, and at
/// 31.25 Hz against a 48 kHz sample rate single precision loses enough of the
/// result to shift the corner audibly.
public struct BiquadCoefficients: Equatable, Sendable {
    public var b0: Float
    public var b1: Float
    public var b2: Float
    public var a1: Float
    public var a2: Float

    public init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    /// Passes the signal through untouched, and does so *exactly* — `y = x`
    /// with no rounding, which is what makes a flat-EQ null test bit-identical
    /// rather than merely close.
    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
}

// MARK: - Design
//
// The Audio EQ Cookbook forms (Robert Bristow-Johnson). Computed off the audio
// thread — never from the IOProc.

extension BiquadCoefficients {
    /// A band whose gain is centred on `frequency`, tapering either side.
    /// Bands 2–9 of the graphic EQ.
    ///
    /// - Parameter q: For an octave-spaced bank, `EQBank.octaveQ` (≈1.414)
    ///   gives each band one octave of bandwidth, so neighbours meet without
    ///   piling up.
    public static func peaking(
        frequency: Double,
        q: Double,
        gainDecibels: Double,
        sampleRate: Double
    ) -> BiquadCoefficients {
        guard gainDecibels != 0 else { return .identity }
        guard let w0 = angularFrequency(frequency, sampleRate) else { return .identity }

        let a = pow(10, gainDecibels / 40)
        let alpha = sin(w0) / (2 * max(q, 0.0001))
        let cosW0 = cos(w0)

        let b0 = 1 + alpha * a
        let b1 = -2 * cosW0
        let b2 = 1 - alpha * a
        let a0 = 1 + alpha / a
        let a1 = -2 * cosW0
        let a2 = 1 - alpha / a

        return normalised(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    /// Lifts or cuts everything below `frequency`. Band 1 of the graphic EQ,
    /// the bass half of the boost contour, and the bass half of the tone
    /// control.
    ///
    /// - Parameter slope: Shelf steepness. 1 is the maximally flat case; above
    ///   about 1 the shelf peaks before it settles.
    public static func lowShelf(
        frequency: Double,
        slope: Double = 1,
        gainDecibels: Double,
        sampleRate: Double
    ) -> BiquadCoefficients {
        guard gainDecibels != 0 else { return .identity }
        guard let w0 = angularFrequency(frequency, sampleRate) else { return .identity }

        let a = pow(10, gainDecibels / 40)
        let cosW0 = cos(w0)
        let alpha = shelfAlpha(a: a, w0: w0, slope: slope)
        let twoSqrtAAlpha = 2 * sqrt(a) * alpha

        let b0 = a * ((a + 1) - (a - 1) * cosW0 + twoSqrtAAlpha)
        let b1 = 2 * a * ((a - 1) - (a + 1) * cosW0)
        let b2 = a * ((a + 1) - (a - 1) * cosW0 - twoSqrtAAlpha)
        let a0 = (a + 1) + (a - 1) * cosW0 + twoSqrtAAlpha
        let a1 = -2 * ((a - 1) + (a + 1) * cosW0)
        let a2 = (a + 1) + (a - 1) * cosW0 - twoSqrtAAlpha

        return normalised(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    /// Lifts or cuts everything above `frequency`. Band 10 of the graphic EQ,
    /// the treble half of the boost contour, and the treble half of the tone
    /// control.
    public static func highShelf(
        frequency: Double,
        slope: Double = 1,
        gainDecibels: Double,
        sampleRate: Double
    ) -> BiquadCoefficients {
        guard gainDecibels != 0 else { return .identity }
        guard let w0 = angularFrequency(frequency, sampleRate) else { return .identity }

        let a = pow(10, gainDecibels / 40)
        let cosW0 = cos(w0)
        let alpha = shelfAlpha(a: a, w0: w0, slope: slope)
        let twoSqrtAAlpha = 2 * sqrt(a) * alpha

        let b0 = a * ((a + 1) + (a - 1) * cosW0 + twoSqrtAAlpha)
        let b1 = -2 * a * ((a - 1) + (a + 1) * cosW0)
        let b2 = a * ((a + 1) + (a - 1) * cosW0 - twoSqrtAAlpha)
        let a0 = (a + 1) - (a - 1) * cosW0 + twoSqrtAAlpha
        let a1 = 2 * ((a - 1) - (a + 1) * cosW0)
        let a2 = (a + 1) - (a - 1) * cosW0 - twoSqrtAAlpha

        return normalised(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    /// Digital angular frequency, or nil if the band sits at or above Nyquist,
    /// where it has no meaning and the formulae degenerate.
    private static func angularFrequency(
        _ frequency: Double,
        _ sampleRate: Double
    ) -> Double? {
        guard sampleRate > 0, frequency > 0 else { return nil }
        // Stop short of Nyquist: at exactly Nyquist sin(w0) is 0 and the
        // design collapses. A band above it is simply not realisable, and at
        // 44.1 kHz the 16 kHz band is close enough to matter.
        let nyquist = sampleRate / 2
        guard frequency < nyquist * 0.999 else { return nil }
        return 2 * .pi * frequency / sampleRate
    }

    private static func shelfAlpha(a: Double, w0: Double, slope: Double) -> Double {
        let s = max(slope, 0.0001)
        return sin(w0) / 2 * sqrt((a + 1 / a) * (1 / s - 1) + 2)
    }

    private static func normalised(
        b0: Double, b1: Double, b2: Double,
        a0: Double, a1: Double, a2: Double
    ) -> BiquadCoefficients {
        guard a0 != 0, a0.isFinite else { return .identity }
        let coefficients = BiquadCoefficients(
            b0: Float(b0 / a0),
            b1: Float(b1 / a0),
            b2: Float(b2 / a0),
            a1: Float(a1 / a0),
            a2: Float(a2 / a0)
        )
        // A NaN reaching the audio thread is permanent: it propagates through
        // the filter state and the channel stays silent until reset. An
        // unstable set is worse — it produces a signal that grows without
        // bound. Neither is worth risking for one band, so a suspect design
        // degrades to a flat one.
        guard coefficients.isFinite, coefficients.isStable else { return .identity }
        return coefficients
    }

    public var isFinite: Bool {
        b0.isFinite && b1.isFinite && b2.isFinite && a1.isFinite && a2.isFinite
    }

    /// Whether the poles sit inside the unit circle. The stability triangle:
    /// `|a2| < 1` and `|a1| < 1 + a2`.
    public var isStable: Bool {
        abs(a2) < 1 && abs(a1) < 1 + a2
    }
}

// MARK: - Analysis

extension BiquadCoefficients {
    /// Magnitude of the transfer function at `frequency`.
    ///
    /// Used by the tests to check the filters against their intended response,
    /// and by `FrequencyResponse` to draw the curve. Not realtime.
    public func magnitude(atFrequency frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * .pi * frequency / sampleRate
        return magnitude(cos1: cos(w), cos2: cos(2 * w), sin1: sin(w), sin2: sin(2 * w))
    }

    /// The same magnitude, from trigonometric values the caller already has.
    ///
    /// Split out for the sweep: a curve evaluates every section at the same
    /// frequency, so the four values below are worth computing once per
    /// frequency rather than once per section per frequency. With twelve
    /// sections that is four transcendental calls instead of forty-eight, and
    /// the curve is recomputed on every movement of every control.
    ///
    /// The arithmetic lives here, in one place, rather than being copied into
    /// the sweep — a second copy of a transfer function is a second thing to
    /// get subtly wrong.
    public func magnitude(cos1: Double, cos2: Double, sin1: Double, sin2: Double) -> Double {
        squaredMagnitude(cos1: cos1, cos2: cos2, sin1: sin1, sin2: sin2).squareRoot()
    }

    /// The same quantity squared — the form the sweep actually wants.
    ///
    /// `|H|²` is what the arithmetic below naturally produces; the square root
    /// in `magnitude` is undoing that, and a cascade then immediately takes a
    /// logarithm of the result. Since `log(∏|H|) = ½·log(∏|H|²)`, a sweep can
    /// multiply these together and take one logarithm at the end instead of a
    /// square root *and* a logarithm per section per point — see
    /// `FrequencyResponse.magnitudeResponse`, where that is 28 transcendental
    /// calls per point rather than one.
    ///
    /// Kept as a separate entry point rather than changing `magnitude`, which
    /// is public API and is what a single-section question should still ask.
    public func squaredMagnitude(
        cos1: Double, cos2: Double, sin1: Double, sin2: Double
    ) -> Double {
        // H(e^jw) = Σ b_k e^-jwk / (1 + Σ a_k e^-jwk), and e^-jwk contributes
        // cos(wk) to the real part and -sin(wk) to the imaginary part.
        let numeratorReal = Double(b0) + Double(b1) * cos1 + Double(b2) * cos2
        let numeratorImaginary = -(Double(b1) * sin1 + Double(b2) * sin2)
        let denominatorReal = 1 + Double(a1) * cos1 + Double(a2) * cos2
        let denominatorImaginary = -(Double(a1) * sin1 + Double(a2) * sin2)

        let numerator = numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary
        let denominator = denominatorReal * denominatorReal
            + denominatorImaginary * denominatorImaginary
        guard denominator > 0 else { return .infinity }
        return numerator / denominator
    }

    public func magnitudeDecibels(atFrequency frequency: Double, sampleRate: Double) -> Double {
        let magnitude = magnitude(atFrequency: frequency, sampleRate: sampleRate)
        guard magnitude > 0 else { return -.infinity }
        return 20 * log10(magnitude)
    }
}

// MARK: - The filter itself

/// One second-order section, direct form II transposed.
///
/// DF2T is the usual choice for floating-point audio: it needs two state
/// variables rather than four, and its rounding behaviour is better than
/// direct form I at the low corner frequencies this EQ uses.
///
/// `process` is realtime — it does nothing but multiply and add.
public struct Biquad: Sendable {
    public var coefficients: BiquadCoefficients = .identity

    private var s1: Float = 0
    private var s2: Float = 0

    public init(coefficients: BiquadCoefficients = .identity) {
        self.coefficients = coefficients
    }

    @inline(__always)
    public mutating func process(_ input: Float) -> Float {
        let output = coefficients.b0 * input + s1
        s1 = coefficients.b1 * input - coefficients.a1 * output + s2
        s2 = coefficients.b2 * input - coefficients.a2 * output
        return output
    }

    /// Clear the delay line. Needed whenever the signal is discontinuous —
    /// a device change, a sample rate change — because the state left behind
    /// belongs to a stream that no longer exists.
    public mutating func reset() {
        s1 = 0
        s2 = 0
    }
}
