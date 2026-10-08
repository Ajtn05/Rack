import CoreAudio
import Darwin
import RackRealtime

/// State shared between the IOProc and everyone else.
///
/// Allocated once, at a fixed address, and never moved or resized while the
/// IOProc is installed. The counters are lock-free atomics because the audio
/// thread writes them while the UI reads them and neither may wait for the
/// other. `dsp` is not atomic and does not need to be: it belongs to the audio
/// thread alone.
struct TapRenderContext {
    /// Frames rendered since the IOProc was installed. The primary sign of
    /// life: if this is climbing, audio is flowing.
    var framesRendered = RackAtomicU64()

    /// IOProc invocations. Together with `framesRendered` this gives the
    /// average buffer size actually being delivered.
    var buffersRendered = RackAtomicU64()

    /// Buffers where the tap delivered nothing at all. A few at startup is
    /// normal; a steady climb means the tap is installed but not receiving.
    var silentBuffers = RackAtomicU64()

    /// Buffers where input and output could not be matched up — a differing
    /// channel count or byte size.
    var mismatchedBuffers = RackAtomicU64()

    /// Channels across every input buffer of the last callback — what the tap
    /// (and the microphone, when there is one) is *actually* handing us.
    ///
    /// Published from here rather than read off the aggregate with
    /// `kAudioDevicePropertyStreamConfiguration`, because that property does
    /// not settle until some milliseconds after the taps are attached and there
    /// is no moment in `start()` at which asking it gives the right answer. It
    /// is also the more honest number for a readout whose whole job is spotting
    /// a format that is not what we expected: the device's opinion of its
    /// streams and the buffers arriving in the IOProc are exactly the two
    /// things that can disagree.
    var inputChannels = RackAtomicU32()

    /// Peak absolute sample since the last drain, as raw `Float` bits, taken
    /// *after* processing: a meter should show what is leaving the machine.
    var peakLeftBits = RackAtomicU32()
    var peakRightBits = RackAtomicU32()

    /// Cumulative sum of absolute sample values, as raw `Double`
    /// bits, and how many samples went into that sum — together these give
    /// the mean rectified magnitude a VU ballistic needs, which a peak alone
    /// cannot provide. Tracked per channel independently, the same way the
    /// peaks are, so interleaved and deinterleaved buffer layouts never need
    /// reconciling into one shared frame count.
    ///
    /// Written only by the audio thread, which is why a plain load-add-store
    /// is safe here without a compare-exchange loop: nothing else ever writes
    /// these. `drainVU()` subtracts its last coherent snapshot instead of
    /// resetting shared memory while a render may be adding to it.
    var vuMagnitudeSumLeftBits = RackAtomicU64()
    var vuMagnitudeSumRightBits = RackAtomicU64()
    var vuSampleCountLeft = RackAtomicU64()
    var vuSampleCountRight = RackAtomicU64()

    /// Cumulative sums a phase-correlation coefficient needs:
    /// Σ(L·R), Σ(L²), Σ(R²), as raw `Double` bits. A frame count is not kept
    /// alongside these the way `vuSampleCount*` is — the ratio
    /// `Σ(L·R) / sqrt(Σ(L²)·Σ(R²))` is invariant to how many frames went
    /// into it, as long as both channels saw the same frames, which a
    /// correlation sum always does by construction (see
    /// `rackMeasureCorrelation`, which accumulates it one synchronized L/R
    /// pair at a time rather than per-channel).
    var correlationSumLRBits = RackAtomicU64()
    var correlationSumLLBits = RackAtomicU64()
    var correlationSumRRBits = RackAtomicU64()

    /// Even when a complete meter snapshot is available, odd while the audio
    /// thread is updating it. Every total is atomic too, so an overlapping
    /// read is safe even when the reader rejects that snapshot.
    var meterVersion = RackAtomicU64()
    // Single control-side reader only; the audio thread never touches these.
    var lastVUTotals = MeterTotals()
    var lastCorrelationTotals = MeterTotals()

    /// Times the chain produced something that was not a finite number and
    /// the panic bypass was engaged automatically.
    var dspFaults = RackAtomicU64()

    /// Hard bypass. Separate from `DSPParameters.isBypassed` on purpose: this
    /// one is the panic path, settable without going through parameter
    /// compilation, and Phase 3 raises it when the chain misbehaves.
    var bypass = RackAtomicBool()

    /// Raised from off the audio thread to ask the next render to clear every
    /// piece of running state it owns — filter delay lines, the reverb and
    /// echo networks, and the compressor and limiter envelopes.
    ///
    /// A request rather than the deed, and that distinction is the point. All
    /// of that state belongs to the audio thread alone, which is what lets the
    /// rest of this struct be plain non-atomic memory. `retune` used to reach
    /// in and call `dsp.reset()` directly from the actor that handles device
    /// notifications, which is a write to twenty-eight biquads' worth of delay
    /// samples while an IOProc is halfway through reading them — a data race on
    /// the one path where nothing can be recovered afterwards. Consumed at the
    /// top of `rackRender`, which is the only moment nothing is half-written.
    var resetRequested = RackAtomicBool()

    /// Filter state and smoothed gains. Audio thread only.
    var dsp = DSPRenderState()

    /// The rate last adopted from a published block. Audio thread only.
    var sampleRate: Double = 48_000

    /// The howl detector's envelopes and its current cut. Audio thread only,
    /// like every other envelope here. See `Feedback.swift`.
    var feedback = FeedbackGuardState()

    /// How far the microphone is currently being ducked, in dB, published for
    /// a lamp and a readout — the same "raw `Float` bits, last write wins"
    /// convention `limiterReductionBits` uses, and for the same reason: it is a
    /// live gauge, not something to accumulate.
    var feedbackDuckBits = RackAtomicU32()

