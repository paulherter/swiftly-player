//! The exported server page (`swiftly_vm::ServerAdminVm`, `ServerLogsVm`) and the rows of Profile > "Verwaltung".
//! Each host draws the one shared screen object; nothing here decides what is shown.

use std::sync::Arc;

use swiftly_vm::{
    AccountRef, AdminWords, HubSection, HubSectionKind, ProfileEntry, ProfileEntryKind,
    ServerAction, ServerActionKind, ServerAdminAsk, ServerAdminIntent, ServerAdminPage,
    ServerAdminPart, ServerAdminState, ServerBadge, ServerBadgeKind, ServerDiskIo, ServerDiskRow,
    ServerLoadView, ServerLogRow, ServerLogsIntent, ServerLogsPart, ServerLogsState, ServerMeter,
    ServerNumber, ServerStreamCard, ServerTaskRow,
};

use crate::error::CoreError;
use crate::transport::CoreTransport;

#[uniffi::remote(Record)]
pub struct ServerNumber {
    pub label: String,
    pub value: i64,
    pub text: String,
}

#[uniffi::remote(Record)]
pub struct ServerTaskRow {
    pub id: String,
    pub name: String,
    pub progress: Option<f64>,
    pub progress_text: Option<String>,
}

#[uniffi::remote(Enum)]
pub enum ServerBadgeKind {
    Resolution,
    Range,
    Video,
    Audio,
}

#[uniffi::remote(Record)]
pub struct ServerBadge {
    pub kind: ServerBadgeKind,
    pub text: String,
}

#[uniffi::remote(Record)]
pub struct ServerStreamCard {
    pub id: String,
    pub session_id: String,
    pub user_name: String,
    pub user_id: Option<String>,
    pub user_image_tag: Option<String>,
    pub title: String,
    pub addition: Option<String>,
    pub subtitle: Option<String>,
    pub poster_id: String,
    pub poster_tag: Option<String>,
    pub square_poster: bool,
    pub is_audio: bool,
    pub badges: Vec<ServerBadge>,
    pub device_line: String,
    pub share: f64,
    pub time_line: String,
    pub paused: bool,
    pub delivery_text: String,
    pub delivery_line: String,
    pub cautionary: bool,
}

#[uniffi::remote(Record)]
pub struct ServerMeter {
    pub label: String,
    pub share: f64,
    pub text: String,
}

#[uniffi::remote(Record)]
pub struct ServerDiskIo {
    pub label: String,
    pub text: String,
}

#[uniffi::remote(Record)]
pub struct ServerLoadView {
    pub cpu: Option<ServerMeter>,
    pub memory: Option<ServerMeter>,
    pub disk_io: Option<ServerDiskIo>,
}

#[uniffi::remote(Record)]
pub struct ServerDiskRow {
    pub id: String,
    pub title: String,
    pub free_text: String,
    pub free_share: f64,
    pub nearly_full: bool,
}

#[uniffi::remote(Enum)]
pub enum ServerActionKind {
    ScanLibraries,
    Restart,
    Logs,
}

#[uniffi::remote(Record)]
pub struct ServerAction {
    pub kind: ServerActionKind,
    pub title: String,
    pub under: Option<String>,
    pub accent: bool,
}

#[uniffi::remote(Enum)]
pub enum ServerAdminAsk {
    Nothing,
    Restart {
        title: String,
        note: String,
        action: String,
    },
    StopTask {
        id: String,
        title: String,
        action: String,
    },
    StopStream {
        session_id: String,
        title: String,
        line: String,
        message_label: String,
        message: String,
        action: String,
    },
}

#[uniffi::remote(Record)]
pub struct ServerAdminPage {
    pub server_title: String,
    pub name: String,
    pub version: String,
    pub counts: Vec<ServerNumber>,
    pub resolutions: Vec<ServerNumber>,
    pub tasks_title: String,
    pub tasks: Vec<ServerTaskRow>,
    pub streams_title: String,
    pub streams_empty: String,
    pub streams: Vec<ServerStreamCard>,
    pub load_title: String,
    pub load: Option<ServerLoadView>,
    pub disks: Vec<ServerDiskRow>,
    pub actions_title: String,
    pub actions: Vec<ServerAction>,
    pub notice: Option<String>,
    pub ask: ServerAdminAsk,
}

#[uniffi::remote(Enum)]
pub enum ServerAdminState {
    Loading,
    Ready { page: ServerAdminPage },
    Failed { hint: String },
    NotAllowed { hint: String },
}

#[uniffi::remote(Record)]
pub struct ServerAdminPart {
    pub version: u64,
    pub title: String,
    pub state: ServerAdminState,
}

#[uniffi::remote(Enum)]
pub enum ServerAdminIntent {
    Start,
    Stop,
    Retry,
    Scan,
    AskRestart,
    AskStopTask { id: String },
    AskStopStream { session_id: String },
    Confirm { message: Option<String> },
    Cancel,
}

