# Rack — Deep Code Quality Audit

Scope: the whole tree. `git log` has no commits, so every file under `Sources/` and
`Tests/` is the change set under review.

**Verdict: not approved.** The module architecture is genuinely good and the
enforcement around it is better than most codebases ever get. The *implementation
inside* those modules has drifted a long way from it. Four files are over 1,000
lines, one function is 1,075 lines, and there are two blocks of code that are
byte-identical apart from the word "Reverb" being replaced by "Delay".

Findings are ordered by how much structure they cost, not by how easy they are to fix.

---

## 1. `EngineController` is a 1,543-line god object

`Sources/AppCore/EngineController.swift` — one `@Observable final class`, lines
140–1682.

It currently owns: engine lifecycle, device policy, microphone policy, feedback
policy, preset/session persistence, panel layout state (order, full-width set,
full-height set), theme selection, Dock activation policy, login-item state, hotkey
legends, the analyzer mode, the display-standby state machine, a 30 Hz poll loop,
spectrum and goniometer draining, meter ballistics for five meters, and a
470-line hand-written forwarding facade over `DSPParameters`.

That is at least six types wearing one name. It is also the file every future
feature will touch, which is how it got here.

**The measurable core of it:**

| shape | count |
|---|---|
| `get { parameters.x } set { update { $0.x = newValue } }` forwarders | 30 |
| `xxxDisplay: String` formatters | 28 |
| `xxxRange: ClosedRange<Double>` pass-throughs to AudioCore statics | 12 |

Roughly lines 592–1055 — about 470 lines — is that table written out by hand.

### 1a. The stated reason for the facade does not hold

`EngineController.swift:616-618`:

> Individually settable properties rather than key paths into `DSPParameters`, so
> that a screen never has to name an AudioCore type. That is what keeps the App
> target's only import AppCore.

This is not what is happening:

- `RackPanels.swift` and `RackScreen.swift` are in **`Sources/AppCore/`**, the same
  module as `EngineController`, which already imports `AudioCore`. Naming
  `DSPParameters` there costs nothing and the boundary check does not object.
- The `App` target (`RackApp.swift`, 145 lines) reads exactly two things off the
  engine: `showWindow` and `startShell()`. It touches none of the 30 forwarders.
  Deleting all of them cannot affect its imports.
- The invariant is already broken anyway. `public func update(_:(inout DSPParameters) -> Void)`
  (line 599), `public var reverbPreset: ReverbPreset` (865) and
  `public var delayPreset: DelayPreset` (910) all name AudioCore types in public API.

So 470 lines are being maintained to protect a boundary that the boundary checker
does not enforce, that the code already crosses, and that the only target it would
apply to never approaches.

### 1b. The code-judo move

The facade *does* buy one real thing: writes go through `update {}`, which
normalises, recomputes the response curve, publishes to the audio thread, and
schedules a save. That must survive. The hand-written expansion must not.

Keep the behaviour, delete the table:

```swift
@dynamicMemberLookup
public final class EngineController {
    public subscript<V>(dynamicMember keyPath: WritableKeyPath<DSPParameters, V>) -> V {
        get { parameters[keyPath: keyPath] }
        set { update { $0[keyPath: keyPath] = newValue } }
    }
}
```

Every call site (`engine.compressorRatio`, `engine.reverbWetAmount`, …) compiles
unchanged. Observation granularity is unaffected — all 30 forwarders already read
the same single stored `parameters`, so `@Observable` tracks exactly what it tracks
today. That is 30 properties gone in one edit.

The 28 `xxxDisplay` properties are four idioms repeated: plain 1-dp, signed 1-dp,
integer percent, integer milliseconds (plus one ratio). Formatting belongs on the
readout, not on the controller. Give `Readout`/`LabelledReadout` a format:

```swift
public enum ReadoutFormat { case decibels, signedDecibels, percent, milliseconds, ratio }
```

That is another 28 properties gone, and it puts presentation in DesignSystem where
the rest of it lives.

The 12 `xxxRange` pass-throughs are one-liners returning an AudioCore static
(`{ Compressor.thresholdRangeDecibels }`). Per 1a, the panels can name `Compressor`
directly. Gone.

