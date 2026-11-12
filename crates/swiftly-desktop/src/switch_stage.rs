//! The account switch stage (`AccountSwitchStage.swift`, `AccountTransition.swift`): the profile picture lifts, grows 6 %
//! in 0.1 s and flies to its slot on three springs (`AccountSwitchCurve`), the ring pops where it lands, the rails of
//! the new account follow one row after the other. With Reduce Motion the picture and the rails only fade.
//!
//! The poses are pure functions of the time, so the tests read them at two time points; `StageScreen` draws them
//! headless. The engine has no per-node translate transition, so the picture is placed by padding on every frame
//! (`Motion::Instant`), which is what a driven curve needs anyway.

use crate::home::{ins, text};
use swiftly_accounts::AccountSwitchCurve;
use swiftly_design::tokens::colour;
use swiftly_layout::Alignment;
use swiftly_render::Color;
use swiftly_ui::components::color;
use swiftly_ui::{Cx, Env, Node, Ui};

/// Where everything is at one moment.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Pose {
    /// Centre of the picture.
    pub x: f32,
    /// Centre of the picture.
    pub y: f32,
    /// Edge of the picture.
    pub size: f32,
    /// Scale of the ring (0.6 to 1).
    pub ring_scale: f32,
    /// Opacity of the ring.
    pub ring_alpha: f32,
    /// Opacity of the picture.
    pub alpha: f32,
}

/// A running switch.
#[derive(Clone, Copy, Debug)]
pub struct SwitchStage {
    curve: AccountSwitchCurve,
    reduce_motion: bool,
    to: (f32, f32),
}

impl SwitchStage {
    /// The profile picture of `size` centred at `from` flies to the slot centred at `to` (34 points on the Mac).
    pub fn new(from: (f32, f32), size: f32, to: (f32, f32), reduce_motion: bool) -> SwitchStage {
        let curve = AccountSwitchCurve::new(
            (f64::from(from.0), f64::from(from.1)),
            f64::from(size),
            (f64::from(to.0), f64::from(to.1)),
            AccountSwitchCurve::TARGET_SIZE,
        );
        SwitchStage {
            curve,
            reduce_motion,
            to,
        }
    }

    /// When the account itself changes (seconds after the tap).
    pub fn change_at(&self) -> f64 {
        if self.reduce_motion {
            0.25
        } else {
            self.curve.change()
        }
    }

    /// The stage is removed 0.05 s after the painting ends.
    pub fn finished(&self, t: f64) -> bool {
        t >= if self.reduce_motion {
            0.5
        } else {
            self.curve.paint_end() + 0.05
        }
    }

    /// Everything at `t` seconds after the tap.
    pub fn pose(&self, t: f64) -> Pose {
        if self.reduce_motion {
            let alpha = if t < 0.25 {
                (t / 0.25).clamp(0.0, 1.0)
            } else {
                (1.0 - (t - 0.25) / 0.25).clamp(0.0, 1.0)
            };
            return Pose {
                x: self.to.0,
                y: self.to.1,
                size: AccountSwitchCurve::TARGET_SIZE as f32,
                ring_scale: 1.0,
                ring_alpha: 0.0,
                alpha: alpha as f32,
            };
        }
        let (x, y, size) = self.curve.status(t);
        let r = t - self.curve.landing;
        let (ring_scale, ring_alpha) = if r >= 0.0 {
            AccountSwitchCurve::ring(r)
        } else {
            (0.6, 0.0)
        };
        Pose {
            x: x as f32,
            y: y as f32,
            size: size as f32,
            ring_scale: ring_scale as f32,
            ring_alpha: ring_alpha as f32,
            alpha: 1.0,
        }
    }

    /// Row `row` of the new account's rails at `t`: (offset down in points, opacity). Rows start 14 points low, fade in
    /// linearly over 0.22 s and settle on a spring, each 0.08 s after the one above.
    pub fn rail(&self, row: usize, t: f64) -> (f32, f32) {
        let start = self.change_at() + AccountSwitchCurve::RAILS_POST_SWAP;
        let lag = if self.reduce_motion {
            0.0
        } else {
            row as f64 * AccountSwitchCurve::RAILS_SEASON
        };
        let u = t - start - lag;
        let alpha = (u / AccountSwitchCurve::RAILS_FADE).clamp(0.0, 1.0) as f32;
        if self.reduce_motion {
            return (0.0, alpha);
        }
        let settle = swiftly_accounts_spring(u);
        (
            (AccountSwitchCurve::RAILS_OFFSET * (1.0 - settle)) as f32,
            alpha,
        )
    }

    /// The overlay at `t`: the picture with its initial and the ring, placed over a window filling frame.
    pub fn node(&self, cx: &Cx, t: f64, initial: char) -> Node {
        let p = self.pose(t);
        let ring = Color::new(0.20, 0.55, 1.0, p.ring_alpha);
        let rs = p.size * p.ring_scale + 8.0;
        let ring_node = Node::rect(ring, rs / 2.0).frame(Some(rs), Some(rs), Alignment::CENTER);
        let face = text(
            cx,
            &initial.to_string(),
            swiftly_design::TextStyle {
                size: p.size * 0.42,
                weight: 700,
                tracking: 0.0,
                uppercase: false,
            },
            colour::FONT,
            Some(1),
            swiftly_text::Align::Center,
        )
        .frame(Some(p.size), Some(p.size), Alignment::CENTER)
        .background(
            Node::rect(color(colour::AREA), p.size / 2.0),
            Alignment::CENTER,
        )
        .opacity(p.alpha, swiftly_ui::Motion::Instant);
        let placed = face.background(ring_node, Alignment::CENTER).frame(
            Some(rs),
            Some(rs),
            Alignment::CENTER,
        );
        crate::home::fill_frame(
            placed.padding(ins(
                (p.y - rs / 2.0).max(0.0),
                (p.x - rs / 2.0).max(0.0),
                0.0,
                0.0,
            )),
            Alignment::TOP_LEADING,
        )
    }
}

