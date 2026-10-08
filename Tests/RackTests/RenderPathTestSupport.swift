import CoreAudio
import Darwin

@testable import AudioCore

/// Shared harness for the `RenderPathTests+*.swift` files: builds a
/// `TapRenderContext` wired to a publisher, renders test tones through
/// `rackRender`, and reads back the result. Split out when
/// `RenderPathTests.swift` (one 1087-line function, 27 suites) was split by
/// concern — every group of suites needs the same harness, so it lives once,
/// here, rather than once per file.

let renderPathSampleRate = 48_000.0
let renderPathFrameCount = 2048

func makeContext(
    _ publisher: ParameterPublisher
) -> UnsafeMutablePointer<TapRenderContext> {
    let context = UnsafeMutablePointer<TapRenderContext>.allocate(capacity: 1)
    context.initialize(to: TapRenderContext())
    context.pointee.exchange = publisher.exchange
    context.pointee.slots = publisher.slots
    context.pointee.dsp.smoothingCoefficient =
        DSPRenderState.smoothingCoefficient(forSampleRate: renderPathSampleRate)
    context.pointee.reverbSend.crossfadeCoefficient =
        Reverb.crossfadeCoefficient(forSampleRate: renderPathSampleRate)
    context.pointee.delaySend.crossfadeCoefficient =
        Delay.crossfadeCoefficient(forSampleRate: renderPathSampleRate)
    return context
}

/// A stereo interleaved sine of `frames` frames, starting at `startFrame`
/// so successive chunks join seamlessly.
///
/// Continuity matters more than it looks. Restarting the phase at each
/// buffer puts a step discontinuity at every boundary, the filters ring on
/// it, and for a *cut* that transient is louder than the steady state it is
/// supposed to be measuring — which reads as the cut not working.
func makeTone(
    frequency: Double,
    frames: Int,
    startFrame: Int = 0,
    amplitude: Float = 0.25
) -> [Float] {
    var samples = [Float](repeating: 0, count: frames * 2)
    for frame in 0..<frames {
        let phase = 2 * .pi * frequency * Double(startFrame + frame) / renderPathSampleRate
        let value = amplitude * Float(sin(phase))
        samples[frame * 2] = value
        samples[frame * 2 + 1] = value
    }
    return samples
}

/// Push a continuous tone through `rackRender` one buffer at a time and
/// hand back the last buffer's input and output.
///
/// `settlingBuffers` lets the gain ramp and the filter state reach steady
/// state before the measurement, so the result is the frequency response
/// rather than the transient.
func renderStream(
    context: UnsafeMutablePointer<TapRenderContext>,
    frequency: Double,
    settlingBuffers: Int = 0,
    amplitude: Float = 0.25
) -> (input: [Float], output: [Float]) {
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

    var chunk = [Float]()
    for buffer in 0...max(settlingBuffers, 0) {
        chunk = makeTone(
            frequency: frequency,
            frames: renderPathFrameCount,
            startFrame: buffer * renderPathFrameCount,
            amplitude: amplitude
        )
        chunk.withUnsafeBufferPointer { source in
            _ = memcpy(inputStorage, source.baseAddress!, Int(byteCount))
        }
        inputList[0] = AudioBuffer(
            mNumberChannels: 2, mDataByteSize: byteCount, mData: inputStorage
        )
        outputList[0] = AudioBuffer(
            mNumberChannels: 2, mDataByteSize: byteCount, mData: outputStorage
        )
        rackRender(
            context: context,
            input: UnsafePointer(inputList.unsafeMutablePointer),
            output: outputList.unsafeMutablePointer
        )
    }

    var output = [Float](repeating: 0, count: sampleCount)
    output.withUnsafeMutableBufferPointer { destination in
        _ = memcpy(destination.baseAddress!, outputStorage, Int(byteCount))
    }
    return (chunk, output)
}

func peak(_ samples: [Float]) -> Float {
    samples.reduce(0) { max($0, abs($1)) }
}
