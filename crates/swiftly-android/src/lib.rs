//! Android and Android TV shell of the shared Swiftly Rust UI.
//!
//! `host` is the platform-independent core (touch, keys, text, insets, frames in; draw lists out) and is unit-tested
//! on the build machine. `jni_bridge` (Android only) loads the wgpu/Vulkan surface from the Kotlin `Surface` and
//! exposes `host` to the Kotlin `ShellActivity` over six JNI calls. The same `suite` app runs as `--demo app`.

#![deny(missing_docs)]

pub mod host;
pub mod http_wire;

#[cfg(target_os = "android")]
mod engine_bridge;
#[cfg(target_os = "android")]
mod jni_bridge;
#[cfg(target_os = "android")]
mod platform;

/// Stub for the native-activity glue that `winit` links on Android; this shell is hosted by Kotlin, never by it.
#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
#[allow(unsafe_code)]
pub fn android_main(_app: android_activity::AndroidApp) {}
