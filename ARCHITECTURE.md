# Architecture

Rack sits between every app on the Mac and the output device, applying one
shared DSP chain: preamp gain, tone control, ten-band graphic EQ, balance,
boost contour, headroom compensation, tape/tube saturation, a compressor, a
feedback delay network reverb and a separate echo, a stereo width control
and a headphone crossfeed (together the Sound Field Processor), and
per-application volume. See `AUDIO.md` for the realtime side of all of that
and `UI.md` for how it reaches the screen.

It is presented through a skin modelled on a 1980s component hi-fi stack. That
skin is the least important part of the program and the last thing built. The
architecture exists to keep it that way.

## The four targets

```
App/                    executable, wiring only
  └── AppCore/          view models, state, persistence, device policy
        ├── AudioCore/  Core Audio, DSP, realtime.  NO UI IMPORTS.
        │     └── RackRealtime/  C shim: lock-free atomics, denormal control
        └── DesignSystem/  theme protocol, tokens, components.  NO AUDIO IMPORTS.
```

Arrows point downward only. `AudioCore` and `DesignSystem` are leaves and do
not know each other exists.

`RackRealtime` is a support target beneath AudioCore rather than a fifth peer:
nothing else may depend on it. It holds the things the audio thread needs that
Swift cannot express — lock-free atomics (Swift's own are macOS 15+, and Rack
targets 14.4) and flush-to-zero control. The alternatives were raising the
deployment floor, taking a package dependency, or accepting torn reads. It is
two headers of static inline functions.

### App

`@main`, the scene graph, and the object graph handed to AppCore. Nothing else.
If a decision can be made anywhere else, it is made anywhere else. Target size
is a couple hundred lines for the life of the project.

### AppCore

View models, application state, preset persistence, and device policy — the
rules about *which* preset applies to *which* device, as opposed to the
machinery that applies it. This is the only module permitted to see both
AudioCore and DesignSystem, and it is where the two are joined: audio values
in, theme-agnostic view data out.

### AudioCore

The process tap, the aggregate device, the realtime IOProc, and the DSP chain.
Buildable and testable with no window server involved. See `AUDIO.md`.

### DesignSystem

The `Theme` protocol, the semantic tokens, and the skinned components the
screens are assembled from. Components take plain data and callbacks. A
component that knows what a biquad is has been written wrong.

## The boundary rules

**1. AudioCore must not import SwiftUI or AppKit.**

Not a style preference. Realtime audio code has to be reasoned about in terms
of what it allocates and how long it blocks, and a UI framework in scope
invites main-actor hops, ARC traffic, and observation machinery into a context
where all three are bugs. Keeping the frameworks out means the compiler catches
the mistake instead of the user hearing it.

**2. Every target reaches only one level down.**

`App` talks to `AppCore` and stops there; `AppCore` is the only module that may
see both `AudioCore` and `DesignSystem`. This one was added late, after the
Phase 2 screen quietly imported `AudioCore` to read the band frequencies. It
built and it looked harmless — and it meant a Core Audio type was named inside
a view, which is exactly the coupling the layout exists to prevent. AppCore now
restates what a screen needs (`EQBandInfo`), and the check enforces it.

**3. No appearance literal outside `Sources/DesignSystem/Themes/`.**

Rule 5 catches hex strings, which is what was originally specified. Rule 6 was
added in Phase 6, once there were real components to get this wrong in:
`Color.teal` and `.font(.title)` are just as hardcoded as `#00FFEE`, and
arguably worse because they look principled.

No color, font, corner radius, spacing value, or icon name. Everything reads
tokens from an injected theme. A hex string in a view is a skin decision that
has escaped the skin, and every one of them is a line that has to be found and
changed by hand the next time the look changes. The point of the whole
DesignSystem target is that "make it look like a Braun radio" is one new file
and one registry line.

All three are enforced mechanically, not by discipline.

## Enforcement