/// The settle spring of a rail row: the catalogued `AccountRows` (`spring(response 0.55, dampingFraction 0.82)`), 0 before it starts.
fn swiftly_accounts_spring(u: f64) -> f64 {
    if u <= 0.0 {
        return 0.0;
    }
    swiftly_motion::catalogue::Id::AccountRows
        .curve()
        .progress(u)
}

/// The stage on its own, for the headless tests: draws the overlay of the stage `since` ms after the first frame.
pub struct StageScreen {
    ui: Ui<f64>,
    since: Option<f64>,
    stage: SwitchStage,
}

impl StageScreen {
    /// A stage over an empty window of `env`.
    pub fn new(env: Env, cx: Cx, stage: SwitchStage) -> StageScreen {
        StageScreen::with_initial(env, cx, stage, 'P')
    }

    /// A stage whose picture shows `initial` (the first letter of the new account's name).
    pub fn with_initial(env: Env, cx: Cx, stage: SwitchStage, initial: char) -> StageScreen {
        let ui = Ui::new(
            move |t: &f64, _env: &Env, cx: &Cx| stage.node(cx, *t / 1000.0, initial),
            0.0,
            env,
            cx,
        );
        StageScreen {
            ui,
            since: None,
            stage,
        }
    }

    /// One frame at `now` ms (the first frame is the tap).
    pub fn frame(&mut self, now: f64) -> swiftly_render::DrawList {
        let since = *self.since.get_or_insert(now);
        self.ui.set_parts((now - since).max(0.0));
        self.ui.frame(now)
    }

    /// Seconds since the first frame (0 before it).
    pub fn elapsed(&self, now: f64) -> f64 {
        self.since.map_or(0.0, |s| ((now - s) / 1000.0).max(0.0))
    }

    /// The running stage.
    pub fn stage(&self) -> &SwitchStage {
        &self.stage
    }

    /// Renders a list with the software renderer.
    pub fn render(&self, list: &swiftly_render::DrawList) -> swiftly_render::RgbaImage {
        self.ui.render(list, Color::BLACK)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_layout::Size;
    use swiftly_ui::Idiom;

    fn stage() -> SwitchStage {
        SwitchStage::new((640.0, 300.0), 120.0, (1240.0, 34.0), false)
    }

    #[test]
    fn the_picture_grows_then_flies_and_lands_on_the_slot() {
        let s = stage();
        let early = s.pose(0.05);
        assert!(
            (early.x - 640.0).abs() < 0.01
                && early.size > 120.0
                && early.size < 120.0 * 1.06 + 0.01,
            "{early:?}"
        );
        let late = s.pose(s.curve.paint_end());
        assert!(
            (late.x - 1240.0).abs() < 2.0
                && (late.y - 34.0).abs() < 2.0
                && (late.size - 34.0).abs() < 1.0,
            "{late:?}"
        );
        assert!(s.change_at() >= 0.6);
        assert!(s.finished(s.curve.paint_end() + 0.06) && !s.finished(0.2));
    }

    #[test]
    fn the_ring_pops_only_after_landing_and_rails_stagger() {
        let s = stage();
        assert_eq!(s.pose(0.1).ring_alpha, 0.0);
        let popped = s.pose(s.curve.landing + 0.05);
        assert!(
            popped.ring_alpha > 0.4 && popped.ring_scale > 0.6,
            "{popped:?}"
        );
        assert!(s.pose(s.curve.landing + 0.79).ring_alpha < 0.05);
        let t = s.change_at() + 0.1;
        let (o0, a0) = s.rail(0, t);
        let (o3, a3) = s.rail(3, t);
        assert!(a0 > a3 && o0 < o3 && o3 <= 14.0, "{o0} {a0} {o3} {a3}");
    }

    #[test]
    fn reduce_motion_only_fades() {
        let s = SwitchStage::new((640.0, 300.0), 120.0, (1240.0, 34.0), true);
        assert_eq!((s.pose(0.1).x, s.pose(0.1).ring_alpha), (1240.0, 0.0));
        assert!(s.pose(0.25).alpha > s.pose(0.05).alpha && s.pose(0.5).alpha < 0.01);
        assert_eq!(s.rail(5, s.change_at() + 0.3).0, 0.0);
    }

    #[test]
    fn two_frames_of_the_stage_differ() {
        let mut screen = StageScreen::new(
            Env::new(Size::new(1280.0, 800.0), 1.0, Idiom::Desktop),
            Cx::deterministic(),
            stage(),
        );
        let _ = screen.frame(0.0);
        let first = screen.frame(50.0);
        let a = screen.render(&first);
        let mut now = 50.0;
        while now < 700.0 {
            now += 1000.0 / 60.0;
            let _ = screen.frame(now);
        }
        let list = screen.frame(now);
        let b = screen.render(&list);
        assert_eq!((a.width, a.height), (b.width, b.height));
        assert!(
            a.diff(&b).0 > 100,
            "the picture moved between 50 ms and 700 ms"
        );
    }
}
