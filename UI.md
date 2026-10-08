# UI

Everything a person touching `Sources/AppCore/` or `Sources/DesignSystem/`
needs to know before they touch it. `AUDIO.md` covers the realtime side this
layer reads from; `ARCHITECTURE.md` covers the module boundaries this layer
sits inside of.

## EngineController: the view model

`Sources/AppCore/EngineController.swift` is `@Observable` and is the only
object a screen holds a reference to. Everything a panel reads is a property
on it or on something it owns.

Two kinds of state live on it, and they get to it differently:

- **What the user sets.** A single `parameters: DSPParameters` value, mutated
  only through `update(_ transform: (inout DSPParameters) -> Void)`. Every
  knob and toggle on screen goes through this — it compiles, normalises,
  publishes to the audio thread, and schedules a session save, all in one
  call. Safe to call on every frame of a slider drag: publication is a
  compile plus two atomics away, and the audio thread just takes the most
  recent block. A screen never mutates `parameters` directly; it calls a
  named property setter (`engine.reverbWetAmount = 0.4`) that itself calls
  `update`.
- **What the engine measures.** `readout: EngineReadout`, filled in from
  `SystemAudioTap.Diagnostics` on every poll (`apply(_:elapsed:)`,
  `~30 Hz`), plus a family of ballistic structs — `meterLeft`, `vuLeft`,
  `correlation`, and so on — each of which is *stateful*, carrying its own
  filtered value across polls rather than being a snapshot. See "The
  ballistics pattern" below.

Ranges live here too, not in the views: `engine.compressorThresholdRange`,
`gainRange`, `toneRange`, `boostRange`. "A screen should not have to name an
`AudioCore` type to know how far a knob turns" is the literal comment on the
first of these — it is also the reason `Sources/AppCore/RackPanels.swift`
does not `import AudioCore`. If a panel needs a `ClosedRange<Double>` or a
preset's raw parameters, add a computed property to `EngineController`
first; do not reach for the `AudioCore` type directly from a view.

## Panels: one `View` type per rack unit

Every unit on screen — `AmplifierPanel`, `CompressorPanel`,
`SoundFieldProcessorPanel`, `AnalyzerPanel`, and so on, all in
`RackPanels.swift` — is its own `View` struct holding only `let engine:
EngineController`, not a computed property on one shared screen body. The
file's own top comment explains why: `@Observable` tracks dependencies per
*view body invocation*. One shared `body` that happened to read
`engine.meterLeft` anywhere in a long expression tree made *every* property
read anywhere else in that body a dependency too — and the meters and the
spectrum update up to thirty times a second, so a panel with nothing to do
with a meter (Presets, Appearance, Output) was still being fully
reconstructed on every tick. Splitting each panel into its own `View` gives
each one a separate dependency set: `AnalyzerPanel` and `DiagnosticsPanel`
legitimately redraw at poll rate, everything else redraws only when the
user's own actions change what it reads.

**When adding a control that reads a fast-changing property, put it in the
panel that already redraws for that reason, not a new one, unless the
control genuinely belongs somewhere else.** Adding a live meter to a panel
that currently redraws only on user action turns that panel into one that
redraws thirty times a second too.

`RackScreen.swift` composes the panels into the actual window. It no longer
lists them in a fixed order or hand-pairs them into tiled rows: it iterates
`engine.panelOrder` (an array of `RackPanelKind`, the user-reorderable order)
and lays the result out with `RackTileLayout`, which decides row breaks from
each panel's own measured width. See "Layout: order, tiling and the size
toggles" below. A `RackUnit` (the visual frame every panel sits inside —
title, optional status line, optional header control, content) is a
`DesignSystem` component; panels never draw their own border or background.

## Layout: order, tiling and the size toggles

Panels are not laid out in a fixed stack any more. Three pieces cooperate,
and each keeps its concern out of the others:

