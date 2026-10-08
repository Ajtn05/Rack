import Darwin
import RackRealtime

/// How many second-order sections the chain runs, per channel.
///
/// Order follows the amplifier's fixed chain — tone before the graphic EQ,
/// the graphic EQ before boost — so the audio thread's cascade matches the
/// signal path the front panel describes, not just its overall response.
public enum DSPChain {
    /// The tone control's two shelves, first in the chain.
    public static let toneBassSection = 0
    public static let toneTrebleSection = 1

    /// Then the graphic EQ.
    public static let eqSectionStart = 2
    public static var eqSectionCount: Int { EQBank.bandCount }

    /// Then the two boost shelves.
    public static let boostBassSection = eqSectionStart + EQBank.bandCount
    public static let boostTrebleSection = boostBassSection + 1

    public static let sectionCount = eqSectionStart + EQBank.bandCount + 2

    /// The most simultaneous tap streams a block can carry: one global tap
    /// plus fifteen individually controlled applications. Fixed because the
    /// audio thread cannot read a growable array.
    public static let maximumStreams = 16

    /// Design every section of the chain, in order.
    ///
    /// The single description of what the chain *is*. The realtime compile path
    /// fills its fixed-size storage from this, and the response curve evaluates
    /// the same list — so the curve on screen cannot drift away from the
    /// filters actually running. Two copies of this sequence would, and the
    /// drift would be invisible until someone measured it.
    ///
    /// Off the audio thread only: it allocates, and it calls `sin` and `cos`.
    public static func sections(
        for parameters: DSPParameters,
        sampleRate: Double
    ) -> [BiquadCoefficients] {
        let parameters = parameters.normalised()
        var sections: [BiquadCoefficients] = []
        sections.reserveCapacity(sectionCount)

        sections.append(
            .lowShelf(
                frequency: DSPParameters.toneBassFrequency,
                gainDecibels: parameters.effectiveToneBassDecibels,
                sampleRate: sampleRate
            )
        )
        sections.append(
            .highShelf(
                frequency: DSPParameters.toneTrebleFrequency,
                gainDecibels: parameters.effectiveToneTrebleDecibels,
                sampleRate: sampleRate
            )
        )

        for band in 0..<EQBank.bandCount {
            sections.append(
                EQBank.coefficients(
                    forBand: band,
                    gainDecibels: parameters.bandGains[band],
                    sampleRate: sampleRate
                )
            )
        }

        sections.append(
            .lowShelf(
                frequency: DSPParameters.boostBassFrequency,
                gainDecibels: parameters.boostBassDecibels,
                sampleRate: sampleRate
            )
        )
        sections.append(
            .highShelf(
                frequency: DSPParameters.boostTrebleFrequency,
                gainDecibels: parameters.boostTrebleDecibels,
                sampleRate: sampleRate
            )
        )

        return sections
    }
}

/// A compiled parameter set, in the form the audio thread consumes.
///
/// Plain old data with fixed-size storage. No arrays, no references, nothing
/// to retain — the audio thread reads this directly and must not touch the
/// Swift runtime to do it.
///
/// `sections` is deliberately the **first** stored property, so a pointer to
/// the block is also a pointer to the section array and no offset arithmetic
/// is needed on the realtime path. `DSPBlockTests` asserts that.
struct DSPBlock {
    /// One set of coefficients per section. Identical for both channels — the
    /// EQ is symmetric, and only the output gains differ.
    var sections: SectionStorage = DSPBlock.identitySections

    /// Per-stream gain, indexed the same way as the aggregate's tap list:
    /// slot 0 is the global tap, 1… are individually controlled applications.
    /// Applied before the mix, so per-app volume is a source control while
    /// everything else is on the master.
    var streamGains: StreamGainStorage = DSPBlock.unityStreamGains
    var streamCount: Int32 = 1

    /// Preamp trim, volume, and headroom compensation, folded together.
    var outputGain: Float = 1
    var leftGain: Float = 1
    var rightGain: Float = 1
    var isBypassed: Bool = false

