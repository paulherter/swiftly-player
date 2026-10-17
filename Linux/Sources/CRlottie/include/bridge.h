// **rlottie through its C interface.**
//
// The library itself is C++; `rlottie_capi.h` is the C version shipped with
// it, and only that is included here. Swift cannot use C++ directly, and only
// four calls are needed: load, frame count, frame rate, render a frame.
#include <rlottie_capi.h>
