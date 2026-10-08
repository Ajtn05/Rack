import Foundation

/// VU ballistics: the classic backlit-meter movement, not a peak reader.
///
/// A real VU meter is a moving-coil movement driven by the **rectified
/// average** of the signal — mean absolute value, not RMS, which is the
/// actual ANSI C16.5 detector topology and why "VU" and "RMS" meters read
/// program material differently even on identical audio. Its mechanical
/// inertia behaves as a **critically damped 2nd-order system**: a step
/// reaches 99% of its final deflection in 300 ms, with no overshoot, and —
/// unlike `PeakMeter`'s deliberately asymmetric instant-attack/timed-decay —
/// the same time constant governs the way back down. That symmetry is not an
/// approximation here; it falls out of using one filter for both directions.
///
/// Two identical cascaded one-pole low-pass stages reproduce exactly that
/// movement. Each stage is updated as
/// `y += (x − y) * (1 − exp(−elapsed / τ))`, the exact sampled response of a
/// continuous RC one-pole for *any* elapsed time — which matters here more
/// than it does for `PeakMeter`'s linear dB/sec decay, because this is
/// advanced from a jittery ~30 Hz UI poll rather than a fixed audio rate, and
/// a fixed per-tick coefficient would only be correct at one particular
/// polling interval.
///
/// Filtering happens on the **linear** rectified magnitude, not on dB: a real
/// meter's coil responds to rectified voltage, and log-transforming first
/// would change the shape of the response to a step. The conversion to dB
/// happens once, after both stages, purely for display.
public struct VUMeter: Equatable, Sendable {
    /// The left end of the printed scale, in VU — dB relative to
    /// `alignmentLevelDecibels`, which is what a printed VU scale has always
    /// been measured against, never digital full scale directly.
    public static let floorDecibels: Double = -20

    /// "0 VU".
    public static let referenceDecibels: Double = 0

    /// The right end of the printed scale, in VU.
    public static let ceilingDecibels: Double = 3

    /// Where "0 VU" sits relative to digital full scale.
    ///
    /// A real VU meter is calibrated against a line-up tone fed through the
    /// same gain stage the programme material passes through, never against
    /// full-scale digital audio directly — full scale is the loudest a
    /// digital signal can ever be, and ordinary programme material averages
    /// nowhere near it. There is no line-up tone here, so the reference used
    /// is the one professional digital consoles default to: EBU R68's
    /// alignment level of −18 dBFS. Calibrating 0 VU to 0 dBFS instead — the
    /// first attempt at this — pins the reference at a level real audio
    /// essentially never reaches, and the needle sits pegged near the bottom
    /// of the scale for anything short of a mastering-limiter fight.
    public static let alignmentLevelDecibels: Double = -18

    /// ANSI C16.5: a 0 VU step reaches 99% of its final deflection in 300 ms.
    public static let integrationSeconds: Double = 0.3

    /// The fraction of a step a critically damped 2nd-order system has
    /// reached by 300 ms, per `integrationSeconds`/`timeConstant` above.
    private static let settledFraction: Double = 0.99

    /// The per-stage time constant that makes two cascaded one-poles reach
    /// `settledFraction` of a step at `integrationSeconds`.
    ///
    /// The step response of two identical cascaded one-poles is
    /// `y(t) = 1 − (1 + t/τ)e^(−t/τ)`. Solving `y(integrationSeconds) =
    /// settledFraction` for `τ` has no closed form in elementary terms, so it
    /// is root-found once, here, rather than hand-typed as a decimal nobody
    /// could re-derive.
    public static let timeConstant: Double = {
        integrationSeconds / criticalDampingSteps(reaching: settledFraction)
    }()

    /// Solve `(1 + x)e^(−x) = 1 − fraction` for `x` by bisection.
    ///
    /// `(1+x)e^(-x)` is strictly decreasing for `x > 0`, from 1 at `x = 0`
    /// toward 0, so bisection on a bracket that spans the root converges
    /// unconditionally — no derivative, no starting-guess sensitivity.
    private static func criticalDampingSteps(reaching fraction: Double) -> Double {
        let target = 1 - fraction
        var low = 0.0
        var high = 50.0
        for _ in 0..<64 {
            let mid = (low + high) / 2
            let value = (1 + mid) * exp(-mid)
            if value > target {
                low = mid
            } else {
                high = mid
            }
        }
        return (low + high) / 2
    }

