# Audio

Everything a person touching `Sources/AudioCore/` needs to know before they
touch it.

> **Status:** Phase 4 and later feature passes. The capture path, the DSP
> chain, device-change handling and per-application taps are all
> implemented, and so are tape/tube saturation, the compressor, the Sound
> Field Processor's echo, stereo width and crossfeed, and the analyzer's
> VU/correlation/goniometer/oscilloscope/pulse capture — see "The
> saturator", "The compressor" and "The Sound Field Processor" below, and
> "The analyzer's realtime side" near the end of this file. Live microphone
> monitoring is the most recent pass; see "Microphone monitoring".

## Prerequisites

**The binary must be signed.** `AudioHardwareCreateProcessTap` raises the TCC
prompt for audio capture, and that prompt appears only for a signed binary. An
unsigned SwiftPM executable is denied without a dialog, which reads exactly
like a Core Audio bug and is not one.

**And it must be signed with a certificate, not ad-hoc.** TCC records its
answer against the designated requirement. Ad-hoc gives you `cdhash H"…"`,
which changes on every rebuild, so the grant is lost every time you compile.
A certificate gives you `identifier "dev.rack.Rack" and certificate root H"…"`,
which does not. Run this once per machine:

```sh
sh Scripts/make-signing-cert.sh
```

It creates a self-signed identity in its own keychain and `build-app.sh` picks
it up automatically. Details and the undo path are in `ARCHITECTURE.md`.

**`NSAudioCaptureUsageDescription` must be in `Info.plist`.** Without the key
the process is killed rather than prompted.

`NSMicrophoneUsageDescription` is a *different* service, and the two are not
interchangeable: capture covers tapping other processes' audio, microphone
covers reading a physical input device. Both keys are present, because the mic
monitor needs the second one — see "Microphone monitoring" below. If you are
only working on the tap path, the capture key is the one that matters.

**If the prompt stops appearing and capture just fails**, the grant is cached
against the current requirement. Reset it with:

```sh
tccutil reset All dev.rack.Rack
```

**Rack is not sandboxed.** A sandboxed process cannot create an aggregate
device or read `kAudioHardwarePropertyProcessObjectList`. Phases 1 and 4 both
depend on those, so Mac App Store distribution is off the table by
construction. Developer ID is the intended channel.

## Deployment target

The tap API — `CATapDescription`, `AudioHardwareCreateProcessTap`,
`AudioHardwareDestroyProcessTap` — is macOS **14.2+**. SwiftPM's `.macOS(.v14)`
shorthand means 14.0, which is not enough and produces a wall of availability
errors that look like a missing import. `Package.swift` uses the string form,
`.macOS("14.4")`, which is Rack's real floor anyway.

## Setup sequence

The order matters, and several of these flags are the difference between
working audio and silence.

1. **`CATapDescription(stereoGlobalTapButExcludeProcesses:)`** — excluding
   ourselves is what stops the feedback loop: we render to the output device,
   and without the exclusion that render is itself captured.

   **It takes audio object IDs, not PIDs.** The header calls the parameter
   `processesObjectIDsToExcludeFromTap`, and Swift types it `[AudioObjectID]`.
   Passing a raw `pid_t` compiles — `AudioObjectID` is just a `UInt32` — and
   silently excludes nothing. Translate first, with
   `kAudioHardwarePropertyTranslatePIDToProcessObject`, which is a *qualified*
   property read: the PID goes in as qualifier data, not as the object ID.
   It returns `kAudioObjectUnknown` for a process that has never played audio,
   which is not an error.

   - `uuid` — set it explicitly; it is the key the aggregate device refers to
     the tap by.
   - `isPrivate = true` — keeps the tap out of other processes' device lists.
   - `muteBehavior = .mutedWhenTapped` — without this the original signal
     reaches the speakers *as well as* our processed render, and everything
     doubles. The consequence is worth internalising: **while a tap is being
     read, the tapped processes are muted at the hardware.** If our render path
     fails, the Mac goes quiet rather than falling back. That is why
     `TapSession.create()` unwinds a partially built path, why `tearDown()` is
     unconditional, and why Phase 3's hard bypass matters.

2. **`AudioHardwareCreateProcessTap`** — the first call is what triggers the
   TCC prompt. See *Prerequisites* above before concluding it is broken.

3. **`AudioHardwareCreateAggregateDevice`** with a private aggregate:
   - The real output device is the **main** sub-device.
   - `kAudioAggregateDeviceTapAutoStartKey: true`.
   - **No tap list.** See step 5.

