//! The offer row at the foot of the sidebar shows its whole title ("Hier weiterschauen") in the 220 point sidebar, like
//! the Mac's `OfferingRow`; it was cut to "Hier..." although the row had room.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use swiftly_desktop::desk::{self, Offer};
use swiftly_desktop::home::HomeScreen;
use swiftly_desktop::home_data::Scenario;
use swiftly_layout::Size;
use swiftly_text::TextStyle;
use swiftly_ui::{Cx, Env, Idiom};

fn natural_width(cx: &Cx, text: &str, size: f32, weight: u16) -> f32 {
    let style = TextStyle::from(swiftly_design::TextStyle {
        size,
        weight,
        tracking: 0.0,
        uppercase: false,
    });
    cx.measure_text(
        text,
        &style,
        Some(1),
        swiftly_layout::Proposal { w: None, h: None },
    )
    .w
}

fn offered(title: &str, under: &str, count: usize) -> Option<Offer> {
    Some(Offer {
        symbol: "television".into(),
        title: title.into(),
        under: under.into(),
        count,
    })
}

fn title_frame(offer: Option<Offer>) -> ([f32; 4], f32, Cx) {
    let cx = Cx::deterministic();
    let env = Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop);
    desk::set_offer(offer.clone());
    let mut s = HomeScreen::new(env, cx.clone(), Scenario::Ready);
    for i in 0..4 {
        let _ = s.frame(f64::from(i) * 16.0);
    }
    let want = natural_width(&cx, &offer.as_ref().unwrap().title, 13.0, 500);
    let f = s
        .frame_of("offer-title")
        .expect("the offer title is on the sidebar");
    desk::set_offer(None);
    (f, want, cx)
}

#[test]
fn the_offer_title_is_not_cut_in_the_sidebar() {
    for (title, under, count) in [
        ("Hier weiterschauen", "Sommerregen", 1),
        ("Gemeinsam schauen", "Filmabend", 1),
        (
            "Hier weiterschauen",
            "Eine sehr lange Überschrift eines Films, die nicht passt",
            1,
        ),
        ("Läuft gerade", "Sommerregen, Nordlicht", 2),
    ] {
        let (f, want, _) = title_frame(offered(title, under, count));
        assert!(
            f[2] + 0.5 >= want,
            "{title}: the title gets {} pt, it needs {want}",
            f[2]
        );
    }
}
