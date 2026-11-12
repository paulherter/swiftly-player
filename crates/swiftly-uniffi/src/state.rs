//! The core's explicit state machines as host-visible enums (additive: every existing record
//! and flag stays). Each type mirrors the core enum one to one (`From` both ways where a host
//! sends it), so a host reads one value instead of a pile of flags:
//!
//! * `PlayerVm::stage()` -> [`PlayerStageState`] (replaces `restoring`, `startFailed`, `handoverRuns` ...)
//! * `PlayerVm::controls_stage(now)` -> [`ControlsStage`], `seek_chain(now)` -> [`SeekChainState`]
//! * `HomeVm/LibraryVm/SeriesVm/SearchVm::load()` -> [`LoadPart`] (`LoadState` + `version`)
//! * `LoginModel::session()` / `feed_session(event)` -> [`AccountSessionState`] / [`AccountSessionEvent`]

use swiftly_accounts::{Session, SessionEvent, SignInMethod};
use swiftly_vm::{Controls, FailKind, Load, PlayerStage, Resume, SeekChain, Side};

/// What a restored player resumes as.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PlayerResume {
    Playing,
    Paused,
}

/// The player's lifecycle (`swiftly_vm::PlayerStage`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PlayerStageState {
    /// Started, no picture yet.
    Opening,
    Playing,
    Paused,
    /// The position is put back; the picture stays.
    Restoring {
        resume: PlayerResume,
    },
    /// The title is replaced (next episode, quality switch).
    Switching,
    /// The fallback engine takes over.
    HandingOver,
    Ended,
    /// Start or stream failed (retry offered).
    Failed,
    Closed,
}

impl From<PlayerStage> for PlayerStageState {
    fn from(s: PlayerStage) -> Self {
        match s {
            PlayerStage::Opening => Self::Opening,
            PlayerStage::Playing => Self::Playing,
            PlayerStage::Paused => Self::Paused,
            PlayerStage::Restoring(Resume::Playing) => Self::Restoring {
                resume: PlayerResume::Playing,
            },
            PlayerStage::Restoring(Resume::Paused) => Self::Restoring {
                resume: PlayerResume::Paused,
            },
            PlayerStage::Switching => Self::Switching,
            PlayerStage::HandingOver => Self::HandingOver,
            PlayerStage::Ended => Self::Ended,
            PlayerStage::Failed => Self::Failed,
            PlayerStage::Closed => Self::Closed,
        }
    }
}

/// Where the picture goes (`swiftly_vm::Surface`), beside the lifecycle in [`PlayerStageState`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PlayerSurface {
    /// On this screen.
    Inline,
    /// In the small window (PiP).
    Pip,
    /// AirPlay was asked for; the plan is being fetched.
    AirPlayAsking,
    /// The TV shows the picture.
    AirPlay,
}

impl From<swiftly_vm::Surface> for PlayerSurface {
    fn from(s: swiftly_vm::Surface) -> Self {
        match s {
            swiftly_vm::Surface::Inline => Self::Inline,
            swiftly_vm::Surface::Pip => Self::Pip,
            swiftly_vm::Surface::AirPlayAsking => Self::AirPlayAsking,
            swiftly_vm::Surface::AirPlay => Self::AirPlay,
        }
    }
}

/// What the host reports about the surface (`swiftly_vm::SurfaceEvent`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PlayerSurfaceEvent {
    /// The small window opened (`true`) or closed (`false`).
    Pip { on: bool },
    /// The TV took over (the plan is handed to the AirPlay view).
    AirPlayTaken,
    /// The plan fetch failed or the server refused.
    AirPlayRefused,
    /// The route went back to the device.
    AirPlayBack,
}

impl From<PlayerSurfaceEvent> for swiftly_vm::SurfaceEvent {
    fn from(e: PlayerSurfaceEvent) -> Self {
        match e {
            PlayerSurfaceEvent::Pip { on } => Self::Pip(on),
            PlayerSurfaceEvent::AirPlayTaken => Self::AirPlayTaken,
            PlayerSurfaceEvent::AirPlayRefused => Self::AirPlayRefused,
            PlayerSurfaceEvent::AirPlayBack => Self::AirPlayBack,
        }
    }
}