`Scripts/check-boundaries.sh` fails if:

| # | Check |
|---|-------|
| 1 | `AudioCore` imports `SwiftUI` or `AppKit` |
| 2 | `DesignSystem` imports `AudioCore` |
| 3 | `DesignSystem` imports `AppCore` or `App` |
| 4 | `AudioCore` imports `AppCore`, `DesignSystem` or `App` |
| 5 | Any `.swift` file outside `Sources/DesignSystem/Themes/` contains a six-digit hex literal or `Color(red:` |
| 6 | The same, for named colours (`Color.teal`, `.foregroundStyle(.secondary)`) and system fonts (`.font(.title)`) |

`Plugins/BoundaryCheckPlugin` runs it as a prebuild command on the `App`
target, so a plain `swift build` fails on a violation. It is a *prebuild*
command rather than a cached build command deliberately: the check costs
milliseconds and must never be skipped because SwiftPM decided nothing changed.

Run it standalone in CI with:

```sh
sh Scripts/check-boundaries.sh
```

The plugin is attached to `App` only. Building a single lower target directly
(`swift build --target AudioCore`) skips the check; the full build and CI do
not.

## Building

There is no Xcode project and none is wanted. The package builds with Command
Line Tools alone, and `Scripts/build-app.sh` assembles the `.app` by hand.
Debug and release bundles live in `.build/app/debug/` and
`.build/app/release/`. Use `--universal` for both Apple silicon and Intel;
see [the release guide](docs/RELEASING.md) for archives and notarization.

First time on a machine:

```sh
sh Scripts/make-signing-cert.sh        # once; see Signing below
```

Then:

```sh
sh Scripts/build-app.sh --run          # debug, signed, launched
sh Scripts/build-app.sh --release
swift run RackTests                    # the test suite; see below
```

### Signing

Signing is not optional. `AudioHardwareCreateProcessTap` raises its TCC prompt
only for a signed binary, and a bare SwiftPM executable is not one.

*Which* signature matters just as much, because TCC remembers its answer
against the binary's **designated requirement**, and the two forms differ in
exactly the way that hurts:

| | designated requirement |
|---|---|
| ad-hoc | `cdhash H"…"` |
| certificate | `identifier "dev.rack.Rack" and certificate root H"…"` |

(`build-app.sh` prints the real one on every build.)

The ad-hoc requirement names the code hash, so every rebuild is a different
program as far as TCC is concerned and the audio capture prompt comes back. The
certificate requirement names the bundle ID and the certificate, neither of
which a rebuild touches. Verified rather than assumed: a real source change
alters the code hash (`1bac2554…` → `01d47e12…`) while the designated
requirement comes out byte-identical.

Apple-issued certificates need Xcode to provision, so `make-signing-cert.sh`
generates a **self-signed** one in its own keychain. macOS reports it as
`CSSMERR_TP_NOT_TRUSTED` and `security find-identity -v` will not list it; that
is expected. Chain trust governs Gatekeeper, which does not apply to a locally
built app, and `codesign` signs with it regardless. It is a development
identity and must never be used for distribution.

`build-app.sh` picks an identity in this order:

1. `$RACK_SIGN_IDENTITY` — a real Apple certificate, signed with a timestamp.
2. `Rack Local Signing` — the self-signed identity, hardened runtime, no timestamp.
3. Ad-hoc, with a warning.

Undo everything with `sh Scripts/make-signing-cert.sh --remove`. Re-running the
create step generates a *new* key, hence a new designated requirement, so the
capture prompt returns once.

Debug builds get `com.apple.security.get-task-allow` added to the entitlements,
because re-signing the bundle drops the one SwiftPM applies and a
hardened-runtime binary cannot otherwise be attached to by a debugger.

### Tests

`XCTest` and `Testing` both ship inside Xcode, so `swift test` does not work in
a Command Line Tools–only toolchain. The suite is therefore an ordinary
executable with a small assertion harness in `Tests/RackTests/Check.swift`:

