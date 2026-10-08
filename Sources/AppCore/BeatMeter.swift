import Foundation

/// Beat/onset ballistics: a fast-attack, slow-release "did something just hit"
/// gauge, driven by the bass region of the spectrum bands `SpectrumBallistics`
/// already reads — no capture of its own, the same "reuse what the audio
/// thread already publishes" reasoning the VU display gets for reading the
/// always-on peak/VU accumulators.
///
/// The bass level is compared against its own slow-moving average rather than
/// a fixed dB threshold, because a fixed level runs hot on a bass-heavy track
/// and never fires on a quiet one; comparing to a recent average adapts to
/// whatever is actually playing. A refractory period after a hit stops one
/// kick drum's decay from registering as several.
public struct BeatMeter: Equatable, Sendable {
    /// How many dB the current bass level must clear the running average by
    /// to count as a hit. Loud enough that ordinary wobble inside a bassline
    /// does not trigger it, small enough that an actual kick does.
    public static let onsetMarginDecibels: Double = 4

    /// How slowly the running average itself moves — long enough that a
    /// single kick drum barely nudges it, short enough that it still tracks
    /// a song's overall level as one track ends and another begins.
    public static let averageTimeConstant: Double = 2

    /// How long after a hit before another one can register — long enough
    /// that a kick drum's own decay is not mistaken for a second hit, short
    /// enough not to miss a fast tempo.
    public static let refractorySeconds: Double = 0.12

    /// How quickly the needle snaps toward a hit — fast enough to read as a
    /// snap rather than a swell.
    public static let attackTimeConstant: Double = 0.02

    /// How slowly it falls back afterwards — slow enough to read as a pulse
    /// rather than a flicker.
    public static let releaseTimeConstant: Double = 0.35

    /// Below this, a band (or a whole window) counts as carrying no energy —
    /// the same role `PeakMeter.floorDecibels` plays on the meter side.
    private static let silenceFloorDecibels: Double = -72

    private var runningAverageDecibels: Double = BeatMeter.silenceFloorDecibels
    private var refractoryRemaining: Double = 0

    /// The needle position, 0…1 — snaps toward 1 on a hit, decays back to 0.
    public private(set) var position: Double = 0

    public init() {}

    /// Fold in the latest bass-band level.
    ///
    /// - Parameters:
    ///   - bassDecibels: the current bass-band level, in dBFS — see
    ///     `bassLevel(bandsDecibels:bandFrequencies:)`.
    ///   - elapsed: seconds since the last update.
    public mutating func update(bassDecibels: Double, elapsed: Double) {
        guard elapsed > 0 else { return }
        let level = bassDecibels.isFinite ? bassDecibels : Self.silenceFloorDecibels

        let averageAlpha = 1 - exp(-elapsed / Self.averageTimeConstant)
        runningAverageDecibels += (level - runningAverageDecibels) * averageAlpha

        if refractoryRemaining > 0 {
            refractoryRemaining -= elapsed
        }

        let isHit = refractoryRemaining <= 0
            && level - runningAverageDecibels >= Self.onsetMarginDecibels
        if isHit {
            refractoryRemaining = Self.refractorySeconds
        }

        let target = isHit ? 1.0 : 0.0
        let timeConstant = isHit ? Self.attackTimeConstant : Self.releaseTimeConstant
        let alpha = 1 - exp(-elapsed / timeConstant)
        position = min(max(position + (target - position) * alpha, 0), 1)
    }

    /// Drop back to silence — on stop, or on leaving the mode, so the needle
    /// does not sit deflected showing a hit for audio that ended.
    public mutating func reset() {
        self = BeatMeter()
    }

    /// The average level of the third-octave bands whose centre frequency
    /// falls inside `range` — the "bass" this meter watches.
    ///
    /// Takes the raw bands and their frequencies directly rather than naming
    /// `SpectrumAnalyzer` — decoupled the same way `goniometerPoint(for:)`
    /// and `oscilloscopeValue(for:)` are, and directly testable without an
    /// engine or an FFT anywhere near it. A band with no energy at all
    /// (`-.infinity`) is left out of the average rather than dragging it to
    /// negative infinity; a window with nothing in range at all reads as
    /// silence.
    public static func bassLevel(
        bandsDecibels: [Float],
        bandFrequencies: [Double],
        range: ClosedRange<Double> = 60...250
    ) -> Double {
        var sum = 0.0
        var count = 0
        for (index, frequency) in bandFrequencies.enumerated() where range.contains(frequency) {
            guard index < bandsDecibels.count else { continue }
            let level = bandsDecibels[index]
            guard level.isFinite else { continue }
            sum += Double(level)
            count += 1
        }
        return count > 0 ? sum / Double(count) : silenceFloorDecibels
    }
}
