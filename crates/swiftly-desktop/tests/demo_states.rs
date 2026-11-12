//! `--demo app --state S`: the whole app starts in the scripted server state, so a tester can drive every screen
//! into loading, offline and empty from the command line.

use swiftly_desktop::home_data::Scenario;
use swiftly_desktop::suite::Suite;
use swiftly_layout::Size;
use swiftly_ui::{Cx, Env, Idiom};

const STEP: f64 = 1000.0 / 60.0;

/// Pixels of the first tab after the settle time.
fn shot(state: Scenario) -> Vec<u8> {
    let env = Env::new(Size::new(1000.0, 640.0), 1.0, Idiom::Desktop);
    let mut s = Suite::with_state(env, Cx::deterministic(), state);
    let (mut now, mut list) = (0.0, None);
    while now < 1500.0 {
        now += STEP;
        list = Some(s.frame(now).0);
    }
    list.map(|l| s.render_software(&l).pixels)
        .unwrap_or_default()
}

#[test]
fn every_state_draws_its_own_screen() {
    let ready = shot(Scenario::Ready);
    assert_eq!(ready, shot(Scenario::Ready), "deterministic");
    for st in [Scenario::Loading, Scenario::Offline, Scenario::Empty] {
        let a = shot(st);
        assert_ne!(a, ready, "{st:?} must differ from the normal screen");
        assert_eq!(a, shot(st), "{st:?} deterministic");
    }
    assert_ne!(shot(Scenario::Offline), shot(Scenario::Empty));
    assert_ne!(shot(Scenario::Loading), shot(Scenario::Empty));
}
