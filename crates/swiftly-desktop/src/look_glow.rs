//! The look's glow (`LookGlowLayer`, `.lookGlow()`; `Sources/Shared/LookStore.swift:286-345`): one tone at the top of
//! Start, the library, the Merkliste, search and playlists, drawn as an elliptical gradient behind the page that goes up
//! with the scroll. Nothing at all while the glow is off, which is the original look's default.
//!
//! The look itself (what is shown, who may wear it) is the core's `LookStore` over the settings file; the suite reads it
//! into [`set`] every few hundred milliseconds, the pages read [`current`] and build the glow from it.

use std::cell::Cell;
use swiftly_layout::Alignment;
use swiftly_render::Color;
use swiftly_settings::KeyValueStore;
use swiftly_support::look_store::LookStore;
use swiftly_support::support::SupportStore;
use swiftly_ui::{Node, Paint};

/// What a page needs to draw the glow.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Glow {
    /// The one tone, `0xRRGGBB`.
    pub tone: u32,
    /// The faint second tone of a look with a gradient mark.
    pub tint: Option<u32>,
    /// Opacity at the centre in thousandths (soft 200, bright 320); 0 = no glow.
    pub strength: u16,
}

impl Glow {
    /// Whether anything is drawn.
    pub fn visible(self) -> bool {
        self.strength > 0
    }
}

thread_local! {
    static CURRENT: Cell<Glow> = const { Cell::new(Glow { tone: 0, tint: None, strength: 0 }) };
}

/// Sets the glow the pages draw.
pub fn set(glow: Glow) {
    CURRENT.with(|c| c.set(glow));
}

/// The glow the pages draw.
pub fn current() -> Glow {
    CURRENT.with(Cell::get)
}

/// The glow of what the app shows now: the saved look (or the one being tried on), worn only when the core's rules
/// allow it (a supporter, or the original and picked-up gifts).
pub fn read<S: KeyValueStore + Clone>(settings: S) -> Glow {
    let supporter = SupportStore::new(settings.clone()).status().is_supporter();
    let mut look = LookStore::load(settings);
    let _ = look.change(|s| s.set_supporter(supporter));
    let palette = look.selection().palette();
    Glow {
        tone: palette.glow_color().hex,
        tint: palette.glow_tint().map(|c| c.hex),
        strength: (palette.glow.opacity() * 1000.0).round() as u16,
    }
}

/// How far the page has scrolled as the glow counts it: only the first 300 points matter, by then it is gone.
pub fn scrolled(offset: f64) -> u16 {
    offset.clamp(0.0, 300.0).round() as u16
}

fn colour(hex: u32, alpha: f32) -> Color {
    let ch = |shift: u32| ((hex >> shift) & 0xFF) as f32 / 255.0;
    Color::new(ch(16), ch(8), ch(0), alpha)
}

/// A quarter of a phone's height, grown with the page: 211 pt on a 390 pt wide page (`max(width, 390) * 2.16 * 0.25`).
pub fn reach(width: f32) -> f32 {
    width.max(390.0) * 2.16 * 0.25
}

/// The glow behind a page `width` points wide that has scrolled `scrolled` points: lay it out as the background of the
/// scroll area, clipped to the column. The ellipse starts at the top centre with half axes 0.75 x width and `reach`
/// (the Mac's frame of 1.5 x width by 2 x reach with `endRadiusFraction` 0.5), the faint second tone at the top right
/// reaching 1.2 times further.
pub fn node(glow: Glow, width: f32, scrolled: u16) -> Node {
    let r = reach(width);
    // The node is as tall as the widest ellipse, the second tone's.
    let h = r * 1.2;
    let s = f32::from(glow.strength) / 1000.0;
    let mut n = Node::spacer().frame(Some(width), Some(h), Alignment::TOP_LEADING);
    if let Some(tint) = glow.tint {
        n = n.paint(Paint::Radial {
            center: [1.25, 0.0],
            radii: [0.9, 1.0],
            stops: vec![
                (0.0, colour(tint, s * 0.36)),
                (0.5, colour(tint, s * 0.16)),
                (1.0, colour(tint, 0.0)),
            ],
        });
    }
    n.paint(Paint::Radial {
        center: [0.5, 0.0],
        radii: [0.75, 1.0 / 1.2],
        stops: vec![
            (0.0, colour(glow.tone, s)),
            (0.35, colour(glow.tone, s * 0.62)),
            (0.7, colour(glow.tone, s * 0.22)),
            (1.0, colour(glow.tone, 0.0)),
        ],
    })
    .offset(0.0, -f32::from(scrolled), swiftly_ui::Motion::Instant)
}