```sh
swift run RackTests
```

Test bodies map onto XCTest one-for-one, so if Xcode is installed later the
harness file is the only thing that has to change.

## The library

Presets, rules and session state live as JSON under
`~/Library/Application Support/Rack/`:

| file | |
|---|---|
| `presets.json` | `[Preset]` — a name plus a full `DSPParameters` |
| `rules.json` | `[AutoSwitchRule]` — `(condition, presetID)` pairs, evaluated top down |
| `state.json` | Active preset, per-app mix, mic monitor settings, current settings, whether the amplifier was left switched on, and the rack's own layout (panel order plus per-panel full-width/full-height choices), so a relaunch resumes where it left off |

Restoring is only half of it. Everything above is loaded into `EngineController`,
but the actor that builds the capture path keeps **its own copy** of the three
pieces a session is built and published from — parameters, app mix, mic monitor
— so restoring into the controller and not handing them across means a freshly
launched engine renders `.flat` with every knob on screen showing something
else. `SystemAudioTap.adopt` takes all three in one call and `start()` makes it
first, so a session is either built before any of it or after all of it.

Rack also powers itself on at launch, unless the last session was explicitly
switched off. It processes every sound the Mac makes, registers a login item and
can live in the menu bar with no window at all, none of which means anything if
opening it leaves the engine waiting to be found. That start is made from
`EngineController.init` rather than from the window's own `.task`, so it does
not depend on a window having opened.

JSON rather than `UserDefaults` because these are meant to be edited and
shared, and that has consequences: output is pretty-printed with sorted keys so
it diffs sensibly, writes are atomic so a crash cannot truncate a library, and
**a file that fails to decode is moved aside rather than overwritten**. Someone
hand-editing a preset will eventually drop a comma, and losing their work as a
punishment for a typo is not acceptable — the bad file is renamed with an
`.invalid-<timestamp>` suffix and the app starts empty.

Per-application volumes are kept in `state.json`, deliberately not in presets.
A preset is a sound worth sharing; "Safari at 40% on this Mac" is not, and
loading someone else's preset must not silently reassign local app volumes. The
mic monitor is there for the same reason, and one stronger: which microphone is
plugged into this Mac is not part of a sound, and a recalled preset must never
be able to switch an input on.

The rule engine is `(condition, preset)` pairs evaluated top down, first
enabled match wins. No specificity scoring and no combining: if two rules could
apply, the higher one does, and the user fixes it by reordering. Anything
cleverer is behaviour that has to be explained rather than read.

## Phase status

| Phase | | |
|---|---|---|
| 0 | Scaffold | **done** |
| 1 | Passthrough tap → aggregate device → IOProc | **done** |
| 2 | DSP chain | **done** |
| 3 | Device management | **done** |
| 4 | Per-application control | **done** |
| 5 | Presets and persistence | **done** |
| 6 | UI, themes, components | **done** |
| 7 | Menu bar shell, login item, hotkeys | **done** |

Past Phase 6 the project moved to feature passes rather than numbered phases.
Each pass follows the same shape: a realtime `AudioCore` piece (a new render
pass or accumulator, always with its own tests) — or none at all, when a
pass can be built entirely from something the audio thread already
publishes — an `AppCore` ballistic or view-model property that turns the raw
value into something a screen can draw, and a `DesignSystem` component or
reused existing one. Landed so far: the VU meter, the phase correlation
meter, the goniometer and oscilloscope analyzer modes, the compressor, the
Sound Field Processor's echo, stereo width and crossfeed, tape/tube
saturation, the Pulse analyzer mode, and live microphone monitoring.
`UI.md` documents the pattern these
all follow; read one of them before starting a new one — the compressor for
a full new realtime pass with its own state, or Pulse (`BeatMeter`) for a
pass that needs no `AudioCore` changes at all because it reuses an existing
capture path.