    /// Converts a rectified mean magnitude to the equivalent full-scale-sine
    /// reading. `mean(|sin|)` over a cycle is `2/π`, so multiplying by its
    /// reciprocal makes a full-scale sine read 0 dB — the same "0 dBFS is
    /// where a full-scale sine sits" convention `SpectrumAnalyzer` and
    /// `PeakMeter` already use.
    public static let sineCalibration: Double = .pi / 2

    private var stage1: Double = 0
    private var stage2: Double = 0

    public init() {}

    /// Fold in a freshly drained mean magnitude.
    ///
    /// - Parameters:
    ///   - linearAverage: the mean absolute sample value since the last
    ///     drain — `TapRenderContext.drainVU()`'s output, uncalibrated.
    ///   - elapsed: seconds since the last update. Passed in, as it is for
    ///     `PeakMeter`, so the filter is correct however irregularly it is
    ///     actually polled.
    public mutating func update(linearAverage: Float, elapsed: Double) {
        guard elapsed > 0 else { return }
        let input = max(0, Double(linearAverage)) * Self.sineCalibration
        let alpha = 1 - exp(-elapsed / Self.timeConstant)
        stage1 += (input - stage1) * alpha
        stage2 += (stage1 - stage2) * alpha
    }

    /// Drop back to silence — on stop, so the needle does not sit deflected
    /// showing a level for audio that ended.
    public mutating func reset() {
        self = VUMeter()
    }

    /// The settled (second-stage) reading, in VU — dB relative to
    /// `alignmentLevelDecibels`, not to digital full scale — or `-.infinity`
    /// at or below the scale's own floor.
    ///
    /// The filter only approaches zero asymptotically, so without a floor
    /// this would read a technically-true but absurd finite number for a
    /// long time after the signal stops — `PeakMeter.silenced()` documents
    /// the exact same trap for the exact same reason: a bar's *position*
    /// clamps at zero and hides it, but a numeric readout does not, and
    /// counts on down through −200, −400, −800 as the filter keeps
    /// asymptoting. Below `floorDecibels` is off the printed scale anyway, so
    /// there is nothing meaningful left to report.
    public var decibels: Double {
        guard stage2 > 0 else { return -.infinity }
        let value = 20 * log10(stage2) - Self.alignmentLevelDecibels
        return value >= Self.floorDecibels ? value : -.infinity
    }

    /// The five points `NeedleMeter.vuMarks` prints its labels at. They do
    /// not fall on any single linear-dB or linear-amplitude formula — they
    /// were hand-placed to look like a real face — so the needle is aligned
    /// to them by reproducing the same table here rather than by computing
    /// it. Duplicated rather than shared, because `DesignSystem` is not
    /// allowed to know what a decibel is; the same boundary `PeakMeter` and
    /// `SpectrumBallistics` already respect for their own floors.
    private static let scalePoints: [(decibels: Double, position: Double)] = [
        (floorDecibels, 0.00),
        (-10, 0.26),
        (-5, 0.50),
        (referenceDecibels, 0.75),
        (ceilingDecibels, 1.00)
    ]

    /// Where the needle points, 0…1 across the scale.
    public static func position(forDecibels decibels: Double) -> Double {
        guard decibels > -.infinity else { return 0 }
        guard decibels > scalePoints.first!.decibels else { return 0 }
        guard decibels < scalePoints.last!.decibels else { return 1 }

        for index in 1..<scalePoints.count {
            let upper = scalePoints[index]
            guard decibels <= upper.decibels else { continue }
            let lower = scalePoints[index - 1]
            let span = upper.decibels - lower.decibels
            let fraction = span > 0 ? (decibels - lower.decibels) / span : 0
            return lower.position + fraction * (upper.position - lower.position)
        }
        return 1
    }

    public var position: Double { Self.position(forDecibels: decibels) }
}