/// The control bar (`swiftly_vm::Controls`); times are the host's clock in seconds.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Enum)]
pub enum ControlsStage {
    Hidden,
    /// Fading in since `since`.
    Showing {
        since: f64,
    },
    /// On screen until `hide_at`.
    Visible {
        hide_at: f64,
    },
    /// Fading out since `since`.
    Hiding {
        since: f64,
    },
}

impl From<Controls> for ControlsStage {
    fn from(c: Controls) -> Self {
        match c {
            Controls::Hidden => Self::Hidden,
            Controls::Showing { since } => Self::Showing { since },
            Controls::Visible { hide_at } => Self::Visible { hide_at },
            Controls::Hiding { since } => Self::Hiding { since },
        }
    }
}

/// Which side a seek tap was on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SeekSide {
    Back,
    Forward,
}

/// The seek chain (`swiftly_vm::SeekChain`).
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Enum)]
pub enum SeekChainState {
    None,
    /// Taps add up on one side until `until`.
    Chain {
        side: SeekSide,
        seconds: i64,
        taps: u32,
        until: f64,
    },
    /// The finger holds the progress bar.
    Scrubbing,
}

impl From<SeekChain> for SeekChainState {
    fn from(c: SeekChain) -> Self {
        match c {
            SeekChain::None => Self::None,
            SeekChain::Chain {
                side,
                seconds,
                taps,
                until,
            } => Self::Chain {
                side: match side {
                    Side::Back => SeekSide::Back,
                    Side::Forward => SeekSide::Forward,
                },
                seconds,
                taps,
                until,
            },
            SeekChain::Scrubbing => Self::Scrubbing,
        }
    }
}

/// Why a load failed although the server was reachable.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LoadFailKind {
    Server,
    Unreadable,
    Denied,
}

/// Where a screen's load stands (`swiftly_vm::Load`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LoadState {
    /// Nothing asked yet / signed out: show nothing, not "empty".
    Idle,
    Loading,
    /// Data is shown and a fresh answer is on its way.
    Refreshing,
    Loaded,
    Empty,
    Failed {
        kind: LoadFailKind,
    },
    Offline,
}

impl From<Load> for LoadState {
    fn from(l: Load) -> Self {
        match l {
            Load::Idle => Self::Idle,
            Load::Loading => Self::Loading,
            Load::Refreshing => Self::Refreshing,
            Load::Loaded => Self::Loaded,
            Load::Empty => Self::Empty,
            Load::Failed(k) => Self::Failed {
                kind: match k {
                    FailKind::Server => LoadFailKind::Server,
                    FailKind::Unreadable => LoadFailKind::Unreadable,
                    FailKind::Denied => LoadFailKind::Denied,
                },
            },
            Load::Offline => Self::Offline,
        }
    }
}

/// A screen's load state with the version of its view model.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct LoadPart {
    pub version: u64,
    pub load: LoadState,
    /// Data is on screen (`Loaded` or `Refreshing`).
    pub shows_data: bool,
    /// A request is on its way.
    pub busy: bool,
    /// The screen may offer "try again".
    pub can_retry: bool,
}

impl LoadPart {
    pub(crate) fn of(version: u64, load: Load) -> Self {
        Self {
            version,
            load: load.into(),
            shows_data: load.shows_data(),
            busy: load.is_busy(),
            can_retry: load.can_retry(),
        }
    }
}

/// How the user signs in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AccountSignInMethod {
    Password,
    QuickConnect,
    Browser,
}

impl From<SignInMethod> for AccountSignInMethod {
    fn from(m: SignInMethod) -> Self {
        match m {
            SignInMethod::Password => Self::Password,
            SignInMethod::QuickConnect => Self::QuickConnect,
            SignInMethod::Browser => Self::Browser,
        }
    }
}

impl From<AccountSignInMethod> for SignInMethod {
    fn from(m: AccountSignInMethod) -> Self {
        match m {
            AccountSignInMethod::Password => Self::Password,
            AccountSignInMethod::QuickConnect => Self::QuickConnect,
            AccountSignInMethod::Browser => Self::Browser,
        }
    }
}