#[uniffi::remote(Record)]
pub struct ServerLogRow {
    pub name: String,
    pub size_text: String,
    pub day: Option<String>,
}

#[uniffi::remote(Enum)]
pub enum ServerLogsState {
    Loading,
    Files { rows: Vec<ServerLogRow> },
    Empty { hint: String },
    Text { name: String, text: String },
    Failed { hint: String },
}

#[uniffi::remote(Record)]
pub struct ServerLogsPart {
    pub version: u64,
    pub title: String,
    pub state: ServerLogsState,
}

#[uniffi::remote(Enum)]
pub enum ServerLogsIntent {
    Load,
    Open { name: String },
    Back,
}

#[uniffi::remote(Enum)]
pub enum ProfileEntryKind {
    Admin,
    Mine,
}

#[uniffi::remote(Enum)]
pub enum HubSectionKind {
    Requests,
    Issues,
    Server,
}

/// The action words of the management hub (`SeerrHub::admin_words`).
#[uniffi::remote(Record)]
pub struct AdminWords {
    pub approve: String,
    pub decline: String,
    pub retry: String,
    pub withdraw: String,
    pub reply: String,
    pub resolve: String,
    pub reopen: String,
    pub cancel: String,
    pub back: String,
    pub loading: String,
    pub no_reports: String,
    pub nothing_requested: String,
    pub seerr_offline: String,
    pub reports: String,
    pub server: String,
}

#[uniffi::remote(Record)]
pub struct HubSection {
    pub kind: HubSectionKind,
    pub title: String,
    pub count: i64,
    pub manage: bool,
}

#[uniffi::remote(Record)]
pub struct ProfileEntry {
    pub kind: ProfileEntryKind,
    pub title: String,
    pub under: Option<String>,
    pub count: i64,
    pub sections: Vec<HubSection>,
}

/// Does this account's server have the page (Jellyfin only)? The host also needs `is_administrator` from the account
/// defaults; `SeerrHub::profile_entry` combines both.
#[uniffi::export]
pub fn server_admin_offered(account: AccountRef) -> bool {
    swiftly_vm::server_admin_offered(&account)
}

/// The server page of one account.
#[derive(uniffi::Object)]
pub struct ServerAdminVm {
    vm: swiftly_vm::ServerAdminVm<CoreTransport>,
}

impl ServerAdminVm {
    pub(crate) fn wrap(vm: swiftly_vm::ServerAdminVm<CoreTransport>) -> Arc<Self> {
        Arc::new(Self { vm })
    }
}

#[uniffi::export]
impl ServerAdminVm {
    /// The version; moves whenever the part changes.
    pub fn version(&self) -> u64 {
        self.vm.version()
    }

    /// The whole screen state.
    pub fn part(&self) -> ServerAdminPart {
        ServerAdminPart::clone(&self.vm.part())
    }

    /// An intent: `Start` when the page is on screen, `Stop` when it left.
    pub fn send(&self, intent: ServerAdminIntent) {
        self.vm.send(intent);
    }

    /// Resolves when the part is newer than `seen`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn changed(&self, seen: u64) -> Result<swiftly_vm::Change, CoreError> {
        Ok(self.vm.changed(seen).await)
    }

    /// Observers parked in `changed`.
    pub fn waiters(&self) -> u32 {
        self.vm.waiters()
    }
}

/// The log files of the server.
#[derive(uniffi::Object)]
pub struct ServerLogsVm {
    vm: swiftly_vm::ServerLogsVm<CoreTransport>,
}

impl ServerLogsVm {
    pub(crate) fn wrap(vm: swiftly_vm::ServerLogsVm<CoreTransport>) -> Arc<Self> {
        Arc::new(Self { vm })
    }
}

#[uniffi::export]
impl ServerLogsVm {
    /// The version; moves whenever the part changes.
    pub fn version(&self) -> u64 {
        self.vm.version()
    }

    /// The whole screen state.
    pub fn part(&self) -> ServerLogsPart {
        ServerLogsPart::clone(&self.vm.part())
    }

    /// An intent: `Load` first, then `Open` / `Back`.
    pub fn send(&self, intent: ServerLogsIntent) {
        self.vm.send(intent);
    }

