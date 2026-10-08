import CoreAudio
import Darwin
import Dispatch
import RackRealtime

@testable import AudioCore

func runAnalyzerHandoffTests() {
    Check.suite("Analyzer rings — reject an overwrite before its completion cursor advances") {
        let spectrum = SpectrumRing(capacity: 1024)
        let scope = GoniometerRing(capacity: 1024)
        // Model a full ring followed by a writer starting its next buffer.
        // The old completed cursor still reports a full, readable window.
        rack_u64_store_release(&spectrum.header.pointee.written, 1024)
        rack_u64_store_release(&spectrum.header.pointee.writing, 1152)
        rack_u64_store_release(&scope.header.pointee.written, 1024)
        rack_u64_store_release(&scope.header.pointee.writing, 1152)
        let mono = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
        let stereo = UnsafeMutablePointer<GoniometerSample>.allocate(capacity: 1024)
        defer { mono.deallocate(); stereo.deallocate() }
        Check.isTrue(!spectrum.snapshot(into: mono, count: 1024), "mono snapshot rejects an in-flight lap")
        Check.isTrue(!scope.snapshot(into: stereo, count: 1024), "stereo snapshot rejects an in-flight lap")
    }

    Check.suite("Analyzer rings — concurrent wrapping keeps accepted windows coherent") {
        let spectrum = SpectrumRing(capacity: 1024)
        let scope = GoniometerRing(capacity: 1024)
        let group = DispatchGroup()
        let frames = 128
        let batches = 4000
        DispatchQueue.global().async(group: group) {
            let source = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
            let list = AudioBufferList.allocate(maximumBuffers: 1)
            defer { source.deallocate(); free(list.unsafeMutablePointer) }
            list[0] = AudioBuffer(
                mNumberChannels: 2,
                mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float>.size), mData: source
            )
            for batch in 0..<batches {
                for frame in 0..<frames {
                    source[frame * 2] = Float(batch * frames + frame)
                    source[frame * 2 + 1] = source[frame * 2] + 1
                }
                rackSpectrumPush(ring: spectrum.header, samples: source, frameCount: frames, channels: 2)
                rackGoniometerPush(ring: scope.header, buffers: list)
            }
        }
        let window = 256
        let mono = UnsafeMutablePointer<Float>.allocate(capacity: window)
        let stereo = UnsafeMutablePointer<GoniometerSample>.allocate(capacity: window)
        defer { mono.deallocate(); stereo.deallocate() }
        var monoCoherent = true
        var stereoCoherent = true
        repeat {
            if spectrum.snapshot(into: mono, count: window) {
                for offset in 1..<window where mono[offset] != mono[0] + Float(offset) {
                    monoCoherent = false
                }
            }
            if scope.snapshot(into: stereo, count: window) {
                for offset in 0..<window {
                    if stereo[offset].left != stereo[0].left + Float(offset)
                        || stereo[offset].right != stereo[offset].left + 1 {
                        stereoCoherent = false
                    }
                }
            }
        } while group.wait(timeout: .now()) != .success
        Check.isTrue(monoCoherent, "accepted mono windows contain consecutive frames")
        Check.isTrue(stereoCoherent, "accepted stereo windows contain consecutive paired frames")
        Check.isTrue(spectrum.snapshot(into: mono, count: window), "mono history settles after the writer finishes")
        Check.isTrue(scope.snapshot(into: stereo, count: window), "stereo history settles after the writer finishes")
        Check.equal(mono[window - 1], Float(batches * frames - 1) + 0.5, "the latest mono sample survives")
        Check.equal(stereo[window - 1].left, Float(batches * frames - 1), "the latest stereo frame survives")
    }
}
