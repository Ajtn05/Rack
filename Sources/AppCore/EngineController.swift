import AppKit
import AudioCore
import DesignSystem
import Foundation
import Observation
import os

/// What the engine is doing, in terms a screen can render.
///
/// Deliberately not `SystemAudioTap.State`. Translating here is what lets the
/// App target stay free of any audio import, and it means a Core Audio type
/// changing shape does not ripple into the UI.
public enum EngineStatus: Equatable, Sendable {
    case idle
    case starting
    case running
    case stopped
    case failed(String)

    public var isRunning: Bool { self == .running }

    /// The one string any panel shows for this state.
    ///
    /// One case, one word, everywhere. Three panels previously described the
    /// same stopped engine as `Idle`, `ENGINE OFF` and `IDLE`, each having
    /// invented its own wording and its own casing at the point of use — which
    /// reads as three different conditions rather than one.
    ///
    /// `.idle` and `.stopped` deliberately share a word. The distinction
    /// between "has not run yet" and "has run and been stopped" is real inside
    /// the engine and means nothing to someone looking at the front of it: in
    /// both cases the power is off.
    ///
    /// Cased here rather than by the caller, so nobody has to remember to
    /// `.uppercased()` it and nobody can forget.
    public var displayName: String {
        switch self {
        case .idle, .stopped: "OFF"
        case .starting: "STARTING"
        case .running: "RUNNING"
        case .failed: "FAULT"
        }
    }
}

/// Everything the Phase 1 screen displays. Phase 6 will present these through
/// themed components rather than raw text; the values do not change.
public struct EngineReadout: Equatable, Sendable {
    public var deviceName: String = "—"

    /// The stable device identifier, which is what auto-switching rules match
    /// on. The name is for people; this is for the rules.
    public var outputDeviceUID: String?
    public var sampleRate: Double = 0
    /// Channels across the last callback's input buffers — what the tap is
    /// actually handing the render path, published from the audio thread
    /// rather than read off the aggregate device. The two are different
    /// questions, and this is the one a diagnostics panel is for; see
    /// `TapRenderContext.inputChannels`.
    public var inputChannelCount: Int = 0
    public var outputChannelCount: Int = 0
    public var framesRendered: UInt64 = 0
    public var buffersRendered: UInt64 = 0
    public var silentBuffers: UInt64 = 0
    public var mismatchedBuffers: UInt64 = 0

    /// Times the DSP chain bypassed itself after producing a non-finite
    /// sample. Should stay at zero.
    public var dspFaults: UInt64 = 0

    /// How long the last start or device rebuild took, in milliseconds — the
    /// width of the audio gap. Measured rather than assumed, because
    /// destroying and recreating an aggregate device is not instantaneous and
    /// it is worth knowing how far from instantaneous it is.
    public var lastStartMilliseconds: Double = 0

    /// Parameter sets handed to the engine. A plumbing statistic: if this does
    /// not move while a control is worked, the fault is between the screen and
    /// the engine, not inside it.
    ///
    /// Refreshed on the heartbeat rather than on every poll, along with the
    /// counters above — so "worked" now means over a few seconds rather than
    /// instantaneously. That is the right resolution for the question it
    /// answers, and the reason for the change is in `apply(_:elapsed:)`.
    public var publicationCount: UInt64 = 0

    /// Average frames per IOProc call — the buffer size actually in use, as
    /// opposed to the one we asked for.
    ///
    /// The only reason `framesRendered` is still carried: the raw total is no
    /// longer shown anywhere, but the average is, and it is this divided by
    /// `buffersRendered`.
    public var averageBufferFrames: UInt64 {
        guard buffersRendered > 0 else { return 0 }
        return framesRendered / buffersRendered
    }

}

/// The part of the engine's state that changes on every poll: what the meters
/// read.
///
/// Split out from `EngineReadout` for one reason, and it is a battery reason
/// rather than a tidiness one. `@Observable` tracks whole stored properties,
/// not the fields inside them, so a view reading *any* part of `readout` is
/// invalidated when *any other* part changes. With the levels living in there,
/// a peak that moved — which it does thirty times a second while music plays —
/// redrew the diagnostics panel, the output-device selector and the menu bar
/// summary, none of which show a level.
///
/// Now the two are separate properties: whatever reads levels redraws at meter
/// rate because that is its job, and whatever reads the device and the counters
/// redraws when the device or the counters actually change.
public struct EngineLevels: Equatable, Sendable {
    public var peakLeft: Float = 0
    public var peakRight: Float = 0

    /// The compressor's current gain reduction, in dB — already the settled
    /// reading the audio thread's own attack/release produced.
    public var compressorReductionDecibels: Float = 0

    /// What the limiter is currently holding back, in dB. Zero whenever the
    /// signal is under the ceiling, which is most of the time and is the
    /// point.
    public var limiterReductionDecibels: Float = 0