    /// The compressor's envelope — the gain reduction currently in effect,
    /// smoothed by attack and release. Audio thread only, the same as every
    /// other running gain state in `dsp`; unlike the Sound Field Processor's
    /// engines this needs no allocation of its own, since it is one number,
    /// not a delay line.
    var compressorEnvelopeDb: Float = 0

    /// The compressor's current gain reduction, published for the meter to
    /// read — the same "raw `Float` bits in an atomic word" convention
    /// `peakLeftBits` uses. There is nothing to accumulate or reset here the
    /// way a peak is, so unlike `drainPeaks()` this is a plain read of
    /// whatever the audio thread wrote last, not a drain-and-clear.
    var compressorReductionBits = RackAtomicU32()

    /// The Sound Field Processor's own state: two full networks and the
    /// crossfade between them. Allocated once, here, when the context
    /// itself is — see `ReverbEngine.allocate()`. Freed by
    /// `TapSession.tearDown()` before the context is deallocated, since
    /// deallocating the context does nothing about memory a pointer *inside*
    /// it happens to own.
    var reverb = ReverbEngine.allocate()

    /// The reverb's wet/dry send — smoothed mix gains (ordinary gain-ramp
    /// smoothing, at the same 20 ms time constant as every other gain in the
    /// chain; distinct from `reverb`'s own ~50 ms preset crossfade, which
    /// smooths a voice being swapped out rather than a mix *knob* moving),
    /// whether the network is currently being stepped at all (the "disabled
    /// is genuinely no work, not merely silent" guarantee saturation and
    /// crossfeed already keep, extended to a stateful effect — starts
    /// inactive because reverb is off by default; the off→on edge clears the
    /// frozen lines via `ReverbEngine.silence()` so the tail builds from
    /// silence), and the one-pole coefficient for the ~50 ms preset
    /// crossfade, derived from the sample rate the same way
    /// `dsp.smoothingCoefficient` is and recomputed whenever the rate
    /// changes. Audio thread only.
    var reverbSend = WetDrySendState(
        crossfadeCoefficient: Reverb.crossfadeCoefficient(forSampleRate: 48_000)
    )

    /// The Sound Field Processor's echo, alongside its reverb — a second,
    /// independent effect in the same rack unit, mixed in after it. Same
    /// "two full networks and a crossfade" shape as `reverb`, for the same
    /// reason: switching echo presets must never reconfigure a delay line
    /// still feeding the output.
    var delay = DelayEngine.allocate()

    /// The delay's wet/dry send — see `reverbSend`; kept as a separate value
    /// because the two effects' mixes move independently. Audio thread only.
    var delaySend = WetDrySendState(
        crossfadeCoefficient: Delay.crossfadeCoefficient(forSampleRate: 48_000)
    )

    /// Smoothed stereo width — the last stage of the Sound Field Processor,
    /// after both reverb and delay. Ordinary gain-ramp smoothing again, at
    /// the standard 20 ms constant, so moving the knob does not click.
    var widthGain: Float = 1

    /// The limiter's current gain, chased down instantly and released
    /// smoothly. 1 is "not limiting", which is where it sits for any signal
    /// that never reaches the ceiling. Audio thread only.
    var limiterGain: Float = 1

    /// How far the limiter is pulling the output down right now, in dB,
    /// published for a meter — the same "raw `Float` bits in an atomic word,
    /// last write wins" convention `compressorReductionBits` uses, and for the
    /// same reason: this is a live gauge, not something to accumulate.
    var limiterReductionBits = RackAtomicU32()

    /// Where to read published parameters from. Set once at setup; nil means
    /// passthrough, which is the correct behaviour before anything is
    /// published.
    var exchange: UnsafeMutablePointer<ParameterExchange>?
    var slots: UnsafeMutablePointer<DSPBlock>?

    /// Where to drop samples for the analyzer. Nil, or a ring with its enable
    /// flag down, means the IOProc does no analysis work at all — which is the
    /// whole of what the display's `OFF` mode buys.
    var spectrum: UnsafeMutablePointer<SpectrumRingBuffer>?

    /// Where to drop stereo sample pairs for the goniometer. Same nil/disabled
    /// convention as `spectrum` — a scope nobody has selected costs one
    /// relaxed load per buffer and nothing else.
    var goniometer: UnsafeMutablePointer<GoniometerRingBuffer>?
}

// MARK: - Reading from the non-realtime side

extension UnsafeMutablePointer<TapRenderContext> {
    var framesRendered: UInt64 { rack_u64_load(&pointee.framesRendered) }
    var buffersRendered: UInt64 { rack_u64_load(&pointee.buffersRendered) }
    var silentBuffers: UInt64 { rack_u64_load(&pointee.silentBuffers) }
    var mismatchedBuffers: UInt64 { rack_u64_load(&pointee.mismatchedBuffers) }
    var dspFaults: UInt64 { rack_u64_load(&pointee.dspFaults) }

    /// Channels across the last callback's input buffers — see
    /// `TapRenderContext.inputChannels`.
    var inputChannelCount: Int { Int(rack_u32_load(&pointee.inputChannels)) }

    /// Read the peak levels and reset them, so a meter shows the maximum since
    /// it last looked rather than since the engine started.
    func drainPeaks() -> (left: Float, right: Float) {
        (
            Float(bitPattern: rack_u32_exchange(&pointee.peakLeftBits, 0)),
            Float(bitPattern: rack_u32_exchange(&pointee.peakRightBits, 0))
        )
    }

