//! Login, server connect and account switch as ONE state machine.
//!
//! Replaces `AppModel.phase` + `isWorking` + `errorMessage` + "client set in five places" +
//! the per-screen `pinChecking`/`pinWrong`/`checking`/`signingIn` flags. Impossible before:
//! `ready && no client`, `working && error`, `connecting` while the previous account's rails
//! are still on screen, a switch while another switch runs. All transitions are in
//! [`Session::reduce`]; ids are the account ids of the bundle.

/// How the user signs in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SignInMethod {
    /// Name and password.
    Password,
    /// Quick Connect code.
    QuickConnect,
    /// Plex / Emby / token flow in the browser.
    Browser,
}

/// Where login and account stand. `from` is the account that stays active if the flow is
/// cancelled (adding a second account while signed in).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Session {
    /// No account.
    SignedOut,
    /// The server address is being checked.
    Connecting {
        /// Server address.
        server: String,
        /// The account to return to on cancel.
        from: Option<String>,
    },
    /// The server is there; the login form is shown (also after a wrong password).
    NeedsLogin {
        /// Server address.
        server: String,
        /// The account to return to on cancel.
        from: Option<String>,
    },
    /// A sign-in request runs.
    SigningIn {
        /// Server address.
        server: String,
        /// How.
        method: SignInMethod,
        /// The account to return to on cancel.
        from: Option<String>,
    },
    /// An account is active.
    Ready {
        /// Account id.
        account: String,
    },
    /// The active account changes; the old one stays until the new one answers.
    Switching {
        /// Account id before.
        from: String,
        /// Account id after.
        to: String,
    },
    /// The server could not be reached (retry with `Connect`).
    Failed {
        /// Server address.
        server: String,
        /// Short reason.
        reason: String,
    },
}

/// What happens to the session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionEvent {
    /// A server address is entered or retried.
    Connect {
        /// Server address.
        server: String,
    },
    /// The server answered.
    Reachable,
    /// The server did not answer.
    Unreachable {
        /// Short reason.
        reason: String,
    },
    /// A sign-in request starts.
    BeginSignIn {
        /// How.
        method: SignInMethod,
    },
    /// The sign-in worked.
    SignedIn {
        /// Account id.
        account: String,
    },
    /// The sign-in was refused (wrong password): back to the form, never `Failed`.
    SignInRefused,
    /// The user backs out of connect or login.
    Cancelled,
    /// The user picks another stored account.
    SwitchTo {
        /// Account id.
        to: String,
    },
    /// The new account answered.
    SwitchDone {
        /// Account id.
        account: String,
    },
    /// The new account did not answer: the old one stays.
    SwitchFailed,
    /// The user signs out.
    SignOut,
    /// The server revoked the account's token.
    Revoked {
        /// Account id.
        account: String,
    },
}

impl Session {
    /// The only place that decides what an event does. Events that make no sense in a state
    /// (a switch while another runs, a sign-in without a form) leave it unchanged.
    #[must_use]
    pub fn reduce(self, event: SessionEvent) -> Self {
        use Session as S;
        use SessionEvent as E;
        match (self, event) {
            (S::SignedOut | S::Failed { .. }, E::Connect { server }) => {
                S::Connecting { server, from: None }
            }
            (S::NeedsLogin { from, .. }, E::Connect { server }) => S::Connecting { server, from },
            (S::Ready { account }, E::Connect { server }) => S::Connecting {
                server,
                from: Some(account),
            },
            (S::Connecting { server, from }, E::Reachable) => S::NeedsLogin { server, from },
            (S::Connecting { server, from }, E::Unreachable { reason }) => {
                from.map_or(S::Failed { server, reason }, |account| S::Ready { account })
            }
            (S::NeedsLogin { server, from }, E::BeginSignIn { method }) => S::SigningIn {
                server,
                method,
                from,
            },
            (S::SigningIn { server, from, .. }, E::SignInRefused) => S::NeedsLogin { server, from },
            (S::SigningIn { .. }, E::SignedIn { account }) => S::Ready { account },
            (
                S::Connecting { from, .. } | S::NeedsLogin { from, .. } | S::SigningIn { from, .. },
                E::Cancelled,
            ) => from.map_or(S::SignedOut, |account| S::Ready { account }),
            (S::Failed { .. }, E::Cancelled) => S::SignedOut,
            (S::Ready { account }, E::SwitchTo { to }) if to != account => {
                S::Switching { from: account, to }
            }
            (S::Switching { to, .. }, E::SwitchDone { account }) if account == to => {
                S::Ready { account }
            }
            (S::Switching { from, .. }, E::SwitchFailed) => S::Ready { account: from },
            (S::Ready { .. } | S::Switching { .. }, E::SignOut) => S::SignedOut,
            (S::Ready { account }, E::Revoked { account: gone }) if account == gone => S::SignedOut,
            (state, _) => state,
        }
    }

    /// The account whose data may be on screen (never the target of a running switch).
    #[must_use]
    pub fn active_account(&self) -> Option<&str> {
        match self {
            Self::Ready { account } => Some(account),
            Self::Switching { from, .. } => Some(from),
            _ => None,
        }
    }

