# Sandbox code review — 2026-10-01

Reviewed the audio render path, parameter publication, analyzer handoffs,
engine lifecycle, asynchronous monitoring, application mix, persistence,
module boundaries, and test harness. Changes concentrate on confirmed
correctness problems and avoidable work in the audio/control paths.

All commands ran inside the existing session sandbox. No desktop tools,
application launch, audio capture, device selection, signing, or permission
changes were used. The test executable's new `--headless` option skips both
AppKit appearance tests and SwiftUI screenshot rendering.

## Fixed findings

| Priority | Problem and effect | Change |
|---|---|---|
| P1 | The triple buffer published its index and dirty flag separately. A reader could acquire a newer slot between clearing the flag and swapping the index, then consume the flag for that same publication on its next read and swap back to older parameters. | Exchange the dirty bit and slot index as one atomic word. |
| P1 | A null input pointer with a nonzero byte count left previous output samples untouched. | Silence the entire destination and count the mismatch. |
| P1 | Retuning wrote smoothing values into audio-owned state while a callback could read it. Clearing effect tails also left the same reverb/echo preset configured with old-rate line lengths. | Publish the rate and smoothing coefficients in the DSP block. The render thread adopts them together and installs new-rate effect timing with cleared state. |
| P1 | A device notification could cancel the task performing a rebuild during retry backoff, leaving the engine in `starting`. A retry started by another caller could also resume after `stop()`. | Preserve an active rebuild when notifications arrive, coalesce follow-up changes, reject duplicate starts, and guard retries with the session generation. |
| P2 | Analyzer rings shared non-atomic sample storage. Their completed-cursor check missed overwrites that had begun but not yet published completion. | Store mono samples atomically and stereo pairs in one atomic word. Announce the upcoming write range and reject snapshots overlapping it. Payload acquire/release ordering ties an observed overwrite to its announced range. |
| P2 | VU/correlation draining reset shared sums while the audio thread performed load/add/store updates. That could resurrect drained values, lose contributions, or combine sums and counts from different windows. | Keep cumulative Double totals and read coherent versioned snapshots. Drains subtract the previous snapshot. Only the control reader retries, with a four-attempt limit. |
| P2 | Asynchronous monitoring could apply analyzer data after cancellation/standby, or restart polling after the engine stopped. | Recheck cancellation, running state, standby state, and analyzer mode after awaits. |
| P2 | Application-volume edits compared requested taps with the successfully created subset. A failed tap or an over-budget request therefore caused another aggregate rebuild on each fader edit. | Retain and compare the original bounded request; successful taps remain the source of actual stream gains. |

## Efficiency

`ParameterPublisher` caches the DSP design against normalized parameters and
sample rate. Application/microphone gain-only publications now reuse it,
avoiding repeat filter design and the 120-point headroom sweep. Stream gains
and feedback settings are still applied for every publication. Changes to
DSP settings or sample rate invalidate the cache.

The render path retains fixed allocations and lock-free atomics. New rate
handling performs no exponential design in the callback. Analyzer payloads
use the same amount of storage as their previous Float representation.
Meter snapshots add a small fixed amount of context storage and atomic work;
the audio writer has no retry loop. No percentage speedup is claimed without
a hardware performance profile.

## Validation

- Debug headless suite: **20,620 checks passed**.
- Optimized headless suite: **20,620 checks passed**.
- Full optimized package build, including `Rack`: **passed**; neither the
  application nor a window was launched.
- Module boundary and test registration checks: **passed**.
- Added concurrent stress coverage for 50,000 parameter publications,
  512,000 analyzer frames, and 20,000 rendered meter buffers, plus missing
  input, in-flight ring overwrite, cache invalidation, and rate-transition
  regression coverage.

SwiftPM's nested sandbox was unavailable within this session sandbox, so
builds used `--disable-sandbox` for that inner wrapper. The outer sandbox
remained enforced. Compiler/package caches stayed under `.build`. Release
validation used `-enable-testing` because the custom executable harness
imports internal APIs, and `-debug-info-format none` because debug-symbol
generation was denied by the sandbox.

Hardware lifecycle branches were inspected statically. Live device changes,
microphone behavior, listening tests, UI rendering, and hardware CPU/latency
measurements remain unverified under the requested constraints.
