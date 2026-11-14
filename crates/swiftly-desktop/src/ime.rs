//! What the window tells the system's input method: whether it may open at all, whether the field in front is a
//! password, and where the caret is, so the candidate window sits at the caret and not in a corner.
//!
//! [`ImeState`] is what the screen in front wants; [`ImeSync`] remembers what the window was told and turns a new state
//! into the few `winit` calls that changed ([`plan`], pure so a host test can check it).

#[cfg(feature = "window")]
use winit::dpi::{LogicalPosition, LogicalSize};
#[cfg(feature = "window")]
use winit::window::{ImePurpose, Window};

/// What the input method needs right now.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ImeState {
    /// A text field has the keyboard (otherwise no composition window may open).
    pub allowed: bool,
    /// The field is a password field (no candidate suggestions, no history).
    pub password: bool,
    /// The caret or composition `(x, y, w, h)` in window points; `None` when the screen cannot tell.
    pub area: Option<[f32; 4]>,
}

/// One call on the window.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Call {
    /// `Window::set_ime_allowed`.
    Allowed(bool),
    /// `Window::set_ime_purpose` (`true`: password).
    Password(bool),
    /// `Window::set_ime_cursor_area` in window points.
    Area([f32; 4]),
}

/// The calls that bring a window that was told `last` (`None`: nothing yet) to `now`. The area is only sent while the
/// input method is allowed (winit ignores it otherwise on some platforms), and again whenever it moves.
pub fn plan(last: Option<&ImeState>, now: &ImeState) -> Vec<Call> {
    let mut calls = Vec::new();
    if last.is_none_or(|l| l.allowed != now.allowed) {
        calls.push(Call::Allowed(now.allowed));
    }
    // A field that just opened always says its purpose: what the window was told for the field before is unknown.
    if now.allowed && last.is_none_or(|l| !l.allowed || l.password != now.password) {
        calls.push(Call::Password(now.password));
    }
    if let (true, Some(a)) = (now.allowed, now.area)
        && last.is_none_or(|l| !l.allowed || l.area != Some(a))
    {
        calls.push(Call::Area(a));
    }
    calls
}

/// Remembers what the window was told.
#[derive(Debug, Default)]
pub struct ImeSync {
    last: Option<ImeState>,
}

impl ImeSync {
    /// Sends what changed since the last call.
    #[cfg(feature = "window")]
    pub fn sync(&mut self, window: &Window, now: ImeState) {
        for call in plan(self.last.as_ref(), &now) {
            match call {
                Call::Allowed(on) => window.set_ime_allowed(on),
                Call::Password(on) => window.set_ime_purpose(if on {
                    ImePurpose::Password
                } else {
                    ImePurpose::Normal
                }),
                Call::Area([x, y, w, h]) => window.set_ime_cursor_area(
                    LogicalPosition::new(f64::from(x), f64::from(y)),
                    LogicalSize::new(f64::from(w), f64::from(h)),
                ),
            }
        }
        self.last = Some(now);
    }
}

/// The anchor of the candidate window for a field whose editable area starts at `origin` (window points) and whose
/// caret or composition is `rect` in the area's own coordinates (`swiftly_ui::field::candidate_rect`).
pub fn anchor(origin: [f32; 4], rect: (f32, f32, f32, f32)) -> [f32; 4] {
    [origin[0] + rect.0, origin[1] + rect.1, rect.2, rect.3]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn on(area: Option<[f32; 4]>) -> ImeState {
        ImeState {
            allowed: true,
            password: false,
            area,
        }
    }

    #[test]
    fn first_state_sends_everything_that_applies() {
        let a = [10.0, 20.0, 2.0, 18.0];
        assert_eq!(
            plan(None, &on(Some(a))),
            vec![Call::Allowed(true), Call::Password(false), Call::Area(a)]
        );
        assert_eq!(plan(None, &ImeState::default()), vec![Call::Allowed(false)]);
    }

    #[test]
    fn nothing_changed_sends_nothing() {
        let s = on(Some([1.0, 2.0, 3.0, 4.0]));
        assert!(plan(Some(&s), &s).is_empty());
    }

    #[test]
    fn the_caret_moving_sends_only_the_area() {
        let (a, b) = ([1.0, 2.0, 3.0, 4.0], [9.0, 2.0, 3.0, 4.0]);
        assert_eq!(plan(Some(&on(Some(a))), &on(Some(b))), vec![Call::Area(b)]);
    }

    #[test]
    fn a_password_field_switches_the_purpose_and_back() {
        let a = Some([1.0, 2.0, 3.0, 4.0]);
        let pw = ImeState {
            allowed: true,
            password: true,
            area: a,
        };
        assert_eq!(plan(Some(&on(a)), &pw), vec![Call::Password(true)]);
        assert_eq!(plan(Some(&pw), &on(a)), vec![Call::Password(false)]);
    }

    #[test]
    fn no_field_closes_the_input_method_and_a_new_one_resends_the_area() {
        let a = [1.0, 2.0, 3.0, 4.0];
        assert_eq!(
            plan(Some(&on(Some(a))), &ImeState::default()),
            vec![Call::Allowed(false)]
        );
        assert_eq!(
            plan(Some(&ImeState::default()), &on(Some(a))),
            vec![Call::Allowed(true), Call::Password(false), Call::Area(a)]
        );
    }

    #[test]
    fn anchor_adds_the_field_origin() {
        assert_eq!(
            anchor([100.0, 50.0, 300.0, 20.0], (12.0, 1.0, 2.0, 18.0)),
            [112.0, 51.0, 2.0, 18.0]
        );
    }
}