/// What a page's chrome carries: the glow and how far the page has scrolled. The scroll counts only while a glow shows,
/// so a page without one is not rebuilt for every scrolled point.
pub fn bar_state(offset: f64) -> (Glow, u16) {
    let glow = current();
    (glow, if glow.visible() { scrolled(offset) } else { 0 })
}

/// `content` with the glow behind it, clipped to the column of `width` points. Unchanged while there is no glow.
pub fn behind(content: Node, state: (Glow, u16), width: f32) -> Node {
    let (glow, scrolled) = state;
    if !glow.visible() || width <= 0.0 {
        return content;
    }
    content
        .background(node(glow, width, scrolled), Alignment::TOP_LEADING)
        .clipped()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use swiftly_render::QuadKind;
    use swiftly_settings::{MemoryStore, StoreError, Value};
    use swiftly_support::look::{LookSelection, storage_key};
    use swiftly_support::support::{SupportStatus, SupportStore};
    use swiftly_ui::{Cx, Env, Idiom, Ui};

    #[derive(Clone, Default)]
    struct Mem(Arc<MemoryStore>);
    impl KeyValueStore for Mem {
        fn get(&self, key: &str) -> Option<Value> {
            self.0.get(key)
        }
        fn set(&self, key: &str, value: Value) -> Result<(), StoreError> {
            self.0.set(key, value)
        }
        fn remove(&self, key: &str) -> Result<(), StoreError> {
            self.0.remove(key)
        }
        fn keys(&self) -> Vec<String> {
            self.0.keys()
        }
    }

    fn store_with(look: &str, supporter: bool) -> Mem {
        let m = Mem::default();
        m.set(
            storage_key::SELECTION,
            Value::Data(LookSelection::of(look).encoded()),
        )
        .unwrap();
        if supporter {
            let _ = SupportStore::new(m.clone()).set_status(SupportStatus::Supporter {
                source: swiftly_support::support::Source::Key,
                since: None,
            });
        }
        m
    }

    #[test]
    fn no_glow_for_the_original_or_for_someone_who_may_not_wear_the_look() {
        assert!(
            !read(Mem::default()).visible(),
            "the original look has no glow"
        );
        assert!(
            !read(store_with("neonNight", false)).visible(),
            "a paid look needs a supporter"
        );
    }

    #[test]
    fn a_supporters_look_gives_its_tone_and_strength() {
        let g = read(store_with("neonNight", true));
        assert!(g.visible() && g.strength >= 200, "{g:?}");
        assert_ne!(g.tone, 0);
    }

    fn quads(glow: Glow, scrolled: u16) -> Vec<swiftly_render::DrawQuad> {
        let mut env = Env::new(swiftly_layout::Size::new(900.0, 700.0), 1.0, Idiom::Desktop);
        env.reduce_motion = true;
        let mut u = Ui::new(
            move |_: &(), _: &Env, _: &Cx| {
                behind(
                    Node::spacer().frame(Some(680.0), Some(700.0), Alignment::TOP_LEADING),
                    (glow, scrolled),
                    680.0,
                )
            },
            (),
            env,
            Cx::deterministic(),
        );
        u.frame(100.0).quads().to_vec()
    }

    #[test]
    fn the_glow_is_radial_goes_up_with_the_scroll_and_is_absent_when_off() {
        let on = Glow {
            tone: 0x00D4FF,
            tint: Some(0xFF00AA),
            strength: 200,
        };
        let q = quads(on, 0);
        let radial: Vec<_> = q.iter().filter(|q| q.kind == QuadKind::Radial).collect();
        assert!(radial.len() >= 4, "main tone and tint: {}", radial.len());
        assert!(
            radial.iter().all(|q| q.rect.y.abs() < 0.01),
            "starts at the top of the page"
        );
        let moved = quads(on, 100);
        let top = moved
            .iter()
            .filter(|q| q.kind == QuadKind::Radial)
            .map(|q| q.rect.y)
            .fold(f32::MAX, f32::min);
        assert!((top + 100.0).abs() < 0.01, "goes up by the scroll: {top}");
        assert!(
            quads(Glow::default(), 0)
                .iter()
                .all(|q| q.kind != QuadKind::Radial)
        );
        assert_eq!(scrolled(1000.0), 300);
        assert_eq!(
            bar_state(50.0),
            (current(), if current().visible() { 50 } else { 0 })
        );
    }
}