    /// Read the mean rectified magnitude since the last snapshot —
    /// the input a VU ballistic filters, as opposed to the peak `drainPeaks()`
    /// hands a peak meter. Zero, not NaN, when nothing was rendered in the
    /// window: an idle channel is silence, not an undefined average.
    func drainVU() -> (leftAverage: Float, rightAverage: Float) {
        guard let totals = meterSnapshot() else { return (0, 0) }
        let previous = pointee.lastVUTotals
        pointee.lastVUTotals = totals
        let countLeft = totals.leftCount &- previous.leftCount
        let countRight = totals.rightCount &- previous.rightCount
        return (
            countLeft > 0 ? Float((totals.leftMagnitude - previous.leftMagnitude) / Double(countLeft)) : 0,
            countRight > 0 ? Float((totals.rightMagnitude - previous.rightMagnitude) / Double(countRight)) : 0
        )
    }

    /// Read the phase-correlation coefficient for the window since the last
    /// snapshot, using differences of cumulative totals.
    ///
    /// `Σ(L·R) / sqrt(Σ(L²)·Σ(R²))`: +1 when the channels are identical, 0
    /// when unrelated, −1 when fully out of phase. Either energy sum being
    /// zero — one or both channels silent — makes the ratio undefined
    /// (0/0), and 0 is returned instead: silence is not a phase fault, so it
    /// reads as the same "nothing wrong" center a healthy wide-stereo signal
    /// would, rather than drifting the needle toward either edge on no
    /// evidence at all.
    func drainCorrelation() -> Float {
        guard let totals = meterSnapshot() else { return 0 }
        let previous = pointee.lastCorrelationTotals
        pointee.lastCorrelationTotals = totals
        let sumLR = totals.lr - previous.lr
        let sumLL = totals.ll - previous.ll
        let sumRR = totals.rr - previous.rr
        guard sumLL > 0, sumRR > 0 else { return 0 }
        return Float(min(max(sumLR / (sumLL * sumRR).squareRoot(), -1), 1))
    }

    /// The compressor's gain reduction right now, in dB, always ≥ 0. Not a
    /// drain — the audio thread overwrites this every buffer regardless of
    /// whether anyone is reading it, so this is just today's reading of a
    /// live gauge, not something that needs resetting after.
    var compressorReductionDecibels: Float {
        Float(bitPattern: rack_u32_load(&pointee.compressorReductionBits))
    }

    /// How far the limiter is pulling the output down right now, in dB, always
    /// ≥ 0. Not a drain, for the same reason `compressorReductionDecibels` is
    /// not one.
    var limiterReductionDecibels: Float {
        Float(bitPattern: rack_u32_load(&pointee.limiterReductionBits))
    }

    /// How far the howl detector is currently cutting the microphone, in dB,
    /// always ≥ 0. Zero for any room that never howls, which is the point.
    var feedbackDuckDecibels: Float {
        Float(bitPattern: rack_u32_load(&pointee.feedbackDuckBits))
    }

    var isBypassed: Bool {
        get { rack_bool_load(&pointee.bypass) }
        nonmutating set { rack_bool_store(&pointee.bypass, newValue) }
    }

    /// Ask the audio thread to clear its running state before the next buffer
    /// — see `TapRenderContext.resetRequested` for why this is a request and
    /// not a call to `reset()` from here.
    ///
    /// Release ordering, for the same reason parameter publication uses it:
    /// the request is consumed at the start of a buffer. Render state itself
    /// must only be written by that reader, never by this caller.
    func requestReset() {
        rack_bool_store_release(&pointee.resetRequested, true)
    }
}

// MARK: - The realtime path
//
// Everything below runs on the audio thread. Read the realtime rules in
// AUDIO.md before changing any of it. In short: no allocation, no locks, no
// ARC, no logging, no throwing.