    // Published with the coefficients, so retuning never writes render state
    // from the control thread. All exponential design stays off the IOProc.
    var sampleRate: Double = 48_000
    var smoothingCoefficient: Float = DSPRenderState.smoothingCoefficient(forSampleRate: 48_000)
    var reverbCrossfadeCoefficient: Float = Reverb.crossfadeCoefficient(forSampleRate: 48_000)
    var delayCrossfadeCoefficient: Float = Delay.crossfadeCoefficient(forSampleRate: 48_000)

    /// Tape/tube saturation, ahead of the compressor — see `Saturation`'s own
    /// doc comment for why the ordering matters.
    var saturation: SaturationCoefficients = SaturationCoefficients()

    /// The compressor, ahead of the Sound Field Processor in the chain —
    /// see `rackProcessCompressor`'s own doc comment for why the ordering
    /// matters.
    var compressor: CompressorCoefficients = CompressorCoefficients()

    /// The Sound Field Processor's reverb, fully designed for this block's
    /// sample rate. What `ReverbEngine.process` reads every buffer — never
    /// what it computes.
    var reverb: ReverbCoefficients = ReverbCoefficients()

    /// The Sound Field Processor's echo, alongside its reverb.
    var delay: DelayCoefficients = DelayCoefficients()

    /// The Sound Field Processor's stereo width, 0…2 — 1 is unity. Needs no
    /// design step of its own the way reverb and delay do: it is read
    /// straight off `DSPParameters.stereoWidth`, clamped, in `compile`.
    var widthGain: Float = 1

    /// Headphone crossfeed, the last stage of the Sound Field Processor,
    /// after width.
    var crossfeed: CrossfeedCoefficients = CrossfeedCoefficients()

    /// The brickwall limiter — the last stage of the whole chain, after every
    /// effect that could have raised the level. See `Limiter`.
    var limiter: LimiterCoefficients = LimiterCoefficients()

    /// The howl detector, which acts on one input stream rather than on the
    /// mix — so unlike everything else here it is compiled from the session's
    /// shape (is there a microphone, and which stream is it) as well as from
    /// the user's settings. See `Feedback.swift`.
    var feedback: FeedbackCoefficients = FeedbackCoefficients()

    /// Fourteen sections: two tone shelves, ten EQ bands, and two boost
    /// shelves. A tuple rather than an array because it must be inline,
    /// fixed-size storage.
    typealias SectionStorage = (
        BiquadCoefficients, BiquadCoefficients, BiquadCoefficients,
        BiquadCoefficients, BiquadCoefficients, BiquadCoefficients,
        BiquadCoefficients, BiquadCoefficients, BiquadCoefficients,
        BiquadCoefficients, BiquadCoefficients, BiquadCoefficients,
        BiquadCoefficients, BiquadCoefficients
    )

    typealias StreamGainStorage = (
        Float, Float, Float, Float, Float, Float, Float, Float,
        Float, Float, Float, Float, Float, Float, Float, Float
    )

    static let unityStreamGains: StreamGainStorage = (
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
    )

    static let identitySections: SectionStorage = (
        .identity, .identity, .identity, .identity, .identity, .identity,
        .identity, .identity, .identity, .identity, .identity, .identity,
        .identity, .identity
    )
}

extension UnsafeMutablePointer<DSPBlock> {
    /// The sections as a buffer. Valid only because `sections` is the first
    /// field of `DSPBlock`; this is the whole reason it is placed there.
    @inline(__always)
    var sectionsBuffer: UnsafeMutableBufferPointer<BiquadCoefficients> {
        UnsafeMutableBufferPointer(
            start: UnsafeMutableRawPointer(self)
                .assumingMemoryBound(to: BiquadCoefficients.self),
            count: DSPChain.sectionCount
        )
    }

    /// The stream gains as a buffer.
    ///
    /// Unlike `sectionsBuffer` this cannot rely on being the first field, so
    /// the offset is asked for rather than assumed. `DSPBlockTests` asserts it
    /// is non-nil, which it is for any stored property.
    @inline(__always)
    var streamGainsBuffer: UnsafeMutableBufferPointer<Float> {
        let offset = MemoryLayout<DSPBlock>.offset(of: \.streamGains) ?? 0
        return UnsafeMutableBufferPointer(
            start: UnsafeMutableRawPointer(self)
                .advanced(by: offset)
                .assumingMemoryBound(to: Float.self),
            count: DSPChain.maximumStreams
        )
    }

