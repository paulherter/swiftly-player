// C boundary of the shared Rust UI (crates/swiftly-ios/src/ffi.rs). Main thread only.
// Positions are points, times are seconds of the display link. Calls return a flag set:
// 1 = another frame wanted, 2 = a text field has focus, 4 = the picture changed, 8 = Menu not handled.
#ifndef SwiftlyRust_h
#define SwiftlyRust_h

#include <stdint.h>
#include <stddef.h>

typedef struct Handle SwiftlyRustHandle;

// form: 0 phone, 1 pad, 2 tv. layer: the CAMetalLayer (NULL = headless).
SwiftlyRustHandle *swiftly_rust_create(int32_t form, uint32_t width, uint32_t height, float screen_scale, void *layer);
void swiftly_rust_destroy(SwiftlyRustHandle *h);
int32_t swiftly_rust_resize(SwiftlyRustHandle *h, uint32_t width, uint32_t height, float screen_scale);
int32_t swiftly_rust_insets(SwiftlyRustHandle *h, float top, float left, float bottom, float right);
int32_t swiftly_rust_appearance(SwiftlyRustHandle *h, int32_t dark, int32_t reduce_motion);
// phase: 0 down, 1 move, 2 up, 3 cancel.
int32_t swiftly_rust_touch(SwiftlyRustHandle *h, uint64_t id, int32_t phase, float x, float y, double time_s);
// press: 0 up, 1 down, 2 left, 3 right, 4 select, 5 menu, 6 play/pause.
int32_t swiftly_rust_press(SwiftlyRustHandle *h, int32_t press, int32_t down, double time_s);
// kind: 0 commit, 1 preedit, 2 cancel, 3 backspace, 4 submit, 5 replace the whole field (tvOS text entry).
int32_t swiftly_rust_text(SwiftlyRustHandle *h, int32_t kind, const char *utf8);
size_t swiftly_rust_take_pinches(SwiftlyRustHandle *h, double *out, size_t cap);
// kind: 1 selection, 2 light impact, 3 success.
void swiftly_rust_set_haptics(SwiftlyRustHandle *h, void (*callback)(int32_t));
int32_t swiftly_rust_frame(SwiftlyRustHandle *h, double time_s);


// The real app: callbacks the host provides. Buffers and strings are malloc'ed by the host and freed through release.
typedef struct {
    void *ctx;
    // method, url, header lines "name: value\n", body, body length, timeout ms (0 = default), out length.
    // Returns "S<status>\n<headers>\nx-final-url: <url>\n\n<body>" or "E<kind>\n<text>" (net:<code>, cert, cancelled).
    uint8_t *(*http)(void *ctx, const char *method, const char *url, const char *headers, const uint8_t *body, size_t body_len, int32_t timeout_ms, size_t *out_len);
    char *(*secret_get)(void *ctx, const char *name);
    void (*secret_set)(void *ctx, const char *name, const char *value);
    void (*secret_remove)(void *ctx, const char *name);
    void (*release)(void *ctx, void *ptr);
} SwiftlyPlatform;

// Once, before swiftly_rust_create: switches the app from the demo suite to the real app.
void swiftly_rust_init_live(const SwiftlyPlatform *platform, const char *config_dir, const char *cache_dir, const char *device_name);
// 0 = background (nothing is drawn), 1 = active.
int32_t swiftly_rust_set_active(SwiftlyRustHandle *h, int32_t active);
// Player engine, JSON lines (crates/swiftly-player-surface/src/wire.rs). Free the commands with swiftly_rust_free_string.
int32_t swiftly_rust_engine_event(const char *line);
char *swiftly_rust_engine_commands(void);
void swiftly_rust_free_string(char *s);

#endif