/// Capture, process, render.
///
/// The order is: copy the tap's input to the output buffers, then process
/// those buffers in place. Doing it in place avoids a scratch buffer, and the
/// copy has to happen anyway.
@inline(__always)
func rackRender(
    context: UnsafeMutablePointer<TapRenderContext>,
    input: UnsafePointer<AudioBufferList>,
    output: UnsafeMutablePointer<AudioBufferList>
) {
    // Denormals are flushed for the duration of the render and the previous
    // mode restored afterwards — the thread belongs to Core Audio, not to us.
    let denormalMode = rack_denormals_disable()
    defer { rack_denormals_restore(denormalMode) }

    // Value-type wrappers that compute offsets into the buffer list. No
    // allocation, no retain.
    let inputBuffers = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: input)
    )
    let outputBuffers = UnsafeMutableAudioBufferListPointer(output)

    rack_u64_add(&context.pointee.buffersRendered, 1)

    // Before anything is read, so nothing this buffer produces is built on
    // half-cleared state.
    if rack_bool_exchange_ordered(&context.pointee.resetRequested, false) {
        rackResetRunningState(context: context)
    }

    let outputCount = outputBuffers.count
    guard outputCount > 0 else { return }

    let inputCount = inputBuffers.count

    // What the tap is actually delivering, for the diagnostics readout. A walk
    // of at most seventeen buffer headers, no sample data touched.
    var inputChannels: UInt32 = 0
    var header = 0
    while header < inputCount {
        inputChannels &+= inputBuffers[header].mNumberChannels
        header += 1
    }
    rack_u32_store(&context.pointee.inputChannels, inputChannels)

    if inputCount == 0 {
        silenceAll(outputBuffers)
        rack_u64_add(&context.pointee.silentBuffers, 1)
        return
    }

    // The published parameter block is acquired exactly once per buffer, here,
    // and threaded through every pass. Each pass used to acquire it for itself;
    // because the triple buffer's dirty bit is consumed on the
    // first acquire, the seven acquires that followed only ever re-read the
    // same slot — so all that repetition bought was seven extra atomic
    // exchanges a buffer. Nil means nothing has been published yet: passthrough,
    // the correct state before the first `setParameters`.
    let block: UnsafeMutablePointer<DSPBlock>?
    if let exchange = context.pointee.exchange, let slots = context.pointee.slots {
        block = rackAcquireBlock(exchange: exchange, slots: slots)
    } else {
        block = nil
    }

    if let block, block.pointee.sampleRate != context.pointee.sampleRate {
        context.pointee.sampleRate = block.pointee.sampleRate
        context.pointee.dsp.smoothingCoefficient = block.pointee.smoothingCoefficient
        context.pointee.reverbSend.crossfadeCoefficient = block.pointee.reverbCrossfadeCoefficient
        context.pointee.delaySend.crossfadeCoefficient = block.pointee.delayCrossfadeCoefficient
        rackResetRunningState(context: context, block: block)
    }

    // With per-application taps the aggregate presents one input stream per
    // tap, and they have to be summed with individual gains rather than
    // copied. The single-stream path below is left exactly as it was: it is
    // what Phases 1–3 proved, and it is what keeps the flat-EQ null test
    // bit-identical.
    if let block, let mixed = rackMixStreams(
        context: context, block: block, input: inputBuffers, output: outputBuffers
    ) {
        rack_u64_add(&context.pointee.framesRendered, mixed)
        rackApplyChain(context: context, block: block, buffers: outputBuffers)
        rackMeasureAndCapture(context: context, buffers: outputBuffers)
        return
    }

    var framesThisPass: UInt64 = 0
    var sawAnyInput = false
    var mismatched = false

    var index = 0
    while index < outputCount {
        let destination = outputBuffers[index]
        guard let destinationData = destination.mData, destination.mDataByteSize > 0 else {
            index += 1
            continue
        }

        // More output buffers than the tap provides: the remainder must still
        // be written, or the device plays whatever was left in them.
        guard index < inputCount else {
            memset(destinationData, 0, Int(destination.mDataByteSize))
            mismatched = true
            index += 1
            continue
        }

        let source = inputBuffers[index]
        guard let sourceData = source.mData else {
            memset(destinationData, 0, Int(destination.mDataByteSize))
            mismatched = true
            index += 1
            continue
        }
        let copyBytes = min(source.mDataByteSize, destination.mDataByteSize)

        if copyBytes > 0 {
            memcpy(destinationData, sourceData, Int(copyBytes))
            sawAnyInput = true

            if index == 0 {
                let bytesPerFrame = UInt32(MemoryLayout<Float>.size)
                    * max(destination.mNumberChannels, 1)
                framesThisPass = UInt64(copyBytes / max(bytesPerFrame, 1))
            }
        }

        // Anything the tap did not fill has to be zeroed for the same reason.
        if copyBytes < destination.mDataByteSize {
            memset(
                destinationData.advanced(by: Int(copyBytes)),
                0,
                Int(destination.mDataByteSize - copyBytes)
            )
            mismatched = true
        }

        index += 1
    }

    if let block {
        rackApplyChain(context: context, block: block, buffers: outputBuffers)
    }
    rackMeasureAndCapture(context: context, buffers: outputBuffers)

    rack_u64_add(&context.pointee.framesRendered, framesThisPass)
    if !sawAnyInput { rack_u64_add(&context.pointee.silentBuffers, 1) }
    if mismatched { rack_u64_add(&context.pointee.mismatchedBuffers, 1) }
}

/// Clear everything the audio thread carries from one buffer to the next.
///
/// Called for a discontinuity — a sample rate change, or a poisoned buffer —
/// and it has to be *everything*, which is what `dsp.reset()` on its own was
/// not. That covers the biquads and the crossfeed filters and stops there,
/// leaving the two places state actually persists longest untouched: the
/// reverb's eight feedback lines and the echo's four, each holding seconds of
/// audio. After a rate change those seconds belong to a stream that no longer
/// exists and get released into the new one at the wrong pitch; after a NaN
/// fault they hold the NaN itself, which is the case AUDIO.md calls permanent
/// — it propagates round the feedback path forever and the channel never
/// recovers, so the one routine that exists to recover from it has to reach
/// them.
///
/// The two envelopes go with them for the same reason: a compressor holding
/// 12 dB of reduction earned from the old stream would spend its whole release
/// time getting off the new one's first note.
///
/// Realtime-safe: `silence()` is a memset over already-allocated lines, which
/// is what `rackProcessReverb` already does on this thread when an effect
/// wakes from idle. Nothing here allocates.
@inline(__always)
private func rackResetRunningState(
    context: UnsafeMutablePointer<TapRenderContext>,
    block: UnsafeMutablePointer<DSPBlock>? = nil
) {
    context.pointee.dsp.reset()
    if let block {
        context.pointee.reverb.reset(to: block.pointee.reverb)
        context.pointee.delay.reset(to: block.pointee.delay)
    } else {
        context.pointee.reverb.silence()
        context.pointee.delay.silence()
    }
    context.pointee.compressorEnvelopeDb = 0
    context.pointee.limiterGain = 1
    context.pointee.feedback.reset()
    rack_u32_store(&context.pointee.feedbackDuckBits, Float(0).bitPattern)
    rack_u32_store(&context.pointee.compressorReductionBits, Float(0).bitPattern)
    rack_u32_store(&context.pointee.limiterReductionBits, Float(0).bitPattern)
}

/// Apply the full DSP chain to the output buffers, in the amplifier's fixed
/// order. The bypass test the seven passes used to each make for themselves —
/// the panic flag on the context and the block's own bypass — is made once
/// here instead, since a block that says "bypass" bypasses the whole chain.
@inline(__always)
private func rackApplyChain(
    context: UnsafeMutablePointer<TapRenderContext>,
    block: UnsafeMutablePointer<DSPBlock>,
    buffers: UnsafeMutableAudioBufferListPointer
) {
    guard !rack_bool_load(&context.pointee.bypass) else { return }
    guard !block.pointee.isBypassed else { return }

    rackProcess(context: context, block: block, buffers: buffers)
    rackProcessSaturation(context: context, block: block, buffers: buffers)
    rackProcessCompressor(context: context, block: block, buffers: buffers)
    rackProcessReverb(context: context, block: block, buffers: buffers)
    rackProcessDelay(context: context, block: block, buffers: buffers)
    rackProcessWidth(context: context, block: block, buffers: buffers)
    rackProcessCrossfeed(context: context, block: block, buffers: buffers)
    // Last, and it has to be last: every stage above it can raise the level,
    // and a limiter with anything after it is not a ceiling.
    rackProcessLimiter(context: context, block: block, buffers: buffers)
}