    /// What the howl detector is cutting the microphone by, in dB. Zero for
    /// any room that never howls, which is the point in exactly the same way.
    public var feedbackDuckDecibels: Float = 0
}

/// Owns the audio engine and exposes it to the UI.
///
/// The polling loop exists because the audio thread cannot notify anyone —
/// it publishes counters to lock-free atomics and something else has to come
/// and look. Ten times a second is well under a display refresh and costs a
/// handful of relaxed loads.
@MainActor
@Observable
@dynamicMemberLookup
public final class EngineController {
    public internal(set) var status: EngineStatus = .idle
    public internal(set) var readout = EngineReadout()

    /// What the meters read, kept apart from `readout` so that a moving peak
    /// does not invalidate every view showing a device name — see
    /// `EngineLevels`.
    public internal(set) var levels = EngineLevels()

    /// Meter ballistics, kept separately from the raw peaks in `readout`
    /// because they carry state across updates rather than being a snapshot.
    public internal(set) var meterLeft = PeakMeter()
    public internal(set) var meterRight = PeakMeter()

    /// VU ballistics, alongside the peak ones — a different filter over a
    /// different signal (mean rectified magnitude, not peak), for the VU
    /// display mode. Kept live regardless of `analyzerMode`, the same way
    /// `meterLeft`/`meterRight` are: the audio thread's extra accumulation
    /// work is one add per sample, already paid for measuring peaks.
    public internal(set) var vuLeft = VUMeter()
    public internal(set) var vuRight = VUMeter()

    /// Phase correlation ballistics, same "always live" reasoning as
    /// `vuLeft`/`vuRight` — it sits in the analyzer's persistent meter
    /// strip, visible regardless of `analyzerMode`, not behind a mode of its
    /// own.
    public internal(set) var correlation = CorrelationMeter()

    /// True after `idleThreshold` has passed with no control touched — a
    /// knob turned, a preset recalled, a mode switched. Old VFD and LCD
    /// displays on hi-fi gear go to standby on exactly this signal: not
    /// because the music stopped, but because nobody has operated the unit
    /// for a while.
    ///
    /// When it trips, monitoring stops outright rather than merely slowing:
    /// `enterDisplayIdle` cancels the poll loop and takes the analyzer's
    /// capture out of the IOProc, and the panels swap their live meters for a
    /// standby placeholder. The audio itself keeps flowing — only the looking
    /// at it stops — and the next interaction wakes it (`exitDisplayIdle`). A
    /// stopped poll is the point: a display nobody is watching should cost
    /// nothing to run, not a sixth of its active cost.
    public internal(set) var isDisplayIdle = false

    /// Whether the monitor is allowed to dim itself at all. Off for someone
    /// who wants the display readable across the room, or who finds a
    /// meter that changes brightness on its own more distracting than the
    /// battery saving is worth.
    public var isIdleTimeoutEnabled = true {
        didSet {
            guard isIdleTimeoutEnabled != oldValue else { return }
            // Turning the timeout off has to actively wake a display that has
            // already slept — restart the poll loop and re-arm capture — not
            // merely clear the flag, since idle now means the loop is gone.
            if !isIdleTimeoutEnabled { exitDisplayIdle() }
            noteInteraction()
        }
    }

    /// When a control was last touched. Advanced by `scheduleStateSave`,
    /// which every parameter change, preset action, and mode switch already
    /// calls — one hook rather than one at every call site.
    @ObservationIgnored var lastInteractionAt = ContinuousClock.now

    /// The full decoded Core Audio error, kept separately from `status` so a
    /// screen can show the one-line summary and the detail independently.
    public internal(set) var errorDetail: String?

    /// Whether the user wants the amplifier on, as opposed to whether it
    /// currently *is* — `status` answers the second question and is the wrong
    /// one to persist, since it also carries "starting" and "failed", neither
    /// of which is an instruction.
    ///
    /// Restored at launch and acted on there. Rack processes every sound the
    /// Mac makes, registers a login item and can live in the menu bar with no
    /// window at all, and none of that means anything if opening it leaves the
    /// engine switched off waiting to be found — which is what it did, because
    /// nothing but the Power control ever called `start()`.
    ///
    /// A saved *off* is still honoured: someone who switched the amplifier off
    /// and quit meant it, and coming back up playing would be the opposite
    /// mistake. Absent from the file — every state written before this existed
    /// — means on.
    @ObservationIgnored var isPoweredOn = true

    func setPoweredOn(_ powered: Bool) {
        guard isPoweredOn != powered else { return }
        isPoweredOn = powered
        noteInteraction()
    }

    /// The current DSP settings. Mutate through `update`, which republishes.
    public private(set) var parameters: DSPParameters = .flat