**~470 lines → ~15.** Then split what remains along the seams that are already
there as `// MARK:` headers: `EngineController+Layout` (panel order/width/height,
theme, ~120 lines), `EngineController+Monitoring` (poll loop, standby, drains,
meter ballistics, ~300 lines), `EngineController+Shell` (Dock policy, login item,
hotkeys, ~90 lines). What is left is an engine controller of about 350 lines that
you can actually hold in your head.

---

## 2. `ReverbEngine` and `DelayEngine` are the same type written twice

This is the clearest defect in the codebase and it is verifiable mechanically.

`ReverbRenderState.swift:221-303` and `Delay.swift:297-369`. Substituting the
effect name in one and diffing against the other produces **differences in comment
lines only**. The stored properties, the crossfade gain semantics, `silence()`,
and the entire body of `process(inputLeft:inputRight:coefficients:crossfadeCoefficient:)`
— the preset-switch guard, the `targetIsA.toggle()`, the weight handling — are
identical, token for token. About 80 lines.

`Delay.swift:298-299` even says so out loud: *"is the same problem with the same
solution, just over a simpler voice."* That comment is correct and is the argument
for extracting it, not for copying it.

The same holds one layer up. `rackProcessReverb` (`TapRenderContext.swift:824-885`)
and `rackProcessDelay` (887-941) are also identical modulo the name — the idle
check, the wake-and-silence, the two `rackSmooth` calls, the wet/dry mix, the
fade-to-idle test. Another ~55 lines. `rackProcessDelay`'s own doc comment says it
*"mirrors `rackProcessReverb` exactly."*

**~135 lines of exact duplication, in the one part of the codebase where a divergence
between the two copies is a bug you hear rather than a bug you see.**

### The fix

The *voices* genuinely differ — `ReverbVoiceState` is a four-line FDN with pre-delay,
`DelayVoiceState` is a single line — which is exactly why the generic works. Only
the crossfade machinery is common:

```swift
protocol CrossfadeVoice {
    associatedtype Coefficients
    var currentPresetIndex: Int32 { get }
    static func allocate() -> Self
    func deallocate()
    mutating func reconfigure(to coefficients: Coefficients)
    mutating func process(inputLeft: Float, inputRight: Float) -> (Float, Float)
    mutating func silence()
}

struct CrossfadeEngine<Voice: CrossfadeVoice> { /* the 80 lines, once */ }

typealias ReverbEngine = CrossfadeEngine<ReverbVoiceState>
typealias DelayEngine  = CrossfadeEngine<DelayVoiceState>
```

And the send, once:

```swift
struct WetDrySendState { var wetGain: Float = 0; var dryGain: Float = 1
                         var isActive = false; var crossfadeCoefficient: Float = 0 }

@inline(__always)
func rackProcessSend<E: CrossfadeVoice>(...)
```

so `TapRenderContext` holds `reverbSend: WetDrySendState` and
`delaySend: WetDrySendState` instead of eight loose parallel fields
(`reverbWetGain`, `reverbDryGain`, `reverbActive`, `reverbCrossfadeCoefficient`,
and the four delay twins at lines 137–174).

**One realtime caveat, and it is a real one:** this must specialise, not dispatch
through a witness table. Both engines are used from the same module as their
definition, so a release build will specialise, but do not take that on faith —
check the SIL, or assert it the way `DSPBlockTests` already asserts the
`DSPBlock.sections` layout. That test file establishes the right precedent for
proving a realtime assumption rather than commenting it.

---

## 3. `TapRenderContext.swift` (1,459 lines) holds the render graph apart from the effects it renders

Every effect is currently split across three places:

| | lives in |
|---|---|
| ranges + `XCoefficients.compile` | `Saturation.swift`, `Compressor.swift`, … |
| mutable render state | `TapRenderContext` struct fields, lines 98–190 |
| the per-sample kernel | `rackProcessX` in `TapRenderContext.swift` |

Adding one effect means editing `TapRenderContext` in three separate regions
(state fields, the `rackApplyChain` call list, a new `rackProcessX` several hundred
lines away) plus `DSPBlock` plus the effect's own file. That is the tax that
produced finding 2 — copying `rackProcessReverb` was simply cheaper than doing the
five-site edit properly.

**Remedy.** Move each `rackProcessX` and its state into the file that already owns
that effect. `TapRenderContext.swift` should then hold only: the shared context
struct, the non-realtime reader extension (211–300), `rackRender`, `rackApplyChain`,
and the genuinely shared primitives (`rackWalkStereoPairs`, `rackMeasureLevels`,
`rackMeasureCorrelation`, `rackAccumulate`). That is a ~500-line file describing the
graph, with seven ~80-line files describing the nodes — and `rackApplyChain` becomes
the single readable statement of what the chain *is*, which is what it is trying to
be already.