/// The always-on tail of every render, run whether or not the chain above was
/// bypassed: the level measurement (which also arms the panic bypass and feeds
/// the peak/VU meters), then the correlation, goniometer and spectrum captures.
///
/// The safety net inside it: if the chain has produced anything that is not a
/// finite number, the filters are poisoned — NaN propagates through the delay
/// line and never leaves — and whatever reaches the DAC is at best noise.
/// Engage the panic bypass, clear the state, and silence this one buffer. A
/// click is recoverable; a burst of full-scale noise into headphones is not,
/// and permanent silence is what this exists to prevent.
@inline(__always)
private func rackMeasureAndCapture(
    context: UnsafeMutablePointer<TapRenderContext>,
    buffers: UnsafeMutableAudioBufferListPointer
) {
    let version = rack_u64_load(&context.pointee.meterVersion)
    rack_u64_store_release(&context.pointee.meterVersion, version &+ 1)
    if !rackMeasureLevels(context: context, buffers: buffers) {
        rack_bool_store(&context.pointee.bypass, true)
        rackResetRunningState(context: context)
        rack_u64_add(&context.pointee.dspFaults, 1)
        silenceAll(buffers)
    }

    rackMeasureCorrelation(context: context, buffers: buffers)
    rack_u64_store_release(&context.pointee.meterVersion, version &+ 2)
    rackCaptureGoniometer(context: context, buffers: buffers)
    rackCaptureSpectrum(context: context, buffers: buffers)
}

/// Hand the analyzer what is leaving the machine.
///
/// Deliberately placed after processing, so the display shows the sound the
/// user is hearing rather than the sound before the equalizer touched it — the
/// same reasoning that puts the peak meters where they are.
///
/// The IOProc's entire share of the analyzer is this: a flag test, and a copy.
/// The window, the transform and the band folding all happen on another thread
/// reading the other end of the ring. Nothing here allocates, waits, or takes
/// longer than the buffer it was given.
@inline(__always)
private func rackCaptureSpectrum(
    context: UnsafeMutablePointer<TapRenderContext>,
    buffers: UnsafeMutableAudioBufferListPointer
) {
    guard let ring = context.pointee.spectrum,
          rack_bool_load(&ring.pointee.isEnabled)
    else { return }

    // Buffer zero only. Interleaved, it already carries both channels and is
    // summed to mono on the way in; deinterleaved, it is the left channel and
    // the right is a separate buffer this does not go looking for. A spectrum
    // of one channel is a spectrum; a second ring and a second transform to
    // average two that almost always agree is not worth the audio thread's
    // time.
    let buffer = buffers[0]
    guard let data = buffer.mData, buffer.mDataByteSize > 0 else { return }

    let channels = Int(max(buffer.mNumberChannels, 1))
    let frameCount = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
    guard frameCount > 0 else { return }

    rackSpectrumPush(
        ring: ring,
        samples: data.assumingMemoryBound(to: Float.self),
        frameCount: frameCount,
        channels: channels
    )
}

/// Hand the goniometer what is leaving the machine, the same "after
/// processing, gated by an enable flag" reasoning `rackCaptureSpectrum`
/// documents.
@inline(__always)
private func rackCaptureGoniometer(
    context: UnsafeMutablePointer<TapRenderContext>,
    buffers: UnsafeMutableAudioBufferListPointer
) {
    guard let ring = context.pointee.goniometer,
          rack_bool_load(&ring.pointee.isEnabled)
    else { return }
    rackGoniometerPush(ring: ring, buffers: buffers)
}

/// Apply the graphic-EQ cascade and per-channel gain to the output buffers, in
/// place — the first stage of the chain. Bypass (the panic flag and the block's
/// own switch) is handled once by `rackApplyChain` before this is called, so a
/// fault in parameter compilation still can never mean silence.
@inline(__always)
private func rackProcess(
    context: UnsafeMutablePointer<TapRenderContext>,
    block: UnsafeMutablePointer<DSPBlock>,
    buffers: UnsafeMutableAudioBufferListPointer
) {
    let coefficients = block.sectionsBuffer
    let smoothing = context.pointee.dsp.smoothingCoefficient
    let output = block.pointee.outputGain

    // Preamp, volume and balance fold into one per-channel gain: one multiply
    // per sample rather than three, and one ramp rather than three chasing
    // each other.
    let targetLeft = output * block.pointee.leftGain
    let targetRight = output * block.pointee.rightGain

    withUnsafeMutablePointer(to: &context.pointee.dsp) { dsp in
        let leftFilters = withUnsafeMutablePointer(to: &dsp.pointee.left) { $0.filtersBuffer }
        let rightFilters = withUnsafeMutablePointer(to: &dsp.pointee.right) { $0.filtersBuffer }

        var index = 0
        while index < buffers.count {
            let buffer = buffers[index]
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else {
                index += 1
                continue
            }
            let samples = data.assumingMemoryBound(to: Float.self)
            let channels = Int(max(buffer.mNumberChannels, 1))
            let frameCount = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)

            if channels >= 2 {
                // Interleaved: this one buffer carries both channels.
                rackProcessChannel(
                    samples: samples, frameCount: frameCount, stride: channels,
                    filters: leftFilters, coefficients: coefficients,
                    gain: &dsp.pointee.leftGain, targetGain: targetLeft,
                    smoothing: smoothing
                )
                rackProcessChannel(
                    samples: samples + 1, frameCount: frameCount, stride: channels,
                    filters: rightFilters, coefficients: coefficients,
                    gain: &dsp.pointee.rightGain, targetGain: targetRight,
                    smoothing: smoothing
                )
            } else if index % 2 == 1 {
                // Deinterleaved: even buffers are left, odd are right.
                // Spelled out rather than selected with a ternary, because an
                // inout argument cannot be chosen by one.
                rackProcessChannel(
                    samples: samples, frameCount: frameCount, stride: 1,
                    filters: rightFilters, coefficients: coefficients,
                    gain: &dsp.pointee.rightGain, targetGain: targetRight,
                    smoothing: smoothing
                )
            } else {
                rackProcessChannel(
                    samples: samples, frameCount: frameCount, stride: 1,
                    filters: leftFilters, coefficients: coefficients,
                    gain: &dsp.pointee.leftGain, targetGain: targetLeft,
                    smoothing: smoothing
                )
            }

            index += 1
        }
    }
}

