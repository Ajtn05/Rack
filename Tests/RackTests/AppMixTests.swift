import CoreAudio
import Darwin

@testable import AudioCore

/// Per-application mixing: the identity rules, and the mix itself.
func runAppMixTests() {
    let sampleRate = 48_000.0

    Check.suite("AppMix — identity") {
        var mix = AppMix()
        mix.upsert(
            AppMix.Entry(bundleID: "com.apple.Safari", processID: 100, displayName: "Safari", volume: 0.5)
        )

        // Bundle ID is the durable key. An app that quits and reopens gets a
        // new PID and a new Core Audio object, and its setting must survive
        // both or per-app volume would silently reset every launch.
        Check.isTrue(
            mix.entry(forBundleID: "com.apple.Safari", processID: 999) != nil,
            "a bundled app is found again after its PID changes"
        )
        Check.isTrue(
            mix.entry(forBundleID: "com.apple.Music", processID: 100) == nil,
            "a different bundle is not matched by a coincidental PID"
        )

        // Processes with no bundle fall back to the PID, and that is not
        // durable — which is correct rather than unfortunate. Inventing a
        // stable identity for a helper process would attach a setting to the
        // wrong thing later.
        mix.upsert(AppMix.Entry(bundleID: nil, processID: 42, displayName: "PID 42"))
        Check.isTrue(
            mix.entry(forBundleID: nil, processID: 42) != nil,
            "an unbundled process is found by PID"
        )
        Check.isTrue(
            mix.entry(forBundleID: nil, processID: 43) == nil,
            "and not by a different PID"
        )
        Check.equal(
            mix.entry(forBundleID: nil, processID: 42)?.id, "pid:42",
            "its identity is explicitly PID-based"
        )
    }

    Check.suite("AppMix — gain") {
        var entry = AppMix.Entry(bundleID: "a", processID: 1, displayName: "A")

        entry.volume = 1
        Check.close(entry.gain, 1, tolerance: 0.0001, "full volume is unity")

        // Square-law, matching the master fader so both behave alike.
        entry.volume = 0.5
        Check.close(entry.gain, 0.25, tolerance: 0.0001, "half travel is a quarter power")

        entry.volume = 0
        Check.close(entry.gain, 0, tolerance: 0.0001, "zero is silence")

        entry.volume = 1
        entry.isMuted = true
        Check.close(entry.gain, 0, tolerance: 0.0001, "mute overrides volume")
    }

    Check.suite("AppMix — editing") {
        var mix = AppMix()
        mix.upsert(AppMix.Entry(bundleID: "a", processID: 1, displayName: "A", volume: 0.5))
        mix.upsert(AppMix.Entry(bundleID: "a", processID: 2, displayName: "A", volume: 0.9))
        Check.equal(mix.entries.count, 1, "upserting the same app replaces rather than duplicates")
        Check.close(mix.entries[0].volume, 0.9, tolerance: 0.0001, "with the newer value")

        mix.upsert(AppMix.Entry(bundleID: "b", processID: 3, displayName: "B"))
        Check.equal(mix.entries.count, 2, "a different app is added")

        mix.remove(id: "a")
        Check.equal(mix.entries.count, 1, "removal works")
        Check.equal(mix.entries[0].bundleID, "b", "and removes the right one")
    }

    Check.suite("AppMix — stream order") {
        // The tap list order *is* the stream order, and the render path matches
        // streams to applications by position. If this ever stopped following
        // entry order, one app's volume would land on another's audio.
        var mix = AppMix()
        mix.upsert(AppMix.Entry(bundleID: "first", processID: 1, displayName: "First"))
        mix.upsert(AppMix.Entry(bundleID: "second", processID: 2, displayName: "Second"))

        let processes = [
            AudioProcessInfo(
                objectID: 77, processID: 2, bundleID: "second",
                displayName: "Second", isPlaying: true
            ),
            AudioProcessInfo(
                objectID: 55, processID: 1, bundleID: "first",
                displayName: "First", isPlaying: true
            )
        ]

        Check.equal(
            mix.controlledProcessObjects(among: processes), [55, 77],
            "stream order follows entry order, not the order processes are listed"
        )

        // An app with an entry but no live process contributes no stream, and
        // must not leave a hole that shifts everything after it.
        var withGhost = AppMix()
        withGhost.upsert(AppMix.Entry(bundleID: "gone", processID: 9, displayName: "Gone"))
        withGhost.upsert(AppMix.Entry(bundleID: "first", processID: 1, displayName: "First"))
        Check.equal(
            withGhost.controlledProcessObjects(among: processes), [55],
            "a dead application is skipped without shifting the rest"
        )
    }

    Check.suite("AudioProcesses — display names") {
        Check.equal(
            AudioProcesses.displayName(bundleID: "com.apple.Safari", processID: 1),
            "Safari",
            "the last component of a bundle ID is a usable name"
        )
        Check.equal(
            AudioProcesses.displayName(bundleID: nil, processID: 4321),
            "PID 4321",
            "an unbundled process shows its PID rather than a guess"
        )
        Check.equal(
            AudioProcesses.displayName(bundleID: "", processID: 7),
            "PID 7",
            "an empty bundle ID is treated as absent"
        )
    }

    Check.suite("rackRender — mixing two application streams") {
        // Two taps at different gains must sum, and changing one must not
        // touch the other. This is the whole point of the phase.
        let publisher = ParameterPublisher()
        publisher.publish(.flat, streamGains: [1, 0.5, 0], sampleRate: sampleRate)

        let context = UnsafeMutablePointer<TapRenderContext>.allocate(capacity: 1)
        context.initialize(to: TapRenderContext())
        context.pointee.exchange = publisher.exchange
        context.pointee.slots = publisher.slots
        // Smoothing off, so one buffer reaches the target gain and the test
        // measures the mix rather than the ramp.
        context.pointee.dsp.smoothingCoefficient = 1
        defer { context.deinitialize(count: 1); context.deallocate() }

        let frameCount = 256
        let sampleCount = frameCount * 2
        let byteCount = UInt32(sampleCount * MemoryLayout<Float>.size)

        // Three input streams: global, app one, app two.
        var storage: [UnsafeMutablePointer<Float>] = []
        for value in [Float(0.1), 0.2, 0.4] {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
            for i in 0..<sampleCount { buffer[i] = value }
            storage.append(buffer)
        }
        defer { storage.forEach { $0.deallocate() } }

        let outputStorage = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { outputStorage.deallocate() }

        let inputList = AudioBufferList.allocate(maximumBuffers: 3)
        defer { free(inputList.unsafeMutablePointer) }
        let outputList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(outputList.unsafeMutablePointer) }

        for index in 0..<3 {
            inputList[index] = AudioBuffer(
                mNumberChannels: 2, mDataByteSize: byteCount, mData: storage[index]
            )
        }
        outputList[0] = AudioBuffer(
            mNumberChannels: 2, mDataByteSize: byteCount, mData: outputStorage
        )

        rackRender(
            context: context,
            input: UnsafePointer(inputList.unsafeMutablePointer),
            output: outputList.unsafeMutablePointer
        )

        // 0.1×1 + 0.2×0.5 + 0.4×0 = 0.2
        Check.close(
            Double(outputStorage[0]), 0.2, tolerance: 0.001,
            "streams sum at their individual gains"
        )
        Check.close(
            Double(outputStorage[sampleCount - 1]), 0.2, tolerance: 0.001,
            "and do so across the whole buffer"
        )

        // Now change only the second app. The first must not move.
        publisher.publish(.flat, streamGains: [1, 0, 1], sampleRate: sampleRate)
        rackRender(
            context: context,
            input: UnsafePointer(inputList.unsafeMutablePointer),
            output: outputList.unsafeMutablePointer
        )
        // 0.1×1 + 0.2×0 + 0.4×1 = 0.5
        Check.close(
            Double(outputStorage[0]), 0.5, tolerance: 0.001,
            "muting one application leaves the others untouched"
        )
    }

    Check.suite("rackRender — a stream count mismatch declines to guess") {
        // If the aggregate does not present one input buffer per tap, matching
        // streams to applications by position would apply one app's volume to
        // another's audio. Falling back to the plain copy is the safe failure.
        let publisher = ParameterPublisher()
        publisher.publish(.flat, streamGains: [1, 0], sampleRate: sampleRate)

        let context = UnsafeMutablePointer<TapRenderContext>.allocate(capacity: 1)
        context.initialize(to: TapRenderContext())
        context.pointee.exchange = publisher.exchange
        context.pointee.slots = publisher.slots
        context.pointee.dsp.smoothingCoefficient = 1
        defer { context.deinitialize(count: 1); context.deallocate() }

        let frameCount = 128
        let sampleCount = frameCount * 2
        let byteCount = UInt32(sampleCount * MemoryLayout<Float>.size)

        let inputStorage = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { inputStorage.deallocate() }
        for i in 0..<sampleCount { inputStorage[i] = 0.3 }
        let outputStorage = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { outputStorage.deallocate() }

        // Block says two streams; only one buffer arrives.
        let inputList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(inputList.unsafeMutablePointer) }
        let outputList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(outputList.unsafeMutablePointer) }

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

        Check.close(
            Double(outputStorage[0]), 0.3, tolerance: 0.0001,
            "audio still flows, unmixed, rather than being silenced or mismatched"
        )
    }
}
