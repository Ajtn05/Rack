import AppCore
import CoreAudio
import Darwin

@testable import AudioCore

/// The goniometer ring is the newest member of a family of realtime
/// handoffs alongside `SpectrumRingBuffer` — a signal wrong by a swapped
/// channel or a torn window looks exactly like a signal, so every claim
/// here is checked against buffers whose content is known exactly, the same
/// discipline `SpectrumTests` applies to its own ring.
func runGoniometerTests() {
    /// Push one interleaved stereo buffer through `rackGoniometerPush`.
    func pushInterleaved(_ samples: [Float], into ring: GoniometerRing) {
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
        defer { storage.deallocate() }
        for index in samples.indices { storage[index] = samples[index] }

        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        list[0] = AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
            mData: storage
        )
        rackGoniometerPush(
            ring: ring.header,
            buffers: UnsafeMutableAudioBufferListPointer(list.unsafeMutablePointer)
        )
    }

    /// Push one buffer pair of deinterleaved mono channels.
    func pushDeinterleaved(left: [Float], right: [Float], into ring: GoniometerRing) {
        let leftStorage = UnsafeMutablePointer<Float>.allocate(capacity: left.count)
        defer { leftStorage.deallocate() }
        let rightStorage = UnsafeMutablePointer<Float>.allocate(capacity: right.count)
        defer { rightStorage.deallocate() }
        for index in left.indices { leftStorage[index] = left[index] }
        for index in right.indices { rightStorage[index] = right[index] }

        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        list[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(left.count * MemoryLayout<Float>.size),
            mData: leftStorage
        )
        list[1] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(right.count * MemoryLayout<Float>.size),
            mData: rightStorage
        )
        rackGoniometerPush(
            ring: ring.header,
            buffers: UnsafeMutableAudioBufferListPointer(list.unsafeMutablePointer)
        )
    }

    Check.suite("GoniometerRing — history") {
        let ring = GoniometerRing(capacity: 1024)
        Check.equal(ring.capacity, 1024, "a power of two is kept as it is")

        let window = 256
        let destination = UnsafeMutablePointer<GoniometerSample>.allocate(capacity: window)
        defer { destination.deallocate() }

        Check.isTrue(
            ring.snapshot(into: destination, count: window) == false,
            "an empty ring has no snapshot to give"
        )

        // Interleaved L,R where every frame identifies its own position and
        // its channel — left counts up, right counts down, so a swap shows.
        var interleaved = [Float](repeating: 0, count: 700 * 2)
        for frame in 0..<700 {
            interleaved[frame * 2] = Float(frame)
            interleaved[frame * 2 + 1] = -Float(frame)
        }
        pushInterleaved(interleaved, into: ring)

        Check.equal(ring.written, 700, "the cursor counts frames, not floats")
        Check.isTrue(ring.snapshot(into: destination, count: window), "a filled ring gives a snapshot")

        // The most recent window, oldest first — frames 444…699.
        var correct = true
        for offset in 0..<window {
            let expectedFrame = Float(700 - window + offset)
            let sample = destination[offset]
            if sample.left != expectedFrame || sample.right != -expectedFrame {
                correct = false
            }
        }
        Check.isTrue(correct, "the snapshot is the newest frames, in order, with channels intact")
    }

    Check.suite("GoniometerRing — wrapping") {
        // Past the end of the buffer and round, which is where an off-by-one
        // in the mask shows up.
        let ring = GoniometerRing(capacity: 1024)
        let window = 512
        let destination = UnsafeMutablePointer<GoniometerSample>.allocate(capacity: window)
        defer { destination.deallocate() }

        var interleaved = [Float](repeating: 0, count: 3000 * 2)
        for frame in 0..<3000 {
            interleaved[frame * 2] = Float(frame)
            interleaved[frame * 2 + 1] = Float(-frame)
        }
        pushInterleaved(interleaved, into: ring)

        Check.isTrue(ring.snapshot(into: destination, count: window), "still readable")
        var correct = true
        for offset in 0..<window {
            let expectedFrame = Float(3000 - window + offset)
            if destination[offset].left != expectedFrame || destination[offset].right != -expectedFrame {
                correct = false
            }
        }
        Check.isTrue(correct, "wrapping past the end preserves order and both channels")

        let oversized = UnsafeMutablePointer<GoniometerSample>.allocate(capacity: 2048)
        defer { oversized.deallocate() }
        Check.isTrue(
            ring.snapshot(into: oversized, count: 2048) == false,
            "a window larger than the ring is refused rather than half-filled"
        )
    }

    Check.suite("GoniometerRing — channels are kept separate, not summed") {
        // Unlike the spectrum ring, which deliberately averages L and R into
        // one mono value, a goniometer's entire purpose is the relationship
        // between the two — so this proves they survive independently.
        let ring = GoniometerRing(capacity: 1024)
        let interleaved: [Float] = [1, 3, 1, 3, 1, 3, 1, 3]
        pushInterleaved(interleaved, into: ring)

        Check.equal(ring.written, 4, "four frames from eight interleaved samples")

        let destination = UnsafeMutablePointer<GoniometerSample>.allocate(capacity: 4)
        defer { destination.deallocate() }
        Check.isTrue(ring.snapshot(into: destination, count: 4), "readable")
        for offset in 0..<4 {
            Check.close(Double(destination[offset].left), 1, tolerance: 0.0001, "left stays 1")
            Check.close(Double(destination[offset].right), 3, tolerance: 0.0001, "right stays 3, not averaged to 2")
        }
    }

    Check.suite("GoniometerRing — deinterleaved buffers pair correctly") {
        // The pairing `rackProcessReverb` and `rackMeasureCorrelation`
        // already establish: even buffers are left, odd are right.
        let ring = GoniometerRing(capacity: 1024)
        let left: [Float] = [10, 20, 30, 40]
        let right: [Float] = [-10, -20, -30, -40]
        pushDeinterleaved(left: left, right: right, into: ring)

        Check.equal(ring.written, 4, "four frames from two four-frame mono buffers")

        let destination = UnsafeMutablePointer<GoniometerSample>.allocate(capacity: 4)
        defer { destination.deallocate() }
        Check.isTrue(ring.snapshot(into: destination, count: 4), "readable")
        var correct = true
        for offset in 0..<4 {
            if destination[offset].left != left[offset] || destination[offset].right != right[offset] {
                correct = false
            }
        }
        Check.isTrue(correct, "left and right land in the sample they came from, not swapped")
    }

    Check.suite("EngineController.goniometerPoint — the mid/side rotation") {
        // Mono: identical channels. The whole point of the rotation is that
        // this lands on the vertical axis, not the diagonal a naive L-vs-R
        // plot would put it on. The rotation is energy-preserving, not
        // amplitude-preserving, so genuinely correlated mono lands *past*
        // the unit circle a single hard-panned channel is calibrated to —
        // at √2, not 1. `Goniometer` clips the dot at the edge; the
        // transform itself does not, and this is the value that proves it.
        let rotation = 1 / sqrt(2.0)
        let mono = EngineController.goniometerPoint(for: GoniometerSample(left: 1, right: 1))
        Check.close(mono.x, 0, tolerance: 0.0001, "identical channels have no side component")
        Check.close(mono.y, 2 * rotation, tolerance: 0.0001, "and overshoot the unit circle on the mid axis")

        // Fully out of phase: the mirror image, on the horizontal axis.
        let outOfPhase = EngineController.goniometerPoint(for: GoniometerSample(left: 1, right: -1))
        Check.close(outOfPhase.y, 0, tolerance: 0.0001, "opposite channels cancel on the mid axis")
        Check.close(outOfPhase.x, -2 * rotation, tolerance: 0.0001, "and overshoot the same way on the side axis")

        // Silence maps to the origin, not to a divide-by-zero or a NaN.
        let silence = EngineController.goniometerPoint(for: GoniometerSample(left: 0, right: 0))
        Check.close(silence.x, 0, tolerance: 0.0001, "silence sits at the origin")
        Check.close(silence.y, 0, tolerance: 0.0001, "on both axes")

        // A single channel panned hard right (silence on the left) is what
        // the unit circle is actually calibrated to: magnitude exactly 1,
        // split evenly between the two axes since summing a channel with
        // silence does not cancel it.
        let hardRight = EngineController.goniometerPoint(for: GoniometerSample(left: 0, right: 1))
        Check.close(hardRight.x, rotation, tolerance: 0.0001, "half the deflection lands on the side axis")
        Check.close(hardRight.y, rotation, tolerance: 0.0001, "and half on the mid axis")
        Check.close(
            (hardRight.x * hardRight.x + hardRight.y * hardRight.y).squareRoot(), 1,
            tolerance: 0.0001, "landing exactly on the edge of the unit circle"
        )
    }

    Check.suite("EngineController.oscilloscopeValue — the mono sum") {
        // The same channel-summing convention `SpectrumRing`'s "stereo is
        // summed to mono" test checks for its own ring, applied to the
        // oscilloscope's single trace.
        Check.close(
            EngineController.oscilloscopeValue(for: GoniometerSample(left: 1, right: 1)), 1,
            tolerance: 0.0001, "identical full-scale channels sum to full scale, not double"
        )
        Check.close(
            EngineController.oscilloscopeValue(for: GoniometerSample(left: 1, right: -1)), 0,
            tolerance: 0.0001, "opposite channels cancel to silence"
        )
        Check.close(
            EngineController.oscilloscopeValue(for: GoniometerSample(left: 0, right: 1)), 0.5,
            tolerance: 0.0001, "a single channel is halved, not carried at full weight"
        )
    }

    Check.suite("EngineController.oscilloscopePoints — spread across the window") {
        let samples = [
            GoniometerSample(left: 1, right: 1),
            GoniometerSample(left: -1, right: -1),
            GoniometerSample(left: 0.5, right: 0.5)
        ]
        let points = EngineController.oscilloscopePoints(for: samples)

        Check.equal(points.count, 3, "one point per captured sample")
        Check.close(points[0].position, 0, tolerance: 0.0001, "the oldest sample opens the trace")
        Check.close(points[1].position, 0.5, tolerance: 0.0001, "evenly spread across the window")
        Check.close(points[2].position, 1, tolerance: 0.0001, "the newest sample closes it")
        Check.close(points[0].value, 1, tolerance: 0.0001, "values pass through the mono sum unchanged")
        Check.close(points[1].value, -1, tolerance: 0.0001, "including the sign")
        Check.close(points[2].value, 0.5, tolerance: 0.0001, "and fractional levels")

        Check.isTrue(
            EngineController.oscilloscopePoints(for: []).isEmpty,
            "no samples yet means no points, not a crash"
        )
        Check.isTrue(
            EngineController.oscilloscopePoints(for: [GoniometerSample(left: 1, right: 1)]).isEmpty,
            "a single sample has no window to spread across, so it is refused rather than divided by zero"
        )
    }

    Check.suite("GoniometerRing — disabled by default") {
        // The IOProc's cost when nothing has selected the goniometer is one
        // flag test. The flag starts down, so a session that never shows one
        // never captures.
        let ring = GoniometerRing(capacity: 1024)
        Check.isTrue(ring.isEnabled == false, "capture starts switched off")
        ring.isEnabled = true
        Check.isTrue(ring.isEnabled, "and can be switched on")
    }
}