/// Walks every buffer, handing each stereo frame to `mix` as a pair of
/// mutable samples — interleaved (one buffer, both channels side by side)
/// or deinterleaved (even buffers left, odd right, the same pairing
/// `rackProcess` assumes). A buffer with no partner (an odd channel count)
/// is left untouched rather than guessed at.
///
/// Factored out of `rackProcessReverb` once `rackProcessDelay` needed the
/// identical walk over a different effect — two real call sites, not a
/// speculative one.
@inline(__always)
func rackWalkStereoPairs(
    buffers: UnsafeMutableAudioBufferListPointer,
    _ mix: (inout Float, inout Float) -> Void
) {
    var index = 0
    while index < buffers.count {
        let buffer = buffers[index]
        guard let data = buffer.mData, buffer.mDataByteSize > 0 else {
            index += 1
            continue
        }
        let samples = data.assumingMemoryBound(to: Float.self)
        let channels = Int(max(buffer.mNumberChannels, 1))
        let frameCount = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)

        if channels >= 2 {
            var frame = 0
            while frame < frameCount {
                let leftIndex = frame * channels
                mix(&samples[leftIndex], &samples[leftIndex + 1])
                frame += 1
            }
        } else if index % 2 == 0, index + 1 < buffers.count {
            let rightBuffer = buffers[index + 1]
            guard let rightData = rightBuffer.mData, rightBuffer.mDataByteSize > 0 else {
                index += 1
                continue
            }
            let rightSamples = rightData.assumingMemoryBound(to: Float.self)
            // Bounded by the *shorter* of the pair. The two buffers of a
            // deinterleaved frame normally carry the same count, but nothing
            // here is in a position to insist on it, and taking the left
            // buffer's count on trust writes past the end of a shorter right
            // one — a heap overrun on the audio thread, which is the one place
            // it cannot be recovered from.
            let pairedFrames = min(
                frameCount, Int(rightBuffer.mDataByteSize) / MemoryLayout<Float>.size
            )
            var frame = 0
            while frame < pairedFrames {
                mix(&samples[frame], &rightSamples[frame])
                frame += 1
            }
            index += 1
        }

        index += 1
    }
}

/// Sum every tap stream into the output, each at its own gain.
///
/// Returns the frame count when it handled the buffer, or nil to fall through
/// to the single-stream copy path.
///
/// The aggregate presents its taps as input streams in tap-list order, so
/// input buffer *i* is tap *i*: slot 0 the global tap, 1… the individually
/// controlled applications. If that correspondence does not hold — a differing
/// buffer count — this declines rather than guessing, and the caller copies
/// stream 0 as before. Guessing here would mean applying one app's volume to
/// another's audio.
@inline(__always)
private func rackMixStreams(
    context: UnsafeMutablePointer<TapRenderContext>,
    block: UnsafeMutablePointer<DSPBlock>,
    input: UnsafeMutableAudioBufferListPointer,
    output: UnsafeMutableAudioBufferListPointer
) -> UInt64? {
    let streamCount = Int(block.pointee.streamCount)
    guard streamCount > 1 else { return nil }
    guard input.count == streamCount, output.count >= 1 else { return nil }

    let destination = output[0]
    guard let destinationData = destination.mData, destination.mDataByteSize > 0 else {
        return nil
    }

    let channels = Int(max(destination.mNumberChannels, 1))
    let frameCount = Int(destination.mDataByteSize) / (MemoryLayout<Float>.size * channels)
    let sampleCount = frameCount * channels
    let target = destinationData.assumingMemoryBound(to: Float.self)

    memset(destinationData, 0, Int(destination.mDataByteSize))

    let smoothing = context.pointee.dsp.smoothingCoefficient
    let targetGains = block.streamGainsBuffer

    withUnsafeMutablePointer(to: &context.pointee.dsp) { dsp in
        let currentGains = dsp.streamGainsBuffer

        var stream = 0
        while stream < streamCount {
            let source = input[stream]
            guard let sourceData = source.mData, source.mDataByteSize > 0 else {
                stream += 1
                continue
            }
            let samples = sourceData.assumingMemoryBound(to: Float.self)
            let sourceChannels = Int(max(source.mNumberChannels, 1))

            var gain = currentGains[stream]
            var wanted = targetGains[stream]

            // The microphone, and only the microphone: measured before its
            // gain is applied, and ducked by whatever the detector concluded
            // from the previous buffer. One buffer of latency is right rather
            // than merely tolerable — a howl takes tens of milliseconds to
            // become loud, and acting on this buffer's own measurement would
            // mean measuring a signal we had already changed.
            let isMicStream = Int32(stream) == block.pointee.feedback.micStream
            if isMicStream, block.pointee.feedback.isActive {
                wanted *= context.pointee.feedback.duckGain
            }

            if sourceChannels == 1, channels >= 2 {
                // A mono source into a stereo mix: a microphone, in practice.
                // Each sample feeds both channels, which centres it — the
                // right default for a monitored voice, and the reason this
                // needs its own loop rather than the element-wise sum below.
                // Summing element-wise would send the first half of the mic's
                // buffer to alternating L/R samples and leave the second half
                // of the frame untouched, which is noise, not a signal.
                //
                // Keyed on the buffer describing itself as mono rather than on
                // the stream index: `TapSession.micStreamIndex` records where
                // the microphone is *expected*, and this stays correct even if
                // that expectation is ever wrong.
                let availableFrames = min(
                    frameCount, Int(source.mDataByteSize) / MemoryLayout<Float>.size
                )
                // Accumulated in the loop that was already reading these
                // samples: two adds and a comparison per frame, and only for a
                // mono source, which in practice means only for the microphone.
                var sumOfSquares: Float = 0
                var micPeak: Float = 0
                var frame = 0
                while frame < availableFrames {
                    gain = rackSmooth(gain, toward: wanted, coefficient: smoothing)
                    let raw = samples[frame]
                    if isMicStream {
                        sumOfSquares += raw * raw
                        let magnitude = abs(raw)
                        if magnitude > micPeak { micPeak = magnitude }
                    }
                    let value = raw * gain
                    let base = frame * channels
                    target[base] += value
                    target[base + 1] += value
                    frame += 1
                }

                if isMicStream, availableFrames > 0 {
                    rackAdvanceFeedbackGuard(
                        context: context,
                        block: block,
                        sumOfSquares: sumOfSquares,
                        peak: micPeak,
                        frameCount: availableFrames
                    )
                }
            } else {
                let available = min(
                    sampleCount, Int(source.mDataByteSize) / MemoryLayout<Float>.size
                )
                var i = 0
                while i < available {
                    // Ramped per frame rather than per sample so the two channels
                    // of a frame get the same gain — a gain that changes between
                    // L and R shifts the stereo image while it moves.
                    if i % channels == 0 {
                        gain = rackSmooth(gain, toward: wanted, coefficient: smoothing)
                    }
                    target[i] += samples[i] * gain
                    i += 1
                }
            }
            currentGains[stream] = gain
            stream += 1
        }
    }

    return UInt64(frameCount)
}

