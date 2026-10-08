import AudioCore
import DesignSystem
import Foundation

/// What a screen needs in order to draw the response curve.
///
/// The same arrangement as `EQBandInfo`, and for the same reason. The maths is
/// an audio fact and lives in `AudioCore`; the drawing is a `DesignSystem`
/// component that takes plain numbers and knows nothing about filters. This
/// file is the only place the two meet, and all it does is translate — the
/// logarithmic axis is applied here, so what crosses the boundary is positions
/// and values rather than frequencies and decibels.
extension EngineController {
    /// How many points the curve is drawn from.
    ///
    /// 120 across three decades is finer than a pixel at any width this display
    /// is given, and cheap enough to recompute whenever a control moves.
    /// More would be invisible; noticeably fewer shows as facets on the steep
    /// side of a boosted band.
    static let responsePointCount = 120

    /// The curve's own axis, and the horizontal position of each of its
    /// points, built once.
    ///
    /// Neither depends on anything that changes — the axis is three constants
    /// and a count, and `axisPosition` is a pure function of a frequency — but
    /// `refreshResponseCurve` runs on every frame of a slider drag, and it was
    /// rebuilding both each time: 120 `pow` calls for the axis and 120 more
    /// `log10` pairs for the positions, to arrive at the same two arrays.
    private static let curveFrequencies: [Double] = FrequencyResponse.logSpacedFrequencies(
        count: responsePointCount
    )
    private static let curvePositions: [Double] = curveFrequencies.map {
        FrequencyResponse.axisPosition(of: $0)
    }

    /// The vertical extent of the plot.
    ///
    /// ±15 rather than the ±12 a single fader travels: the boost contour
    /// reaches 15 dB of volume-driven attenuation on its own, and a plot that
    /// clips the loudest thing the engine does would be lying about exactly
    /// the case worth looking at.
    public var responseRange: ClosedRange<Double> { -15...15 }

    /// Recompute the cached curve and the cached headroom-compensation
    /// figure. Called wherever the parameters or the sample rate change, and
    /// nowhere else.
    func refreshResponseCurve() {
        let response = FrequencyResponse(
            parameters: parameters,
            sampleRate: readout.sampleRate
        )
        let magnitudes = response.magnitudeResponse(at: Self.curveFrequencies)

        responseCurve = zip(Self.curvePositions, magnitudes).map { position, decibels in
            ResponseCurve.Point(position: position, value: decibels)
        }

        // Asked of the response already built rather than of the parameters,
        // which would construct a second, identical one and sweep it again.
        // The two sweeps were the same 120-point, fourteen-section pass over
        // the same filters, and this runs on every frame of a slider drag.
        headroomCompensationDecibels = response.headroomCompensationDecibels(
            isEnabled: parameters.isHeadroomCompensationEnabled
        )
    }

    /// Decade markers, plus the unlabelled thirds between them.
    ///
    /// Labelling every gridline on a plot this small turns the bottom edge into
    /// a wall of text; labelling none makes the curve unreadable. The decades
    /// are named and the rest are there to be counted against.
    public var responseGridlines: [ResponseCurve.Gridline] {
        let labelled: [(Double, String)] = [(100, "100"), (1000, "1k"), (10_000, "10k")]
        let plain: [Double] = [50, 200, 500, 2000, 5000]

        return labelled.map { frequency, label in
            ResponseCurve.Gridline(
                position: FrequencyResponse.axisPosition(of: frequency),
                label: label
            )
        } + plain.map { frequency in
            ResponseCurve.Gridline(
                position: FrequencyResponse.axisPosition(of: frequency)
            )
        }
    }

    /// The datum and one marker either side of it.
    public var responseRules: [ResponseCurve.Rule] {
        [
            ResponseCurve.Rule(value: 10, label: "+10"),
            ResponseCurve.Rule(value: 0, label: "0", isEmphasised: true),
            ResponseCurve.Rule(value: -10, label: "−10")
        ]
    }
}
