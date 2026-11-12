//! More explicit state machines as host-visible enums (additive, see `state.rs`): next-episode
//! card, download item/queue/network, settings sync, Quick Connect, server probe, discovery.
//! Every enum mirrors the core enum one to one; the pure `reduce` functions are exported so a
//! host without its own copy of the table can run the transition (`None` = illegal event).

use swiftly_downloads::{ItemEvent, ItemPhase, Network, PausedBy, QueuePhase};
use swiftly_jellyfin::{DiscoveryEvent, DiscoveryPhase, QuickEvent, QuickPhase};
use swiftly_sync::{Decision, SettingsSyncEvent, SettingsSyncPhase};
use swiftly_vm::{NextCard, NextCardEvent as CoreNextCardEvent};
use swiftly_vm::{ProbeEvent, ServerProbe};

/// The next-episode card (`swiftly_vm::NextCard`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum NextCardState {
    Hidden,
    Offered { episode: u32 },
    Zooming { episode: u32 },
    Switching { episode: u32 },
    Dismissed { episode: u32 },
}

impl From<NextCard> for NextCardState {
    fn from(s: NextCard) -> Self {
        match s {
            NextCard::Hidden => Self::Hidden,
            NextCard::Offered { episode } => Self::Offered { episode },
            NextCard::Zooming { episode } => Self::Zooming { episode },
            NextCard::Switching { episode } => Self::Switching { episode },
            NextCard::Dismissed { episode } => Self::Dismissed { episode },
        }
    }
}

impl From<NextCardState> for NextCard {
    fn from(s: NextCardState) -> Self {
        match s {
            NextCardState::Hidden => Self::Hidden,
            NextCardState::Offered { episode } => Self::Offered { episode },
            NextCardState::Zooming { episode } => Self::Zooming { episode },
            NextCardState::Switching { episode } => Self::Switching { episode },
            NextCardState::Dismissed { episode } => Self::Dismissed { episode },
        }
    }
}

/// What happens to the card (`swiftly_vm::NextCardEvent`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum NextCardEvent {
    Offer { episode: u32 },
    Accept,
    ZoomDone,
    Switched,
    SwitchFailed,
    Dismiss,
    WindowLeft,
    Reset,
}

impl From<NextCardEvent> for CoreNextCardEvent {
    fn from(e: NextCardEvent) -> Self {
        match e {
            NextCardEvent::Offer { episode } => Self::Offer { episode },
            NextCardEvent::Accept => Self::Accept,
            NextCardEvent::ZoomDone => Self::ZoomDone,
            NextCardEvent::Switched => Self::Switched,
            NextCardEvent::SwitchFailed => Self::SwitchFailed,
            NextCardEvent::Dismiss => Self::Dismiss,
            NextCardEvent::WindowLeft => Self::WindowLeft,
            NextCardEvent::Reset => Self::Reset,
        }
    }
}

/// The card's transition as a pure function; `None` = the event is illegal in that state.
#[uniffi::export]
pub fn next_card_reduce(state: NextCardState, event: NextCardEvent) -> Option<NextCardState> {
    NextCard::from(state)
        .try_reduce(event.into())
        .map(Into::into)
}

// ---- downloads ----

/// What the network offers (`swiftly_downloads::Network`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DownloadNetwork {
    Unknown,
    Offline,
    Cellular,
    Wifi,
}

impl From<DownloadNetwork> for Network {
    fn from(n: DownloadNetwork) -> Self {
        match n {
            DownloadNetwork::Unknown => Self::Unknown,
            DownloadNetwork::Offline => Self::Offline,
            DownloadNetwork::Cellular => Self::Cellular,
            DownloadNetwork::Wifi => Self::Wifi,
        }
    }
}

/// Who paused a download.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DownloadPausedBy {
    User,
    Transfer,
}

/// One download (`swiftly_downloads::ItemPhase`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DownloadItemPhase {
    Queued,
    Running { generation: u32 },
    Paused { by: DownloadPausedBy },
    Offline,
    Failed,
    Done,
}

impl From<ItemPhase> for DownloadItemPhase {
    fn from(p: ItemPhase) -> Self {
        match p {
            ItemPhase::Queued => Self::Queued,
            ItemPhase::Running { generation } => Self::Running { generation },
            ItemPhase::Paused(PausedBy::User) => Self::Paused {
                by: DownloadPausedBy::User,
            },
            ItemPhase::Paused(PausedBy::Transfer) => Self::Paused {
                by: DownloadPausedBy::Transfer,
            },
            ItemPhase::Offline => Self::Offline,
            ItemPhase::Failed => Self::Failed,
            ItemPhase::Done => Self::Done,
        }
    }
}

