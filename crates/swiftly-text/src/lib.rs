// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Text for the shared Swiftly Rust UI: font loading, shaping and layout (parley), glyph rasterisation (swash) and a
//! glyph atlas that plugs into swiftly-render.
//!
//! ```no_run
//! use swiftly_render::{Color, DrawList};
//! use swiftly_text::{Align, FontSystem, GlyphAtlas, TextStyle};
//!
//! let mut fonts = FontSystem::new();
//! let mut atlas = GlyphAtlas::new(1024);
//! let style = TextStyle::new(17.0, 600);
//! let text = fonts.layout("Frieren", &style, Some(140.0), Some(2), Align::Start);
//! let mut list = DrawList::new(200.0, 60.0, 2.0);
//! atlas.begin_frame();
//! atlas.draw(&text, &mut list, 10.0, 10.0, Color::WHITE);
//! ```

#![deny(missing_docs)]

mod atlas;
mod edit;
mod fonts;
mod input;
mod layout;
mod style;

pub use atlas::{AtlasStats, GlyphAtlas, SUBPIXEL_BINS};
pub use edit::{
    Display, MASK, Outcome, Preedit, PreeditSpan, PreeditStyle, TextEditor, is_rtl_text,
};
pub use fonts::{FontSystem, INTER_VARIABLE};
pub use input::{Clipboard, EditKey, MemoryClipboard, Mods, TextInputEvent};
pub use layout::{ELLIPSIS, LineInfo, TextLayout};
pub use style::{Align, LineHeight, TextStyle};
