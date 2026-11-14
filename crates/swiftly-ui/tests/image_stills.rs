//! The player's episode stills keep a shelf of their own on the image page: a page the posters and icons filled up
//! still has room for every card of a ten-episode season, again for the next set, and never overlaps a picture.
#![allow(clippy::unwrap_used)]

use swiftly_ui::ImageStore;

const PAGE: u32 = 4096;

fn filled_page() -> ImageStore {
    let mut s = ImageStore::new(PAGE);
    s.keep_preview();
    let px = vec![200_u8; 300 * 450 * 4];
    while s.add(300, 450, &px).is_some() {}
    let small = vec![200_u8; 64 * 64 * 4];
    while s.add(64, 64, &small).is_some() {}
    s
}

fn rect(uv: [f32; 4]) -> [f32; 4] {
    uv.map(|v| v * PAGE as f32)
}

#[test]
fn a_full_page_still_has_room_for_ten_stills_and_then_ten_more() {
    let mut s = filled_page();
    assert!(
        s.reserve(360, 203).is_none(),
        "the shared shelf is full, as in a long session"
    );
    for round in 0..2 {
        s.reset_stills();
        let mut taken: Vec<[f32; 4]> = Vec::new();
        for i in 0..10 {
            // The running card is 1.25 x the others.
            let (w, h) = if i == 4 { (450, 254) } else { (360, 203) };
            let slot = s
                .reserve_still(w, h)
                .unwrap_or_else(|| panic!("round {round}: still {i} found no room"));
            let r = rect(slot.id.uv);
            for o in &taken {
                let apart = r[2] <= o[0] || o[2] <= r[0] || r[3] <= o[1] || o[3] <= r[1];
                assert!(apart, "still {i} overlaps another one: {r:?} {o:?}");
            }
            taken.push(r);
            let px = vec![9_u8; (w * h * 4) as usize];
            assert!(s.rewrite(&slot, w, h, &px));
        }
    }
}