/// Login, connect and account switch (`swiftly_accounts::Session`); `from` is the account that
/// stays active if the flow is cancelled.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum AccountSessionState {
    SignedOut,
    Connecting {
        server: String,
        from: Option<String>,
    },
    NeedsLogin {
        server: String,
        from: Option<String>,
    },
    SigningIn {
        server: String,
        method: AccountSignInMethod,
        from: Option<String>,
    },
    Ready {
        account: String,
    },
    Switching {
        from: String,
        to: String,
    },
    Failed {
        server: String,
        reason: String,
    },
}

impl From<Session> for AccountSessionState {
    fn from(s: Session) -> Self {
        match s {
            Session::SignedOut => Self::SignedOut,
            Session::Connecting { server, from } => Self::Connecting { server, from },
            Session::NeedsLogin { server, from } => Self::NeedsLogin { server, from },
            Session::SigningIn {
                server,
                method,
                from,
            } => Self::SigningIn {
                server,
                method: method.into(),
                from,
            },
            Session::Ready { account } => Self::Ready { account },
            Session::Switching { from, to } => Self::Switching { from, to },
            Session::Failed { server, reason } => Self::Failed { server, reason },
        }
    }
}

impl From<AccountSessionState> for Session {
    fn from(s: AccountSessionState) -> Self {
        match s {
            AccountSessionState::SignedOut => Self::SignedOut,
            AccountSessionState::Connecting { server, from } => Self::Connecting { server, from },
            AccountSessionState::NeedsLogin { server, from } => Self::NeedsLogin { server, from },
            AccountSessionState::SigningIn {
                server,
                method,
                from,
            } => Self::SigningIn {
                server,
                method: method.into(),
                from,
            },
            AccountSessionState::Ready { account } => Self::Ready { account },
            AccountSessionState::Switching { from, to } => Self::Switching { from, to },
            AccountSessionState::Failed { server, reason } => Self::Failed { server, reason },
        }
    }
}

/// What a host tells the session machine (the screen's own steps are fed by `LoginModel`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum AccountSessionEvent {
    Connect { server: String },
    Reachable,
    Unreachable { reason: String },
    BeginSignIn { method: AccountSignInMethod },
    SignedIn { account: String },
    SignInRefused,
    Cancelled,
    SwitchTo { to: String },
    SwitchDone { account: String },
    SwitchFailed,
    SignOut,
    Revoked { account: String },
}

impl From<AccountSessionEvent> for SessionEvent {
    fn from(e: AccountSessionEvent) -> Self {
        use AccountSessionEvent as E;
        match e {
            E::Connect { server } => Self::Connect { server },
            E::Reachable => Self::Reachable,
            E::Unreachable { reason } => Self::Unreachable { reason },
            E::BeginSignIn { method } => Self::BeginSignIn {
                method: method.into(),
            },
            E::SignedIn { account } => Self::SignedIn { account },
            E::SignInRefused => Self::SignInRefused,
            E::Cancelled => Self::Cancelled,
            E::SwitchTo { to } => Self::SwitchTo { to },
            E::SwitchDone { account } => Self::SwitchDone { account },
            E::SwitchFailed => Self::SwitchFailed,
            E::SignOut => Self::SignOut,
            E::Revoked { account } => Self::Revoked { account },
        }
    }
}

/// The session facts a host reads instead of `phase`/`isWorking`/`client == nil`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AccountSessionPart {
    pub state: AccountSessionState,
    /// A request runs: show progress, disable the form.
    pub working: bool,
    /// The account whose data may be on screen (never the target of a running switch).
    pub active_account: Option<String>,
    /// Home/library may load (an account is active and no switch runs).
    pub screens_may_load: bool,
}