    /// The combined response of the chain, in the form a curve draws.
    ///
    /// Cached rather than computed when asked for. A SwiftUI body re-evaluates
    /// whenever anything it reads changes, and the meters change sixty times a
    /// second — so a computed property here would sweep twelve filters across
    /// a hundred and twenty points sixty times a second to produce the same
    /// answer. It only changes when the parameters or the sample rate do, and
    /// it is recomputed exactly there.
    public internal(set) var responseCurve: [ResponseCurve.Point] = []

    /// What the equalizer's display is showing.
    ///
    /// `.off` is not cosmetic — it takes the capture out of the IOProc and
    /// stops the analysis thread entirely.
    public var analyzerMode: AnalyzerMode = .spectrum {
        didSet {
            guard analyzerMode != oldValue else { return }
            applyAnalyzerMode()
            noteInteraction()
        }
    }

    /// Bar heights and peak markers, with their ballistics.
    public internal(set) var spectrumBallistics = SpectrumBallistics()

    /// The Pulse mode's needle ballistics — reads the same bands
    /// `spectrumBallistics` does, reduced to a bass-onset gauge. See
    /// `BeatMeter`.
    public internal(set) var beatMeter = BeatMeter()

    /// The last frame taken from the analyzer, and when. Asking for anything
    /// newer than this is how sixty polls a second turn into thirty updates.
    @ObservationIgnored var lastSpectrumSequence: UInt64 = 0
    @ObservationIgnored var lastSpectrumTick: ContinuousClock.Instant?

    /// The goniometer's raw material: the most recent window of stereo
    /// pairs, undecorated. Unlike `spectrumBallistics` this carries no
    /// ballistic state of its own — each poll's window fully replaces the
    /// last one rather than decaying into it, which is enough to show a
    /// stereo image's *shape* at display rate without a phosphor-persistence
    /// model this first pass does not attempt.
    public internal(set) var goniometerSamples: [GoniometerSample] = []

    func applyAnalyzerMode() {
        let needsSpectrum = analyzerMode.needsSpectrumCapture
        let needsGoniometer = analyzerMode.needsGoniometerCapture
        Task { [tap] in
            await tap.setSpectrumEnabled(needsSpectrum)
            await tap.setGoniometerEnabled(needsGoniometer)
        }
        if !needsSpectrum { clearSpectrum() }
        if !needsGoniometer { clearGoniometer() }
    }

    func clearSpectrum() {
        spectrumBallistics.reset()
        beatMeter.reset()
        lastSpectrumSequence = 0
        lastSpectrumTick = nil
    }

    func clearGoniometer() {
        goniometerSamples = []
    }

    /// Per-application volume and mute. Mutate through the helpers in
    /// `AppMixController`.
    public internal(set) var appMix = AppMix()

    // MARK: - Library

    public internal(set) var presets: [Preset] = []
    public internal(set) var rules: [AutoSwitchRule] = []
    public internal(set) var activePresetID: UUID?

    /// The frontmost application's bundle ID, for rules that switch on it.
    public internal(set) var foregroundAppBundleID: String?

    /// The selected skin. Changing it redraws everything and touches no other
    /// state — which is the entire claim the DesignSystem boundary makes.
    public var themeID: String = ThemeRegistry.fallback.id {
        didSet { noteInteraction() }
    }

    public var theme: any Theme { ThemeRegistry.theme(id: themeID) }

    /// Which panel sits where. User-arranged by dragging a panel's own title
    /// bar onto another — see `RackScreen` — and otherwise the rack's own
    /// order.
    public var panelOrder: [RackPanelKind] = RackPanelKind.defaultOrder {
        didSet { noteInteraction() }
    }

    /// Visibility is a layout preference; hiding a panel never bypasses its DSP.
    /// Writes go through `setPanelEnabled` so the amplifier cannot be removed.
    public private(set) var enabledPanels = RackPanelKind.defaultEnabledPanels {
        didSet { noteInteraction() }
    }

    public var visiblePanelOrder: [RackPanelKind] {
        panelOrder.filter { enabledPanels.contains($0) }
    }

    public func setPanelEnabled(_ kind: RackPanelKind, isEnabled: Bool) {
        guard kind != .amplifier else { return }
        if isEnabled {
            enabledPanels.insert(kind)
        } else {
            enabledPanels.remove(kind)
        }
    }

    public func resetPanelVisibility() {
        enabledPanels = RackPanelKind.defaultEnabledPanels
    }

    /// Moves `kind` so it sits immediately before `destination`, for a panel
    /// dropped onto another one. A no-op for a panel dropped onto itself, or
    /// naming a kind that is not (or is no longer) in `panelOrder` — both
    /// silent rather than a crash, since a drag session can easily outlive
    /// the state it started with.
    public func movePanel(_ kind: RackPanelKind, before destination: RackPanelKind) {
        guard kind != destination, let sourceIndex = panelOrder.firstIndex(of: kind) else { return }
        panelOrder.remove(at: sourceIndex)
        let destinationIndex = panelOrder.firstIndex(of: destination) ?? panelOrder.count
        panelOrder.insert(kind, at: destinationIndex)
    }

