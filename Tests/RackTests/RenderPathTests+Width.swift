import CoreAudio
import Darwin

@testable import AudioCore

/// Stereo width narrowing and widening the image.
func runWidthRenderPathTests() {
    Check.suite("rackRender — width narrows and widens the stereo image") {
        // A pure side signal (left and right opposite) collapses toward
        // silence as width falls to 0, and a pure mid signal (identical
        // channels) is untouched by width at any setting — the two
        // properties that prove this is a mid/side rotation and not some
        // other stereo trick.
        func peakAfterWidth(_ width: Double, left: Float, right: Float) -> (left: Float, right: Float) {
            var parameters = DSPParameters.flat
            parameters.stereoWidth = width
            let publisher = ParameterPublisher()
            publisher.publish(parameters, sampleRate: renderPathSampleRate)
            let context = makeContext(publisher)
            defer {
                context.pointee.reverb.free()
                context.pointee.delay.free()
                context.deinitialize(count: 1)
                context.deallocate()
            }

            let sampleCount = renderPathFrameCount * 2
            let byteCount = UInt32(sampleCount * MemoryLayout<Float>.size)
            let storage = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
            defer { storage.deallocate() }
            let outputStorage = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
            defer { outputStorage.deallocate() }
            for frame in 0..<renderPathFrameCount {
                storage[frame * 2] = left
                storage[frame * 2 + 1] = right
            }
            let inputList = AudioBufferList.allocate(maximumBuffers: 1)
            defer { free(inputList.unsafeMutablePointer) }
            let outputList = AudioBufferList.allocate(maximumBuffers: 1)
            defer { free(outputList.unsafeMutablePointer) }
            inputList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: byteCount, mData: storage)
            outputList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: byteCount, mData: outputStorage)
            // Several buffers of settling before the measured one — the
            // width gain ramps at the standard 20 ms time constant, and one
            // buffer alone (~43 ms) leaves a small but real residual.
            for _ in 0..<8 {
                rackRender(
                    context: context,
                    input: UnsafePointer(inputList.unsafeMutablePointer),
                    output: outputList.unsafeMutablePointer
                )
            }
            return (outputStorage[sampleCount - 2], outputStorage[sampleCount - 1])
        }

        let sideNarrowed = peakAfterWidth(0, left: 0.2, right: -0.2)
        Check.close(
            Double(sideNarrowed.left), 0, tolerance: 0.005,
            "a pure side signal collapses toward silence at zero width"
        )
        Check.close(
            Double(sideNarrowed.right), 0, tolerance: 0.005,
            "on both channels"
        )

        let midUnwidened = peakAfterWidth(0, left: 0.2, right: 0.2)
        Check.close(
            Double(midUnwidened.left), 0.2, tolerance: 0.005,
            "a pure mid signal is untouched even at zero width"
        )

        let midDoubled = peakAfterWidth(2, left: 0.2, right: 0.2)
        Check.close(
            Double(midDoubled.left), 0.2, tolerance: 0.005,
            "or at double width — width only ever acts on the side component"
        )
    }

}
