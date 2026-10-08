import AudioCore
import DesignSystem
import Foundation

/// What the equalizer's display is showing.
///
/// Three states rather than a switch, because the third one is not "hide the
/// picture" — it is "stop computing the picture". An analyzer is the only part
/// of Rack that costs measurable CPU while doing nothing a listener can hear,
/// so being able to turn it off is a feature and not a preference.
public enum AnalyzerMode: String, CaseIterable, Sendable, Codable {
    /// Live band levels from the audio actually playing.
    case spectrum

    /// A backlit VU meter: two needles, real ballistics (300 ms integration
    /// to 99%, symmetric release), the classic −20…+3 scale. Reads the mean
    /// rectified magnitude of the signal, not its peak — a different quantity
    /// from the always-on L/R bar underneath the display, and the reason this
    /// tends to sit lower for ordinary program material than that bar does.
    case vu

    /// The equalizer's own frequency response — the same curve the amplifier
    /// draws, on the same axis, so switching between the two compares like
    /// with like.
    case response

    /// Both, layered: the live spectrum underneath, the EQ's own curve traced
    /// over it. The two do not share a vertical scale — one is absolute level,
    /// the other is relative gain — so the curve is a shape overlaid on the
    /// bars rather than a second axis; that is enough to see whether a boost
    /// is landing where the music actually has energy to boost.
    case overlay

    /// A beat/onset gauge: a needle that snaps toward a hit whenever the
    /// bass region jumps above its own recent average, then decays back
    /// down — reads the same bands `.spectrum` does, just reduced to one
    /// number instead of drawn as bars. See `BeatMeter`.
    case pulse

    /// A goniometer: raw L/R sample pairs, rotated 45° so a mono signal
    /// traces a vertical line and a fully out-of-phase one traces a
    /// horizontal one — the stereo image's actual shape, rather than the
    /// single number the phase correlation meter reduces it to.
    case goniometer

    /// A time-domain waveform: amplitude against time, drawn from the same
    /// raw stereo ring the goniometer reads. Left and right are summed to
    /// one trace — the same "one channel is a spectrum" call
    /// `rackCaptureSpectrum` already makes, here as "one trace is a
    /// waveform"; shape, not the stereo image, is this mode's whole point,
    /// and the goniometer already exists for the image.
    case oscilloscope

    /// Nothing drawn, and nothing computed: no capture in the IOProc, no
    /// transform on the analysis thread.
    case off

    public var displayName: String {
        switch self {
        case .spectrum: "SPECTRUM"
        case .vu: "VU"
        case .response: "RESPONSE"
        case .overlay: "MIX"
        case .pulse: "PULSE"
        case .goniometer: "SCOPE"
        case .oscilloscope: "WAVE"
        case .off: "OFF"
        }
    }

    /// Whether this mode needs a live spectrum — `.spectrum` on its own and
    /// `.overlay`, which draws one underneath the curve. Every other mode
    /// needs no samples from the analysis thread at all: the VU ballistic
    /// reads the peak/VU accumulators the audio thread already maintains
    /// regardless of mode, the same ones the always-on L/R bar reads, so
    /// selecting VU turns the FFT off exactly as Response does — and the
    /// goniometer and oscilloscope both read the raw stereo ring instead,
    /// not the spectrum's.
    public var needsSpectrumCapture: Bool {
        switch self {
        case .spectrum, .overlay, .pulse: true
        case .vu, .response, .goniometer, .oscilloscope, .off: false
        }
    }

    /// Whether this mode needs the raw stereo ring — the goniometer, for its
    /// rotated scatter, and the oscilloscope, for its waveform trace over
    /// the same captured pairs. Same "off means off" reasoning as
    /// `needsSpectrumCapture`: the IOProc does not copy samples nobody is
    /// going to look at.
    public var needsGoniometerCapture: Bool {
        self == .goniometer || self == .oscilloscope
    }
}

/// Ballistics for the analyzer, in the same spirit as `PeakMeter`.
///
/// The transform reports what the last window contained and nothing more; it
/// has no memory and no opinion about how a display should move. Deciding that
/// a bar falls quickly and its peak marker falls slowly is presentation, which
/// is why it is here and not in `AudioCore`.
public struct SpectrumBallistics: Equatable, Sendable {
    /// The bottom of the display. Third-octave bands of ordinary music sit
    /// between about −55 and −25 dBFS, so a floor much lower than this wastes
    /// most of the height on silence.
    public static let floorDecibels: Double = -72

    /// Bars fall faster than the amplifier's meters do. A spectrum that decays
    /// slowly turns every transient into a smear and stops looking like the
    /// music it is drawn from.
    public static let decayPerSecond: Double = 60

    /// How long a peak marker sits before it starts falling.
    public static let holdDuration: Double = 1.0

    /// And how slowly it falls once it does — slow enough to read, which is
    /// the entire reason the marker exists.
    public static let holdDecayPerSecond: Double = 10

    public private(set) var levels: [Double] = []
    public private(set) var holds: [Double] = []
    private var holdRemaining: [Double] = []

    public init() {}

    /// Fold in a freshly published frame.
    public mutating func update(bandsDecibels: [Float], elapsed: Double) {
        guard !bandsDecibels.isEmpty else {
            reset()
            return
        }

        if levels.count != bandsDecibels.count {
            levels = Array(repeating: 0, count: bandsDecibels.count)
            holds = Array(repeating: 0, count: bandsDecibels.count)
            holdRemaining = Array(repeating: 0, count: bandsDecibels.count)
        }

        for index in bandsDecibels.indices {
            let incoming = Self.position(forDecibels: Double(bandsDecibels[index]))

            // Instant attack, timed decay — the same asymmetry a peak meter
            // has, and for the same reason.
            levels[index] =
                incoming >= levels[index]
                ? incoming
                : max(incoming, levels[index] - Self.decayPerSecond / -Self.floorDecibels * elapsed)

            if levels[index] >= holds[index] {
                holds[index] = levels[index]
                holdRemaining[index] = Self.holdDuration
            } else if holdRemaining[index] > 0 {
                holdRemaining[index] -= elapsed
            } else {
                holds[index] = max(
                    levels[index],
                    holds[index] - Self.holdDecayPerSecond / -Self.floorDecibels * elapsed
                )
            }
        }
    }

