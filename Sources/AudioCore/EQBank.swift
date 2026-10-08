import Darwin

/// The ten-band graphic equalizer: which frequencies, how wide, how much.
///
/// Octave spacing from 31.25 Hz, which is the classic hi-fi graphic layout and
/// lands the top band on 16 kHz — the highest centre that is still realisable
/// at 44.1 kHz.
public enum EQBank {
    /// Centre frequencies, one octave apart.
    public static let frequencies: [Double] = [
        31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16_000
    ]

    public static var bandCount: Int { frequencies.count }

    /// The travel of one slider, either way.
    public static let maximumGainDecibels: Double = 12

    /// Q for one octave of bandwidth.
    ///
    /// From `Q = √(2^N) / (2^N − 1)` with N = 1 octave. Get this wrong and the
    /// bands either overlap — so raising two neighbours gives more than either
    /// slider promises — or leave gaps between them.
    public static let octaveQ: Double = 2.0.squareRoot() / (2.0 - 1.0)

    /// The role each band plays.
    ///
    /// The outer two are shelves rather than peaks so that the extremes of the
    /// range actually move. A peaking band centred at 31.25 Hz tapers off
    /// below itself, leaving the bottom octave — which is most of what a
    /// "bass" control is wanted for — untouched.
    public enum BandShape: Equatable, Sendable {
        case lowShelf
        case peaking
        case highShelf
    }

    public static func shape(forBand index: Int) -> BandShape {
        switch index {
        case 0: .lowShelf
        case frequencies.count - 1: .highShelf
        default: .peaking
        }
    }

    /// Design one band. Off the audio thread only.
    public static func coefficients(
        forBand index: Int,
        gainDecibels: Double,
        sampleRate: Double
    ) -> BiquadCoefficients {
        guard frequencies.indices.contains(index) else { return .identity }
        let frequency = frequencies[index]
        let gain = min(max(gainDecibels, -maximumGainDecibels), maximumGainDecibels)

        return switch shape(forBand: index) {
        case .lowShelf:
            .lowShelf(frequency: frequency, gainDecibels: gain, sampleRate: sampleRate)
        case .peaking:
            .peaking(
                frequency: frequency, q: octaveQ,
                gainDecibels: gain, sampleRate: sampleRate
            )
        case .highShelf:
            .highShelf(frequency: frequency, gainDecibels: gain, sampleRate: sampleRate)
        }
    }

    /// A short label for a band, for the fader legend in Phase 6.
    public static func label(forBand index: Int) -> String {
        guard frequencies.indices.contains(index) else { return "—" }
        let frequency = frequencies[index]
        if frequency >= 1000 {
            let kilohertz = frequency / 1000
            return kilohertz == kilohertz.rounded()
                ? "\(Int(kilohertz))k"
                : "\(kilohertz)k"
        }
        // Rounded to a whole number of hertz. "31.25" is more precise than a
        // fader legend needs to be, and it wraps to two lines in the column
        // width a fader actually has.
        return "\(Int(frequency.rounded()))"
    }
}
