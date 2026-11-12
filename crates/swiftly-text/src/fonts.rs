//! Font loading: bundled Inter plus the system fallback chain.

use std::sync::Arc;

use parley::fontique::{Blob, GenericFamily};
use parley::{FontContext, LayoutContext};

/// Inter 4.1 variable font (weight and optical-size axes), SIL OFL 1.1, licence in `fonts/OFL.txt`.
pub static INTER_VARIABLE: &[u8] = include_bytes!("../fonts/InterVariable.ttf");

/// The font database and the shaping scratch space. Keep one per UI thread and reuse it.
pub struct FontSystem {
    pub(crate) font_cx: FontContext,
    pub(crate) layout_cx: LayoutContext<()>,
    pub(crate) primary: String,
}

impl FontSystem {
    /// Inter plus every font the system has. Arabic, Hebrew, CJK and the rest come from the system by script
    /// (fontique asks Core Text, DirectWrite or fontconfig).
    pub fn new() -> FontSystem {
        FontSystem::with_font_context(FontContext::new())
    }

    /// Inter only, no system discovery. Deterministic; other scripts have no glyphs (tests for the Latin goldens).
    pub fn bundled_only() -> FontSystem {
        let mut font_cx = FontContext::new();
        font_cx.collection =
            parley::fontique::Collection::new(parley::fontique::CollectionOptions {
                shared: false,
                system_fonts: false,
            });
        FontSystem::with_font_context(font_cx)
    }

    fn with_font_context(mut font_cx: FontContext) -> FontSystem {
        let blob = Blob::new(Arc::new(INTER_VARIABLE));
        let registered = font_cx.collection.register_fonts(blob, None);
        let primary = registered
            .first()
            .and_then(|(id, _)| font_cx.collection.family_name(*id).map(str::to_owned))
            .unwrap_or_else(|| "Inter Variable".to_owned());
        FontSystem {
            font_cx,
            layout_cx: LayoutContext::new(),
            primary,
        }
    }

    /// Registers more font data (for example bundled Noto Arabic later). It joins the families by name and is
    /// found by the script fallback like any system font.
    pub fn register_font(&mut self, data: Vec<u8>) -> usize {
        self.font_cx
            .collection
            .register_fonts(Blob::from(data), None)
            .len()
    }

    /// The name of the primary family ("Inter Variable").
    pub fn primary_family(&self) -> &str {
        &self.primary
    }

    /// The family fontique picks for a generic family on this machine, if any. Used by tests to find out whether a
    /// script has a fallback font.
    pub fn generic_family_exists(&mut self, g: GenericFamily) -> bool {
        self.font_cx.collection.generic_families(g).next().is_some()
    }
}

impl Default for FontSystem {
    fn default() -> FontSystem {
        FontSystem::new()
    }
}