- **`RackPanelKind`** (`Sources/AppCore/RackPanelKind.swift`) is one `enum`
  case per panel — a stable identity that survives being dragged elsewhere
  and being written to disk, independent of where the panel currently sits.
  Its `String` raw value is what `PresetStore.SessionState` stores; the case
  is what `RackScreen.panelView(for:)` switches on to build the actual view.
  `defaultOrder` is what a fresh install shows and the fallback a saved order
  uses for any kind it does not name; `defaultIsFullWidth` is true only for
  the two panels (`amplifier`, `analyzer`) whose content is the widest thing
  on the rack. **Adding a panel means: a case here, an entry in
  `defaultOrder`, and a case in `panelView(for:)`'s `switch` — nothing else,
  because everything downstream iterates `allCases` or `panelOrder`.**

- **`EngineController` owns the user's layout choices** as three pieces of
  persisted state, each saved through `scheduleStateSave()` the same way
  every other setting is: `panelOrder: [RackPanelKind]` (mutated by
  `movePanel(_:before:)`), `fullWidthPanels: Set<RackPanelKind>` (toggled by
  `toggleFullWidth(_:)`), and `fullHeightPanels: Set<RackPanelKind>` (toggled
  by `toggleFullHeight(_:)`). All three are restored leniently in `init` —
  an unknown raw value from an older or newer save is dropped rather than
  failing the decode, and `restoredPanelOrder(from:)` appends any kind the
  save predates. `PresetStore.SessionState` carries the matching optional
  `panelOrder` / `fullWidthPanels` / `fullHeightPanels` string arrays, all
  absent-means-default so a state file written before these existed still
  decodes.

- **`RackTileLayout`** (`Sources/AppCore/RackTileLayout.swift`) is a custom
  SwiftUI `Layout` that packs the ordered panels into rows. It does not guess
  widths from a formula — it *measures* each panel with
  `sizeThatFits(.unspecified)` and only ever places a panel in a row where
  the sum of measured minimums still fits, so a row it builds can never ask a
  panel to clip. A panel tagged full-width (via the `IsFullWidthKey`
  `LayoutValueKey`, which `RackScreen` sets from `fullWidthPanels`) always
  starts its own row. `columnWidths(for:)` gives each panel in a row its own
  measured minimum first, then splits any surplus evenly — the fix for an
  earlier even-split that starved wide-content panels while inflating narrow
  ones.

`RackScreen` wires the user's choices into each panel through **three
environment values `RackUnit` reads**, rather than init parameters threaded
through all ten panel types (the same reasoning the file's own doc comments
give: reordering and sizing are screen-level concerns the panels have no
reason to know about):

- `rackUnitDragPayload` — a `String?`; when set, the panel's *title block*
  (not its whole header) becomes a `draggable` drag source, and the panel's
  whole body a `dropDestination`, so dragging one panel's title onto another
  reorders the rack. Scoped to the title block on purpose: a knob or fader in
  the body keeps its own drag gesture.
- `rackUnitWidthToggle` — a `RackUnitWidthToggle` (an `isFullWidth` flag plus
  a `@MainActor` closure). Drawn in the header as a small icon button: one
  bar for full-width, two for tiling beside others.
- `rackUnitHeightToggle` — a `RackUnitHeightToggle`, the vertical twin. When
  on, the panel takes `maxHeight: .infinity` so it stretches to match the
  tallest panel in its row (content pinned to the top); off, it stops at its
  own natural height. Off by default for every panel — there is no natural
  "should be full height" case the way there is for width.

**Tooltips.** Individual dials and meters carry a one-line `.help(...)`
explaining what they do — Volume, the saturator's drive/mix knobs, the
compressor's five knobs and its GR meter, the Sound Field Processor's
mix/width/crossfeed knobs, the equalizer's fader bank, and every analyzer
display (spectrum, VU, response, overlay, pulse, goniometer, oscilloscope,
the L/R and phase meters), plus each application's own volume slider. These are the built-in macOS hover tooltip, invisible
until hovered, so they add nothing to normal use. They are the one exception
to "the legend says what a control is": a legend names it, the tooltip
explains it. Keep them one plain sentence, and where a number has direction
(phase +1/−1, attack vs. release) say which way.

## The ballistics pattern

This is the one pattern to understand before adding a new meter, and every
meter in the app follows it exactly:

1. **`AudioCore` publishes a raw, uncalibrated value.** A linear peak
   amplitude, a mean rectified magnitude, a phase-correlation coefficient, a
   gain-reduction reading in dB — whatever the audio thread can compute
   cheaply, undecorated. It does not know what a VU meter's scale looks like
   or what a "warning zone" is. See `SystemAudioTap.Diagnostics`.
