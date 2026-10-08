import CoreAudio
import Foundation
import RackRealtime

@testable import AppCore
@testable import AudioCore

/// What has to survive a relaunch, and — the part that actually broke — what
/// has to reach the engine before the first buffer is rendered.
///
/// Everything Rack restores lives on `EngineController`, and the actor that
/// builds the capture path keeps its own copy of the three pieces a session is
/// built and published from. Only the microphone was ever handed across, so a
/// freshly launched Rack rendered `.flat`: the knobs showed the saved sound and
/// the audio thread was a bit-transparent passthrough until any control at all
/// was moved, since moving one is what published. These cover the handover
/// itself, without hardware — the same reason `DeviceChangeDecision` is tested
/// apart from `DeviceMonitor`.
func runSessionRestoreTests() {
    Check.suite("SystemAudioTap — a cold start adopts the whole restored session") {
        awaiting {
            let tap = SystemAudioTap()

            // What `.flat` is not: the point of the test is that these values
            // are what a session gets built from, not the defaults the actor
            // was constructed with.
            var restored = DSPParameters.flat
            restored.bandGains[0] = 6
            restored.volume = 0.4
            restored.isSaturationEnabled = true

            var mix = AppMix()
            mix.upsert(
                AppMix.Entry(
                    bundleID: "com.apple.Music", processID: 501,
                    displayName: "Music", volume: 0.3
                )
            )
            let monitor = MicMonitor(
                isEnabled: true, deviceUID: "BuiltInMicrophoneDevice", volume: 0.75
            )

            await tap.adopt(parameters: restored, appMix: mix, micMonitor: monitor)

            Check.equal(
                await tap.parameters, restored,
                "the restored settings reach the engine before it is started"
            )
            Check.equal(
                await tap.appMix, mix,
                "so does the per-application mix, which decides the tap list"
            )
            Check.equal(
                await tap.micMonitor, monitor,
                "and the microphone, which decides the sub-device list"
            )
            Check.isTrue(
                await tap.diagnostics().publicationCount > 0,
                "and it counts as a publication, so the plumbing statistic agrees"
            )
        }
    }

    Check.suite("SystemAudioTap — adopting does not start anything by itself") {
        awaiting {
            let tap = SystemAudioTap()
            await tap.adopt(
                parameters: .flat, appMix: AppMix(), micMonitor: MicMonitor()
            )
            Check.isTrue(
                await !tap.isRunning,
                "seeding is not starting — no device is touched until start()"
            )
        }
    }

    Check.suite("rackRender — a requested reset clears the effect tails") {
        // What `dsp.reset()` on its own never touched. A rate change and a NaN
        // fault both go through this, and both used to leave the reverb's eight
        // feedback lines and the echo's four holding whatever they held — in
        // the fault case that is the NaN itself, going round the feedback path
        // forever, which is exactly the condition the fault handler exists to
        // recover from.
        let sampleRate = 48_000.0
        let frameCount = 512
        let sampleCount = frameCount * 2
        let byteCount = UInt32(sampleCount * MemoryLayout<Float>.size)

        var parameters = DSPParameters.flat
        parameters.isReverbEnabled = true
        parameters.reverbPreset = .hall
        parameters.reverbWetAmount = 1
        parameters.isDelayEnabled = true
        parameters.delayWetAmount = 1

        let publisher = ParameterPublisher()
        publisher.publish(parameters, sampleRate: sampleRate)

        let context = UnsafeMutablePointer<TapRenderContext>.allocate(capacity: 1)
        context.initialize(to: TapRenderContext())
        context.pointee.exchange = publisher.exchange
        context.pointee.slots = publisher.slots
        context.pointee.dsp.smoothingCoefficient =
            DSPRenderState.smoothingCoefficient(forSampleRate: sampleRate)
        context.pointee.reverbSend.crossfadeCoefficient =
            Reverb.crossfadeCoefficient(forSampleRate: sampleRate)
        context.pointee.delaySend.crossfadeCoefficient =
            Delay.crossfadeCoefficient(forSampleRate: sampleRate)
        defer {
            context.pointee.reverb.free()
            context.pointee.delay.free()
            context.deinitialize(count: 1)
            context.deallocate()
        }

        let inputStorage = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { inputStorage.deallocate() }
        let outputStorage = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { outputStorage.deallocate() }
        let inputList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(inputList.unsafeMutablePointer) }
        let outputList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(outputList.unsafeMutablePointer) }

        /// One buffer through the IOProc, filled with a tone or with silence,
        /// handing back the loudest sample that came out.
        func render(amplitude: Float, startFrame: Int) -> Float {
            for frame in 0..<frameCount {
                let phase = 2 * Double.pi * 220 * Double(startFrame + frame) / sampleRate
                let value = amplitude * Float(sin(phase))
                inputStorage[frame * 2] = value
                inputStorage[frame * 2 + 1] = value
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
            var peak: Float = 0
            for index in 0..<sampleCount { peak = max(peak, abs(outputStorage[index])) }
            return peak
        }

        // Long enough for the pre-delay to pass and the lines to be carrying
        // real energy rather than still filling.
        for buffer in 0..<40 { _ = render(amplitude: 0.5, startFrame: buffer * frameCount) }

        let tail = render(amplitude: 0, startFrame: 0)
        Check.isTrue(
            tail > 0.001,
            "silence in still rings out — there is a tail to clear in the first place"
        )

        context.requestReset()
        let cleared = render(amplitude: 0, startFrame: 0)
        Check.close(
            Double(cleared), 0, tolerance: 1e-9,
            "and after a reset the lines are empty, not merely quieter"
        )
        Check.isTrue(
            !rack_bool_load(&context.pointee.resetRequested),
            "the request is consumed, so it clears once rather than every buffer"
        )
    }

    Check.suite("PresetStore — the power switch is remembered") {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rack-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PresetStore(directory: directory)

        // Absent is the case that matters most: every state file written
        // before the field existed has to decode to *on*, or the fix for "Rack
        // does nothing when you open it" would land as "Rack still does
        // nothing when you open it" for everyone who already had one.
        store.save(
            state: PresetStore.SessionState(parameters: .flat)
        )
        Check.equal(
            store.loadState().isPoweredOn, nil,
            "a state file that says nothing about power says nothing"
        )

        store.save(state: PresetStore.SessionState(parameters: .flat, isPoweredOn: false))
        Check.equal(
            store.loadState().isPoweredOn, false,
            "an amplifier switched off and quit stays off"
        )

        store.save(state: PresetStore.SessionState(parameters: .flat, isPoweredOn: true))
        Check.equal(
            store.loadState().isPoweredOn, true,
            "and one left on comes back on"
        )
    }
}

/// Bridge one async body into the synchronous harness.
///
/// `Task.detached`, not `Task`: the suite is top-level code and therefore
/// main-actor isolated, so a task inheriting that isolation could never start
/// while this thread sits on the semaphore. Nothing awaited here touches the
/// main actor.
private func awaiting(_ body: @escaping @Sendable () async -> Void) {
    let finished = DispatchSemaphore(value: 0)
    Task.detached {
        await body()
        finished.signal()
    }
    finished.wait()
}