impl From<DownloadItemPhase> for ItemPhase {
    fn from(p: DownloadItemPhase) -> Self {
        match p {
            DownloadItemPhase::Queued => Self::Queued,
            DownloadItemPhase::Running { generation } => Self::Running { generation },
            DownloadItemPhase::Paused {
                by: DownloadPausedBy::User,
            } => Self::Paused(PausedBy::User),
            DownloadItemPhase::Paused {
                by: DownloadPausedBy::Transfer,
            } => Self::Paused(PausedBy::Transfer),
            DownloadItemPhase::Offline => Self::Offline,
            DownloadItemPhase::Failed => Self::Failed,
            DownloadItemPhase::Done => Self::Done,
        }
    }
}

/// What happens to one download.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DownloadItemEvent {
    Start { generation: u32 },
    Pause,
    Resume,
    Finished { generation: u32 },
    TransferFailed { generation: u32, resumable: bool },
    NetworkLost,
    NetworkBack,
    Retry,
}

impl From<DownloadItemEvent> for ItemEvent {
    fn from(e: DownloadItemEvent) -> Self {
        match e {
            DownloadItemEvent::Start { generation } => Self::Start { generation },
            DownloadItemEvent::Pause => Self::Pause,
            DownloadItemEvent::Resume => Self::Resume,
            DownloadItemEvent::Finished { generation } => Self::Finished { generation },
            DownloadItemEvent::TransferFailed {
                generation,
                resumable,
            } => Self::TransferFailed {
                generation,
                resumable,
            },
            DownloadItemEvent::NetworkLost => Self::NetworkLost,
            DownloadItemEvent::NetworkBack => Self::NetworkBack,
            DownloadItemEvent::Retry => Self::Retry,
        }
    }
}

/// The whole queue (`swiftly_downloads::QueuePhase`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DownloadQueuePhase {
    Empty,
    Running { waiting: u64 },
    Ready { waiting: u64 },
    Offline { waiting: u64 },
    Paused { paused: u64 },
    Idle { failed: u64 },
    Broken { running: u64 },
}

impl From<QueuePhase> for DownloadQueuePhase {
    fn from(p: QueuePhase) -> Self {
        match p {
            QueuePhase::Empty => Self::Empty,
            QueuePhase::Running { waiting } => Self::Running {
                waiting: waiting as u64,
            },
            QueuePhase::Ready { waiting } => Self::Ready {
                waiting: waiting as u64,
            },
            QueuePhase::Offline { waiting } => Self::Offline {
                waiting: waiting as u64,
            },
            QueuePhase::Paused { paused } => Self::Paused {
                paused: paused as u64,
            },
            QueuePhase::Idle { failed } => Self::Idle {
                failed: failed as u64,
            },
            QueuePhase::Broken { running } => Self::Broken {
                running: running as u64,
            },
        }
    }
}

/// One download's transition as a pure function; `None` = illegal event.
#[uniffi::export]
pub fn download_item_reduce(
    phase: DownloadItemPhase,
    event: DownloadItemEvent,
) -> Option<DownloadItemPhase> {
    ItemPhase::from(phase)
        .try_reduce(event.into())
        .map(Into::into)
}

/// May a transfer run on this network?
#[uniffi::export]
pub fn download_network_allows(network: DownloadNetwork, only_wifi: bool) -> bool {
    Network::from(network).allows(only_wifi)
}

// ---- settings sync ----

/// Where the settings sync is (`swiftly_sync::SettingsSyncPhase`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SettingsSyncPhaseState {
    Idle,
    Pulling,
    Applying,
    Pushing,
    Conflict,
    Done,
    Failed,
}

impl From<SettingsSyncPhase> for SettingsSyncPhaseState {
    fn from(p: SettingsSyncPhase) -> Self {
        match p {
            SettingsSyncPhase::Idle => Self::Idle,
            SettingsSyncPhase::Pulling => Self::Pulling,
            SettingsSyncPhase::Applying => Self::Applying,
            SettingsSyncPhase::Pushing => Self::Pushing,
            SettingsSyncPhase::Conflict => Self::Conflict,
            SettingsSyncPhase::Done => Self::Done,
            SettingsSyncPhase::Failed => Self::Failed,
        }
    }
}

