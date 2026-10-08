import Foundation

/// Phase correlation ballistics: how in-phase the left and right channels are.
///
/// `TapRenderContext.drainCorrelation()` hands over the normalized
/// cross-correlation coefficient for the window since the last drain —
/// `Σ(L·R) / sqrt(Σ(L²)·Σ(R²))`, the standard phase-correlation formula.
/// `+1` means the channels are identical (perfectly mono-compatible), `0`
/// means unrelated (typical of wide, healthy stereo material), and `−1`
/// means fully out of phase — sums to silence when collapsed to mono, which
/// is the fault this meter exists to catch.
///
/// Unlike `VUMeter`, there is no mechanical standard being reproduced here:
/// real phase meters are simple RC-damped movements, not a critically damped
/// 2nd-order system, because the quantity is already bounded to `[−1, 1]`
/// by the formula itself — there is no step-response overshoot to guard
/// against the way a VU coil's inertia can overshoot a sudden level change.
/// One one-pole low-pass is enough: fast enough that a real phase fault
/// reads within a fraction of a second, slow enough that the needle does not
/// visibly jitter with every ~30 Hz poll of a single short buffer's raw
/// coefficient.
public struct CorrelationMeter: Equatable, Sendable {
    /// The left end of the scale — fully out of phase.
    public static let floor: Double = -1

    /// The right end of the scale — fully in phase.
    public static let ceiling: Double = 1

    /// The one-pole time constant. Chosen, not derived: fast enough that a
    /// genuine phase problem shows up well within a second, slow enough that
    /// the raw per-poll coefficient — noisy over a buffer as short as a few
    /// hundred samples — reads as a settled needle rather than a flicker.
    public static let timeConstant: Double = 0.15

    public private(set) var value: Double = 0

    public init() {}

    /// Fold in a freshly drained correlation reading.
    ///
    /// - Parameters:
    ///   - rawCorrelation: `TapRenderContext.drainCorrelation()`'s output —
    ///     already in `[-1, 1]` by construction, but clamped again here
    ///     rather than trusted, the same defensiveness `VUMeter.update`
    ///     applies to its own input.
    ///   - elapsed: seconds since the last update, passed in so the filter
    ///     is correct however irregularly it is actually polled.
    public mutating func update(rawCorrelation: Float, elapsed: Double) {
        guard elapsed > 0 else { return }
        let target = min(Self.ceiling, max(Self.floor, Double(rawCorrelation)))
        let alpha = 1 - exp(-elapsed / Self.timeConstant)
        value += (target - value) * alpha
    }

    /// Back to center — on stop, so the needle does not sit deflected
    /// showing a phase reading for audio that ended.
    public mutating func reset() {
        self = CorrelationMeter()
    }

    /// Where to draw the indicator, 0…1. A straight linear map, unlike
    /// `VUMeter`'s hand-placed scale: a phase meter's face is evenly divided
    /// from −1 to +1, with no equivalent of a VU dial's compressed top end.
    public static func position(forCorrelation value: Double) -> Double {
        (min(ceiling, max(floor, value)) - floor) / (ceiling - floor)
    }

    public var position: Double { Self.position(forCorrelation: value) }
}
