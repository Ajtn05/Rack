import Darwin

@testable import AudioCore

/// The analyzer is the one part of Rack whose output nobody can check by ear.
/// A spectrum that is wrong by a constant, or shifted by a band, or reading a
/// torn window, looks exactly like a spectrum — so every claim it makes is
/// asserted here against a signal whose content is known exactly.
func runSpectrumTests() {
    let sampleRate = 48_000.0

    // MARK: - The ring

    Check.suite("SpectrumRing — history") {
        let ring = SpectrumRing(capacity: 1024)
        Check.equal(ring.capacity, 1024, "a power of two is kept as it is")

        let window = 256
        let destination = UnsafeMutablePointer<Float>.allocate(capacity: window)
        defer { destination.deallocate() }

        // Nothing written yet: there is no window to take.
        Check.isTrue(
            ring.snapshot(into: destination, count: window) == false,
            "an empty ring has no snapshot to give"
        )

        // Write a ramp, so every sample identifies its own position.
        var source = [Float](repeating: 0, count: 700)
        for index in source.indices { source[index] = Float(index) }
        source.withUnsafeBufferPointer { buffer in
            rackSpectrumPush(
                ring: ring.header,
                samples: buffer.baseAddress!,
                frameCount: source.count,
                channels: 1
            )
        }

        Check.equal(ring.written, 700, "the cursor counts what went in")
        Check.isTrue(
            ring.snapshot(into: destination, count: window),
            "a filled ring gives a snapshot"
        )

        // The *most recent* window, oldest first — 444…699.
        var correct = true
        for offset in 0..<window where destination[offset] != Float(700 - window + offset) {
            correct = false
        }
        Check.isTrue(correct, "the snapshot is the newest samples, in order")
    }

    Check.suite("SpectrumRing — wrapping") {
        // Past the end of the buffer and round, which is where an off-by-one
        // in the mask shows up.
        let ring = SpectrumRing(capacity: 1024)
        let window = 512
        let destination = UnsafeMutablePointer<Float>.allocate(capacity: window)
        defer { destination.deallocate() }

        var source = [Float](repeating: 0, count: 3000)
        for index in source.indices { source[index] = Float(index) }
        source.withUnsafeBufferPointer { buffer in
            rackSpectrumPush(
                ring: ring.header, samples: buffer.baseAddress!,
                frameCount: source.count, channels: 1
            )
        }

        Check.isTrue(ring.snapshot(into: destination, count: window), "still readable")
        var correct = true
        for offset in 0..<window where destination[offset] != Float(3000 - window + offset) {
            correct = false
        }
        Check.isTrue(correct, "wrapping past the end preserves order and value")

        // Asking for more than the ring can hold is not a request it can honour.
        let oversized = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
        defer { oversized.deallocate() }
        Check.isTrue(
            ring.snapshot(into: oversized, count: 2048) == false,
            "a window larger than the ring is refused rather than half-filled"
        )
    }

    Check.suite("SpectrumRing — stereo is summed to mono") {
        let ring = SpectrumRing(capacity: 1024)
        // Interleaved L,R: left is 1, right is 3, so the mean is 2.
        let source: [Float] = [1, 3, 1, 3, 1, 3, 1, 3]
        source.withUnsafeBufferPointer { buffer in
            rackSpectrumPush(
                ring: ring.header, samples: buffer.baseAddress!,
                frameCount: 4, channels: 2
            )
        }
        Check.equal(ring.written, 4, "four frames from eight interleaved samples")

        let destination = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        defer { destination.deallocate() }
        Check.isTrue(ring.snapshot(into: destination, count: 4), "readable")
        Check.close(Double(destination[0]), 2, tolerance: 0.0001, "the channels are averaged")
        Check.close(Double(destination[3]), 2, tolerance: 0.0001, "for every frame")
    }

    Check.suite("SpectrumRing — disabled by default") {
        // The IOProc's cost when the display is off is one flag test. The flag
        // starts down, so a session that never shows a spectrum never captures.
        let ring = SpectrumRing(capacity: 1024)
        Check.isTrue(ring.isEnabled == false, "capture starts switched off")
        ring.isEnabled = true
        Check.isTrue(ring.isEnabled, "and can be switched on")
    }

    // MARK: - The band layout

    Check.suite("SpectrumAnalyzer — band layout") {
        let centres = SpectrumAnalyzer.bandFrequencies
        Check.equal(centres.count, 31, "thirty-one bands")
        Check.close(centres[0], 20, tolerance: 0.001, "starting at 20 Hz")
        Check.close(centres[30], 20_000, tolerance: 0.01, "and ending at 20 kHz")

        // A third of an octave is a ratio of 2^(1/3) ≈ 1.2599; three decades
        // over thirty steps is 10^0.1 ≈ 1.2589. Close enough to be the same
        // layout, which is what makes these the standard analyzer bands.
        Check.close(
            SpectrumAnalyzer.bandRatio, pow(2, 1.0 / 3), tolerance: 0.002,
            "the spacing is a third of an octave"
        )

        // Edges tile: each band's top is the next band's bottom, with no gap
        // and no overlap. A gap loses energy; an overlap counts it twice.
        var tiles = true
        for band in 0..<30 {
            let here = SpectrumAnalyzer.bandEdges(band)
            let next = SpectrumAnalyzer.bandEdges(band + 1)
            if abs(here.high - next.low) > here.high * 0.0001 { tiles = false }
        }
        Check.isTrue(tiles, "the bands tile the axis without gaps or overlap")

        // Where the analyzer and the equalizer's own faders coincide they must
        // agree, or the display cannot be read against the sliders under it.
        for fader in [500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16_000.0] {
            var nearest = 0
            for band in centres.indices
            where abs(log(centres[band] / fader)) < abs(log(centres[nearest] / fader)) {
                nearest = band
            }
            let (low, high) = SpectrumAnalyzer.bandEdges(nearest)
            Check.isTrue(
                fader >= low && fader <= high,
                "the \(Int(fader)) Hz fader falls inside band \(nearest)"
            )
        }
    }

    // MARK: - The transform

    /// A windowed transform of a pure tone, as the engine would run it.
    func analyse(
        _ build: (Int) -> Float,
        size: Int = SpectrumAnalyzer.defaultSize
    ) -> [Float] {
        guard let analyzer = SpectrumAnalyzer(size: size) else { return [] }
        var samples = [Float](repeating: 0, count: size)
        for index in samples.indices { samples[index] = build(index) }
        return samples.withUnsafeBufferPointer { buffer in
            analyzer.analyse(buffer.baseAddress!, sampleRate: sampleRate)
        }
    }

    /// Index of the loudest band.
    func loudest(_ levels: [Float]) -> Int {
        var best = 0
        for index in levels.indices where levels[index] > levels[best] { best = index }
        return best
    }

    /// The band a frequency belongs to.
    func band(containing frequency: Double) -> Int {
        let centres = SpectrumAnalyzer.bandFrequencies
        var nearest = 0
        for index in centres.indices
        where abs(log(centres[index] / frequency)) < abs(log(centres[nearest] / frequency)) {
            nearest = index
        }
        return nearest
    }

    Check.suite("SpectrumAnalyzer — a tone lands in its own band") {
        // Well clear of the bottom, where third-octave bands are narrower than
        // one bin and neighbours genuinely cannot be told apart.
        for frequency in [125.0, 400.0, 1000.0, 3150.0, 10_000.0] {
            let levels = analyse { index in
                sin(2 * .pi * frequency * Double(index) / sampleRate).asFloat
            }
            Check.equal(
                loudest(levels), band(containing: frequency),
                "a \(Int(frequency)) Hz tone is loudest in its own band"
            )
        }
    }

    Check.suite("SpectrumAnalyzer — a full-scale tone reads 0 dBFS") {
        // The claim the whole scale rests on. Placed exactly on a bin centre so
        // the assertion is about the normalisation and not about scalloping.
        let size = SpectrumAnalyzer.defaultSize
        let binWidth = sampleRate / Double(size)
        let frequency = binWidth * 86  // ≈ 1008 Hz

        let levels = analyse { index in
            sin(2 * .pi * frequency * Double(index) / sampleRate).asFloat
        }
        let target = band(containing: frequency)
        Check.close(
            Double(levels[target]), 0, tolerance: 0.3,
            "a full-scale sine reads 0 dB in its band"
        )

        // Half amplitude is 6 dB down, which is the property that makes the
        // display a measurement rather than a decoration.
        let halved = analyse { index in
            (0.5 * sin(2 * .pi * frequency * Double(index) / sampleRate)).asFloat
        }
        Check.close(
            Double(halved[target]), -6.02, tolerance: 0.3,
            "half amplitude is 6 dB down"
        )

        // And the rest of the spectrum stays out of the way. Hann's sidelobes
        // are what keep a single tone from painting the whole display.
        var worstElsewhere = -Double.infinity
        for index in levels.indices where abs(index - target) > 2 {
            worstElsewhere = max(worstElsewhere, Double(levels[index]))
        }
        Check.isTrue(
            worstElsewhere < -55,
            "bands away from the tone stay far below it — got \(worstElsewhere)"
        )
    }

    Check.suite("SpectrumAnalyzer — silence") {
        let levels = analyse { _ in 0 }
        Check.equal(levels.count, 31, "still one level per band")
        var allSilent = true
        for level in levels where level > -.infinity { allSilent = false }
        Check.isTrue(allSilent, "silence reads as silence in every band")
    }

    Check.suite("SpectrumAnalyzer — refuses a size it cannot transform") {
        Check.isTrue(SpectrumAnalyzer(size: 1000) == nil, "a non-power-of-two is refused")
        Check.isTrue(SpectrumAnalyzer(size: 16) == nil, "an absurdly short window is refused")
        Check.isTrue(SpectrumAnalyzer(size: 1024) != nil, "a valid size is accepted")
    }

    Check.suite("SpectrumAnalyzer — bins to bands, without an FFT") {
        // The fold on its own, against a hand-built power array: all the energy
        // in one bin, and nothing anywhere else.
        let size = 4096
        let binCount = size / 2
        let binWidth = sampleRate / Double(size)

        let power = UnsafeMutablePointer<Float>.allocate(capacity: binCount)
        defer { power.deallocate() }
        power.initialize(repeating: 0, count: binCount)

        let bin = 86
        // The level that makes a single bin read 0 dB, from the same
        // normalisation the analyzer uses.
        power[bin] = Float(3 * Double(size) * Double(size) / 8)

        let levels = SpectrumAnalyzer.fold(
            power: power, binCount: binCount, size: size, sampleRate: sampleRate
        )
        let target = band(containing: Double(bin) * binWidth)
        Check.close(
            Double(levels[target]), 0, tolerance: 0.001,
            "one bin at full scale gives its band 0 dB"
        )

        var elsewhereSilent = true
        for index in levels.indices where index != target && levels[index] > -.infinity {
            elsewhereSilent = false
        }
        Check.isTrue(elsewhereSilent, "and leaves every other band empty")

        // Bin zero is DC — an offset, not a pitch — and must never reach a band.
        power.update(repeating: 0, count: binCount)
        power[0] = 1e12
        let withOffset = SpectrumAnalyzer.fold(
            power: power, binCount: binCount, size: size, sampleRate: sampleRate
        )
        var dcIgnored = true
        for level in withOffset where level > -.infinity { dcIgnored = false }
        Check.isTrue(dcIgnored, "a DC offset does not light up the bottom band")
    }

    Check.suite("SpectrumAnalyzer — the bottom bands are bin-limited, not empty") {
        // Below about 60 Hz a third-octave band is narrower than one bin at
        // this window length, so no bin centre falls inside it. It must borrow
        // its nearest neighbour rather than read as silence — a display whose
        // bottom three bars never move looks broken and would be.
        let levels = analyse { index in
            sin(2 * .pi * 25 * Double(index) / sampleRate).asFloat
        }
        var bottomAlive = false
        for index in 0..<4 where levels[index] > -40 { bottomAlive = true }
        Check.isTrue(bottomAlive, "a 25 Hz tone moves the bottom of the display")
    }
}

extension Double {
    /// Spelled out because the tone generators above are computed in `Double`
    /// and the analyzer takes `Float`.
    fileprivate var asFloat: Float { Float(self) }
}
