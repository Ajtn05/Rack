import CoreAudio
import Foundation

@testable import AudioCore

// Phase 2 adds the biquad frequency-response suites. What is testable in Phase
// 1 is the error decoding — which matters more than it looks, because every
// diagnosis from here on starts with reading one of these.

Check.suite("CoreAudioError four-character codes") {
    let badObject = CoreAudioError(
        operation: "AudioObjectGetPropertyData",
        status: kAudioHardwareBadObjectError
    )
    Check.equal(badObject.fourCharCode, "!obj", "kAudioHardwareBadObjectError decodes")
    Check.equal(
        badObject.symbolicName,
        "kAudioHardwareBadObjectError",
        "known status is named"
    )

    let badDevice = CoreAudioError(
        operation: "AudioDeviceStart",
        status: kAudioHardwareBadDeviceError
    )
    Check.equal(badDevice.fourCharCode, "!dev", "kAudioHardwareBadDeviceError decodes")

    let unknownProperty = CoreAudioError(
        operation: "AudioObjectGetPropertyData",
        status: kAudioHardwareUnknownPropertyError
    )
    Check.equal(unknownProperty.fourCharCode, "who?", "unknown-property decodes")

    // Not every status is four printable bytes; -50 is just -50.
    let paramError = CoreAudioError(operation: "AudioDeviceStart", status: -50)
    Check.equal(paramError.fourCharCode, nil, "numeric status has no four-char code")
    Check.equal(paramError.symbolicName, "paramErr", "numeric status is still named")
}

Check.suite("CoreAudioError messages") {
    let error = CoreAudioError(
        operation: "AudioHardwareCreateProcessTap",
        status: kAudioHardwareIllegalOperationError,
        context: "creating the global system tap"
    )
    let text = error.description
    Check.isTrue(
        text.contains("AudioHardwareCreateProcessTap"),
        "message names the failing call"
    )
    Check.isTrue(
        text.contains("creating the global system tap"),
        "message says what we were doing"
    )
    Check.isTrue(text.contains("TCC"), "illegal-operation carries the TCC hint")
}

Check.suite("OSStatus.orThrow") {
    var threw = false
    do {
        try OSStatus(noErr).orThrow("AudioDeviceStart")
    } catch {
        threw = true
    }
    Check.isTrue(!threw, "noErr does not throw")

    var caught: CoreAudioError?
    do {
        try kAudioHardwareBadStreamError.orThrow("AudioDeviceStart", "starting")
    } catch let error as CoreAudioError {
        caught = error
    } catch {
        // Nothing else can be thrown here.
    }
    Check.equal(caught?.fourCharCode, "!str", "non-zero status throws a decoded error")
}

runBiquadTests()
runFrequencyResponseTests()
runDSPChainTests()
runReverbTests()
runDelayTests()
runSaturationTests()
runCrossfeedTests()
runLimiterTests()
runCompressorTests()
runEQRenderPathTests()
runReverbRenderPathTests()
runBalanceRenderPathTests()
runMeteringRenderPathTests()
runDelayRenderPathTests()
runWidthRenderPathTests()
runDynamicsRenderPathTests()
runStreamsRenderPathTests()
runDeviceChangeTests()
runAppMixTests()
runMicMonitorTests()
runFeedbackTests()
runPresetTests()
runSessionRestoreTests()
runAppIdentityTests()
runPeakMeterTests()
runBeatMeterTests()
runVUMeterTests()
runCorrelationMeterTests()
runSpectrumTests()
runGoniometerTests()
runAnalyzerHandoffTests()
runSpectrumBallisticsTests()
// Headless runs exercise the audio and model code without invoking AppKit
// appearance resolution or SwiftUI image rendering.
if !CommandLine.arguments.contains("--headless") {
    runThemeContrastTests()
    // Some CI hosts cannot initialize Metal for SwiftUI ImageRenderer.
    // Keep their contrast and CPU texture checks while omitting screenshots.
    if CommandLine.arguments.contains("--skip-theme-screenshots") {
        print("• Theme screenshots — skipped (--skip-theme-screenshots)")
    } else {
        runThemeScreenshotTests()
    }
}


Check.finish()
