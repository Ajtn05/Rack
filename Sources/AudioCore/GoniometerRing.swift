import CoreAudio
import Darwin
import RackRealtime

/// The handoff from the audio thread to the goniometer: a single-producer,
/// single-consumer ring of stereo sample *pairs*.
///
/// Same contract as `SpectrumRingBuffer` — the writer never waits, and the
/// reader checks completed and announced writes around its atomic payload
/// copy — but packed L/R pairs rather than samples summed to mono. A
/// goniometer's whole subject is the relationship between the two channels,
/// which summing to mono would erase before it ever reached the display.
struct GoniometerRingBuffer {
    /// Frames (L/R pairs) ever written. Monotonic; the position in the ring
    /// is this masked. Release-stored by the audio thread *after* the pair
    /// it names.
    var written = RackAtomicU64()
    var writing = RackAtomicU64()

    /// Whether the audio thread should write at all. Same reasoning as
    /// `SpectrumRingBuffer.isEnabled`: a goniometer nobody has selected does
    /// no work anywhere.
    var isEnabled = RackAtomicBool()

    /// One atomic word per stereo frame, packing both Float bit patterns.
    /// A reader can never combine channels from different writes.
    var samples: UnsafeMutablePointer<RackAtomicU64>?

    /// `capacity - 1`, capacity in frames. A power of two so the wrap is a
    /// mask rather than a division.
    var mask: UInt64 = 0

    /// In frames, not floats.
    var capacity: Int = 0
}

// MARK: - The realtime side

/// Append one buffer's worth of frames, left and right kept separate.
///
/// Needs synchronized frame pairs, the same requirement `rackMeasureCorrelation`
/// has and for the same reason: this is a stereo quantity, not two independent
/// per-channel ones. The interleaved/deinterleaved pairing below is the same
/// one `rackProcessReverb` and `rackMeasureCorrelation` already use — reused
/// rather than reinvented a third time.
@inline(__always)
func rackGoniometerPush(
    ring: UnsafeMutablePointer<GoniometerRingBuffer>,
    buffers: UnsafeMutableAudioBufferListPointer
) {
    guard let storage = ring.pointee.samples else { return }
    let mask = ring.pointee.mask

    // Only this thread writes the cursor, so a relaxed load of our own value
    // is enough; the release below is what the reader synchronises against.
    var position = rack_u64_load(&ring.pointee.written)

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
            rack_u64_store_release(&ring.pointee.writing, position &+ UInt64(frameCount))
            // Interleaved: both channels of a frame sit side by side.
            var frame = 0
            while frame < frameCount {
                let leftIndex = frame * channels
                let pair = UInt64(samples[leftIndex].bitPattern)
                    | (UInt64(samples[leftIndex + 1].bitPattern) << 32)
                rack_u64_store_release(storage + Int(position & mask), pair)
                position &+= 1
                frame += 1
            }
        } else if index % 2 == 0, index + 1 < buffers.count {
            // Deinterleaved: even buffers are left, odd are right. A buffer
            // with no partner contributes nothing rather than being paired
            // with the wrong stream.
            let rightBuffer = buffers[index + 1]
            guard let rightData = rightBuffer.mData, rightBuffer.mDataByteSize > 0 else {
                index += 1
                continue
            }
            let rightSamples = rightData.assumingMemoryBound(to: Float.self)
            // Bounded by the shorter of the pair, the same reason
            // `rackWalkStereoPairs` bounds its own walk — reading past the end
            // of the right buffer would put whatever the allocator left there
            // on the goniometer's face.
            let pairedFrames = min(
                frameCount, Int(rightBuffer.mDataByteSize) / MemoryLayout<Float>.size
            )
            rack_u64_store_release(&ring.pointee.writing, position &+ UInt64(pairedFrames))
            var frame = 0
            while frame < pairedFrames {
                let pair = UInt64(samples[frame].bitPattern)
                    | (UInt64(rightSamples[frame].bitPattern) << 32)
                rack_u64_store_release(storage + Int(position & mask), pair)
                position &+= 1
                frame += 1
            }
            index += 1
        }

        index += 1
    }

    rack_u64_store_release(&ring.pointee.written, position)
}

// MARK: - The owning side

/// One stereo sample pair, undecorated.
public struct GoniometerSample: Sendable, Equatable {
    public let left: Float
    public let right: Float

    public init(left: Float, right: Float) {
        self.left = left
        self.right = right
    }
}

