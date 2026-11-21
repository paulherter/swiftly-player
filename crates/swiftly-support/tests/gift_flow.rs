//! The gift offer flow (`GiftFlow` in `LookGiftSheet.swift`): what comes up after the home page, and the steps from the
//! offer through picking it up to the looks panel.

use std::collections::BTreeSet;

use swiftly_support::Look;
use swiftly_support::gift_flow::{
    CLAIM_MS, GiftEval, GiftFlow, GiftOutcome, GiftStage, WhatsNewDue, evaluate,
};
use swiftly_support::time::Calendar;

fn cal() -> Calendar {
    Calendar::fixed(3600)
}
fn noon(y: i32, m: u32, d: u32) -> f64 {
    cal().timestamp(y, m, d, 12, 0)
}
fn input(now: f64) -> GiftEval {
    GiftEval {
        now,
        stage_open: false,
        big_ask_shown: false,
        home_ready: true,
        blocked: false,
        seconds_on_home: 3.0,
        whats_new: WhatsNewDue::Nothing,
        whats_new_gift: None,
        owned: BTreeSet::new(),
        offered: BTreeSet::new(),
    }
}

#[test]
fn the_gift_is_offered_once_in_its_window() {
    let inside = noon(2026, 10, 26);
    let out = evaluate(&input(inside), &Look::ALL, cal());
    assert_eq!(out.outcome, GiftOutcome::Offer(Look::HALLOWEEN));
    assert!(!out.mark_seen);
    assert_eq!(out.mark_offered, Some(Look::HALLOWEEN));
    // Outside the window, nothing.
    assert_eq!(
        evaluate(&input(noon(2026, 9, 1)), &Look::ALL, cal()).outcome,
        GiftOutcome::Nothing
    );
    // Offered this season already, or picked up: nothing.
    let mut again = input(inside);
    again.offered.insert("halloween-2026".to_owned());
    assert_eq!(
        evaluate(&again, &Look::ALL, cal()).outcome,
        GiftOutcome::Nothing
    );
    let mut owned = input(inside);
    owned.owned.insert("halloween".to_owned());
    assert_eq!(
        evaluate(&owned, &Look::ALL, cal()).outcome,
        GiftOutcome::Nothing
    );
    // Next year again.
    let mut next = input(noon(2027, 10, 26));
    next.offered.insert("halloween-2026".to_owned());
    assert_eq!(
        evaluate(&next, &Look::ALL, cal()).outcome,
        GiftOutcome::Offer(Look::HALLOWEEN)
    );
}

#[test]
fn nothing_comes_while_something_else_is_up_or_the_page_is_young() {
    let now = noon(2026, 10, 26);
    for tweak in [
        |i: &mut GiftEval| i.stage_open = true,
        |i: &mut GiftEval| i.big_ask_shown = true,
        |i: &mut GiftEval| i.home_ready = false,
        |i: &mut GiftEval| i.blocked = true,
        |i: &mut GiftEval| i.seconds_on_home = 1.0,
    ] {
        let mut i = input(now);
        tweak(&mut i);
        assert_eq!(
            evaluate(&i, &Look::ALL, cal()).outcome,
            GiftOutcome::Nothing
        );
    }
}

#[test]
fn whats_new_carries_the_gift_and_comes_first() {
    let now = noon(2026, 10, 26);
    let mut i = input(now);
    i.whats_new = WhatsNewDue::Show;
    i.whats_new_gift = Some(Look::HALLOWEEN);
    let out = evaluate(&i, &Look::ALL, cal());
    assert_eq!(
        out.outcome,
        GiftOutcome::WhatsNew {
            gift: Some(Look::HALLOWEEN)
        }
    );
    assert!(out.mark_seen);
    assert_eq!(out.mark_offered, Some(Look::HALLOWEEN));

    // The window is over: the sheet shows without the gift and marks nothing.
    let mut late = input(noon(2026, 12, 1));
    late.whats_new = WhatsNewDue::Show;
    late.whats_new_gift = Some(Look::HALLOWEEN);
    let out = evaluate(&late, &Look::ALL, cal());
    assert_eq!(out.outcome, GiftOutcome::WhatsNew { gift: None });
    assert_eq!(out.mark_offered, None);

    // Already picked up: no gift on the card either.
    let mut owned = i.clone();
    owned.owned.insert("halloween".to_owned());
    assert_eq!(
        evaluate(&owned, &Look::ALL, cal()).outcome,
        GiftOutcome::WhatsNew { gift: None }
    );
}

#[test]
fn mark_seen_still_lets_the_gift_through_and_nothing_does_not_mark() {
    let now = noon(2026, 10, 26);
    let mut i = input(now);
    i.whats_new = WhatsNewDue::MarkSeen;
    let out = evaluate(&i, &Look::ALL, cal());
    assert!(out.mark_seen);
    assert_eq!(out.outcome, GiftOutcome::Offer(Look::HALLOWEEN));
    i.whats_new = WhatsNewDue::Nothing;
    assert!(!evaluate(&i, &Look::ALL, cal()).mark_seen);
}

#[test]
fn the_steps_offer_claim_choose_close() {
    let mut flow = GiftFlow::default();
    assert!(!flow.presented());
    flow.show(GiftStage::Offer(Look::HALLOWEEN));
    assert!(flow.presented() && flow.big_ask_shown());
    assert!(!flow.looks_open());

    // Grab: claimed at once, the animation runs; a second press does not claim again.
    assert_eq!(flow.grab(Look::HALLOWEEN, false), Some(Look::HALLOWEEN));
    assert_eq!(flow.stage(), Some(&GiftStage::Claiming(Look::HALLOWEEN)));
    assert_eq!(flow.grab(Look::HALLOWEEN, false), None);
    const { assert!(CLAIM_MS > 0.0) };
    // The animation ends (timer or a tap): the looks panel, the icon landing in its row.
    flow.land();
    assert_eq!(flow.stage(), Some(&GiftStage::Choosing { from_gift: true }));
    assert!(flow.looks_open());
    // Landing twice changes nothing.
    flow.land();
    assert_eq!(flow.stage(), Some(&GiftStage::Choosing { from_gift: true }));
    assert!(flow.close());
    assert!(!flow.presented());
    assert!(flow.big_ask_shown());
}

#[test]
fn reduced_motion_skips_the_animation_and_not_now_closes_without_claiming() {
    let mut flow = GiftFlow::default();
    flow.show(GiftStage::Offer(Look::HALLOWEEN));
    assert_eq!(flow.grab(Look::HALLOWEEN, true), Some(Look::HALLOWEEN));
    assert_eq!(flow.stage(), Some(&GiftStage::Choosing { from_gift: true }));

    let mut other = GiftFlow::default();
    other.show(GiftStage::Offer(Look::HALLOWEEN));
    assert!(
        !other.close(),
        "an offer closed is not a looks panel closed"
    );
    assert!(!other.presented());
}

#[test]
fn another_big_ask_holds_the_gift_back_and_reset_clears() {
    let mut flow = GiftFlow::default();
    flow.note_big_ask();
    assert!(flow.big_ask_shown());
    flow.reset();
    assert!(!flow.big_ask_shown() && !flow.presented());
    flow.open_looks();
    assert_eq!(
        flow.stage(),
        Some(&GiftStage::Choosing { from_gift: false })
    );
}
