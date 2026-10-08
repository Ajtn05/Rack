import Darwin
import RackRealtime

/// The handoff from the audio thread to the analyzer: a single-producer,
/// single-consumer ring of mono samples.
///
/// **The audio thread never waits and never retries.** It writes its frames and
/// release-stores a cursor; that is the whole of its involvement, and it is why
/// the FFT can exist at all without an FFT existing in the IOProc.
///
/// **Overwriting, not blocking.** A visualiser wants the most recent window,
/// not every window. If the analyzer falls behind, the correct behaviour is to
/// lose the frames it missed rather than to stall the producer — so the writer
/// simply laps the reader and the reader notices.
///
/// The reader checks both completed and announced writes. Payloads are atomic,
/// so a writer lapping the copy cannot cause a data race, and a payload acquire
/// that observes an overwrite also observes the range announced before it.
/// A window overlapping that range is discarded and the next tick tries again.
struct SpectrumRingBuffer {
    /// Total samples ever written. Monotonic; the position in the ring is this
    /// masked. Release-stored by the audio thread *after* the samples it names.
    var written = RackAtomicU64()

    /// End of the range the writer is about to modify, announced before any
    /// sample store. `written` alone cannot detect an in-flight overwrite.
    var writing = RackAtomicU64()

    /// Whether the audio thread should write at all.
    ///
    /// The `OFF` mode's entire cost is this one relaxed load per buffer. That
    /// is the point of having the flag down here rather than up in the UI: an
    /// analyzer that is switched off does no work anywhere.
    var isEnabled = RackAtomicBool()

    var samples: UnsafeMutablePointer<RackAtomicU32>?

    /// `capacity - 1`. Capacity is a power of two so the wrap is a mask rather
    /// than a division, which is not something to put in an inner audio loop.
    var mask: UInt64 = 0
    var capacity: Int = 0
}

// MARK: - The realtime side

/// Append one buffer's worth of frames, summed to mono.
///
/// Realtime: no allocation, no locks, one release store at the end. Mono
/// because a single spectrum display is one spectrum — and because summing
/// here costs one add per frame, where carrying two rings would cost a second
/// FFT.
@inline(__always)
func rackSpectrumPush(
    ring: UnsafeMutablePointer<SpectrumRingBuffer>,
    samples source: UnsafePointer<Float>,
    frameCount: Int,
    channels: Int
) {
    guard let storage = ring.pointee.samples, frameCount > 0 else { return }
    let mask = ring.pointee.mask

    // Only this thread writes the cursor, so a relaxed load of our own value is
    // enough; the release below is what the reader synchronises against.
    var position = rack_u64_load(&ring.pointee.written)
    rack_u64_store_release(&ring.pointee.writing, position &+ UInt64(frameCount))

    if channels >= 2 {
        var frame = 0
        while frame < frameCount {
            let index = frame * channels
            let mono = (source[index] + source[index + 1]) * 0.5
            rack_u32_store_release(storage + Int(position & mask), mono.bitPattern)
            position &+= 1
            frame += 1
        }
    } else {
        var frame = 0
        while frame < frameCount {
            rack_u32_store_release(storage + Int(position & mask), source[frame].bitPattern)
            position &+= 1
            frame += 1
        }
    }

    rack_u64_store_release(&ring.pointee.written, position)
}

// MARK: - The owning side

/// Allocates the ring and reads snapshots out of it. Not realtime.
final class SpectrumRing: @unchecked Sendable {
    /// Samples of history.
    ///
    /// 32768 is two thirds of a second at 48 kHz — eight analysis windows. Far
    /// more than the analyzer needs, reducing how often a lapped snapshot
    /// needs to be discarded.
    static let defaultCapacity = 32_768

    let header: UnsafeMutablePointer<SpectrumRingBuffer>
    let capacity: Int

    private let storage: UnsafeMutablePointer<RackAtomicU32>

    init(capacity: Int = SpectrumRing.defaultCapacity) {
        // Rounded up to a power of two rather than trusted, because the mask
        // is meaningless otherwise and the failure would be silent corruption.
        var rounded = 1
        while rounded < max(capacity, 1024) { rounded <<= 1 }
        self.capacity = rounded

        storage = .allocate(capacity: rounded)
        storage.initialize(repeating: RackAtomicU32(), count: rounded)

        header = .allocate(capacity: 1)
        header.initialize(to: SpectrumRingBuffer())
        header.pointee.samples = storage
        header.pointee.mask = UInt64(rounded - 1)
        header.pointee.capacity = rounded
    }

    deinit {
        // The audio thread must already be stopped. `TapSession.tearDown`
        // guarantees that ordering: the analyzer is shut down and the device
        // is stopped before this object is released.
        header.deinitialize(count: 1)
        header.deallocate()
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    var isEnabled: Bool {
        get { rack_bool_load(&header.pointee.isEnabled) }
        set { rack_bool_store(&header.pointee.isEnabled, newValue) }
    }

    /// Total samples the audio thread has written.
    var written: UInt64 { rack_u64_load_acquire(&header.pointee.written) }

    /// Copy the most recent `count` samples, oldest first.
    ///
    /// - Returns: false if there is not yet enough history, or if the writer
    ///   lapped the copy — in which case `destination` holds a torn window and
    ///   must not be used.
    func snapshot(into destination: UnsafeMutablePointer<Float>, count: Int) -> Bool {
        guard count > 0, count <= capacity else { return false }

        let before = rack_u64_load_acquire(&header.pointee.written)
        guard before >= UInt64(count) else { return false }

        let start = before &- UInt64(count)
        guard rack_u64_load_acquire(&header.pointee.writing) &- start <= UInt64(capacity) else {
            return false
        }
        let mask = UInt64(capacity - 1)
        for offset in 0..<count {
            destination[offset] = Float(bitPattern: rack_u32_load_acquire(
                storage + Int((start &+ UInt64(offset)) & mask)
            ))
        }

        // Include writes still in progress: the completed cursor may not yet
        // have advanced even though the writer has overwritten our window.
        let after = rack_u64_load_acquire(&header.pointee.writing)
        return after &- start <= UInt64(capacity)
    }
}
