//
//  RackAtomics.h
//
//  Lock-free primitives for passing values between the audio thread and
//  everyone else.
//
//  WHY THIS TARGET EXISTS
//
//  Swift's `Synchronization.Atomic` is macOS 15.0 or newer, and Rack targets
//  macOS 14.4. The alternatives were to raise the deployment floor, add a
//  package dependency, or accept torn reads on shared counters. This is about
//  forty lines and has none of those costs.
//
//  Storage is a plain scalar rather than a C11 `_Atomic` field, because Swift
//  cannot import a struct with an `_Atomic` member — it becomes opaque and
//  unusable from Swift. Access goes through Clang's `__atomic_*` builtins,
//  which are defined on ordinary lvalues and generate exactly the same
//  instructions. Every field is naturally aligned, which is what makes the
//  operations single-instruction on arm64.
//
//  All of these are safe to call from the realtime thread: no allocation, no
//  locks, no libc.
//

#ifndef RACK_ATOMICS_H
#define RACK_ATOMICS_H

#include <stdbool.h>
#include <stdint.h>

// MARK: - 64-bit counter
//
// Monotonic counters written by the audio thread and read by the UI. Relaxed
// ordering is correct here: the values are independent, and a reader that sees
// a slightly stale count is displaying a statistic, not making a decision.

typedef struct { uint64_t _storage; } RackAtomicU64;

static inline void rack_u64_init(RackAtomicU64 *a, uint64_t value) {
    __atomic_store_n(&a->_storage, value, __ATOMIC_RELAXED);
}

static inline uint64_t rack_u64_load(const RackAtomicU64 *a) {
    return __atomic_load_n(&a->_storage, __ATOMIC_RELAXED);
}

static inline void rack_u64_store(RackAtomicU64 *a, uint64_t value) {
    __atomic_store_n(&a->_storage, value, __ATOMIC_RELAXED);
}

static inline void rack_u64_add(RackAtomicU64 *a, uint64_t delta) {
    __atomic_fetch_add(&a->_storage, delta, __ATOMIC_RELAXED);
}

/// Release store, paired with `rack_u64_load_acquire`. Relaxed is NOT
/// sufficient for the spectrum ring's write cursor: the release is what
/// guarantees the samples written into the ring are visible to the analysis
/// thread before the cursor that names them is. Without it the reader can
/// legally observe an advanced cursor over stale audio.
static inline void rack_u64_store_release(RackAtomicU64 *a, uint64_t value) {
    __atomic_store_n(&a->_storage, value, __ATOMIC_RELEASE);
}

static inline uint64_t rack_u64_load_acquire(const RackAtomicU64 *a) {
    return __atomic_load_n(&a->_storage, __ATOMIC_ACQUIRE);
}

// MARK: - 32-bit word
//
// Used for OSStatus values and for float bit patterns (peak levels), which are
// moved across the boundary as their raw bits rather than as floats.

typedef struct { uint32_t _storage; } RackAtomicU32;

static inline void rack_u32_init(RackAtomicU32 *a, uint32_t value) {
    __atomic_store_n(&a->_storage, value, __ATOMIC_RELAXED);
}

static inline uint32_t rack_u32_load(const RackAtomicU32 *a) {
    return __atomic_load_n(&a->_storage, __ATOMIC_RELAXED);
}

static inline uint32_t rack_u32_load_acquire(const RackAtomicU32 *a) {
    return __atomic_load_n(&a->_storage, __ATOMIC_ACQUIRE);
}

static inline void rack_u32_store(RackAtomicU32 *a, uint32_t value) {
    __atomic_store_n(&a->_storage, value, __ATOMIC_RELAXED);
}

static inline void rack_u32_store_release(RackAtomicU32 *a, uint32_t value) {
    __atomic_store_n(&a->_storage, value, __ATOMIC_RELEASE);
}

/// Store `value` only if it is greater than what is already there. Used for
/// peak metering, where the audio thread reports a maximum that the UI drains.
/// The loop is wait-free in practice: it only spins if another thread wins the
/// race, and only one thread ever writes.
static inline void rack_u32_store_max(RackAtomicU32 *a, uint32_t value) {
    uint32_t current = __atomic_load_n(&a->_storage, __ATOMIC_RELAXED);
    while (value > current) {
        if (__atomic_compare_exchange_n(&a->_storage, &current, value,
                                        true, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {
            return;
        }
        // `current` now holds the value that was actually there; retry.
    }
}

/// Read and reset in one step, so a meter drains what it displays.
static inline uint32_t rack_u32_exchange(RackAtomicU32 *a, uint32_t value) {
    return __atomic_exchange_n(&a->_storage, value, __ATOMIC_RELAXED);
}

/// Ordered exchange, for the triple buffer's slot index. Relaxed is NOT
/// sufficient there: the acquire half is what guarantees the coefficients
/// written into a slot are visible before the index naming that slot is.
static inline uint32_t rack_u32_exchange_ordered(RackAtomicU32 *a, uint32_t value) {
    return __atomic_exchange_n(&a->_storage, value, __ATOMIC_ACQ_REL);
}

// MARK: - Flag

typedef struct { bool _storage; } RackAtomicBool;

static inline void rack_bool_init(RackAtomicBool *a, bool value) {
    __atomic_store_n(&a->_storage, value, __ATOMIC_RELAXED);
}

static inline bool rack_bool_load(const RackAtomicBool *a) {
    return __atomic_load_n(&a->_storage, __ATOMIC_RELAXED);
}

static inline void rack_bool_store(RackAtomicBool *a, bool value) {
    __atomic_store_n(&a->_storage, value, __ATOMIC_RELAXED);
}

/// Release store, paired with `rack_bool_exchange_ordered`. Used for a render
/// reset request. Triple-buffer publication uses one combined index/dirty word.
static inline void rack_bool_store_release(RackAtomicBool *a, bool value) {
    __atomic_store_n(&a->_storage, value, __ATOMIC_RELEASE);
}

/// Test-and-clear in one step, so the reader cannot see the same publication
/// twice and cannot miss one.
static inline bool rack_bool_exchange_ordered(RackAtomicBool *a, bool value) {
    return __atomic_exchange_n(&a->_storage, value, __ATOMIC_ACQ_REL);
}

// MARK: - Pointer
//
// Phase 2 publishes DSP parameters by swapping a pointer to an immutable value.
// Acquire/release ordering is required there and relaxed is NOT sufficient:
// the release pairs with the acquire to guarantee that everything written into
// the pointed-to block is visible to the audio thread before the pointer is.

typedef struct { void *_storage; } RackAtomicPointer;

static inline void rack_ptr_init(RackAtomicPointer *a, void *value) {
    __atomic_store_n(&a->_storage, value, __ATOMIC_RELAXED);
}

/// Acquire load. Pairs with `rack_ptr_store_release`.
static inline void *rack_ptr_load_acquire(const RackAtomicPointer *a) {
    return __atomic_load_n(&a->_storage, __ATOMIC_ACQUIRE);
}

/// Release store. Everything written before this call is visible to a thread
/// that subsequently acquire-loads this pointer.
static inline void rack_ptr_store_release(RackAtomicPointer *a, void *value) {
    __atomic_store_n(&a->_storage, value, __ATOMIC_RELEASE);
}

/// Swap in a new pointer and hand back the old one, so the writer knows which
/// block is now safe to reclaim.
static inline void *rack_ptr_exchange_acq_rel(RackAtomicPointer *a, void *value) {
    return __atomic_exchange_n(&a->_storage, value, __ATOMIC_ACQ_REL);
}

#endif /* RACK_ATOMICS_H */
