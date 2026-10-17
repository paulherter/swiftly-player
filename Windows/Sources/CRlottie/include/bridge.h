// **rlottie, through its C interface.**
//
// The library itself is C++; `rlottie_capi.h` is the C version shipped with it,
// and only that is included here. Swift cannot easily use C++, and only four
// calls are needed: load, frame count, frame rate, draw a frame.
#include <rlottie_capi.h>
