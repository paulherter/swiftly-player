// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Drawing foundation of the shared Swiftly Rust UI (Windows, Linux, Android, Android TV).
//!
//! * [`DrawList`] collects [`DrawQuad`]s in painter's order. Coordinates are points; the list carries a scale factor
//!   (pixels per point) that both renderers apply.
//! * [`SoftwareRenderer`] is the pure CPU reference (the oracle for goldens) and writes PNG.
//! * [`WgpuRenderer`] draws the same list with one instanced wgpu draw (WGSL, Vulkan, DX12, GL, Metal), offscreen
//!   with readback or onto a surface.
//! * [`Atlas`] is the interface of the glyph and image pages; text shaping lives in a later crate.
//!
//! Blending happens in sRGB code values (as the Apple apps do), with premultiplied "over".

mod atlas;
mod draw_list;
mod geometry;
mod image;
mod software;
mod video_layer;
mod wgpu_renderer;

pub use atlas::{Atlas, AtlasFormat, DirtyRect, PixelPage};
pub use draw_list::{Border, DrawList, DrawQuad, QuadKind, ShadowStyle};
pub use geometry::{Color, Corners, Fill, LinearGradient, Rect};
pub use image::RgbaImage;
pub use software::{SoftwareRenderer, Sources};
pub use video_layer::VideoFit;
pub use wgpu_renderer::{GpuContext, RenderError, WgpuRenderer};