/// Step the howl detector on this buffer's microphone measurement and publish
/// the cut it settled on.
///
/// The arithmetic lives in `rackFeedbackDuck`, which is pure and tested on its
/// own; this is the part that has to know where the numbers came from and
/// where the answer goes.
@inline(__always)
private func rackAdvanceFeedbackGuard(
    context: UnsafeMutablePointer<TapRenderContext>,
    block: UnsafeMutablePointer<DSPBlock>,
    sumOfSquares: Float,
    peak: Float,
    frameCount: Int
) {
    let coefficients = block.pointee.feedback
    let rms = (sumOfSquares / Float(frameCount)).squareRoot()
    let elapsed = Float(frameCount) / coefficients.sampleRate

    let duck = rackFeedbackDuck(
        state: &context.pointee.feedback,
        coefficients: coefficients,
        rms: rms,
        peak: peak,
        elapsed: elapsed
    )

    // Positive decibels of cut, matching the compressor and limiter meters.
    let decibels = duck < 1 ? -20 * log10f(max(duck, 1e-6)) : 0
    rack_u32_store(&context.pointee.feedbackDuckBits, decibels.bitPattern)
}

@inline(__always)
private func silenceAll(_ buffers: UnsafeMutableAudioBufferListPointer) {
    var index = 0
    while index < buffers.count {
        if let data = buffers[index].mData {
            memset(data, 0, Int(buffers[index].mDataByteSize))
        }
        index += 1
    }
}

/// Track the loudest sample leaving each channel, and the mean rectified
/// magnitude a VU ballistic needs alongside it.
///
/// Handles both layouts Core Audio may hand us: deinterleaved, where each
/// buffer carries one channel and the buffer index selects L or R; and
/// interleaved, where a single buffer carries both and samples alternate.
/// - Returns: false if the output contains anything that is not a finite
///   number, which is the caller's signal to bypass.
@discardableResult
@inline(__always)
private func rackMeasureLevels(
    context: UnsafeMutablePointer<TapRenderContext>,
    buffers: UnsafeMutableAudioBufferListPointer
) -> Bool {
    var index = 0
    while index < buffers.count {
        let buffer = buffers[index]
        guard let data = buffer.mData, buffer.mDataByteSize > 0 else {
            index += 1
            continue
        }

        let samples = data.assumingMemoryBound(to: Float.self)
        let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        var peakLeft: Float = 0
        var peakRight: Float = 0
        var vuSumLeft: Float = 0
        var vuSumRight: Float = 0
        var vuCountLeft: UInt32 = 0
        var vuCountRight: UInt32 = 0

        // Accumulated alongside the peaks purely to detect a poisoned buffer.
        // A comparison against NaN is always false, so NaN never *becomes* the
        // peak and inspecting the peak afterwards would never see it. Addition
        // does propagate it — as it does an infinity — so one test on the
        // running total at the end of the buffer catches both, at the cost of
        // a single add per sample and no branch in the inner loop.
        var magnitudeSum: Float = 0

        if buffer.mNumberChannels >= 2 {
            let stride = Int(buffer.mNumberChannels)
            var i = 0
            while i + 1 < sampleCount {
                let left = abs(samples[i])
                let right = abs(samples[i + 1])
                magnitudeSum += left + right
                if left > peakLeft { peakLeft = left }
                if right > peakRight { peakRight = right }
                vuSumLeft += left
                vuSumRight += right
                vuCountLeft &+= 1
                vuCountRight &+= 1
                i += stride
            }
        } else {
            var peak: Float = 0
            var vuSum: Float = 0
            var vuCount: UInt32 = 0
            var i = 0
            while i < sampleCount {
                let magnitude = abs(samples[i])
                magnitudeSum += magnitude
                if magnitude > peak { peak = magnitude }
                vuSum += magnitude
                vuCount &+= 1
                i += 1
            }
            if index % 2 == 1 {
                peakRight = peak
                vuSumRight = vuSum
                vuCountRight = vuCount
            } else {
                peakLeft = peak
                vuSumLeft = vuSum
                vuCountLeft = vuCount
            }
        }

        guard magnitudeSum.isFinite else { return false }

        if peakLeft > 0 {
            rack_u32_store_max(&context.pointee.peakLeftBits, peakLeft.bitPattern)
        }
        if peakRight > 0 {
            rack_u32_store_max(&context.pointee.peakRightBits, peakRight.bitPattern)
        }

        if vuCountLeft > 0 {
            rackAccumulate(&context.pointee.vuMagnitudeSumLeftBits, vuSumLeft)
            rackAccumulate(&context.pointee.vuSampleCountLeft, vuCountLeft)
        }
        if vuCountRight > 0 {
            rackAccumulate(&context.pointee.vuMagnitudeSumRightBits, vuSumRight)
            rackAccumulate(&context.pointee.vuSampleCountRight, vuCountRight)
        }

        index += 1
    }
    return true
}