/// Allocates the ring and reads snapshots out of it. Not realtime.
final class GoniometerRing: @unchecked Sendable {
    /// Frames of history, in frames (not floats). 8192 at 48 kHz is a little
    /// over 170 ms — many times the window a goniometer actually draws
    /// (`SystemAudioTap.goniometerWindow`), the same margin `SpectrumRing`
    /// gives itself and for the same reason: the copy would have to take
    /// most of a fifth of a second to ever be lapped, which a plain loop over
    /// a few hundred floats never will.
    static let defaultCapacity = 8_192

    let header: UnsafeMutablePointer<GoniometerRingBuffer>
    let capacity: Int

    /// One packed stereo pair per atomic word.
    private let storage: UnsafeMutablePointer<RackAtomicU64>

    /// Where `snapshot(count:)` copies to before building its array.
    ///
    /// Allocated once alongside `storage`, and freed by the same `deinit`,
    /// rather than a fresh allocation on every call: the snapshot is polled at
    /// display rate whenever the goniometer or oscilloscope is showing, and a
    /// malloc/free pair per frame buys nothing. Sized to the full ring so no
    /// legal `count` can outgrow it.
    private let scratch: UnsafeMutablePointer<GoniometerSample>

    init(capacity: Int = GoniometerRing.defaultCapacity) {
        var rounded = 1
        while rounded < max(capacity, 1024) { rounded <<= 1 }
        self.capacity = rounded

        storage = .allocate(capacity: rounded)
        storage.initialize(repeating: RackAtomicU64(), count: rounded)

        scratch = .allocate(capacity: rounded)
        scratch.initialize(repeating: GoniometerSample(left: 0, right: 0), count: rounded)

        header = .allocate(capacity: 1)
        header.initialize(to: GoniometerRingBuffer())
        header.pointee.samples = storage
        header.pointee.mask = UInt64(rounded - 1)
        header.pointee.capacity = rounded
    }

    deinit {
        // The audio thread must already be stopped — `TapSession.tearDown`
        // guarantees that ordering, the same way it does for `SpectrumRing`.
        header.deinitialize(count: 1)
        header.deallocate()
        storage.deinitialize(count: capacity)
        storage.deallocate()
        scratch.deinitialize(count: capacity)
        scratch.deallocate()
    }

    var isEnabled: Bool {
        get { rack_bool_load(&header.pointee.isEnabled) }
        set { rack_bool_store(&header.pointee.isEnabled, newValue) }
    }

    /// Total frames the audio thread has written.
    var written: UInt64 { rack_u64_load_acquire(&header.pointee.written) }

    /// Copy the most recent `count` frames, oldest first, into `destination`
    /// — which must hold `count` `GoniometerSample`s.
    ///
    /// - Returns: false if there is not yet enough history, or if the writer
    ///   lapped the copy — in which case `destination` holds a torn window
    ///   and must not be used. Same detection `SpectrumRing.snapshot` uses.
    func snapshot(into destination: UnsafeMutablePointer<GoniometerSample>, count: Int) -> Bool {
        guard count > 0, count <= capacity else { return false }

        let before = rack_u64_load_acquire(&header.pointee.written)
        guard before >= UInt64(count) else { return false }

        let start = before &- UInt64(count)
        guard rack_u64_load_acquire(&header.pointee.writing) &- start <= UInt64(capacity) else {
            return false
        }
        let mask = UInt64(capacity - 1)
        for offset in 0..<count {
            let pair = rack_u64_load_acquire(storage + Int((start &+ UInt64(offset)) & mask))
            destination[offset] = GoniometerSample(
                left: Float(bitPattern: UInt32(truncatingIfNeeded: pair)),
                right: Float(bitPattern: UInt32(truncatingIfNeeded: pair >> 32))
            )
        }

        let after = rack_u64_load_acquire(&header.pointee.writing)
        return after &- start <= UInt64(capacity)
    }

    /// The most recent `count` frames as an array, oldest first, or nil if
    /// there is not yet enough history or the copy was torn.
    ///
    /// The form a caller actually wants, using this object's own reusable
    /// scratch buffer rather than allocating one per call. The returned array
    /// is a fresh copy, which is what makes it safe to hand anywhere.
    func snapshot(count: Int) -> [GoniometerSample]? {
        guard count > 0, count <= capacity else { return nil }
        guard snapshot(into: scratch, count: count) else { return nil }
        return Array(UnsafeBufferPointer(start: scratch, count: count))
    }
}
