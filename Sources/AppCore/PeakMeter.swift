import Foundation

extension Duration {
    /// Seconds as a `Double`. `Duration` deliberately avoids lossy conversions,
    /// but ballistics are floating point and need one.
    var seconds: Double {
        let (whole, attoseconds) = components
        return Double(whole) + Double(attoseconds) / 1e18
    }
}

/// Peak meter ballistics: how a level is turned into something worth looking at.
///
/// Three things have to be right or a meter feels broken even when its numbers
/// are correct.
///
/// **Scale.** The audio thread reports linear amplitude. Drawing that directly
/// is the classic mistake: −20 dBFS is 0.1 linear, so ordinary music occupies
/// the bottom tenth of the bar and the meter looks dead. Hearing is closer to
/// logarithmic, so the bar is positioned by decibels.
///
/// **Ballistics.** A peak meter rises instantly and falls slowly. Without the
/// slow fall it strobes at the poll rate and reads as noise; with too slow a
/// fall it lies about the current level.
///
/// **Hold.** The highest recent peak stays put for a moment, because the value
/// worth seeing is usually gone before the eye arrives.
///
/// This is presentation logic derived from audio values, which is AppCore's
/// job. Phase 6's `LevelMeter` component consumes `position` and `holdPosition`
/// and does nothing but draw them.
public struct PeakMeter: Equatable, Sendable {
    /// Everything below this reads as silence. −60 dBFS is a conventional
    /// floor: low enough to show a quiet fade, high enough that dither noise
    /// does not keep the bar off zero.
    public static let floorDecibels: Double = -60

    /// Fall rate once the signal drops, in dB per second. Broadcast PPMs fall
    /// roughly 20 dB in 1.7 s; digital meters are usually quicker. 30 dB/s
    /// tracks transients without flickering.
    public static let decayPerSecond: Double = 30

    /// How long the hold marker sits before it starts falling too.
    public static let holdDuration: Double = 1.2

    /// The hold marker falls more slowly than the bar, so it stays readable.
    public static let holdDecayPerSecond: Double = 12

    /// Current displayed level in dBFS. `-.infinity` is silence.
    public private(set) var decibels: Double = -.infinity

    /// The held peak in dBFS.
    public private(set) var holdDecibels: Double = -.infinity

    private var holdRemaining: Double = 0

    public init() {}

    /// Fold in a new peak reading.
    ///
    /// - Parameters:
    ///   - linearPeak: the loudest absolute sample since the last update.
    ///   - elapsed: seconds since the last update. Passed in rather than
    ///     measured here so the decay is correct even when polling is
    ///     irregular, which it always is.
    public mutating func update(linearPeak: Float, elapsed: Double) {
        let incoming = Self.decibels(fromLinear: linearPeak)

        // Attack is instantaneous, decay is timed. That asymmetry is the
        // whole idea of a peak meter.
        let tracked =
            incoming >= decibels
            ? incoming
            : max(incoming, decibels - Self.decayPerSecond * elapsed)

        decibels = Self.silenced(tracked)

        if decibels >= holdDecibels {
            holdDecibels = decibels
            holdRemaining = Self.holdDuration
        } else if holdRemaining > 0 {
            holdRemaining -= elapsed
        } else {
            holdDecibels = Self.silenced(
                max(decibels, holdDecibels - Self.holdDecayPerSecond * elapsed)
            )
        }
    }

    /// Anything under the floor *is* silence, and says so.
    ///
    /// Without this the decay never lands. In real silence the incoming
    /// reading is `-.infinity`, so the `max` that is supposed to stop the fall
    /// never binds and the level subtracts its decay rate forever — past the
    /// floor, past anything meaningful, at 30 dB per second with no bottom.
    /// The bar hid it, because `position` clamps at zero; the numeric readout
    /// did not, and sat there counting down through −200, −400, −800 and
    /// widening out of its field as the digits piled up.
    ///
    /// `>=` rather than `>`, so a level resting exactly on the floor is still
    /// a level. Only below it is nothing.
    private static func silenced(_ decibels: Double) -> Double {
        decibels >= floorDecibels ? decibels : -.infinity
    }

    /// Drop back to silence — on stop, so the meter does not sit frozen at
    /// whatever was playing when the engine went away.
    public mutating func reset() {
        self = PeakMeter()
    }

    public static func decibels(fromLinear value: Float) -> Double {
        guard value > 0 else { return -.infinity }
        return 20 * log10(Double(value))
    }

    /// Where to draw the bar, 0…1 across the meter's dB range.
    public static func position(forDecibels decibels: Double) -> Double {
        guard decibels > -.infinity else { return 0 }
        return min(1, max(0, (decibels - floorDecibels) / -floorDecibels))
    }

    public var position: Double { Self.position(forDecibels: decibels) }
    public var holdPosition: Double { Self.position(forDecibels: holdDecibels) }

    /// Formatted for a numeric readout.
    public var formattedDecibels: String {
        guard decibels > -.infinity else { return "−∞ dB" }
        return "\(decibels.formatted(.number.precision(.fractionLength(1)))) dB"
    }
}