impl From<SettingsSyncPhaseState> for SettingsSyncPhase {
    fn from(p: SettingsSyncPhaseState) -> Self {
        match p {
            SettingsSyncPhaseState::Idle => Self::Idle,
            SettingsSyncPhaseState::Pulling => Self::Pulling,
            SettingsSyncPhaseState::Applying => Self::Applying,
            SettingsSyncPhaseState::Pushing => Self::Pushing,
            SettingsSyncPhaseState::Conflict => Self::Conflict,
            SettingsSyncPhaseState::Done => Self::Done,
            SettingsSyncPhaseState::Failed => Self::Failed,
        }
    }
}

/// What happens to the settings sync. `FetchedApply`/`FetchedPush`/`FetchedNothing` carry the
/// comparison's verdict (`Decision`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SettingsSyncEventKind {
    Pull,
    FetchedApply,
    FetchedPush,
    FetchedNothing,
    Applied,
    Pushed,
    Rejected,
    Failed,
    Reset,
}

impl From<SettingsSyncEventKind> for SettingsSyncEvent {
    fn from(e: SettingsSyncEventKind) -> Self {
        match e {
            SettingsSyncEventKind::Pull => Self::Pull,
            SettingsSyncEventKind::FetchedApply => Self::Fetched(Decision::Apply),
            SettingsSyncEventKind::FetchedPush => Self::Fetched(Decision::Push),
            SettingsSyncEventKind::FetchedNothing => Self::Fetched(Decision::Nothing),
            SettingsSyncEventKind::Applied => Self::Applied,
            SettingsSyncEventKind::Pushed => Self::Pushed,
            SettingsSyncEventKind::Rejected => Self::Rejected,
            SettingsSyncEventKind::Failed => Self::Failed,
            SettingsSyncEventKind::Reset => Self::Reset,
        }
    }
}

/// The settings sync transition as a pure function; `None` = illegal event.
#[uniffi::export]
pub fn settings_sync_reduce(
    phase: SettingsSyncPhaseState,
    event: SettingsSyncEventKind,
) -> Option<SettingsSyncPhaseState> {
    SettingsSyncPhase::from(phase)
        .try_reduce(event.into())
        .map(Into::into)
}

/// A request is on its way (progress shown, a new run refused).
#[uniffi::export]
pub fn settings_sync_busy(phase: SettingsSyncPhaseState) -> bool {
    SettingsSyncPhase::from(phase).busy()
}

// ---- Quick Connect ----

/// Where Quick Connect is (`swiftly_jellyfin::QuickPhase`); `run` numbers the attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum QuickConnectPhase {
    Idle,
    Requesting { run: u32 },
    Waiting { run: u32 },
    Approved { run: u32 },
    SignedIn,
    Expired,
    Failed,
}

impl From<QuickPhase> for QuickConnectPhase {
    fn from(p: QuickPhase) -> Self {
        match p {
            QuickPhase::Idle => Self::Idle,
            QuickPhase::Requesting { run } => Self::Requesting { run },
            QuickPhase::Waiting { run } => Self::Waiting { run },
            QuickPhase::Approved { run } => Self::Approved { run },
            QuickPhase::SignedIn => Self::SignedIn,
            QuickPhase::Expired => Self::Expired,
            QuickPhase::Failed => Self::Failed,
        }
    }
}

impl From<QuickConnectPhase> for QuickPhase {
    fn from(p: QuickConnectPhase) -> Self {
        match p {
            QuickConnectPhase::Idle => Self::Idle,
            QuickConnectPhase::Requesting { run } => Self::Requesting { run },
            QuickConnectPhase::Waiting { run } => Self::Waiting { run },
            QuickConnectPhase::Approved { run } => Self::Approved { run },
            QuickConnectPhase::SignedIn => Self::SignedIn,
            QuickConnectPhase::Expired => Self::Expired,
            QuickConnectPhase::Failed => Self::Failed,
        }
    }
}

/// What happens to Quick Connect; answers carry the run that asked.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum QuickConnectEvent {
    Start { run: u32 },
    Code { run: u32 },
    Released { run: u32 },
    Expired { run: u32 },
    Failed { run: u32 },
    SignedIn { run: u32 },
    Cancel,
}