    /// Resolves when the part is newer than `seen`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn changed(&self, seen: u64) -> Result<swiftly_vm::Change, CoreError> {
        Ok(self.vm.changed(seen).await)
    }

    /// Observers parked in `changed`.
    pub fn waiters(&self) -> u32 {
        self.vm.waiters()
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use std::time::Duration;

    use super::*;
    use crate::core::{Core, Platform};
    use crate::stores::{KeyValueStore, SecretStore};
    use crate::transport::{HttpClient, HttpFailure, NetRequest, NetResponse};
    use swiftly_jellyfin::ServerKind;

    struct Quiet;
    impl Platform for Quiet {
        fn device_name(&self) -> String {
            "test".to_owned()
        }
        fn log(&self, _line: String) {}
        fn cache_dir(&self) -> Option<String> {
            None
        }
    }

    struct NoSecrets;
    impl SecretStore for NoSecrets {
        fn get(&self, _name: String) -> Option<String> {
            None
        }
        fn set(&self, _name: String, _value: String) {}
        fn remove(&self, _name: String) {}
    }

    struct NoBytes;
    impl KeyValueStore for NoBytes {
        fn get(&self, _key: String) -> Option<Vec<u8>> {
            None
        }
        fn set(&self, _key: String, _value: Vec<u8>) {}
        fn remove(&self, _key: String) {}
    }

    /// A Jellyfin that answers what the page and the log screen read.
    struct Server;

    #[async_trait::async_trait]
    impl HttpClient for Server {
        async fn send(&self, r: NetRequest) -> Result<NetResponse, HttpFailure> {
            let path = r.url.split('?').next().unwrap_or("").to_owned();
            let path = path.strip_prefix("https://one.example").unwrap_or(&path);
            let (status, body) = match path {
                "/System/Info" => (200, r#"{"ServerName":"lysnet","Version":"10.11.2"}"#),
                "/Items/Counts" => (
                    200,
                    r#"{"MovieCount":1204,"SeriesCount":2,"EpisodeCount":40}"#,
                ),
                "/Items" => (200, r#"{"Items":[],"TotalRecordCount":5}"#),
                "/Sessions" | "/ScheduledTasks" => (200, "[]"),
                "/System/Logs" => (
                    200,
                    r#"[{"Name":"a.log","Size":1500000,"DateModified":"2026-11-17T10:00:00.0000000Z"}]"#,
                ),
                p if p.starts_with("/JellyTwiggy/") => (404, ""),
                _ => (200, "{}"),
            };
            Ok(NetResponse {
                status,
                headers: Vec::new(),
                body: body.as_bytes().to_vec(),
                url: None,
            })
        }
    }

    fn account(kind: ServerKind) -> AccountRef {
        AccountRef {
            base_url: "https://one.example".into(),
            user_id: "u1".into(),
            token: "TOKEN".into(),
            server_kind: kind,
            device_id: "d".into(),
            plex_machine_id: None,
            plex_account_token: None,
        }
    }

    fn core() -> Arc<Core> {
        Core::new(
            Arc::new(Quiet),
            Arc::new(NoSecrets),
            Arc::new(NoBytes),
            Arc::new(Server),
        )
    }

    #[test]
    fn the_server_offer_follows_the_kind() {
        assert!(server_admin_offered(account(ServerKind::Jellyfin)));
        assert!(!server_admin_offered(account(ServerKind::Plex)));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn the_page_runs_through_the_exported_object() {
        let core = core();
        assert!(
            core.server_admin_vm(account(ServerKind::Plex), "en".into())
                .is_err()
        );
        let vm = core
            .server_admin_vm(account(ServerKind::Jellyfin), "en".into())
            .unwrap();
        assert!(matches!(vm.part().state, ServerAdminState::Loading));
        vm.send(ServerAdminIntent::Start);
        let mut seen = 0;
        for _ in 0..20 {
            if matches!(vm.part().state, ServerAdminState::Ready { .. }) {
                break;
            }
            seen = vm.version();
            tokio::time::timeout(Duration::from_secs(5), vm.changed(seen))
                .await
                .expect("the page changes")
                .unwrap();
        }
        let part = vm.part();
        assert_eq!(part.title, "lysnet");
        let ServerAdminState::Ready { page } = part.state else {
            panic!("not ready after {seen}");
        };
        assert_eq!(page.counts[0].text, "1,204");
        vm.send(ServerAdminIntent::AskRestart);
        let ServerAdminState::Ready { page } = vm.part().state else {
            panic!("not ready");
        };
        assert!(matches!(page.ask, ServerAdminAsk::Restart { .. }));
        vm.send(ServerAdminIntent::Cancel);
        vm.send(ServerAdminIntent::Stop);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn the_log_screen_runs_through_the_exported_object() {
        let core = core();
        let vm = core
            .server_logs_vm(account(ServerKind::Jellyfin), "en".into())
            .unwrap();
        vm.send(ServerLogsIntent::Load);
        for _ in 0..20 {
            if matches!(vm.part().state, ServerLogsState::Files { .. }) {
                break;
            }
            let seen = vm.version();
            tokio::time::timeout(Duration::from_secs(5), vm.changed(seen))
                .await
                .expect("the list changes")
                .unwrap();
        }
        let ServerLogsState::Files { rows } = vm.part().state else {
            panic!("no files");
        };
        assert_eq!(rows[0].name, "a.log");
    }
}
