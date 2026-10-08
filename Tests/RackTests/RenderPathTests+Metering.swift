import CoreAudio
import Darwin
import Dispatch

@testable import AudioCore

// Only rackRender writes running state; the polling thread reads atomics and
// owns its previous snapshots. The writer is joined before deallocation.
private final class MeterStressFixture: @unchecked Sendable {
    let context: UnsafeMutablePointer<TapRenderContext>
    init() {
        context = .allocate(capacity: 1)
        context.initialize(to: TapRenderContext())
    }
    deinit {
        context.pointee.reverb.free()
        context.pointee.delay.free()
        context.deinitialize(count: 1)
        context.deallocate()
    }
}

/// VU, correlation, and goniometer accumulation against known signals.
func runMeteringRenderPathTests() {
    Check.suite("rackRender — concurrent meter drains keep sums and counts together") {
        let fixture = MeterStressFixture()
        let group = DispatchGroup()
        let frames = 64
        let batches = 20_000
        DispatchQueue.global().async(group: group) {
            let source = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
            let destination = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
            let input = AudioBufferList.allocate(maximumBuffers: 1)
            let output = AudioBufferList.allocate(maximumBuffers: 1)
            defer {
                source.deallocate(); destination.deallocate()
                free(input.unsafeMutablePointer); free(output.unsafeMutablePointer)
            }
            for frame in 0..<frames {
                source[frame * 2] = 0.25
                source[frame * 2 + 1] = -0.5
            }
            let bytes = UInt32(frames * 2 * MemoryLayout<Float>.size)
            input[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: bytes, mData: source)
            output[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: bytes, mData: destination)
            for _ in 0..<batches {
                rackRender(context: fixture.context, input: UnsafePointer(input.unsafeMutablePointer),
                           output: output.unsafeMutablePointer)
            }
        }
        var vuCorrect = true
        var correlationCorrect = true
        repeat {
            let vu = fixture.context.drainVU()
            if (vu.leftAverage != 0 || vu.rightAverage != 0)
                && (vu.leftAverage != 0.25 || vu.rightAverage != 0.5) { vuCorrect = false }
            let correlation = fixture.context.drainCorrelation()
            if correlation != 0 && correlation != -1 { correlationCorrect = false }
        } while group.wait(timeout: .now()) != .success
        Check.isTrue(vuCorrect, "draining during a render never produces a mismatched average")
        Check.isTrue(correlationCorrect, "a stereo window keeps its measured phase")
        let totals = fixture.context.meterSnapshot()!
        Check.equal(totals.leftCount, UInt64(frames * batches), "every left sample is counted once")
        Check.equal(totals.rightCount, UInt64(frames * batches), "every right sample is counted once")
        Check.equal(totals.leftMagnitude, Double(frames * batches) * 0.25, "drains cannot resurrect or lose sums")
        _ = fixture.context.drainVU()
        let empty = fixture.context.drainVU()
        Check.equal(empty.leftAverage, 0, "a repeated drain is empty")
        Check.equal(empty.rightAverage, 0, "on both channels")
    }

    Check.suite("rackRender — VU accumulation matches a sine's rectified mean") {
        let publisher = ParameterPublisher()
        publisher.publish(.flat, sampleRate: renderPathSampleRate)
        let context = makeContext(publisher)
        defer { context.pointee.reverb.free(); context.pointee.delay.free(); context.deinitialize(count: 1); context.deallocate() }

        // Flat parameters are bit-transparent, so the output's mean rectified
        // magnitude is the input tone's — mean(|sin|) over a cycle is 2/π,
        // and makeTone's default amplitude is 0.25.
        _ = renderStream(context: context, frequency: 1000, settlingBuffers: 3)

        let (left, right) = context.drainVU()
        let expected = Float(0.25 * 2 / Double.pi)
        Check.close(
            Double(left), Double(expected), tolerance: 0.01,
            "the left channel's drained average matches a 0.25-amplitude sine's analytic mean"
        )
        Check.close(
            Double(right), Double(expected), tolerance: 0.01,
            "and the right channel, since the test tone is dual-mono"
        )
    }

    Check.suite("rackRender — correlation accumulation matches known stereo images") {
        let publisher = ParameterPublisher()
        publisher.publish(.flat, sampleRate: renderPathSampleRate)
        let context = makeContext(publisher)
        defer { context.pointee.reverb.free(); context.pointee.delay.free(); context.deinitialize(count: 1); context.deallocate() }

        let sampleCount = renderPathFrameCount * 2
        let byteCount = UInt32(sampleCount * MemoryLayout<Float>.size)
        let inputStorage = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { inputStorage.deallocate() }
        let outputStorage = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { outputStorage.deallocate() }
        let inputList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(inputList.unsafeMutablePointer) }
        let outputList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(outputList.unsafeMutablePointer) }

        // Renders a stereo buffer built from `left`/`right` twice — once to
        // let the gain ramp settle from whatever state the previous buffer
        // left it in, once to measure a buffer the ramp no longer disturbs —
        // and hands back the correlation drained after the second pass.
        func correlation(left: (Int) -> Float, right: (Int) -> Float) -> Float {
            for frame in 0..<renderPathFrameCount {
                inputStorage[frame * 2] = left(frame)
                inputStorage[frame * 2 + 1] = right(frame)
            }
            inputList[0] = AudioBuffer(
                mNumberChannels: 2, mDataByteSize: byteCount, mData: inputStorage
            )
            outputList[0] = AudioBuffer(
                mNumberChannels: 2, mDataByteSize: byteCount, mData: outputStorage
            )
            for _ in 0..<2 {
                rackRender(
                    context: context,
                    input: UnsafePointer(inputList.unsafeMutablePointer),
                    output: outputList.unsafeMutablePointer
                )
            }
            return context.drainCorrelation()
        }

        func tone(_ frame: Int) -> Float {
            Float(0.25 * sin(2 * .pi * 1000.0 * Double(frame) / renderPathSampleRate))
        }

        let outOfPhase = correlation(left: tone, right: { -tone($0) })
        Check.close(
            Double(outOfPhase), -1, tolerance: 0.01,
            "an inverted right channel reads fully out of phase"
        )

        let inPhase = correlation(left: tone, right: tone)
        Check.close(
            Double(inPhase), 1, tolerance: 0.01,
            "identical channels read fully in phase"
        )

        let unrelated = correlation(
            left: { Float(0.25 * sin(2 * .pi * 1000.0 * Double($0) / renderPathSampleRate)) },
            right: { Float(0.25 * cos(2 * .pi * 1000.0 * Double($0) / renderPathSampleRate)) }
        )
        Check.close(
            Double(unrelated), 0, tolerance: 0.1,
            "a quadrature sine/cosine pair — orthogonal over many cycles — reads as unrelated"
        )
    }

    Check.suite("rackRender — goniometer capture matches known stereo pairs") {
        let publisher = ParameterPublisher()
        publisher.publish(.flat, sampleRate: renderPathSampleRate)
        let context = makeContext(publisher)
        defer { context.pointee.reverb.free(); context.pointee.delay.free(); context.deinitialize(count: 1); context.deallocate() }

        // Disabled by default: rendering a buffer must leave the ring
        // untouched when nothing has asked for a goniometer.
        let disabledRing = GoniometerRing(capacity: 4096)
        context.pointee.goniometer = disabledRing.header

        let sampleCount = renderPathFrameCount * 2
        let byteCount = UInt32(sampleCount * MemoryLayout<Float>.size)
        let inputStorage = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { inputStorage.deallocate() }
        let outputStorage = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { outputStorage.deallocate() }
        let inputList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(inputList.unsafeMutablePointer) }
        let outputList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(outputList.unsafeMutablePointer) }

        for frame in 0..<renderPathFrameCount {
            inputStorage[frame * 2] = Float(frame) * 0.0001
            inputStorage[frame * 2 + 1] = -Float(frame) * 0.0001
        }
        inputList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: byteCount, mData: inputStorage)
        outputList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: byteCount, mData: outputStorage)
        rackRender(
            context: context,
            input: UnsafePointer(inputList.unsafeMutablePointer),
            output: outputList.unsafeMutablePointer
        )
        Check.equal(disabledRing.written, 0, "a disabled ring captures nothing, whatever renders")

        // Enabled: the same render must land in the ring, sample for sample,
        // with left and right intact — flat parameters are bit-transparent,
        // so what comes out is exactly what went in.
        let enabledRing = GoniometerRing(capacity: 4096)
        enabledRing.isEnabled = true
        context.pointee.goniometer = enabledRing.header

        rackRender(
            context: context,
            input: UnsafePointer(inputList.unsafeMutablePointer),
            output: outputList.unsafeMutablePointer
        )
        Check.equal(enabledRing.written, UInt64(renderPathFrameCount), "an enabled ring captures every frame rendered")

        let destination = UnsafeMutablePointer<GoniometerSample>.allocate(capacity: renderPathFrameCount)
        defer { destination.deallocate() }
        Check.isTrue(
            enabledRing.snapshot(into: destination, count: renderPathFrameCount),
            "the whole buffer is there to snapshot"
        )
        var correct = true
        for frame in 0..<renderPathFrameCount {
            let expected = Float(frame) * 0.0001
            let sample = destination[frame]
            if abs(sample.left - expected) > 0.00001 || abs(sample.right - (-expected)) > 0.00001 {
                correct = false
            }
        }
        Check.isTrue(correct, "captured pairs match the rendered signal exactly, channel for channel")
    }

}