Consider splitting `TapRenderContext` (the struct) from `TapRender` (the graph)
while you are in there; they are different concerns sharing a filename.

---

## 4. Core Audio device enumeration runs on the main actor, in the poll loop

`EngineController.swift:1449-1451`:

```swift
self.audioProcesses = tap.audioProcesses()
self.outputDevices  = tap.outputDevices()
self.inputDevices   = tap.inputDevices()
```

All three are `public nonisolated func` on `SystemAudioTap`
(`SystemAudioTap.swift:665, 698, 749`), so they execute on the caller's
executor — here, `@MainActor`, inside a `Task` that inherits main-actor isolation.

`AudioDevices.outputDevices()` does, per device: `outputChannelCount`, `uid`,
`name`, `nominalSampleRate`, plus an `aggregateSubDeviceUIDs` membership walk.
`AudioProcesses.all()` does a property read per process. The code's own comment two
lines up (1436-1438) acknowledges the cost — *"a Core Audio round trip per process"* —
and then makes the calls synchronously on the UI thread anyway, every 5 seconds,
forever.

`nonisolated` here reads as "cheap, no isolation needed." It means the opposite:
these are the three most expensive calls on the object and the annotation is what
lets them land on the main actor unnoticed.

**Remedy.** One `async` gather off the main actor, then a single hop back. That also
fixes the unnecessary serialisation on the next two lines
(`await tap.controlledApplicationIDs()` then `await tap.isMicHeldForFeedback()`) —
five independent reads currently done one after another. The same applies to
`drainSpectrum` / `drainGoniometer` at 1429-1430, which are independent and awaited
in sequence.

---

## 5. `scheduleStateSave()` secretly runs the standby state machine

`EngineController.swift:404-410`:

```swift
func scheduleStateSave() {
    lastInteractionAt = ContinuousClock.now
    if isDisplayIdle { exitDisplayIdle() }
    stateSaveTask?.cancel()
    ...
}
```

Three responsibilities under a name that describes one: record an interaction, wake
the display, debounce a JSON write. The comment concedes the coupling —
*"Every interaction funnels through here, so this is where a sleeping display wakes."*
That is true today by coincidence of call sites, not by construction. The first
future caller that persists without being an interaction (a migration, a restore, a
background sync) silently cancels standby; the first interaction that does not need
persisting silently cannot wake the display.

This is also the only wake path in the codebase — grep for `exitDisplayIdle` returns
this line, `toggleDisplayIdle`, and the `isIdleTimeoutEnabled` setter. A user-visible
state machine hanging off the side of a save debouncer.

**Remedy.** Two functions:

```swift
private func noteInteraction() {
    lastInteractionAt = .now
    if isDisplayIdle { exitDisplayIdle() }
    scheduleStateSave()
}
func scheduleStateSave() { /* persistence only */ }
```

Call `noteInteraction()` from `update {}` and the other interaction paths. The
standby machine then lives in one place with a name that says what it is.

---

## 6. `start()` and `rebuild()` duplicate session bring-up, and have already drifted

`SystemAudioTap.swift:313-327` vs `575-596`. Both run the same nine-step sequence:
create → publish → start → assign → bump generation → set spectrum flag → set
goniometer flag → watch device → set state → schedule liveness check.

They are not the same:

- `start()` calls `beginMonitoring(session)`, which does `monitor.watch(...)`
  **and** starts the `monitorTask` that consumes `monitor.events`.
- `rebuild()` calls only `monitor.watch(device:)`.

That happens to work because `beginMonitoring` guards `monitorTask == nil` and a
rebuild only follows a start. It is a load-bearing coincidence between two copies of
a sequence, with nothing recording that it is one. `rebuild()` also bumps
`sessionGeneration` twice where `start()` bumps once — defensible, but it is another
divergence a reader has to reconstruct.

**Remedy.** One `private func adopt(_ session: TapSession) throws` holding the
sequence; `start()` and `rebuild()` differ only in their error handling and retry
policy, which is the actual difference between them.

---

## 7. `RackPanels.swift` (1,307 lines) and the knob/readout duplication