2. **`AppCore` owns a small ballistic struct that turns the raw value into
   something worth looking at.** `PeakMeter`, `VUMeter`, `CorrelationMeter`
   each do three things: convert to the display's actual domain (linear to
   dB, say), apply an attack/release filter so the needle doesn't strobe at
   poll rate, and expose a `position: Double` in `0...1` via a
   `static func position(forX:) -> Double` the struct's own tests check
   directly. **This is where the scale lives.** `VUMeter`'s scale is a
   hand-placed nonlinear table matching `NeedleMeter.vuMarks`' five printed
   positions; `CorrelationMeter`'s is a straight line, because every real
   phase meter's face is evenly divided. Neither is computed by the
   component that draws it.
3. **`DesignSystem` draws `position`, and knows nothing else.** `NeedleMeter`
   takes a `Double` in `0...1` and a set of `Mark`s to print — nothing in
   that file names a decibel or a VU. This is the same boundary
   `ResponseCurve`'s own doc comment states for itself: "nothing in this
   file names a frequency, a decibel or a filter."

Two consequences worth internalising:

- **A ballistic's own math is directly testable without a running engine.**
  Every one of these structs has `static` methods taking plain numbers, so
  `VUMeterTests`, `CorrelationMeterTests`, `CompressorTests` test the curve
  itself — soft-knee continuity, one-pole settling time, scale anchor
  points — without touching `EngineController` or Core Audio at all. When a
  ballistic's transform is *inline* inside a computed property instead of a
  named `static func`, pull it out first; `EngineController.goniometerPoint(for:)`
  and `oscilloscopeValue(for:)` exist specifically so the rotation math and
  the mono-sum math are each one function call away from a test, not
  buried in a `.map { }` a test would have to instantiate a whole
  `EngineController` to reach.
- **`DesignSystem` components get reused across genuinely different
  domains.** The compressor's gain-reduction meter and the analyzer's VU
  needles are the same `NeedleMeter`, differing only in which `Mark`s and
  which `position` formula feed it. The oscilloscope is not a new component
  at all — it hands `ResponseCurve` (built for the frequency-response curve)
  a waveform, because a waveform is exactly "position against value" too.
  Before writing a new `DesignSystem` component, check whether an existing
  one already draws the right *shape* and just needs different data.

## `AnalyzerMode`

`Sources/AppCore/AnalyzerMode.swift` is one `enum` with eight cases —
`spectrum`, `vu`, `response`, `overlay` ("Mix"), `pulse`, `goniometer`
("Scope"), `oscilloscope` ("Wave"), `off` — and two computed properties
that gate what the audio thread does: `needsSpectrumCapture` (true for
`spectrum` and `overlay`, which is the spectrum bars with the response
curve traced over them, and for `pulse`, which reduces the same bands to
one bass-onset number rather than drawing them — see `BeatMeter`) and
`needsGoniometerCapture` (true for `goniometer` and `oscilloscope`, which
share one ring — see `AUDIO.md`). `off` needs neither: selecting it takes
capture out of the IOProc entirely, not just the display.

Peak and VU stay live in every mode — they read accumulators the audio
thread always maintains, the same ones the always-on L/R bar under the main
display reads — so switching to VU or the oscilloscope costs nothing that
switching to Response doesn't already cost.

Adding a ninth mode means: a case here, `needsSpectrumCapture` /
`needsGoniometerCapture` if it needs either capture path, a case in
`AnalyzerPanel.display`'s `switch` in `RackPanels.swift`, and — if it needs
new capture — the `AudioCore` half described in `AUDIO.md`. `pulse` is the
worked example of the "no new capture needed" case: it reuses
`needsSpectrumCapture`'s existing bands, and the whole of its own logic —
`BeatMeter` — lives in `Sources/AppCore/`.

## Themes

Covered fully in `Sources/DesignSystem/Themes/README.md`. The one fact worth
repeating here: **no color, font, corner radius, spacing value, or icon name
outside that directory.** `Scripts/check-boundaries.sh` fails the build on
one, so a panel or component that needs a new visual token adds it to the
`Theme` protocol and every theme file, not a literal at the call site.
