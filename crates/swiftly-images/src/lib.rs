//! Image logic of the Swiftly core, ported from `Packages/JellyfinKit` (`ImageAddress`,
//! `ImageSelection`, `ImageStoreKey`, `ImageSlab`) and the pure parts of `Sources/Shared`
//! (`ImageTone`, `ImageMood`, `NetworkImage`).
//!
//! `decode` and `loader` add the asynchronous side: fetch through the transport seam, decode to RGBA off the
//! UI thread, memory and disk caches. `fixture` is the demo image server.

pub mod address;
pub mod blurhash;
pub mod color;
pub mod decode;
pub mod fixture;
pub mod loader;
pub mod memory;
pub mod mood;
pub mod selection;
pub mod slab;
pub mod store_key;
pub mod tone;
pub mod trim;
mod url_build;

pub use address::{ImageAddress, ImageKind, ImageMetric};
pub use decode::{Decoded, PixelDecoder, RustDecoder, border_for};
pub use loader::{ImageLoader, Limits, LoadError, Priority, Slot};
pub use memory::{Device, MemoryImageCache};
pub use selection::{ImageSelection, Landscape};
pub use slab::{DiskCache, FolderPlate, MemoryPlate, file_name, name};
pub use store_key::{image_key, store_key};
pub use tone::ToneCache;
pub use trim::{MemoryPressure, Trim, TrimLevel};
pub use url::Url;