4. **`AudioDeviceCreateIOProcIDWithBlock` directly on the aggregate**, then
   `AudioDeviceStart`.

5. **Attach the taps only now**, by setting
   `kAudioAggregateDevicePropertyTapList` on the running aggregate.

### The taps go in last, and that is not a style choice

A private aggregate *created* carrying a tap **does not begin its IO cycle
until one of the tapped processes plays something**. `AudioDeviceStart` returns
`noErr`, the engine reports itself running, and the IOProc is never called —
`buffersRendered` sits at zero indefinitely. The first sound played after that
arrives at a device still spinning up, while `mutedWhenTapped` has already
muted its source, so the front of it is swallowed. Everything after is fine,
which is why the symptom reads as "Rack only works once you have let some audio
through it" rather than as a startup fault.

Measured, counting IOProc callbacks over two seconds with nothing playing:

| | callbacks |
|---|---|
| private, tap in the creation description | **0** |
| private, no drift compensation on the tap | **0** |
| not private, tap in the creation description | 188 |
| private, tap auto-start off | 188 |

So it is `isPrivate` **and** `tapAutoStart` together. Neither of the two working
rows is usable: a non-private aggregate appears in Sound settings and in every
other application's device list, and can be selected as the output — which
routes Rack into itself; and with auto-start off the tap delivers permanent
silence, which is the failure that key exists to prevent.

Attaching afterwards is the third door. Created bare, the aggregate cycles from
the moment it starts like any ordinary device, and the taps go in through
`kAudioAggregateDevicePropertyTapList` once it is running.

Two things to know about that property:

- **It takes UID strings, not the per-tap dictionaries** the creation
  description uses. Handing it dictionaries returns `noErr` and leaves the tap
  list empty — silence again, reported as success.
- Nothing is lost by the plainer form.
  `kAudioAggregateDevicePropertyComposition` reports `{ uid = … }` and nothing
  else for a tap declared at creation *with* `kAudioSubTapDriftCompensationKey`,
  so that flag is not part of what the aggregate remembers either way.

Order is preserved and still load-bearing: the aggregate presents its taps as
input streams in tap-list order, and the render path matches a stream to an
application by position.

One buffer is rendered between `AudioDeviceStart` and the attach. It has no
input, so it is silenced and counted — a lone `silentBuffers` of 1 at startup is
this, and is expected.

`kAudioDevicePropertyStreamConfiguration` does **not** settle in the same breath
as the tap list, so there is no moment in the start path at which asking the
aggregate for its input channel count gives the right answer. The count the
diagnostics panel shows is published from the IOProc instead
(`TapRenderContext.inputChannels`) — which is the more honest number anyway,
since the device's opinion of its streams and the buffers actually arriving are
exactly the two things that can disagree.

### Do not use AVAudioEngine here

Setting `kAudioOutputUnitProperty_CurrentDevice` on a tap-backed aggregate
returns `noErr` and then silently keeps reading the default *input* device. The
call reports success, the graph looks correct, and the audio is wrong. There is
no diagnostic for this beyond knowing it happens.

### Errors

Every `OSStatus` is mapped to `CoreAudioError`, whose message decodes the
four-character code, names the symbolic constant, says which call failed and
what it was trying to do, and adds a hint for the statuses whose cause is not
guessable. `560947818` is `'!obj'` is `kAudioHardwareBadObjectError` is "the
object ID is stale, rebuild rather than retry" — and only the last of those is
actionable.

Use `try someCoreAudioCall(…).orThrow("someCoreAudioCall", "what we were doing")`.

## Lock-free primitives

The audio thread cannot log, allocate, or block, so it publishes counters to
atomics that the UI polls. Swift's `Synchronization.Atomic` is macOS 15+ and we
target 14.4, so `Sources/RackRealtime/` provides the handful we need over
Clang's `__atomic_*` builtins. Storage is a plain scalar rather than a C11
`_Atomic` field because Swift cannot import a struct with an `_Atomic` member.

Counters use relaxed ordering — a stale statistic is a display artefact, not a
decision. The pointer operations use acquire/release, and Phase 2's parameter
publishing **requires** that: the release store is what guarantees the contents
of a new `DSPParameters` block are visible to the audio thread before the
pointer to it is.

## Realtime rules

These apply to anything reachable from the IOProc. They are absolute.

- **No allocation.** No `Array`, no `Dictionary`, no `String`, no boxing.
  Buffers are allocated at setup and reused.