The per-panel `View` split is right and the header comment explaining the
`@Observable` dependency-set problem is the best documentation in the repo. The file
is still too big, and the reason is mechanical: 19 `RotaryControl(` and 25
`LabelledReadout(` sites, most of them in the same shape.

`CompressorPanel` (319-410) is the clean example — a `GridRow` of five knobs, then a
`GridRow` of five readouts, with **every label string typed twice**: `"Threshold"`
in the knob and `"Threshold"` in the readout, ten strings for five controls, kept in
sync by hand. The same pattern repeats in `AmplifierPanel`, `SaturationPanel`,
`LimiterPanel`.

**Remedy.** One descriptor, in AppCore:

```swift
struct ParameterControl {
    let label: String
    let keyPath: WritableKeyPath<DSPParameters, Double>
    let range: ClosedRange<Double>
    let format: ReadoutFormat
    let unit: String?
    let help: String
    var detentAtCentre = false
}
```

`CompressorPanel` becomes a five-element array and one `KnobBank(controls:)` that
emits both `GridRow`s from the same source — the label can then only be written
once. Combined with finding 1's `ReadoutFormat`, this collapses the knob-plus-readout
clusters across four panels.

**Scope this honestly.** Do *not* force `AmplifierPanel`'s mixed knob sizes,
`AnalyzerPanel`'s mode switch, or `SoundFieldProcessorPanel`'s preset rows through
the table — those are genuinely bespoke and a table that has to grow a case for each
of them is worse than what is there now. The uniform "row of N knobs over row of N
readouts" clusters are the whole of the target.

Split the remainder by panel group: `RackPanels+Dynamics.swift`,
`RackPanels+Analyzer.swift`, `RackPanels+Library.swift`. `AnalyzerPanel` alone is
240 lines and does not belong in a file with `AppearancePanel`.

Minor, while you are in there: lines 753–826 are indented at two spaces where the
rest of the file uses four.

---

## 8. The test suite

`Tests/RackTests/RenderPathTests.swift` is **1,087 lines containing one function**,
`runRenderPathTests()`, holding 27 `Check.suite` blocks. A 1,075-line function body
is a 1,075-line function body whether it is production code or not; this is the file
future contributors will read to learn how the render path is meant to behave.
Split it by concern (chain order, metering, streams, feedback guard).

`Tests/RackTests/main.swift` carries a hand-maintained list of 26 `runXxxTests()`
calls (lines 77-102). A new test file that compiles but is never added to that list
silently never runs, and nothing fails. Given the harness is already bespoke
(`Check.swift`), have `Check.suite` self-register at file scope and let `main.swift`
run whatever registered, so the registry cannot fall out of date.

---

## What is working, and should not be touched

Worth stating plainly, because most of it is better than the findings above suggest:

- **The boundary enforcement is exemplary.** `check-boundaries.sh` as a *prebuild*
  command rather than a cached one, rules 5 and 6 catching `Color.teal` and
  `.font(.title)` alongside hex literals, and the comment recording the Phase 2
  violation that motivated rule 4 — this is how architectural intent should be kept
  alive. Every finding above is inside a module, not across one.
- **The per-panel `View` split** and the reasoning behind it (`RackPanels.swift:4-30`).
- **Dark themes delegating structure to their light counterparts** (`RackSteelDark`,
  `BauhausDark`) rather than copying it. That is exactly the discipline findings 2
  and 6 are missing.
- **`DSPChain.sections` as the single description of the chain**, with
  `FrequencyResponse` built from the same call so the on-screen curve cannot drift
  from the running filters.
- **`advance<Value: Equatable>`** (1673) — a real abstraction that earns its keep,
  applied five times.

---

## Blockers before merge

1. **Finding 2** — delete the duplicated crossfade engine and wet/dry send. Two
   copies of realtime code that must stay in step is not a style question.
2. **Finding 1** — the 470-line facade goes, and `EngineController` comes under
   ~600 lines. The justification comment at 616-618 should be corrected or removed
   either way, since it is currently wrong.
3. **Finding 4** — get Core Audio enumeration off the main actor.
4. **Finding 5** — separate interaction/standby from persistence.
5. **Finding 6** — one bring-up path.

Findings 3, 7 and 8 are decomposition work that can follow, but should not be
deferred indefinitely: 3 is the structural cause of 2, and 7 is the structural cause
of the label duplication that will produce the next mismatched readout.