    /// Which panels currently take a full row rather than tiling beside
    /// whatever else fits — `RackPanelKind.defaultIsFullWidth` until the user
    /// touches a panel's own width toggle, and whatever they left it at after
    /// that.
    ///
    /// Automatic width-based tiling already keeps a panel from being asked to
    /// shrink past what its own content needs; what it cannot know is that
    /// two panels which both fit side by side may still be a bad pairing —
    /// a short one beside a tall one wastes exactly as much height as it
    /// saves in width. That judgement is the user's, which is what this
    /// toggle is for.
    public var fullWidthPanels: Set<RackPanelKind> = Set(RackPanelKind.allCases.filter(\.defaultIsFullWidth)) {
        didSet { noteInteraction() }
    }

    /// Flips one panel's own width preference.
    public func toggleFullWidth(_ kind: RackPanelKind) {
        if fullWidthPanels.contains(kind) {
            fullWidthPanels.remove(kind)
        } else {
            fullWidthPanels.insert(kind)
        }
    }

    /// Which panels stretch to match the tallest panel in their own row
    /// rather than stopping at their own content's height. Empty by default
    /// — matching height changes nothing about which panels tile together,
    /// only how a shorter one looks once it is beside a taller one, so there
    /// is no equivalent to `defaultIsFullWidth` here worth defaulting to.
    public var fullHeightPanels: Set<RackPanelKind> = [] {
        didSet { noteInteraction() }
    }

    /// Flips one panel's own height preference.
    public func toggleFullHeight(_ kind: RackPanelKind) {
        if fullHeightPanels.contains(kind) {
            fullHeightPanels.remove(kind)
        } else {
            fullHeightPanels.insert(kind)
        }
    }

    /// Decoded leniently, the same way `themeID` and `analyzerMode` are: a
    /// saved name nothing recognises any more is dropped rather than failing
    /// the whole file, and a kind the save predates — added in a later
    /// version — is appended rather than never appearing at all.
    private static func restoredPanelOrder(from saved: [String]?) -> [RackPanelKind] {
        guard let saved else { return RackPanelKind.defaultOrder }
        let known = saved.compactMap(RackPanelKind.init(rawValue:))
        let missing = RackPanelKind.allCases.filter { !known.contains($0) }
        return known + missing
    }

    let store: PresetStore

    @ObservationIgnored private let foregroundMonitor = ForegroundAppMonitor()
    @ObservationIgnored private nonisolated(unsafe) var stateSaveTask: Task<Void, Never>?

    /// Where the library lives, for a "show me the files" affordance.
    public var libraryPath: String { store.directoryPath }

    /// Record a user/system interaction: reset the idle clock, wake the
    /// display if it was asleep, and persist.
    ///
    /// Kept apart from `scheduleStateSave()` so the two can vary
    /// independently: a future caller that only needs to persist (a
    /// migration, a restore) can call `scheduleStateSave()` without silently
    /// cancelling standby, and a future interaction that has nothing to
    /// persist yet still wakes the display.
    private func noteInteraction() {
        lastInteractionAt = ContinuousClock.now
        // A no-op unless it was actually idle, which is the common case —
        // this runs on every frame of a slider drag.
        if isDisplayIdle { exitDisplayIdle() }
        scheduleStateSave()
    }

