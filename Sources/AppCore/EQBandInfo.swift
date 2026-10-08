import AudioCore
import Foundation

/// What a screen needs to know about one equalizer band.
///
/// The band layout is an audio fact — `EQBank` owns the frequencies and the
/// travel — but a view should not have to import AudioCore to draw a fader.
/// This is that fact, restated in terms a fader can use.
public struct EQBandInfo: Identifiable, Equatable, Sendable {
    public let id: Int

    /// Short legend for the fader, e.g. "125" or "16k".
    public let label: String

    /// Centre frequency in hertz, for a tooltip or a curve.
    public let frequency: Double

    /// Whether this band is a shelf. The outer two are, which is why the
    /// extremes of the range actually move rather than tapering away.
    public let isShelf: Bool
}

extension EngineController {
    /// The bands, in order, left to right.
    public var bands: [EQBandInfo] {
        (0..<EQBank.bandCount).map { index in
            EQBandInfo(
                id: index,
                label: EQBank.label(forBand: index),
                frequency: EQBank.frequencies[index],
                isShelf: EQBank.shape(forBand: index) != .peaking
            )
        }
    }

    /// The travel of a band fader, and of the preamp.
    public var gainRange: ClosedRange<Double> {
        -EQBank.maximumGainDecibels...EQBank.maximumGainDecibels
    }
}