- **No locks.** No mutex, no `os_unfair_lock` held across anything unbounded,
  no `DispatchQueue.sync`.
- **No Swift runtime that can allocate.** No existentials that box, no ARC
  traffic on objects with contended refcounts, no generics that specialize into
  allocation.
- **No `print`.** No logging of any kind on the audio thread. Signalling to the
  UI happens through lock-free atomics that the UI polls.
- **No `try`/`throw`** across the IOProc boundary. Failure is a state flag the
  next buffer reads, not an error propagated out of a callback.

### Parameter passing

The UI thread never touches filter state. Parameters cross the boundary as a
single immutable `DSPParameters` value, compiled into a `DSPBlock` and
published through a **triple buffer** (`ParameterPublisher`).

Three slots are allocated once. Each side advances by *exchanging* its own
index with the shared `published` index, which swaps two of the three and so
keeps all three distinct — and that distinctness is the safety property: the
writer is never writing into the slot being read. A dirty bit in the same
atomic word as the slot index stops the reader swapping when nothing was
published. Exchanging the bit and index together prevents a separate flag
from announcing a publication that the reader already acquired.

A seqlock would have been fewer lines, but its reader retries, and an unbounded
retry is not something to hand a realtime thread. Nothing here waits and there
is no loop: the reader's path is two atomic operations.

Ordering is acquire/release, not relaxed. The release store on the index is
what guarantees the coefficients written into a slot are visible before the
index naming that slot is.

Coefficients are computed off the audio thread — `pow`, `sin` and `cos` have no
business in an IOProc. Publications that only change application/microphone
gains reuse the compiled DSP design. The block also carries sample-rate and
smoothing settings; a rate change is adopted and the effect timing reset by
the audio thread itself. The block is read **once per buffer**, and gains ramp
**per sample** through a one-pole smoother. Per-buffer gain steps are a
discontinuity every 256 samples; a run of them is zipper noise.

### The chain

Fourteen second-order sections per channel, in the amplifier's fixed order:
two tone shelves, then ten EQ bands, then two boost shelves. Preamp, volume,
headroom compensation and balance all fold into a single per-channel gain —
one multiply and one ramp rather than several chasing each other.

Headroom compensation is computed off the audio thread, alongside the
sections themselves: `DSPParameters.headroomCompensationDecibels(sampleRate:)`
sweeps the combined response of every section (excluding the preamp trim,
which is a flat offset the listener sets on purpose) for its highest point,
and that many decibels are folded into the output gain before publication. The
IOProc never sees the sweep, only the number it produced.

`DSPBlock.sections` and `ChannelFilters.sections` are each the **first** stored
property of their struct, so a pointer to the struct is a pointer to the
section array and the realtime path needs no offset arithmetic. `DSPChainTests`
asserts both offsets are zero; if anything is ever inserted above them the
audio thread starts reading gains as coefficients.

### The saturator

A stateless `tanh` waveshaper, dry/wet blended, sitting between the chain
above and the compressor: `rackProcessSaturation` is a separate pass right
after `rackProcess` and before `rackProcessCompressor`. Warmth is the
amplifier stage's own character, and compressing already-saturated
harmonics — tape into a bus compressor — is what glues them together,
rather than compressing a clean signal and saturating the result.

`tanhf` runs once per sample on the audio thread, the same class of
transcendental cost this file already accepts for the compressor's
`log10f`/`powf` below — not an allocation or a lock, and there is no way
to saturate honestly without a nonlinearity. Drive and makeup gain are
designed off the audio thread in `SaturationCoefficients.compile`; the
realtime path only ever reads the compiled coefficients.

Disabled is bit-identical passthrough, not merely close: the pass is
skipped entirely when the compiled `mixWet` is zero, the same guarantee
`DSPChain` keeps for a flat EQ band. See `Saturation.swift`.

### The compressor

A stereo-linked feedforward compressor: the detector reads `max(|left|,
|right|)`, never each channel on its own, specifically so gain reduction
never pulls the stereo image apart the way an unlinked detector would. The
static curve is the standard soft-knee formula (Giannoulis, Massberg &
Reiss), computed in the log domain — which means a real `log10f`/`powf` per
sample. That is a genuine cost next to the multiply-only stages elsewhere in
the chain, but it is not an allocation, a lock, or anything else this file
forbids, and there is no way to compute a compression ratio honestly without
it: a ratio is a slope in dB. See `Compressor.swift`.

