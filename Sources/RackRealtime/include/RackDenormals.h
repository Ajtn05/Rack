//
//  RackDenormals.h
//
//  Flush-to-zero control for the audio thread.
//
//  WHY THIS MATTERS
//
//  A biquad decaying toward silence does not reach zero; it approaches it, and
//  on the way its state variables become denormal — valid floats below the
//  smallest normalised magnitude. Denormal arithmetic is handled by a slow
//  path, often tens of times slower than normal arithmetic. Twenty-four
//  filters quietly ringing out after a track ends is enough to blow the
//  realtime deadline and produce a dropout, and the symptom (a click, seconds
//  after the music stopped) points nowhere near the cause.
//
//  Setting flush-to-zero makes the hardware round those values to zero
//  instead. The audible cost is nil — we are discussing magnitudes below
//  10^-38 — and the cost of not doing it is a glitch.
//
//  The mode is per-thread and saved/restored around the render call rather
//  than set once, because the IOProc thread is not ours: it belongs to Core
//  Audio, and leaving flush-to-zero set behind us would silently change the
//  arithmetic of anything else that runs on it.
//

#ifndef RACK_DENORMALS_H
#define RACK_DENORMALS_H

#include <stdint.h>

/// The previous FPU mode, to be handed back to `rack_denormals_restore`.
typedef struct { uint64_t saved; } RackDenormalMode;

#if defined(__aarch64__)

// FPCR bit 24 is FZ, flush-to-zero. arm64 has no separate denormals-are-zero
// bit: FZ covers both inputs and results.
#define RACK_FPCR_FLUSH_TO_ZERO (1ull << 24)

static inline RackDenormalMode rack_denormals_disable(void) {
    uint64_t fpcr;
    __asm__ __volatile__("mrs %0, fpcr" : "=r"(fpcr));
    RackDenormalMode mode = { fpcr };
    __asm__ __volatile__("msr fpcr, %0" : : "r"(fpcr | RACK_FPCR_FLUSH_TO_ZERO));
    return mode;
}

static inline void rack_denormals_restore(RackDenormalMode mode) {
    __asm__ __volatile__("msr fpcr, %0" : : "r"(mode.saved));
}

#elif defined(__x86_64__)

#include <pmmintrin.h>
#include <xmmintrin.h>

// FTZ (0x8000) flushes denormal results; DAZ (0x0040) treats denormal inputs
// as zero. Both are wanted; on arm64 the single FZ bit does the job of both.
#define RACK_MXCSR_FLUSH_TO_ZERO 0x8040u

static inline RackDenormalMode rack_denormals_disable(void) {
    RackDenormalMode mode = { (uint64_t)_mm_getcsr() };
    _mm_setcsr((unsigned int)mode.saved | RACK_MXCSR_FLUSH_TO_ZERO);
    return mode;
}

static inline void rack_denormals_restore(RackDenormalMode mode) {
    _mm_setcsr((unsigned int)mode.saved);
}

#else

// Unknown architecture: do nothing rather than guess at a control register.
// The DSP stays correct; it may simply be slower as filters ring out.
static inline RackDenormalMode rack_denormals_disable(void) {
    RackDenormalMode mode = { 0 };
    return mode;
}

static inline void rack_denormals_restore(RackDenormalMode mode) {
    (void)mode;
}

#endif

#endif /* RACK_DENORMALS_H */