impl From<QuickConnectEvent> for QuickEvent {
    fn from(e: QuickConnectEvent) -> Self {
        match e {
            QuickConnectEvent::Start { run } => Self::Start { run },
            QuickConnectEvent::Code { run } => Self::Code { run },
            QuickConnectEvent::Released { run } => Self::Released { run },
            QuickConnectEvent::Expired { run } => Self::Expired { run },
            QuickConnectEvent::Failed { run } => Self::Failed { run },
            QuickConnectEvent::SignedIn { run } => Self::SignedIn { run },
            QuickConnectEvent::Cancel => Self::Cancel,
        }
    }
}

/// The Quick Connect transition as a pure function; `None` = illegal event (a stale answer).
#[uniffi::export]
pub fn quick_connect_reduce(
    phase: QuickConnectPhase,
    event: QuickConnectEvent,
) -> Option<QuickConnectPhase> {
    QuickPhase::from(phase)
        .try_reduce(event.into())
        .map(Into::into)
}

/// A request is on its way (spinner, no second start).
#[uniffi::export]
pub fn quick_connect_busy(phase: QuickConnectPhase) -> bool {
    QuickPhase::from(phase).busy()
}

// ---- Plex server choice ----

/// One server's probe (`swiftly_vm::ServerProbe`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ServerProbeState {
    Idle,
    Probing { attempt: u32 },
    Reachable,
    Unreachable,
}

impl From<ServerProbe> for ServerProbeState {
    fn from(p: ServerProbe) -> Self {
        match p {
            ServerProbe::Idle => Self::Idle,
            ServerProbe::Probing { attempt } => Self::Probing { attempt },
            ServerProbe::Reachable => Self::Reachable,
            ServerProbe::Unreachable => Self::Unreachable,
        }
    }
}

impl From<ServerProbeState> for ServerProbe {
    fn from(p: ServerProbeState) -> Self {
        match p {
            ServerProbeState::Idle => Self::Idle,
            ServerProbeState::Probing { attempt } => Self::Probing { attempt },
            ServerProbeState::Reachable => Self::Reachable,
            ServerProbeState::Unreachable => Self::Unreachable,
        }
    }
}

/// What happens to one server's probe.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ServerProbeEvent {
    Tap,
    Answered,
    AllFailed,
    Cancel,
    Reset,
}

impl From<ServerProbeEvent> for ProbeEvent {
    fn from(e: ServerProbeEvent) -> Self {
        match e {
            ServerProbeEvent::Tap => Self::Tap,
            ServerProbeEvent::Answered => Self::Answered,
            ServerProbeEvent::AllFailed => Self::AllFailed,
            ServerProbeEvent::Cancel => Self::Cancel,
            ServerProbeEvent::Reset => Self::Reset,
        }
    }
}

/// One server's probe transition as a pure function; `None` = illegal event.
#[uniffi::export]
pub fn server_probe_reduce(
    state: ServerProbeState,
    event: ServerProbeEvent,
) -> Option<ServerProbeState> {
    ServerProbe::from(state)
        .try_reduce(event.into())
        .map(Into::into)
}

/// The index of the one server being probed in this list (the rule: one at a time).
#[uniffi::export]
pub fn server_probe_connecting(states: Vec<ServerProbeState>) -> Option<u32> {
    states
        .iter()
        .position(|s| matches!(s, ServerProbeState::Probing { .. }))
        .map(|i| i as u32)
}

// ---- server discovery ----

/// Where the local server search is (`swiftly_jellyfin::DiscoveryPhase`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DiscoveryPhaseState {
    Idle,
    Searching { found: u64 },
    Found { found: u64 },
    NothingFound,
    Denied,
}

impl From<DiscoveryPhase> for DiscoveryPhaseState {
    fn from(p: DiscoveryPhase) -> Self {
        match p {
            DiscoveryPhase::Idle => Self::Idle,
            DiscoveryPhase::Searching { found } => Self::Searching {
                found: found as u64,
            },
            DiscoveryPhase::Found { found } => Self::Found {
                found: found as u64,
            },
            DiscoveryPhase::NothingFound => Self::NothingFound,
            DiscoveryPhase::Denied => Self::Denied,
        }
    }
}

impl From<DiscoveryPhaseState> for DiscoveryPhase {
    fn from(p: DiscoveryPhaseState) -> Self {
        match p {
            DiscoveryPhaseState::Idle => Self::Idle,
            DiscoveryPhaseState::Searching { found } => Self::Searching {
                found: found as usize,
            },
            DiscoveryPhaseState::Found { found } => Self::Found {
                found: found as usize,
            },
            DiscoveryPhaseState::NothingFound => Self::NothingFound,
            DiscoveryPhaseState::Denied => Self::Denied,
        }
    }
}