impl AccountSessionPart {
    pub(crate) fn of(s: &Session) -> Self {
        Self {
            state: s.clone().into(),
            working: s.is_working(),
            active_account: s.active_account().map(str::to_owned),
            screens_may_load: s.screens_may_load(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stage_values_equal_the_core() {
        use PlayerStage as C;
        let pairs = [
            (C::Opening, PlayerStageState::Opening),
            (C::Playing, PlayerStageState::Playing),
            (C::Paused, PlayerStageState::Paused),
            (
                C::Restoring(Resume::Playing),
                PlayerStageState::Restoring {
                    resume: PlayerResume::Playing,
                },
            ),
            (
                C::Restoring(Resume::Paused),
                PlayerStageState::Restoring {
                    resume: PlayerResume::Paused,
                },
            ),
            (C::Switching, PlayerStageState::Switching),
            (C::HandingOver, PlayerStageState::HandingOver),
            (C::Ended, PlayerStageState::Ended),
            (C::Failed, PlayerStageState::Failed),
            (C::Closed, PlayerStageState::Closed),
        ];
        for (core, host) in pairs {
            assert_eq!(PlayerStageState::from(core), host);
        }
    }

    #[test]
    fn controls_and_chain_follow_the_core_reduce() {
        use swiftly_vm::{ChainEvent, ControlsEvent};
        let shown = Controls::Hidden.reduce(ControlsEvent::Show { now: 10.0 });
        assert!(
            matches!(ControlsStage::from(shown), ControlsStage::Showing { since } if since == 10.0)
        );
        let hidden = ControlsStage::from(Controls::Hidden);
        assert_eq!(hidden, ControlsStage::Hidden);
        let chain = SeekChain::None.reduce(ChainEvent::Tap {
            side: Side::Forward,
            seconds: -10,
            now: 1.0,
        });
        match SeekChainState::from(chain) {
            SeekChainState::Chain {
                side,
                seconds,
                taps,
                until,
            } => {
                assert_eq!((side, seconds, taps), (SeekSide::Forward, 10, 1));
                assert!((until - 1.7).abs() < 1e-9);
            }
            other => panic!("{other:?}"),
        }
        assert_eq!(
            SeekChainState::from(SeekChain::Scrubbing),
            SeekChainState::Scrubbing
        );
        assert_eq!(SeekChainState::from(SeekChain::None), SeekChainState::None);
    }

    #[test]
    fn load_values_and_flags_equal_the_core() {
        let all = [
            Load::Idle,
            Load::Loading,
            Load::Refreshing,
            Load::Loaded,
            Load::Empty,
            Load::Failed(FailKind::Server),
            Load::Failed(FailKind::Unreadable),
            Load::Failed(FailKind::Denied),
            Load::Offline,
        ];
        for load in all {
            let part = LoadPart::of(3, load);
            assert_eq!(part.shows_data, load.shows_data());
            assert_eq!(part.busy, load.is_busy());
            assert_eq!(part.can_retry, load.can_retry());
            assert_eq!(part.version, 3);
        }
        assert_eq!(
            LoadState::from(Load::Failed(FailKind::Denied)),
            LoadState::Failed {
                kind: LoadFailKind::Denied
            }
        );
        assert_eq!(LoadState::from(Load::Refreshing), LoadState::Refreshing);
    }

    #[test]
    fn session_round_trips_and_reduces_like_the_core() {
        let s = Session::SignedOut
            .reduce(SessionEvent::Connect {
                server: "srv".into(),
            })
            .reduce(SessionEvent::Reachable);
        let host = AccountSessionState::from(s.clone());
        assert_eq!(
            host,
            AccountSessionState::NeedsLogin {
                server: "srv".into(),
                from: None
            }
        );
        assert_eq!(Session::from(host), s);
        // A host event reduces to the same state as the core event.
        let ev = AccountSessionEvent::SignedIn {
            account: "a".into(),
        };
        let ready = s
            .reduce(SessionEvent::BeginSignIn {
                method: SignInMethod::Password,
            })
            .reduce(ev.clone().into());
        let part = AccountSessionPart::of(&ready);
        assert_eq!(
            part.state,
            AccountSessionState::Ready {
                account: "a".into()
            }
        );
        assert!(part.screens_may_load && !part.working);
        let switching = ready.reduce(SessionEvent::SwitchTo { to: "b".into() });
        let part = AccountSessionPart::of(&switching);
        assert!(part.working && !part.screens_may_load);
        assert_eq!(part.active_account.as_deref(), Some("a"));
    }
}