    /// Write the per-stream gains, defaulting anything unspecified to unity.
    ///
    /// An empty list means "one stream at unity", which is the global-tap-only
    /// configuration and the path Phases 1–3 already prove.
    func applyStreamGains(_ gains: [Float]) {
        let buffer = streamGainsBuffer
        let count = min(gains.count, DSPChain.maximumStreams)
        for index in 0..<DSPChain.maximumStreams {
            buffer[index] = index < count ? gains[index] : 1
        }
        pointee.streamCount = Int32(max(count, 1))
    }

    /// Fill this block from user-facing parameters. Off the audio thread —
    /// `pow`, `sin` and `cos` have no business in an IOProc.
    func compile(from parameters: DSPParameters, sampleRate: Double) {
        let parameters = parameters.normalised()
        let sampleRate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        pointee.sampleRate = sampleRate
        pointee.smoothingCoefficient = DSPRenderState.smoothingCoefficient(forSampleRate: sampleRate)
        pointee.reverbCrossfadeCoefficient = Reverb.crossfadeCoefficient(forSampleRate: sampleRate)
        pointee.delayCrossfadeCoefficient = Delay.crossfadeCoefficient(forSampleRate: sampleRate)
        let sections = sectionsBuffer

        // One `FrequencyResponse`, used for both the sections and the headroom
        // sweep below. It holds exactly the section list `DSPChain.sections`
        // produces — it is built from that same call — so asking it for both is
        // one design pass rather than two, and guarantees by construction that
        // the headroom figure describes the filters actually being installed.
        let response = FrequencyResponse(parameters: parameters, sampleRate: sampleRate)
        let designed = response.sections
        for index in 0..<DSPChain.sectionCount {
            sections[index] = designed[index]
        }

        // Headroom compensation is a cut applied at the output stage, on top
        // of preamp and volume — never a reason to touch the sections
        // themselves, which stay exactly what the panel says they are.
        let headroom = response.headroomCompensationDecibels(
            isEnabled: parameters.isHeadroomCompensationEnabled
        )
        let channelGains = parameters.channelGains
        pointee.outputGain = Float(parameters.outputGain * pow(10, -headroom / 20))
        pointee.leftGain = Float(channelGains.left)
        pointee.rightGain = Float(channelGains.right)
        pointee.isBypassed = parameters.isBypassed

        pointee.saturation = SaturationCoefficients.compile(
            driveDecibels: parameters.saturationDriveDecibels,
            mix: parameters.saturationMixAmount,
            isEnabled: parameters.isSaturationEnabled
        )
        pointee.compressor = CompressorCoefficients.compile(
            thresholdDecibels: parameters.compressorThresholdDecibels,
            ratio: parameters.compressorRatio,
            attackMilliseconds: parameters.compressorAttackMilliseconds,
            releaseMilliseconds: parameters.compressorReleaseMilliseconds,
            makeupDecibels: parameters.compressorMakeupDecibels,
            isEnabled: parameters.isCompressorEnabled,
            sampleRate: sampleRate
        )
        pointee.reverb = ReverbCoefficients.compile(
            preset: parameters.reverbPreset,
            wetAmount: parameters.reverbWetAmount,
            isEnabled: parameters.isReverbEnabled,
            sampleRate: sampleRate
        )
        pointee.delay = DelayCoefficients.compile(
            preset: parameters.delayPreset,
            wetAmount: parameters.delayWetAmount,
            isEnabled: parameters.isDelayEnabled,
            sampleRate: sampleRate
        )
        pointee.widthGain = Float(parameters.stereoWidth)
        pointee.crossfeed = CrossfeedCoefficients.compile(
            amount: parameters.crossfeedAmount,
            isEnabled: parameters.isCrossfeedEnabled,
            sampleRate: sampleRate
        )
        pointee.limiter = LimiterCoefficients.compile(
            ceilingDecibels: parameters.limiterCeilingDecibels,
            releaseMilliseconds: parameters.limiterReleaseMilliseconds,
            isEnabled: parameters.isLimiterEnabled,
            sampleRate: sampleRate
        )
    }
}

// MARK: - Publication