    /// Everything to the bottom. Used when the engine stops, so the display
    /// does not sit frozen showing a spectrum of audio that ended.
    public mutating func reset() {
        levels = []
        holds = []
        holdRemaining = []
    }

    /// Where a band level sits on the display, 0…1.
    public static func position(forDecibels decibels: Double) -> Double {
        guard decibels > -.infinity else { return 0 }
        return min(1, max(0, (decibels - floorDecibels) / -floorDecibels))
    }
}

// MARK: - What a screen needs

extension EngineController {
    /// The bars, ready to draw.
    public var spectrumBands: [SpectrumBars.Band] {
        let levels = spectrumBallistics.levels
        guard !levels.isEmpty else { return [] }

        return levels.indices.map { index in
            SpectrumBars.Band(
                level: levels[index],
                hold: index < spectrumBallistics.holds.count
                    ? spectrumBallistics.holds[index] : 0,
                label: Self.spectrumLabels[index]
            )
        }
    }

    /// Legends for a handful of landmark bands. The decades, plus the ends of
    /// the range so the axis is readable without counting from the middle.
    static let spectrumLabels: [Int: String] = [
        0: "20", 5: "63", 10: "200", 15: "630", 20: "2k", 25: "6.3k", 30: "20k"
    ]

    /// Pulse mode's needle position, ready to draw.
    public var beatPulsePosition: Double { beatMeter.position }

    /// The goniometer's dots, ready to draw.
    public var goniometerPoints: [Goniometer.Point] {
        goniometerSamples.map(Self.goniometerPoint)
    }

    /// Rotates one raw stereo pair 45° into the classic mid/side layout:
    /// `x` is the stereo difference (side), `y` is the stereo sum (mid),
    /// scaled by the energy-preserving `1/√2` every hardware goniometer
    /// since the Lissajous tube has used. That scale is calibrated to a
    /// *single* full-scale channel panned hard — `(left: 1, right: 0)` lands
    /// exactly on the edge of the unit circle `Goniometer` draws — not to
    /// mono. Genuinely correlated mono content is louder in the combined
    /// signal than either channel alone and can deflect past the edge
    /// (`left == right == 1` lands at `y = √2`); `Goniometer` clips the dot
    /// there rather than distorting the shape to avoid it, the same way a
    /// peak meter's bar clips at its own scale's top rather than pretending
    /// 0 dBFS is the loudest a signal can ever be. A static function rather
    /// than inline map logic so the rotation itself — easy to get a sign or
    /// a scale wrong in — is directly testable without standing up an
    /// `EngineController`.
    public nonisolated static func goniometerPoint(for sample: GoniometerSample) -> Goniometer.Point {
        let left = Double(sample.left)
        let right = Double(sample.right)
        return Goniometer.Point(
            x: (right - left) * goniometerRotation,
            y: (left + right) * goniometerRotation
        )
    }

    private nonisolated static let goniometerRotation: Double = 1 / sqrt(2.0)

    /// The oscilloscope's trace, ready to draw — left and right summed to
    /// one waveform, spread evenly across the captured window. Reuses
    /// `ResponseCurve` as-is: a waveform is exactly what that component
    /// already draws, position against value, and needs no component of
    /// its own.
    public var oscilloscopePoints: [ResponseCurve.Point] {
        Self.oscilloscopePoints(for: goniometerSamples)
    }

    /// Spreads a captured window evenly across `[0, 1]`. A static function
    /// taking the samples directly, the same reason `goniometerPoint(for:)`
    /// and `oscilloscopeValue(for:)` are static — directly testable without
    /// standing up an `EngineController`.
    ///
    /// Fewer than two samples has no window to spread across — a single
    /// point cannot be divided into a span — so it is refused rather than
    /// dividing by zero.
    public nonisolated static func oscilloscopePoints(
        for samples: [GoniometerSample]
    ) -> [ResponseCurve.Point] {
        guard samples.count > 1 else { return [] }
        let last = Double(samples.count - 1)
        return samples.enumerated().map { index, sample in
            ResponseCurve.Point(
                position: Double(index) / last,
                value: oscilloscopeValue(for: sample)
            )
        }
    }

    /// One sample's trace value: left and right summed and halved — the
    /// same "one channel is enough" call `rackCaptureSpectrum` already makes
    /// for its own single trace, here keeping both channels' energy rather
    /// than picking one arbitrarily. A static function for the same
    /// testability reason `goniometerPoint(for:)` is one.
    public nonisolated static func oscilloscopeValue(for sample: GoniometerSample) -> Double {
        (Double(sample.left) + Double(sample.right)) * 0.5
    }

    /// True when the display is showing something that is not currently being
    /// fed — the engine is off, or the chain is bypassed.
    public var isAnalyzerDimmed: Bool { !status.isRunning || self.isBypassed }

    /// The mode toggle's chips.
    public var analyzerModeItems: [SelectorRow.Item] {
        AnalyzerMode.allCases.map {
            SelectorRow.Item(id: $0.rawValue, label: $0.displayName)
        }
    }

    public func selectAnalyzerMode(id: String) {
        guard let mode = AnalyzerMode(rawValue: id) else { return }
        analyzerMode = mode
    }
}