    /// A request runs: hosts show progress and disable the form.
    #[must_use]
    pub fn is_working(&self) -> bool {
        matches!(
            self,
            Self::Connecting { .. } | Self::SigningIn { .. } | Self::Switching { .. }
        )
    }

    /// The home/library screens may load (an account is active and no switch runs).
    #[must_use]
    pub fn screens_may_load(&self) -> bool {
        matches!(self, Self::Ready { .. })
    }
}

#[cfg(test)]
mod tests {
    use super::SessionEvent as E;
    use super::{Session as S, SignInMethod::Password};

    fn s(x: &str) -> String {
        x.to_owned()
    }

    #[test]
    fn transition_table() {
        let conn = |from: Option<&str>| S::Connecting {
            server: s("srv"),
            from: from.map(s),
        };
        let need = |from: Option<&str>| S::NeedsLogin {
            server: s("srv"),
            from: from.map(s),
        };
        let sign = |from: Option<&str>| S::SigningIn {
            server: s("srv"),
            method: Password,
            from: from.map(s),
        };
        let ready = |a: &str| S::Ready { account: s(a) };
        let switching = S::Switching {
            from: s("a"),
            to: s("b"),
        };
        let failed = S::Failed {
            server: s("srv"),
            reason: s("x"),
        };
        let connect = E::Connect { server: s("srv") };
        let signed = |a: &str| E::SignedIn { account: s(a) };
        let table: Vec<(S, E, S)> = vec![
            (S::SignedOut, connect.clone(), conn(None)),
            (failed.clone(), connect.clone(), conn(None)),
            (ready("a"), connect.clone(), conn(Some("a"))),
            (need(None), connect.clone(), conn(None)),
            (conn(None), E::Reachable, need(None)),
            (
                conn(None),
                E::Unreachable { reason: s("x") },
                failed.clone(),
            ),
            (
                conn(Some("a")),
                E::Unreachable { reason: s("x") },
                ready("a"),
            ),
            (need(None), E::BeginSignIn { method: Password }, sign(None)),
            (sign(None), E::SignInRefused, need(None)),
            (sign(Some("a")), signed("c"), ready("c")),
            (conn(Some("a")), E::Cancelled, ready("a")),
            (need(None), E::Cancelled, S::SignedOut),
            (sign(Some("a")), E::Cancelled, ready("a")),
            (failed.clone(), E::Cancelled, S::SignedOut),
            (ready("a"), E::SwitchTo { to: s("b") }, switching.clone()),
            (
                switching.clone(),
                E::SwitchDone { account: s("b") },
                ready("b"),
            ),
            (switching.clone(), E::SwitchFailed, ready("a")),
            (switching.clone(), E::SignOut, S::SignedOut),
            (ready("a"), E::SignOut, S::SignedOut),
            (ready("a"), E::Revoked { account: s("a") }, S::SignedOut),
            // Illegal events change nothing.
            (S::SignedOut, E::Reachable, S::SignedOut),
            (S::SignedOut, signed("a"), S::SignedOut),
            (S::SignedOut, E::SwitchTo { to: s("b") }, S::SignedOut),
            (S::SignedOut, E::SignOut, S::SignedOut),
            (conn(None), E::BeginSignIn { method: Password }, conn(None)),
            (conn(None), signed("a"), conn(None)),
            (need(None), signed("a"), need(None)),
            (need(None), E::SignInRefused, need(None)),
            (sign(None), connect.clone(), sign(None)),
            (sign(None), E::BeginSignIn { method: Password }, sign(None)),
            (ready("a"), E::SwitchTo { to: s("a") }, ready("a")),
            (ready("a"), E::SwitchDone { account: s("a") }, ready("a")),
            (ready("a"), E::SwitchFailed, ready("a")),
            (ready("a"), E::Revoked { account: s("z") }, ready("a")),
            (ready("a"), E::Reachable, ready("a")),
            (
                switching.clone(),
                E::SwitchTo { to: s("c") },
                switching.clone(),
            ),
            (
                switching.clone(),
                E::SwitchDone { account: s("z") },
                switching.clone(),
            ),
            (switching.clone(), connect.clone(), switching.clone()),
            (
                switching.clone(),
                E::Revoked { account: s("a") },
                switching.clone(),
            ),
            (failed.clone(), E::Reachable, failed.clone()),
            (failed.clone(), signed("a"), failed.clone()),
        ];
        for (from, ev, to) in table {
            assert_eq!(from.clone().reduce(ev.clone()), to, "{from:?} + {ev:?}");
        }
    }

    #[test]
    fn helpers_have_no_impossible_combinations() {
        let switching = S::Switching {
            from: s("a"),
            to: s("b"),
        };
        assert_eq!(switching.active_account(), Some("a"));
        assert!(switching.is_working() && !switching.screens_may_load());
        let ready = S::Ready { account: s("a") };
        assert!(!ready.is_working() && ready.screens_may_load());
        // Connecting never shows the previous account's data.
        assert_eq!(
            S::Connecting {
                server: s("x"),
                from: Some(s("a"))
            }
            .active_account(),
            None
        );
        assert_eq!(S::SignedOut.active_account(), None);
    }
}