Attack and release smooth the *reduction signal itself*, not the raw
detector — the standard topology, and the reason it sounds like compression
rather than distortion. It is `rackProcessCompressor`, a separate pass right
after `rackProcess` and before the Sound Field Processor: compressing a
reverb tail or an echo repeat rather than the dry signal driving them would
pump audibly, so it runs first. The current reduction is published to
`compressorReductionBits` — a plain "last write wins" atomic, not a
drain-and-reset accumulator like the peak/VU sums, because a gain-reduction
meter reads a live gauge, not something to accumulate.

### The Sound Field Processor

Two independent effects sharing one rack unit — reverb and echo — mixed in
one after the other, plus a stereo width control shaping whatever the two of
them hand off to it.

**Reverb.** A four-line feedback delay network per channel — a lossless
Hadamard mix, a per-line decay gain sized so
`feedbackGain(lineSamples:decaySeconds:sampleRate:)` alone determines a
preset's RT60, and a shared one-pole damping filter in the feedback path
that shortens the high end on top of that. See `Reverb.swift` for the design
maths and `ReverbRenderState.swift` for the realtime state.

**Echo.** A genuinely separate, simpler engine, not the reverb reused with
different numbers: the Hadamard matrix that makes a reverb's tail diffuse is
exactly what would prevent a clean, countable repeat, so this is one delay
line per channel with feedback and damping, no cross-mixing. Left and right
run independent tap times, which is what turns a plain echo into the
"Ping-Pong" preset — no cross-channel feedback coupling needed, just two taps
landing at different moments. See `Delay.swift`.

Both effects are a separate pass over the buffer `rackProcess` (by way of the
compressor) just produced, not another stage threaded through
`rackProcessChannel`: each needs a channel's *partner* on every sample, and
mixing in after volume and balance means turning the system down turns the
send down with it. Both passes share their buffer-walking scaffold —
`rackWalkStereoPairs`, which hands a `(inout Float, inout Float)` closure one
stereo frame at a time and handles the interleaved-vs-deinterleaved layout
decision once, for every stereo effect pass in the chain (reverb, echo,
width, and the correlation/goniometer capture below all use it or its exact
shape).

Every reverb line and every echo line is allocated once, at start, sized to
the worst case across every preset and both channels
(`Reverb.maximumLineSamples(forLine:)` / `maximumPreDelaySamples()`,
`Delay.maximumLineSamples()`); a preset switch only ever changes how much of
that buffer wraps, never its size. Switching presets — reverb or echo —
crossfades over `Reverb.crossfadeSeconds` / `Delay.crossfadeSeconds` (~50 ms
each) between two permanently-allocated voices, never a splice on the buffer
still playing. A voice is only reconfigured once the other one has faded to
inaudibility, so a rapid run of preset changes queues rather than clicks: see
`ReverbEngine.process` and `DelayEngine.process`, which are structurally
identical for exactly this reason — the problem they solve is the same
problem. Delay's damping coefficient is stored *per voice*, not passed in
from the engine, so a voice fading out of a switch keeps chasing the rate it
was designed for rather than the incoming preset's — the same reasoning
`ReverbVoiceState.dampingCoefficient` lives on the voice for.

