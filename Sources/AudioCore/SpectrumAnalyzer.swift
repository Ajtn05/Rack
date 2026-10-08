import Accelerate
import Darwin

/// Turns a window of samples into 31 band levels in dBFS.
///
/// Third-octave bands from 20 Hz to 20 kHz — the standard graphic-analyzer
/// layout, and the one that lines up with the equalizer's own faders wherever
/// the two coincide (500 Hz, 1 kHz, 2 kHz, 4 kHz, 8 kHz, 16 kHz land on fader
/// centres; the octave faders are every third band).
///
/// A class rather than a struct because the vDSP setup and its scratch buffers
/// are allocations that must be made once and reused. It is owned by the
/// analysis thread and touched by nothing else — no locking, and no need for
/// any, provided that stays true.
///
/// Never call this from the IOProc. It is not realtime and is not intended to
/// be: that is the entire reason the ring buffer exists.
final class SpectrumAnalyzer {
    /// Samples per transform.
    ///
    /// 4096 is 85 ms at 48 kHz. The trade is resolution against liveliness: a
    /// longer window resolves the bottom bands properly and makes the display
    /// feel like a recording of the music rather than the music, and a shorter
    /// one is responsive and cannot tell 20 Hz from 30 Hz at all. 85 ms is the
    /// usual compromise and is what hardware analyzers of this kind used.
    static let defaultSize = 4096

    /// Third-octave centres, 20 Hz to 20 kHz.
    static let bandCount = 31

    /// The band centres. Geometric, so they are evenly spaced on the log axis
    /// the display draws — the same series `FrequencyResponse` uses for its
    /// curve, which is why the two line up when the mode toggle switches
    /// between them.
    static let bandFrequencies: [Double] = FrequencyResponse.logSpacedFrequencies(
        count: bandCount
    )

    let size: Int

    private let log2n: vDSP_Length
    private let setup: FFTSetup

    // Owned buffers rather than Swift arrays passed inout. `DSPSplitComplex`
    // wants two pointers held simultaneously, and building one from `&array`
    // is an overlapping-access trap the moment anything else touches them.
    private let window: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let realPart: UnsafeMutablePointer<Float>
    private let imaginaryPart: UnsafeMutablePointer<Float>
    private let power: UnsafeMutablePointer<Float>

    private var half: Int { size / 2 }