/// Accumulate the sums a phase-correlation coefficient needs: Σ(L·R),
/// Σ(L²), Σ(R²).
///
/// A separate pass from `rackMeasureLevels`, and necessarily so: peak and VU
/// are per-channel quantities, computed one buffer at a time regardless of
/// how the other channel is laid out. Correlation needs both channels of
/// the *same frame* multiplied together, which means the interleaved buffer
/// (one buffer, both channels side by side) and the deinterleaved layout
/// (two one-channel buffers, paired up) have to be walked differently —
/// exactly the distinction `rackProcessReverb` already draws, for the same
/// reason: a stereo effect needs a channel's partner on every sample. Same
/// "even buffers are left, odd are right" pairing here, reused rather than
/// reinvented.
@inline(__always)
private func rackMeasureCorrelation(
    context: UnsafeMutablePointer<TapRenderContext>,
    buffers: UnsafeMutableAudioBufferListPointer
) {
    var sumLR: Float = 0
    var sumLL: Float = 0
    var sumRR: Float = 0

    var index = 0
    while index < buffers.count {
        let buffer = buffers[index]
        guard let data = buffer.mData, buffer.mDataByteSize > 0 else {
            index += 1
            continue
        }
        let samples = data.assumingMemoryBound(to: Float.self)
        let channels = Int(max(buffer.mNumberChannels, 1))
        let frameCount = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)

        if channels >= 2 {
            // Interleaved: both channels of a frame sit side by side.
            var frame = 0
            while frame < frameCount {
                let leftIndex = frame * channels
                let left = samples[leftIndex]
                let right = samples[leftIndex + 1]
                sumLR += left * right
                sumLL += left * left
                sumRR += right * right
                frame += 1
            }
        } else if index % 2 == 0, index + 1 < buffers.count {
            // Deinterleaved: even buffers are left, odd are right. A buffer
            // with no partner (an odd channel count) contributes nothing
            // rather than being paired with the wrong stream.
            let rightBuffer = buffers[index + 1]
            guard let rightData = rightBuffer.mData, rightBuffer.mDataByteSize > 0 else {
                index += 1
                continue
            }
            let rightSamples = rightData.assumingMemoryBound(to: Float.self)
            // Bounded by the shorter of the pair, the same reason
            // `rackWalkStereoPairs` bounds its own walk: a read past the end is
            // a read of whatever the allocator left there, and it would land in
            // a correlation sum the phase meter presents as fact.
            let pairedFrames = min(
                frameCount, Int(rightBuffer.mDataByteSize) / MemoryLayout<Float>.size
            )
            var frame = 0
            while frame < pairedFrames {
                let left = samples[frame]
                let right = rightSamples[frame]
                sumLR += left * right
                sumLL += left * left
                sumRR += right * right
                frame += 1
            }
            index += 1
        }

        index += 1
    }

    // The same poisoned-buffer guard `rackMeasureLevels` applies to its own
    // sums: a fault is caught and silenced there before this pass ever runs
    // on the same buffers, but a belt-and-braces check costs one branch and
    // means this function is safe to call on its own too.
    guard sumLR.isFinite, sumLL.isFinite, sumRR.isFinite else { return }

    rackAccumulate(&context.pointee.correlationSumLRBits, sumLR)
    rackAccumulate(&context.pointee.correlationSumLLBits, sumLL)
    rackAccumulate(&context.pointee.correlationSumRRBits, sumRR)
}

/// Add a buffer's `Float` sum to a cumulative `Double` in an atomic word.
///
/// Safe without a compare-exchange loop because the audio thread is the only
/// writer — the same single-writer reasoning already used for
/// `framesRendered` and `buffersRendered`. The atomics only need to make the
/// result visible to the thread that later reads a snapshot. Release stores
/// also ensure that observing a new total observes the preceding odd version.
@inline(__always)
private func rackAccumulate(_ storage: UnsafeMutablePointer<RackAtomicU64>, _ delta: Float) {
    let current = Double(bitPattern: rack_u64_load(storage))
    rack_u64_store_release(storage, (current + Double(delta)).bitPattern)
}

/// Add `delta` to a plain count stored in an atomic word. Same single-writer
/// reasoning as the float overload above.
@inline(__always)
private func rackAccumulate(_ storage: UnsafeMutablePointer<RackAtomicU64>, _ delta: UInt32) {
    let current = rack_u64_load(storage)
    rack_u64_store_release(storage, current &+ UInt64(delta))
}