**Width.** A mid/side rotation over the fully processed signal (reverb and
echo's own stereo image included, not just the dry source) — `mid =
(L+R)/2`, `side = (L−R)/2`, output `L' = mid + side·width`, `R' = mid −
side·width`. Lossless at `width == 1`, collapses toward mono below it,
widens past it. No delay line and no crossfade needed, unlike the two
effects above it: it is a stateless per-sample rotation, smoothed only by
the ordinary 20 ms gain ramp every other knob in the chain uses. See
`rackProcessWidth`.

**Crossfeed.** The chain's actual last stage, after width: bleeds a
treble-rolled-off copy of each channel into its opposite — the fix for
hard-panned recordings sounding harsh on headphones that real speakers
give for free (each ear already hears a little of the other channel,
delayed and shadowed by the head) and headphones do not. The rolloff
reuses `BiquadCoefficients.highShelf` directly rather than a filter shape
of its own — the same shelf design the tone and boost controls use, here
at a fixed corner and depth rather than a user control. Unlike width this
needs persistent filter state: two `Biquad`s live directly on
`DSPRenderState` rather than inside either channel's own section cascade,
because each one shapes a signal that crosses between channels —
`crossfeedLeftFilter` rolls the left signal off on its way to bleeding
into the right ear, `crossfeedRightFilter` the mirror. The blend is capped
well short of a full 1:1 mix (crossfeed is meant to soften an image, not
collapse it), and the direct path is cut a little as the blend rises so
raising the effect does not also raise perceived loudness. See
`Crossfeed.swift`.

### Denormals

`rack_denormals_disable()` at IOProc entry, restored on exit. A biquad decaying
toward silence produces denormals, and denormal arithmetic runs on a slow path
— twenty-four filters ringing out after a track ends is enough to miss the
deadline. The mode is saved and restored rather than set once because the
IOProc thread belongs to Core Audio, not to us.

### The analyzer's realtime side

Peak and VU accumulation (`rackMeasureLevels`) are always-on: the extra work
is one add per sample, already paid for measuring peaks, so there is no
reason to gate it behind which analyzer mode is selected.

Correlation and the goniometer are different — genuinely stereo quantities,
not independent per-channel ones — so each gets its own pass:
`rackMeasureCorrelation` accumulates Σ(L·R), Σ(L²), Σ(R²) into atomics that
`drainCorrelation()` turns into a coefficient on demand; `rackGoniometerPush`
copies raw stereo pairs into a ring (`GoniometerRing`, the same
single-producer/single-consumer, lap-detecting shape `SpectrumRing` uses,
just keeping both channels instead of summing to mono — a goniometer's whole
subject is the relationship between them). Both are gated: the goniometer
ring has its own `isEnabled` flag, off unless `AnalyzerMode.needsGoniometerCapture`
says otherwise, the same "off costs one relaxed load" contract
`SpectrumRingBuffer.isEnabled` already keeps. The oscilloscope reads the
identical ring — a waveform is the same raw pairs, just plotted as amplitude
against time instead of L against R, so it shares the goniometer's capture
rather than needing one of its own.

Ring payloads are atomic, with each stereo pair packed into one 64-bit word.
The writer announces its upcoming range before replacing any samples, so a
snapshot can reject an overwrite that has begun but not yet advanced the
completed cursor. Acquire payload reads and the final range check prevent
accepted windows from combining different laps.

VU and correlation use cumulative Double totals behind a versioned atomic
snapshot. Their control-side drains subtract the previous snapshot, keeping
the sums and counts together without clearing memory the audio thread is
updating. Only the non-realtime reader retries, at most four times per poll.

None of the three needs the FFT, so selecting VU, correlation-only,
goniometer, or the oscilloscope all turn the spectrum capture off exactly
the way Response does — see `AnalyzerMode.needsSpectrumCapture` in `UI.md`.

Pulse is a fourth mode that reads the spectrum, alongside Spectrum and
Mix — but it adds nothing here. `BeatMeter` reduces the same published
bands to one bass-onset number entirely on the analysis side, in
`Sources/AppCore/`, with no capture of its own.

## Per-application control

`kAudioHardwarePropertyProcessObjectList` gives the process objects Core Audio
can route for. `kAudioProcessPropertyIsRunningOutput` separates "Music is
playing" from "Music is open" — a process object exists for anything that has
*ever* played.

An application under individual control gets its own tap
(`CATapDescription(stereoMixdownOfProcesses:)`) and is **excluded from the
global tap**, which carries everything else. The aggregate's tap list is
therefore: slot 0 the global tap, then one per controlled application, in a
fixed order.

That order is load-bearing. The aggregate presents its taps as input streams in
tap-list order, so input buffer *i* is tap *i*, and that is how the render path
matches a stream to an application. If the buffer count and the stream count
disagree, `rackMixStreams` **declines and falls through to the plain copy**
rather than guessing — guessing there would apply one application's volume to
another's audio.

Per-application gain is applied *before* the mix, so it is a source control;
everything else in the chain is on the master.

### What costs a rebuild

Changing an application's volume is a republish and costs nothing. Changing
*which* applications are individually controlled means a different set of taps,
which means a new aggregate device and a brief gap. Only that case rebuilds.
The comparison uses the original bounded request, including failed taps,
rather than the successful subset. Moving a fader therefore does not retry a
failed tap or rebuild because an over-budget application has no stream.

### Identity

Settings are keyed on **bundle ID**, because process IDs and Core Audio object
IDs both change when an app restarts and a per-app volume that reset on every
launch would be useless. Processes with no bundle — command-line tools, some
helpers — fall back to the PID, and that key is deliberately not durable:
inventing a stable identity for a helper process would attach the setting to
the wrong thing later. Those are shown with their raw PID.

A per-process tap that fails takes the whole session back to global-only rather
than failing the start. An app that spawns helpers, or exits between being
listed and being tapped, costs the user per-app control and not their audio.

## Microphone monitoring

A physical input can be mixed into the output alongside everything else —
`MicMonitor` holds the settings, the Input panel drives them. The microphone
is **not** a tap: it is real hardware, so it joins the aggregate as a second
*sub-device* beside the output device, drift-compensated for the same reason a
tap is (the main sub-device owns the clock; anything else needs reconciling
against it).

**`NSMicrophoneUsageDescription` must be in `Info.plist`.** A distinct TCC
service from `NSAudioCaptureUsageDescription` — that one covers tapping other
processes, this one covers reading an input device. Same failure mode if it is
missing: killed rather than prompted.

### The mic takes stream 0, ahead of the taps

Measured on real hardware, and the opposite of what the tap-list ordering
above would lead you to expect. An aggregate carrying one mic sub-device and
one process tap presents:

| input stream | | |
|---|---|---|
| 0 | the **microphone** | mono, 2048 B |
| 1 | the global tap | stereo, 4096 B |

— even though the mic is *appended* to the sub-device list after the output
device, and the tap list is a separate key entirely. Core Audio documents none
of this. `TapSession.micStreamIndex` names it once rather than spelling `0` at
each site that needs it, and `streamGains(for:micMonitor:)` builds the gain
array in that order: mic first when present, then the global tap, then the
controlled applications.

Getting this wrong is not subtle, and it is already instrumented: the render
path finds a mono buffer where it expected a stereo one, half-fills the
output, zero-pads the rest, and **`mismatchedBuffers` climbs on every
callback**. That is exactly how the ordering was discovered — a spike that
added the sub-device and reported each raw input buffer's peak, channel count
and byte size to the Diagnostics panel. The peaks alone were not enough (a
quiet tap and a quiet mic look identical); the *shapes* settled it.

### Mono into a stereo mix

`rackMixStreams` gives a mono source its own loop: each sample is written to
both channels, which centres it. Summing element-wise — the path every stereo
stream takes — would send the mic's first half to alternating L/R samples and
leave the rest of the frame untouched, which is noise rather than a voice.

The branch keys on the *buffer* describing itself as mono, not on the stream
index, so it stays correct even if `micStreamIndex` is ever wrong.

### Feedback

Monitoring a microphone through speakers is an acoustic feedback loop by
construction. The limiter bounds how loud a howl gets; it does not prevent one.
So the feature defaults to **off**, and a saved session that says nothing about
it decodes to off.

Two further defences sit behind that, and they are different in kind because
they answer different questions. Both live in `Feedback.swift`.

**Can a loop exist at all?** Usually macOS will simply tell us.
`kAudioDevicePropertyDataSource` on the output reports a four-character code,
and the vocabulary is not in any header — measured on real hardware:

| | |
|---|---|
| `hdpn` | External Headphones |
| `ispk` | MacBook Air Speakers |
| `imic` | MacBook Air Microphone |
| `emic` | External Microphone |

`FeedbackRisk.decide` turns that into `none` (headphones), `loudspeaker`, or
`unknown`. On a `loudspeaker` the microphone is **left out of the aggregate
entirely** rather than included at a gain of zero — a mic that is in the
aggregate is a mic being captured as far as the system is concerned, so that
would light the recording indicator and spend one of the sixteen stream slots
for a signal nobody can hear.

`unknown` is deliberately *not* treated as dangerous. Most external interfaces
have one output and do not describe it, so blocking every USB DAC and every pair
of AirPods to catch the one Bluetooth speaker would make the feature useless far
more often than it would help. Those are left to the detector below, which does
not have to guess in advance.

The hold releases itself: `micDeviceForSession()` resolves to nil while held,
and the device-change decision compares the microphone *actually in the
aggregate* against what that resolves to now — so plugging headphones in is
already a rebuild-worthy change, with no separate path to write.

It is defeatable (`MicMonitor.isFeedbackGuardEnabled`, on by default, and a
missing key in a saved file decodes to **on** — the mirror image of
`isEnabled`). A guard with no override is worse than no guard: someone with
monitors across the room at a sensible level has a real reason to overrule it,
and an app that refuses outright is one they work around by abandoning the
feature.

**Is a loop starting right now?** For everything the rule above cannot classify,
`rackFeedbackDuck` watches the microphone's own signal — before its gain, which
is what closes the loop properly, since ducking lowers what the speakers emit
and the very next buffer measures the result.

Three conditions have to hold *together*, and the conjunction is the whole
design, because each one alone fires on ordinary speech:

- **loud enough** — above −45 dB, so room tone drifting upward is not chased;
- **growing** — the 30 ms envelope more than 4 dB above the 800 ms one;
- **tonal** — peak over RMS below 2.2. A howl collapses toward a pure tone,
  whose crest factor is √2 and stays there. Speech runs 3–10. This is the
  condition that actually separates the two rather than merely delaying the
  response to a loud voice.

Four consecutive suspicious buffers (~30 ms) trigger a −10 dB cut, compounding
on each further trigger down to −34 dB, held 0.75 s, then recovered over 1.5 s
and **snapped to exactly unity** near the end — a one-pole never arrives, and a
microphone left a fraction of a decibel down for the rest of the session is a
bug nobody would ever manage to report.

There is still no echo cancellation and none is planned. Rack is unusually well
placed for it — it has the reference signal for free, sample-aligned in the same
IOProc, which is the hard part elsewhere — but an adaptive filter with
double-talk detection and nonlinear residual suppression is a much larger
feature. Frequency shifting, the other classic trick, is rejected outright: it
buys about 6 dB and detunes everything, which is fatal for an app whose job is
playing back system audio faithfully.

## Surviving device changes

`DeviceMonitor` installs Core Audio property listeners for the default output
device, the default **input** device, the device list, and the attached device's
nominal sample rate. They fire on a private serial dispatch queue — never the
audio thread.

The input listener exists because the microphone monitor follows the system
default until someone opens the picker, and nothing watched that property:
changing the input in Sound settings left Rack monitoring whichever device
happened to be default when the session was built, with no event to notice it
by.

Two details that bite:

- `AudioObjectRemovePropertyListenerBlock` matches on **block identity**. Hand
  it a fresh closure with the same body and the old listener stays installed
  for the life of the process. The blocks are retained for exactly this reason.
- Notifications arrive in **bursts**. Connecting AirPods emits default-device
  and device-list changes over about a second. Acting on each one means
  repeatedly destroying and rebuilding an aggregate device while the user waits
  for sound, so changes are debounced 300 ms — each event cancels and re-arms
  the pending work, and a burst produces one rebuild.

What a change means is decided by `DeviceChangeDecision`, which is pure and
tested without hardware:

| | |
|---|---|
| Same device, same rate, same microphone | ignore — most notifications concern nothing of ours |
| Different device | rebuild the tap and aggregate |
| Different microphone | rebuild — which mic is in the aggregate is a sub-device, not a gain |
| Same device, new rate | **retune**: recompile coefficients, reset the running state, keep the plumbing |
| No default device at all | ignore, and wait — briefly true mid-removal |

The microphone row covers three situations that previously produced no reaction
at all: the system default input changing under a monitor that follows it, the
chosen interface being unplugged (which rebuilds to a session with *no*
microphone rather than one wired to a device that is gone), and that interface
being plugged back in. It is compared against what is actually in the running
aggregate, not against the saved setting — the setting does not change when the
hardware behind it does.

Retuning matters. A rate change invalidates every coefficient, because they are
designed against a specific rate, but the tap, the aggregate and the IOProc are
all still valid. Recompiling costs a fraction of a rebuild and does not
interrupt the stream. Running state is cleared either way: it holds samples from
a stream that no longer exists, and feeding those into filters designed for a
different rate is a burst of noise at precisely the moment someone is listening
for a glitch.

**Cleared by request, not by reaching in.** `retune` runs on the actor that
handles device notifications; the filter delay lines, the reverb and echo
networks and the compressor and limiter envelopes all belong to the audio
thread. Calling `reset()` from the actor is a write to state an IOProc is
halfway through reading. `TapRenderContext.resetRequested` is an atomic flag the
top of `rackRender` consumes, which is the only moment nothing is half-written.

And it clears *everything*. `dsp.reset()` covers the biquads and the crossfeed
filters and stops there — leaving the reverb's eight feedback lines and the
echo's four, which are where state persists longest, holding seconds of audio at
the old rate. The same routine serves the NaN fault path below, where it matters
more: a NaN in a feedback line is the case that never recovers on its own.

Rebuilds tear down **before** creating. Building the new path first would be
quicker, but two taps with `mutedWhenTapped` would be live at once and the
aggregate auto-starts its tap on creation — so the overlap is a window of
*silence*, not a gap. A short gap is the better failure. A failed rebuild
retries with growing delay; between attempts the old tap is already destroyed,
so the user hears normal audio rather than nothing while we wait.

`EngineReadout.lastStartMilliseconds` reports the measured width of the gap.

### Proving the path actually runs

Every route to a running engine — a cold start, a rebuild, a retune — ends by
asserting `.running`, and that assertion used to rest on "every Core Audio call
returned `noErr`". That is a weaker claim than it looks, and the tap stall above
is the proof: nothing failed, and the IOProc was never called.

So the assertion is now checked against the counter that can settle it.
`confirmAudioIsFlowing` samples `buffersRendered`, waits
`livenessWindow` (400 ms — dozens of callbacks at any buffer size Core Audio
actually delivers), and looks again. `LivenessVerdict.decide` is the rule, kept
pure and tested for the same reason `DeviceChangeDecision` is:

| | |
|---|---|
| the counter moved | live — nothing to do |
| it did not, and we are under the limit | rebuild and look again |
| it did not, and we are at the limit | `.failed`, with an error that says so |

Four details are load-bearing, and three of them were learned the hard way:

- **One callback is proof.** The counter climbs on every IOProc invocation
  whatever the audio turns out to be, so this asks "is the path running", not
  "is anything playing". A silent Mac is healthy and must never be rebuilt.
- **It is bounded.** A check that is wrong, or a machine where callbacks
  legitimately stop, must cost a couple of gaps and then a visible fault —
  never an endless teardown-and-rebuild loop, which would be much worse than
  the condition it is chasing.
- **It runs after `.running` is announced, not before.** The window would
  otherwise be added to every start.
- **The window is sized for the slowest legitimate start, not the fastest
  success.** A live path clears the bar two hundred times over, so the only
  number that matters is how long a healthy aggregate may take to produce its
  *first* callback. Starting one over the built-in speakers has to wake an
  amplifier: measured at ~290 ms on this machine (475 callbacks in the first
  5.36 s is 5.07 s of audio). At 400 ms the check rebuilt perfectly healthy
  sessions that were merely still spinning up. Two seconds.

Two reentrancy hazards, both real:

- A check sleeping through its window while a device change rebuilds the path
  underneath it must not judge the new session on the old one's evidence. A
  session generation counter catches that.
- **The observer must not perform the recovery.** `rebuild()` begins by
  cancelling the liveness task, so a check that called it directly cancelled
  the task it was itself running on; `rebuild()`'s own cancellation guard then
  returned immediately and left the engine in `.starting` with no session and
  nothing alive to notice. A watchdog that hangs the thing it is watching is
  worse than no watchdog. `judgeLiveness` is therefore synchronous and hands
  the rebuild to a separate `recoveryTask`.

Worth knowing when reproducing any of this: **a microphone in the aggregate
hides the stall**, because a mic sub-device is a live input stream in its own
right and the aggregate cycles on it regardless of the tap. So does anything
playing at the moment the session is built. A quiet Mac with no mic monitor is
the configuration that shows it.

### Bypass

Three independent bypasses, either of which routes audio through untouched:
`DSPParameters.isBypassed` (the user's switch), the atomic flag on the render
context (the panic path, settable without going through parameter compilation),
and the automatic trip below. A fault on one path cannot mean silence.

**The automatic trip.** If a rendered buffer contains anything that is not a
finite number, the chain engages the panic bypass, clears **all** the running
state — filters, reverb and echo lines, both envelopes — counts a fault, and
silences that one buffer. NaN in a delay line is permanent
— it propagates and the channel never recovers — and what reaches the DAC is at
best noise. A click is recoverable; full-scale noise into headphones is not.

Detecting it needs care. A comparison against NaN is always false, so NaN never
becomes the peak and inspecting the peak afterwards would never see it. The
meter loop therefore also accumulates a magnitude sum, which addition *does*
propagate NaN and infinity through, and one test at the end of the buffer
catches both — one add per sample, no branch in the inner loop.

Upstream of that, coefficient design refuses to publish an unstable set: a
filter outside the stability triangle does not sound wrong, it grows without
bound. A suspect design degrades to the identity, so the worst case is a band
that does nothing.

Flat parameters are **bit-transparent**, not merely close: a 0 dB band compiles
to exact identity coefficients rather than to the cookbook formula's rounding,
and unity gain multiplies by exactly 1.0. `DSPChainTests` runs the null test and
checks for bit equality.