    init?(size: Int = SpectrumAnalyzer.defaultSize) {
        guard size >= 64, size.nonzeroBitCount == 1 else { return nil }
        let log2n = vDSP_Length(log2(Double(size)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }

        self.size = size
        self.log2n = log2n
        self.setup = setup

        window = .allocate(capacity: size)
        windowed = .allocate(capacity: size)
        realPart = .allocate(capacity: size / 2)
        imaginaryPart = .allocate(capacity: size / 2)
        power = .allocate(capacity: size / 2)

        window.initialize(repeating: 0, count: size)
        windowed.initialize(repeating: 0, count: size)
        realPart.initialize(repeating: 0, count: size / 2)
        imaginaryPart.initialize(repeating: 0, count: size / 2)
        power.initialize(repeating: 0, count: size / 2)

        // Hann. A rectangular window smears a steady tone across the whole
        // display through spectral leakage, which reads as a noise floor that
        // is not there.
        vDSP_hann_window(window, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        window.deallocate()
        windowed.deallocate()
        realPart.deallocate()
        imaginaryPart.deallocate()
        power.deallocate()
    }

    /// Window, transform, and fold into bands.
    ///
    /// - Parameter samples: exactly `size` samples, oldest first.
    /// - Returns: one level per band in dBFS, where 0 dB is a full-scale sine
    ///   sitting in that band. `-.infinity` for a band with no energy at all.
    func analyse(
        _ samples: UnsafePointer<Float>,
        sampleRate: Double
    ) -> [Float] {
        vDSP_vmul(samples, 1, window, 1, windowed, 1, vDSP_Length(size))

        // Real-to-complex: the real input is reinterpreted as interleaved
        // complex pairs and split into the two halves vDSP works on.
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: half) { interleaved in
            var split = DSPSplitComplex(realp: realPart, imagp: imaginaryPart)
            vDSP_ctoz(interleaved, 2, &split, 1, vDSP_Length(half))
        }

        var split = DSPSplitComplex(realp: realPart, imagp: imaginaryPart)
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

        // `zrip` packs the Nyquist bin's real value into imagp[0], where bin
        // zero's imaginary part would be. Left alone it makes DC carry the
        // energy of the top of the spectrum. Neither bin is displayed, but the
        // fold below reads bin 0 as a neighbour of band 0.
        imaginaryPart[0] = 0

        vDSP_zvmags(&split, 1, power, 1, vDSP_Length(half))

        return Self.fold(
            power: power,
            binCount: half,
            size: size,
            sampleRate: sampleRate
        )
    }

    // MARK: - Bins to bands

    /// Sum the bins belonging to each band and convert to dBFS.
    ///
    /// Separated from the transform, and given only plain numbers, so the
    /// mapping can be tested without an FFT anywhere near it — the arithmetic
    /// below is where an analyzer is usually wrong, and it is silently wrong.
    static func fold(
        power: UnsafePointer<Float>,
        binCount: Int,
        size: Int,
        sampleRate: Double
    ) -> [Float] {
        guard binCount > 0, size > 0, sampleRate > 0 else {
            return Array(repeating: -.infinity, count: bandCount)
        }

        let binWidth = sampleRate / Double(size)

        // Turns a *sum* of bin powers into the squared amplitude of a sine
        // spread across them, so a full-scale sine reads 0 dB.
        //
        // The window normalisation here is its **power** gain, 3/8 for Hann,
        // not its coherent gain of 1/2. Which one is correct depends entirely
        // on what is being done with the bins: coherent gain normalises a
        // single peak bin, power gain normalises energy summed over several.
        // A band sums, so it is the second — and using the first overstates
        // every band by 1.76 dB, uniformly and therefore invisibly, because a
        // spectrum that is 1.76 dB too tall everywhere still looks like a
        // spectrum.
        //
        // The factor of four from `vDSP_fft_zrip` returning twice the true
        // transform cancels against the two-sided-to-one-sided halving, and
        // what is left is 1 / (N² · 3/8).
        let scale = 8 / (3 * Double(size) * Double(size))

        var levels: [Float] = []
        levels.reserveCapacity(bandCount)

        for band in 0..<bandCount {
            let (low, high) = bandEdges(band)
            var first = Int((low / binWidth).rounded(.up))
            var last = Int((high / binWidth).rounded(.down))

            // Below about 60 Hz a third-octave band is narrower than one bin,
            // so no bin centre lands inside it and the band would read as
            // silence. It takes the nearest bin instead, which is what every
            // analyzer of this size does: the bottom two or three bands share
            // bins with their neighbours and cannot truly be told apart.
            if first > last {
                let nearest = Int((sqrt(low * high) / binWidth).rounded())
                first = nearest
                last = nearest
            }

            // Bin zero is DC — an offset, not a pitch — and never belongs to a
            // band. Nyquist is not displayed either.
            first = max(first, 1)
            last = min(last, binCount - 1)

            guard first <= last else {
                levels.append(-.infinity)
                continue
            }

            var total = 0.0
            for bin in first...last {
                total += Double(power[bin])
            }

            let squaredAmplitude = total * scale
            levels.append(
                squaredAmplitude > 0 ? Float(10 * log10(squaredAmplitude)) : -.infinity
            )
        }

        return levels
    }

    /// The lower and upper edge of a band, in hertz.
    ///
    /// Geometric midpoints between neighbouring centres, which is what makes
    /// the bands tile the axis without gaps or overlap.
    static func bandEdges(_ band: Int) -> (low: Double, high: Double) {
        guard bandFrequencies.indices.contains(band) else { return (0, 0) }
        let centre = bandFrequencies[band]
        // Constant ratio, so half a step either way is one square root of it.
        let halfStep = (bandRatio).squareRoot()
        return (centre / halfStep, centre * halfStep)
    }

    /// The ratio between neighbouring centres. Three decades over thirty steps
    /// is 10^0.1, which is a third of an octave to within half a percent.
    static let bandRatio: Double = pow(
        10, 3 / Double(bandCount - 1)
    )
}