/// What happens to the search.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DiscoveryStep {
    Begin,
    Heard { total: u64 },
    WindowEnded,
    PermissionDenied,
    Stop,
}

impl From<DiscoveryStep> for DiscoveryEvent {
    fn from(e: DiscoveryStep) -> Self {
        match e {
            DiscoveryStep::Begin => Self::Begin,
            DiscoveryStep::Heard { total } => Self::Heard {
                total: total as usize,
            },
            DiscoveryStep::WindowEnded => Self::WindowEnded,
            DiscoveryStep::PermissionDenied => Self::PermissionDenied,
            DiscoveryStep::Stop => Self::Stop,
        }
    }
}

/// The search's transition as a pure function; `None` = illegal event.
#[uniffi::export]
pub fn discovery_reduce(
    phase: DiscoveryPhaseState,
    event: DiscoveryStep,
) -> Option<DiscoveryPhaseState> {
    DiscoveryPhase::from(phase)
        .try_reduce(event.into())
        .map(Into::into)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn next_card_export_follows_the_core() {
        let s = next_card_reduce(NextCardState::Hidden, NextCardEvent::Offer { episode: 2 });
        assert_eq!(s, Some(NextCardState::Offered { episode: 2 }));
        assert_eq!(
            next_card_reduce(NextCardState::Hidden, NextCardEvent::Accept),
            None
        );
    }

    #[test]
    fn download_exports_follow_the_core() {
        let p = download_item_reduce(
            DownloadItemPhase::Queued,
            DownloadItemEvent::Start { generation: 4 },
        );
        assert_eq!(p, Some(DownloadItemPhase::Running { generation: 4 }));
        assert_eq!(
            download_item_reduce(DownloadItemPhase::Done, DownloadItemEvent::Pause),
            None
        );
        assert!(!download_network_allows(DownloadNetwork::Cellular, true));
        assert_eq!(
            DownloadQueuePhase::from(QueuePhase::Ready { waiting: 2 }),
            DownloadQueuePhase::Ready { waiting: 2 }
        );
    }

    #[test]
    fn settings_sync_export_follows_the_core() {
        let p = settings_sync_reduce(
            SettingsSyncPhaseState::Pulling,
            SettingsSyncEventKind::FetchedPush,
        );
        assert_eq!(p, Some(SettingsSyncPhaseState::Pushing));
        assert_eq!(
            settings_sync_reduce(SettingsSyncPhaseState::Idle, SettingsSyncEventKind::Pushed),
            None
        );
        assert!(settings_sync_busy(SettingsSyncPhaseState::Applying));
    }

    #[test]
    fn quick_connect_export_drops_stale_answers() {
        let w = QuickConnectPhase::Waiting { run: 2 };
        assert_eq!(
            quick_connect_reduce(w, QuickConnectEvent::Released { run: 1 }),
            None
        );
        assert_eq!(
            quick_connect_reduce(w, QuickConnectEvent::Released { run: 2 }),
            Some(QuickConnectPhase::Approved { run: 2 })
        );
        assert!(quick_connect_busy(QuickConnectPhase::Requesting { run: 1 }));
    }

    #[test]
    fn server_probe_export_follows_the_core() {
        assert_eq!(
            server_probe_reduce(ServerProbeState::Idle, ServerProbeEvent::Tap),
            Some(ServerProbeState::Probing { attempt: 1 })
        );
        assert_eq!(
            server_probe_reduce(ServerProbeState::Reachable, ServerProbeEvent::Tap),
            None
        );
        assert_eq!(
            server_probe_connecting(vec![
                ServerProbeState::Idle,
                ServerProbeState::Probing { attempt: 1 }
            ]),
            Some(1)
        );
    }

    #[test]
    fn discovery_export_follows_the_core() {
        let s = discovery_reduce(DiscoveryPhaseState::Idle, DiscoveryStep::Begin);
        assert_eq!(s, Some(DiscoveryPhaseState::Searching { found: 0 }));
        assert_eq!(
            discovery_reduce(DiscoveryPhaseState::Idle, DiscoveryStep::WindowEnded),
            None
        );
        let end = discovery_reduce(
            DiscoveryPhaseState::Searching { found: 0 },
            DiscoveryStep::WindowEnded,
        );
        assert_eq!(end, Some(DiscoveryPhaseState::NothingFound));
    }
}