/// The shared state of the triple buffer. POD, at a stable address.
struct ParameterExchange {
    /// Slot index and dirty bit exchanged together. A separate flag can be
    /// raised for a publication the reader has already acquired, causing its
    /// next acquire to swap back to an older slot.
    var published = RackAtomicU32()
    static let indexMask: UInt32 = 3
    static let dirtyBit: UInt32 = 4

    /// The slot the audio thread currently holds. Audio thread only.
    var readIndex: UInt32 = 2
}

/// Publishes an immutable parameter block to the audio thread.
///
/// A triple buffer rather than a pointer swap with deferred reclamation:
/// three slots are allocated once and the writer never touches the one the
/// reader holds, so nothing has to be freed while the audio thread might still
/// be looking at it.
///
/// The invariant is that `writeIndex`, `published & indexMask` and `readIndex` are always
/// three distinct values. Each side advances by *exchanging* its own index
/// with the shared one, which swaps two of the three and therefore preserves
/// distinctness. That is what guarantees the writer is never writing into the
/// slot being read.
///
/// Neither side ever waits, and the reader's path is two atomic operations
/// with no retry loop — a seqlock would have been simpler to write but its
/// retry is unbounded, which is not a property to hand a realtime thread.
final class ParameterPublisher {
    static let slotCount = 3

    let exchange: UnsafeMutablePointer<ParameterExchange>
    let slots: UnsafeMutablePointer<DSPBlock>

    /// Writer side only; never read by the audio thread.
    private var writeIndex: UInt32 = 0

    // App/mic fader changes only alter stream gains and feedback. Reuse the
    // designed chain rather than repeating the filters and headroom sweep.
    private var compiledParameters: DSPParameters?
    private var compiledBlock = DSPBlock()

    init() {
        slots = .allocate(capacity: Self.slotCount)
        slots.initialize(repeating: DSPBlock(), count: Self.slotCount)

        exchange = .allocate(capacity: 1)
        exchange.initialize(to: ParameterExchange())

        // write 0, published 1, read 2 — the three distinct starting values.
        rack_u32_init(&exchange.pointee.published, 1)
        exchange.pointee.readIndex = 2
    }

    deinit {
        slots.deinitialize(count: Self.slotCount)
        slots.deallocate()
        exchange.deinitialize(count: 1)
        exchange.deallocate()
    }

    /// Compile and publish. Safe to call as fast as a slider can be dragged;
    /// the audio thread picks up the most recent publication and skips any it
    /// missed, which is the correct behaviour for parameters.
    func publish(
        _ parameters: DSPParameters,
        streamGains: [Float] = [],
        feedback: FeedbackCoefficients = FeedbackCoefficients(),
        sampleRate: Double
    ) {
        let slot = slots.advanced(by: Int(writeIndex))
        let parameters = parameters.normalised()
        let sampleRate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        if compiledParameters != parameters || compiledBlock.sampleRate != sampleRate {
            slot.compile(from: parameters, sampleRate: sampleRate)
            compiledBlock = slot.pointee
            compiledParameters = parameters
        } else {
            slot.pointee = compiledBlock
        }
        slot.applyStreamGains(streamGains)
        slot.pointee.feedback = feedback

        // Release: everything written into the slot above is visible to the
        // audio thread before the index naming that slot becomes visible.
        writeIndex = rack_u32_exchange_ordered(
            &exchange.pointee.published, writeIndex | ParameterExchange.dirtyBit
        ) & ParameterExchange.indexMask
    }
}

/// Take the newest published block, or keep the one already held.
///
/// Realtime. Two atomics, no loop, no allocation.
@inline(__always)
func rackAcquireBlock(
    exchange: UnsafeMutablePointer<ParameterExchange>,
    slots: UnsafeMutablePointer<DSPBlock>
) -> UnsafeMutablePointer<DSPBlock> {
    if rack_u32_load_acquire(&exchange.pointee.published) & ParameterExchange.dirtyBit != 0 {
        exchange.pointee.readIndex = rack_u32_exchange_ordered(
            &exchange.pointee.published,
            exchange.pointee.readIndex
        ) & ParameterExchange.indexMask
    }
    return slots.advanced(by: Int(exchange.pointee.readIndex))
}