    /// Persist session state, coalesced.
    ///
    /// Every slider movement changes the parameters, and writing JSON sixty
    /// times a second would be absurd. One second after the last change is
    /// soon enough to survive a quit and cheap enough to ignore.
    func scheduleStateSave() {
        stateSaveTask?.cancel()
        stateSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.store.save(
                state: PresetStore.SessionState(
                    activePresetID: self.activePresetID,
                    appMix: self.appMix,
                    parameters: self.parameters,
                    themeID: self.themeID,
                    analyzerMode: self.analyzerMode.rawValue,
                    isIdleTimeoutEnabled: self.isIdleTimeoutEnabled,
                    panelOrder: self.panelOrder.map(\.rawValue),
                    enabledPanels: self.enabledPanels.map(\.rawValue),
                    fullWidthPanels: self.fullWidthPanels.map(\.rawValue),
                    fullHeightPanels: self.fullHeightPanels.map(\.rawValue),
                    isMenuBarOnly: self.isMenuBarOnly,
                    micMonitor: self.micMonitor,
                    isPoweredOn: self.isPoweredOn
                )
            )
        }
    }

    /// The processes Core Audio can route audio for, refreshed while running.
    public internal(set) var audioProcesses: [AudioProcessInfo] = []

    /// Which of them actually have a tap of their own. Refreshed on the same
    /// beat as the process list, and the difference between this and the app
    /// mix is what a row shows as global-only.
    public internal(set) var controlledApplicationIDs: Set<String> = []

    /// Everywhere audio could be sent. Refreshed on the same beat as the
    /// process list, and whenever the engine reports a device change.
    public internal(set) var outputDevices: [OutputDeviceInfo] = []

    /// Everywhere audio could be captured from, for the mic monitor's picker.
    /// Refreshed on the same beat as `outputDevices`.
    public internal(set) var inputDevices: [InputDeviceInfo] = []

    // MARK: - Microphone monitoring

    /// Live mic monitoring settings. Mutate through the properties below,
    /// each of which pushes to the engine — switching the monitor on or
    /// changing device costs a rebuild, level and mute do not.
    public internal(set) var micMonitor = MicMonitor()

    private func applyMicMonitor(_ transform: (inout MicMonitor) -> Void) {
        var next = micMonitor
        transform(&next)
        guard next != micMonitor else { return }
        micMonitor = next
        Task { [weak self, tap, next] in
            await tap.setMicMonitor(next)
            self?.isMicHeldForFeedback = await tap.isMicHeldForFeedback()
        }
        noteInteraction()
    }

    /// Whether the microphone is in the signal path.
    ///
    /// Off by default and never turned on by anything but this — see
    /// `MicMonitor` for why a monitoring feature that can howl should not
    /// start itself.
    public var isMicMonitorEnabled: Bool {
        get { micMonitor.isEnabled }
        set { applyMicMonitor { $0.isEnabled = newValue } }
    }

    public var micMonitorVolume: Double {
        get { micMonitor.volume }
        set { applyMicMonitor { $0.volume = newValue } }
    }

    public var isMicMonitorMuted: Bool {
        get { micMonitor.isMuted }
        set { applyMicMonitor { $0.isMuted = newValue } }
    }

    /// The selected input's UID, or nil for the system default.
    public var micMonitorDeviceUID: String? {
        micMonitor.deviceUID
    }

    public func selectMicMonitorDevice(uid: String) {
        applyMicMonitor { $0.deviceUID = uid }
    }

    /// The level knob's readout, as a percentage — the same convention the
    /// reverb and echo mix knobs use.
    public var micMonitorVolumeDisplay: String {
        "\(Int((micMonitor.volume * 100).rounded()))"
    }

    /// What the picker shows as selected. Falls back to whichever device the
    /// system currently calls the default, so the row is never blank — a
    /// monitor with no visible selection reads as broken, when in fact "no
    /// explicit choice" is a perfectly ordinary state.
    public var micMonitorSelection: Set<String> {
        if let uid = micMonitor.deviceUID { return [uid] }
        return inputDevices.first.map { [$0.uid] } ?? []
    }

    /// Whether the feedback guard is holding the microphone out of the signal
    /// path because the output is a loudspeaker.
    ///
    /// Refreshed on the heartbeat and whenever the engine reports a device
    /// change, which are the two moments it can alter — it is a fact about
    /// which output is selected, not about anything the audio thread measures.
    public internal(set) var isMicHeldForFeedback = false

    /// Whether to hold the monitor closed when the output is a loudspeaker.
    ///
    /// See `MicMonitor.isFeedbackGuardEnabled` for why this is defeatable at
    /// all.
    public var isFeedbackGuardEnabled: Bool {
        get { micMonitor.isFeedbackGuardEnabled }
        set { applyMicMonitor { $0.isFeedbackGuardEnabled = newValue } }
    }

    /// True while the howl detector is actually cutting the microphone, for a
    /// lamp that says so — the same convention `isLimiting` uses.
    public var isDuckingFeedback: Bool {
        levels.feedbackDuckDecibels > 0.1
    }

    /// What the detector is taking off, for the readout. Always a cut, so it
    /// reads as one.
    public var feedbackDuckDisplay: String {
        "−\(levels.feedbackDuckDecibels.formatted(.number.precision(.fractionLength(1))))"
    }

    /// Whether the monitor is switched on but has nothing to capture from —
    /// the saved interface is unplugged, or the Mac has no input at all.
    /// Worth saying out loud rather than leaving as silence the user has to
    /// diagnose.
    public var isMicMonitorDeviceMissing: Bool {
        guard micMonitor.isEnabled else { return false }
        if inputDevices.isEmpty { return true }
        guard let uid = micMonitor.deviceUID else { return false }
        return !inputDevices.contains { $0.uid == uid }
    }

    /// Send system audio somewhere else.
    ///
    /// Changes the system default, so every other application follows too —
    /// which is what a source selector on an amplifier does. The engine's own
    /// device listener then rebuilds the capture path onto it.
    ///
    /// The UID goes straight to the tap rather than being resolved against
    /// `outputDevices` here first — that cache is up to several seconds old,
    /// and resolving against it risked handing the tap an object ID for a
    /// device that had since reconnected under a new one. `selectOutputDevice`
    /// re-resolves live; a failure there is logged rather than swallowed,
    /// because a selection that silently does nothing is indistinguishable
    /// from a switch that does not work.
    public func selectOutputDevice(uid: String) {
        Task { [tap] in
            do {
                try await tap.selectOutputDevice(uid: uid)
            } catch {
                Self.log.error(
                    "output device selection failed — \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// Push per-application settings to the engine.
    ///
    /// Adding or removing an application rebuilds the aggregate device and so
    /// costs a brief gap; changing a volume does not.
    func applyAppMix(_ mix: AppMix) {
        appMix = mix
        Task { [tap, mix] in await tap.setAppMix(mix) }
        noteInteraction()
    }

    // MARK: - Parameters

    /// Change settings and push them to the audio thread.
    ///
    /// Safe to call on every frame of a slider drag: publication is a compile
    /// plus two atomics, and the audio thread takes the most recent block and
    /// skips any it missed.
    public func update(_ transform: (inout DSPParameters) -> Void) {
        var next = parameters
        transform(&next)
        parameters = next.normalised()
        refreshResponseCurve()
        Task { [tap, parameters] in await tap.setParameters(parameters) }
        noteInteraction()
    }

    /// Every individually-settable `DSPParameters` property
    /// (`engine.compressorRatio`, `engine.reverbWetAmount`, …) resolves
    /// through here rather than through 30 hand-written
    /// `get { parameters.x } set { update { $0.x = newValue } } }` pairs —
    /// the mutation semantics (normalise, recompute the response curve,
    /// publish to the audio thread, schedule a save) live once, in
    /// `update(_:)`, not once per property.
    public subscript<V>(dynamicMember keyPath: WritableKeyPath<DSPParameters, V>) -> V {
        get { parameters[keyPath: keyPath] }
        set { update { $0[keyPath: keyPath] = newValue } }
    }

    public func setBandGain(_ decibels: Double, forBand index: Int) {
        update { parameters in
            guard parameters.bandGains.indices.contains(index) else { return }
            parameters.bandGains[index] = decibels
        }
    }

    public func bandGain(forBand index: Int) -> Double {
        parameters.bandGains.indices.contains(index) ? parameters.bandGains[index] : 0
    }

    /// Boost depth for the readout beside its knob.
    public var boostDepthDisplay: String {
        parameters.boostDepthDecibels.formatted(.number.precision(.fractionLength(1)))
    }

    private func toneDisplay(_ value: Double) -> String {
        let text = value.formatted(.number.precision(.fractionLength(1)))
        return value > 0 ? "+\(text)" : text
    }

    public var toneBassDisplay: String { toneDisplay(parameters.toneBassDecibels) }
    public var toneTrebleDisplay: String { toneDisplay(parameters.toneTrebleDecibels) }

    /// What headroom compensation is currently cutting, cached alongside the
    /// response curve for the same reason: it takes a `FrequencyResponse` —
    /// `pow`, `sin` and `cos` — to compute, and a view re-evaluates far more
    /// often than the parameters or the sample rate actually change.
    public internal(set) var headroomCompensationDecibels: Double = 0

    /// The amount being subtracted, for the readout — so the behaviour is
    /// never a mystery. Signed, because it is always a cut.
    public var headroomCompensationDisplay: String {
        (-headroomCompensationDecibels).formatted(.number.precision(.fractionLength(1)))
    }

    // MARK: - Limiter

    /// What the limiter is currently taking off, for the readout. Always a
    /// cut, so it reads as one — the same convention
    /// `compressorGainReductionDisplay` uses.
    public var limiterReductionDisplay: String {
        "−\(levels.limiterReductionDecibels.formatted(.number.precision(.fractionLength(1))))"
    }

    /// True while the limiter is actually holding the signal back, for a lamp
    /// that says so. A limiter that never lights is one the user can trust is
    /// staying out of the way; one that is lit constantly is the signal that
    /// something upstream is too hot.
    public var isLimiting: Bool {
        levels.limiterReductionDecibels > 0.1
    }

    // MARK: - Compressor

    /// The gain-reduction meter's needle position, 0…1. Unlike `VUMeter`'s
    /// hand-placed scale, this is a straight line — 0 dB reduction rests at
    /// the right (`1`), and reduction swings the needle left toward `0` as
    /// it deepens. `20` dB is where the printed scale ends; anything past it
    /// pins rather than running off the face.
    public var compressorGainReductionPosition: Double {
        1 - min(max(Double(levels.compressorReductionDecibels), 0) / 20, 1)
    }

    /// The reading beside the meter, always shown as a cut.
    public var compressorGainReductionDisplay: String {
        "−\(levels.compressorReductionDecibels.formatted(.number.precision(.fractionLength(1))))"
    }

    // MARK: - Sound Field Processor

    /// The preset picker's chips.
    public var reverbPresetItems: [SelectorRow.Item] {
        ReverbPreset.allCases.map { SelectorRow.Item(id: $0.rawValue, label: $0.displayName) }
    }

    public func selectReverbPreset(id: String) {
        guard let preset = ReverbPreset(rawValue: id) else { return }
        self.reverbPreset = preset
    }

    /// The mix knob's readout, as a percentage — "0…1" means nothing beside
    /// a knob; "0…100%" is what a wet/dry control has always read.
    public var reverbWetDisplay: String {
        "\(Int((parameters.reverbWetAmount * 100).rounded()))"
    }

    /// The latency this preset adds, for the readout — pre-delay plus
    /// processing is a lip-sync risk on video, so this is shown plainly
    /// rather than left to be discovered. A property of which preset is
    /// selected, not of anything the engine measures, so it needs no round
    /// trip to the audio thread.
    public var reverbLatencyDisplay: String {
        "\(Int(parameters.reverbPreset.latencyMilliseconds.rounded()))"
    }

    // MARK: - Sound Field Processor: echo

    /// The preset picker's chips.
    public var delayPresetItems: [SelectorRow.Item] {
        DelayPreset.allCases.map { SelectorRow.Item(id: $0.rawValue, label: $0.displayName) }
    }

    public func selectDelayPreset(id: String) {
        guard let preset = DelayPreset(rawValue: id) else { return }
        self.delayPreset = preset
    }

    /// The mix knob's readout, as a percentage — same convention
    /// `reverbWetDisplay` uses.
    public var delayWetDisplay: String {
        "\(Int((parameters.delayWetAmount * 100).rounded()))"
    }

    /// The preset's own tap time, for the readout. Not "latency" the way
    /// `reverbLatencyDisplay` reports one — the dry signal passes straight
    /// through untouched, only the wet echo is delayed — so this reads
    /// "Time", the number that actually describes what the effect does.
    public var delayTimeDisplay: String {
        "\(Int(parameters.delayPreset.timeMilliseconds.rounded()))"
    }

    // MARK: - Sound Field Processor: width

    /// The width knob's readout, as a percentage — 100% is unity, matching
    /// the knob's own centre detent.
    public var stereoWidthDisplay: String {
        "\(Int((parameters.stereoWidth * 100).rounded()))"
    }

    // MARK: - Sound Field Processor: crossfeed

    public var crossfeedAmountDisplay: String {
        "\(Int((parameters.crossfeedAmount * 100).rounded()))"
    }

    /// The volume setting in decibels, for the readout beside the knob.
    public var volumeDisplay: String { parameters.volumeDisplay }

    /// Preamp trim, signed, for the readout beside its knob.
    public var preampDisplay: String {
        let value = parameters.preampDecibels
        let text = value.formatted(.number.precision(.fractionLength(1)))
        return value > 0 ? "+\(text)" : text
    }

    /// Output peak in decibels, without a unit — the readout adds one.
    public var peakDisplay: String {
        let decibels = max(meterLeft.decibels, meterRight.decibels)
        guard decibels > -.infinity else { return "−∞" }
        return decibels.formatted(.number.precision(.fractionLength(1)))
    }

    /// Phase correlation, signed — "+1.00", "−0.35" — the same convention
    /// `preampDisplay` uses for a value that can land on either side of zero.
    public var correlationDisplay: String {
        let text = correlation.value.formatted(.number.precision(.fractionLength(2)))
        return correlation.value > 0 ? "+\(text)" : text
    }

    /// Balance as a short legend — "L 40", "CTR", "R 15".
    public var balanceDisplay: String {
        let value = parameters.balance
        guard abs(value) >= 0.005 else { return "CTR" }
        let percent = Int((abs(value) * 100).rounded())
        return value < 0 ? "L \(percent)" : "R \(percent)"
    }

    /// Show the library in Finder.
    public func revealLibrary() {
        NSWorkspace.shared.selectFile(
            nil, inFileViewerRootedAtPath: store.directoryPath
        )
    }

    /// Back to flat, keeping the bypass state — resetting the EQ and silently
    /// un-bypassing would be a surprise.
    public func resetParameters() {
        update { parameters in
            let wasBypassed = parameters.isBypassed
            parameters = .flat
            parameters.isBypassed = wasBypassed
        }
    }

    /// True when every control is at its neutral position.
    public var isFlat: Bool {
        parameters.bandGains.allSatisfy { $0 == 0 }
            && parameters.preampDecibels == 0
            && parameters.balance == 0
            && parameters.boostDepthDecibels == 0
            && parameters.toneBassDecibels == 0
            && parameters.toneTrebleDecibels == 0
    }

    // MARK: - The shell

    @ObservationIgnored let hotKeys = HotKeyMonitor()

    /// Called when something asks for the rack window to come forward — the
    /// ⌥⌘R shortcut, or the menu bar's own item. Set by the App target, which
    /// is the only layer that knows what a scene is; nothing here opens a
    /// window itself.
    @ObservationIgnored public var showWindow: (() -> Void)?

    /// Whether the system has Rack registered to open at login.
    ///
    /// A mirror of `LoginItem.isEnabled` rather than the truth itself — the
    /// system owns that — kept as stored state only so a view has something
    /// observable to read. Always written by reading the system back, never by
    /// assuming the request worked.
    public internal(set) var opensAtLogin: Bool = LoginItem.isEnabled

    /// Whether Rack hides its Dock icon and lives in the menu bar alone.
    ///
    /// Done at runtime with `setActivationPolicy` rather than by shipping
    /// `LSUIElement` in the bundle, which is the same decision made at build
    /// time and therefore not the user's. An amplifier that has been put away
    /// in the menu bar should be able to come back out without reinstalling
    /// it.
    public var isMenuBarOnly: Bool = false {
        didSet {
            guard isMenuBarOnly != oldValue else { return }
            applyActivationPolicy()
            // Coming back out of the menu bar has to re-activate and show
            // itself: an app that changes to `.regular` while another app is
            // frontmost gets its Dock icon back and nothing else, which reads
            // as the switch not having worked. Only on the user's own edge,
            // never at launch — hence here rather than inside
            // `applyActivationPolicy`, which `init` also calls.
            if !isMenuBarOnly {
                NSApplication.shared.activate(ignoringOtherApps: true)
                showWindow?()
            }
            noteInteraction()
        }
    }

    let tap = SystemAudioTap()

    // `@ObservationIgnored` because no view observes a task handle, and
    // because @Observable rewrites tracked properties into computed ones,
    // which cannot carry an isolation annotation.
    //
    // `nonisolated(unsafe)` so that `deinit` — which is not main-actor
    // isolated — can cancel them. Safe for the usual reason: deinit runs only
    // once the last reference is gone, so nothing else can be touching these.
    // Every other access is on the main actor.
    @ObservationIgnored var startingAt: ContinuousClock.Instant?
    @ObservationIgnored nonisolated(unsafe) var stateTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) var pollTask: Task<Void, Never>?

    public init(store: PresetStore = PresetStore()) {
        self.store = store
        observeStateChanges()
        outputDevices = tap.outputDevices()
        inputDevices = tap.inputDevices()

        presets = store.loadPresets()
        rules = store.loadRules()

        // Settings are restored before anything starts, so the first buffer
        // rendered is already the user's sound rather than a flat one they
        // then watch snap into place.
        let state = store.loadState()
        activePresetID = state.activePresetID
        appMix = state.appMix
        parameters = state.parameters.normalised()
        themeID = ThemeRegistry.theme(id: state.themeID).id
        analyzerMode = state.analyzerMode.flatMap(AnalyzerMode.init(rawValue:)) ?? .spectrum
        isIdleTimeoutEnabled = state.isIdleTimeoutEnabled ?? true
        panelOrder = Self.restoredPanelOrder(from: state.panelOrder)
        if let savedEnabled = state.enabledPanels {
            enabledPanels = Set(savedEnabled.compactMap(RackPanelKind.init(rawValue:)))
                .union([.amplifier])
        }
        if let savedFullWidth = state.fullWidthPanels {
            fullWidthPanels = Set(savedFullWidth.compactMap(RackPanelKind.init(rawValue:)))
        }
        if let savedFullHeight = state.fullHeightPanels {
            fullHeightPanels = Set(savedFullHeight.compactMap(RackPanelKind.init(rawValue:)))
        }
        isMenuBarOnly = state.isMenuBarOnly ?? false
        micMonitor = state.micMonitor ?? MicMonitor()
        isPoweredOn = state.isPoweredOn ?? true
        refreshResponseCurve()

        // `didSet` does not fire for an assignment inside an initialiser, so
        // the mode restored above has to be pushed to the engine by hand. The
        // Dock policy restored alongside it is *not* applied here: this runs
        // while the `@State` holding it is being constructed, which is before
        // `NSApplication` exists at all. `startShell()` applies it once there
        // is an application to apply it to.
        applyAnalyzerMode()

        foregroundAppBundleID = foregroundMonitor.currentBundleID
        foregroundMonitor.onChange = { [weak self] bundleID in
            guard let self else { return }
            self.foregroundAppBundleID = bundleID
            self.evaluateAutoSwitch()
        }
        foregroundMonitor.start()

        // Last, once everything the first session is built from has been
        // restored. Deliberately here rather than in `startShell()`, which the
        // window's own `.task` calls: an amplifier that only powers on if a
        // window happened to open is one that does nothing at all when Rack is
        // launched into the menu bar, or by the login item, or with its window
        // left closed from the last quit. Nothing below the actor boundary
        // touches `NSApplication`, so this is safe to run before there is one.
        if isPoweredOn { start() }
    }

    deinit {
        stateTask?.cancel()
        pollTask?.cancel()
        stateSaveTask?.cancel()
    }

}
