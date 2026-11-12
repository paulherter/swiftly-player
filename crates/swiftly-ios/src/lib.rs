//! iPhone, iPad and Apple TV comparison shell of the shared Swiftly Rust UI (W9).
//!
//! `host` is the platform-free core (touch with a pinch seam, tvOS presses, text, insets, appearance, frames) and is
//! unit-tested on the build machine. `ffi` is the C boundary a thin Swift UIKit host calls; on iOS and tvOS `gpu`
//! presents the draw list on the host's `CAMetalLayer` through wgpu/Metal. The same `suite` app runs in the `touch`
//! (390x844-class points) and `tv` (1920x1080 points) forms.

#![deny(missing_docs)]

pub mod host;

mod ffi;
#[cfg(any(target_os = "ios", target_os = "tvos"))]
mod gpu;
pub mod platform;
