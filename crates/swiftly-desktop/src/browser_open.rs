//! Addresses the screens ask the system to open ([`crate::effects::Effect::OpenUrl`]), with the window's activation
//! token. On Wayland (and X11) a browser that is already running loads the page but only comes to the front when the
//! launcher hands it a token from the window the user clicked in. Without it the click seems to do nothing: the page
//! loads in a window that stays behind. So the window asks the compositor for a token first ([`Waiting::add`]), the
//! answer ([`Waiting::done`]) starts the opener with it, and an answer that does not come within [`WAIT_MS`] starts
//! it without one ([`Waiting::expired`]), so a click is never lost.

/// How long to wait for the compositor's token (ms).
pub const WAIT_MS: f64 = 1500.0;

/// Addresses waiting for their token, by the serial of the request.
pub struct Waiting<S> {
    list: Vec<(S, String, f64)>,
}

impl<S: PartialEq> Default for Waiting<S> {
    fn default() -> Self {
        Self { list: Vec::new() }
    }
}

impl<S: PartialEq> Waiting<S> {
    /// An address whose token was asked for at `now` (ms).
    pub fn add(&mut self, serial: S, url: String, now: f64) {
        self.list.push((serial, url, now));
    }

    /// The token of `serial` came: the address it was for.
    pub fn done(&mut self, serial: &S) -> Option<String> {
        let i = self.list.iter().position(|(s, ..)| s == serial)?;
        Some(self.list.remove(i).1)
    }

    /// The addresses whose token is overdue at `now` (ms); they are no longer waiting.
    pub fn expired(&mut self, now: f64) -> Vec<String> {
        let mut out = Vec::new();
        self.list.retain(|(_, url, at)| {
            let late = now - at >= WAIT_MS;
            if late {
                out.push(url.clone());
            }
            !late
        });
        out
    }

    /// Whether something waits (the frame loop keeps polling for the timeout).
    pub fn pending(&self) -> bool {
        !self.list.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_token_releases_exactly_its_address() {
        let mut w = Waiting::default();
        w.add(1, "https://a".into(), 0.0);
        w.add(2, "https://b".into(), 10.0);
        assert_eq!(w.done(&2).as_deref(), Some("https://b"));
        assert_eq!(w.done(&2), None, "once");
        assert!(w.pending());
        assert_eq!(w.done(&1).as_deref(), Some("https://a"));
        assert!(!w.pending());
    }

    #[test]
    fn an_overdue_token_never_loses_the_click() {
        let mut w = Waiting::default();
        w.add(1, "https://a".into(), 100.0);
        assert!(w.expired(100.0 + WAIT_MS - 1.0).is_empty());
        assert_eq!(w.expired(100.0 + WAIT_MS), vec!["https://a".to_owned()]);
        assert!(!w.pending());
        assert_eq!(w.done(&1), None, "a late token finds nothing");
    }
}
