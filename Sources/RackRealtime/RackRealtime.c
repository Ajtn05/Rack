// Everything in RackRealtime is a static inline function in the header, which
// is deliberate: the operations must inline into the caller's frame to be
// worth using on the audio thread. SwiftPM still requires a C target to have
// at least one source file, so this is that file.

#include "include/RackAtomics.h"
