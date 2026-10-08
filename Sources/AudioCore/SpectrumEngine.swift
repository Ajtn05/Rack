import Dispatch
import Foundation

/// One published set of band levels.
///
/// `sequence` is what lets a consumer poll faster than this is produced and
/// still do nothing when there is nothing new — which is the difference
/// between a display that updates thirty times a second and one that redraws
/// sixty times a second to show the same thing twice.
public struct SpectrumFrame: Sendable, Equatable {
    public let sequence: UInt64

    /// One level per band, in dBFS. `-.infinity` for silence.
    public let bandsDecibels: [Float]

    public static let empty = SpectrumFrame(sequence: 0, bandsDecibels: [])
}

/// Runs the analyzer off the audio thread and publishes what it finds.
///
/// A serial `DispatchQueue` at utility QoS, not the audio thread and not the
/// main one. The choice of a queue over a bare `Thread` is for the shutdown
/// guarantee: `stop()` cancels the timer and then synchronises on the queue, so
/// any transform already in flight has finished before it returns. That is what
/// makes it safe for `TapSession` to free the ring immediately afterwards —
/// with a raw thread the same guarantee costs a hand-rolled join.
final class SpectrumEngine: @unchecked Sendable {
    /// Thirty a second. Fast enough to look continuous, and a third of the
    /// work of running it per audio buffer — which at a 512-frame buffer would
    /// be nearly a hundred transforms a second to feed a display that cannot
    /// show them.
    static let framesPerSecond = 30

    private let ring: SpectrumRing
    private let analyzer: SpectrumAnalyzer?
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCount: Int

    private let queue = DispatchQueue(label: "dev.rack.spectrum", qos: .utility)
    private var timer: DispatchSourceTimer?

    /// Guards `frame` only. Contended between this queue and the main thread,
    /// never by the audio thread — which is why a plain lock is the right tool
    /// here and would be the wrong one two files over.
    private let lock = NSLock()
    private var frame = SpectrumFrame.empty
    private var sequence: UInt64 = 0

    /// The rate the ring's samples were captured at. Changed by `retune`.
    private var sampleRate: Double
    private let rateLock = NSLock()

    init(ring: SpectrumRing, sampleRate: Double) {
        self.ring = ring
        self.sampleRate = sampleRate
        self.analyzer = SpectrumAnalyzer()
        self.scratchCount = analyzer?.size ?? 0
        self.scratch = .allocate(capacity: max(scratchCount, 1))
        self.scratch.initialize(repeating: 0, count: max(scratchCount, 1))
    }

    deinit {
        stop()
        scratch.deallocate()
    }

    // MARK: - Control

    /// Whether the audio thread captures and this engine transforms.
    ///
    /// Off is genuinely off: the IOProc stops writing, the timer stops firing,
    /// and the last frame is cleared so a display cannot show a stale spectrum
    /// of audio that is no longer playing.
    var isEnabled: Bool {
        get { ring.isEnabled }
        set {
            guard newValue != ring.isEnabled else { return }
            ring.isEnabled = newValue
            if newValue {
                start()
            } else {
                stop()
                publish([])
            }
        }
    }

    func retune(to newSampleRate: Double) {
        guard newSampleRate > 0 else { return }
        rateLock.lock()
        sampleRate = newSampleRate
        rateLock.unlock()
    }

    private func start() {
        guard timer == nil, analyzer != nil else { return }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now(),
            repeating: .milliseconds(1000 / Self.framesPerSecond),
            // Generous: this is a picture, and letting the system coalesce our
            // wake-ups with ones it was making anyway is most of what "low
            // priority" is supposed to buy.
            leeway: .milliseconds(8)
        )
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    /// Cancel and wait. On return, no transform is in flight and the ring is
    /// safe to free.
    func stop() {
        guard let timer else { return }
        timer.cancel()
        self.timer = nil
        queue.sync {}
    }

    // MARK: - The analysis pass

    private func tick() {
        guard let analyzer, scratchCount > 0 else { return }

        // A false return means the window was torn or the ring has not filled
        // yet. Both are handled by doing nothing: the next tick is 33 ms away
        // and nobody can see a missing frame at that rate.
        guard ring.snapshot(into: scratch, count: scratchCount) else { return }

        rateLock.lock()
        let rate = sampleRate
        rateLock.unlock()

        publish(analyzer.analyse(scratch, sampleRate: rate))
    }

    private func publish(_ bands: [Float]) {
        lock.lock()
        sequence &+= 1
        frame = SpectrumFrame(sequence: sequence, bandsDecibels: bands)
        lock.unlock()
    }

    /// The newest frame, or nil if nothing has been published since `sequence`.
    func latestFrame(after sequence: UInt64) -> SpectrumFrame? {
        lock.lock()
        defer { lock.unlock() }
        return frame.sequence > sequence ? frame : nil
    }
}
