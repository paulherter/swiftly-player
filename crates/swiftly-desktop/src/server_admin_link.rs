//! The server management page of the desktop (`Profil > Serververwaltung`): the core's `ServerAdminVm` and
//! `ServerLogsVm` (`swiftly_vm::server_admin`: the same screen objects the iPhone draws) over the app transport. The
//! core runs every call and keeps the states (`Loading | Ready | Failed | NotAllowed`, the question before a restart,
//! the once-vs-live reads); this file only gives the screen one handle to them and answers the one thing the page needs
//! besides: "is this account an administrator" (`Policy.IsAdministrator`, asked once per account and kept for the run, as
//! the iPhone's `ServerAdminAccess` does).

use crate::live::Core;
use crate::seerr_link::Shared;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use swiftly_images::{ImageAddress, ImageKind, ImageMetric};
use swiftly_jellyfin::ServerKind;
use swiftly_l10n::Locale;
use swiftly_net::HttpTransport;
use swiftly_vm::{
    ProfileEntry, SeerrHubInfo, ServerAdminIntent, ServerAdminPart, ServerAdminVm,
    ServerLogsIntent, ServerLogsPart, ServerLogsVm, profile_entry, server_admin_offered,
};

/// The page as the Profile and the two pages use it.
pub trait AdminLink {
    /// Whether the active account is an administrator; `None` until the server answered (no row meanwhile).
    fn administrator(&self) -> Option<bool>;
    /// The one Profile entry (`profile_entry`): the core decides from the server (Jellyfin and an administrator) and
    /// the Seerr hub's answer (`seerr`, `None` without a connection), or `None` when nothing is offered.
    fn entry(&self, seerr: Option<&SeerrHubInfo>) -> Option<ProfileEntry> {
        profile_entry(
            &swiftly_l10n::current_locale(),
            ServerKind::Emby,
            false,
            seerr,
        )
    }
    /// The page is on screen, or is being read ahead: load once, then read every second.
    fn start(&self);
    /// The page left the screen: stop reading.
    fn stop(&self);
    /// What the page draws.
    fn part(&self) -> Arc<ServerAdminPart>;
    /// An intent of the page.
    fn send(&self, intent: ServerAdminIntent);
    /// What the log pages draw.
    fn logs_part(&self) -> Arc<ServerLogsPart>;
    /// An intent of the log pages.
    fn send_logs(&self, intent: ServerLogsIntent);
    /// The address builder of the server, for posters and the pictures of the viewers.
    fn images(&self) -> Option<ImageAddress>;
}

/// No page: Plex, Emby, the demo and a signed-out app have no server row.
pub struct NoAdmin;

impl AdminLink for NoAdmin {
    fn administrator(&self) -> Option<bool> {
        None
    }
    fn start(&self) {}
    fn stop(&self) {}
    fn part(&self) -> Arc<ServerAdminPart> {
        Arc::new(ServerAdminPart {
            version: 0,
            title: String::new(),
            state: swiftly_vm::ServerAdminState::Loading,
        })
    }
    fn send(&self, _intent: ServerAdminIntent) {}
    fn logs_part(&self) -> Arc<ServerLogsPart> {
        Arc::new(ServerLogsPart {
            version: 0,
            title: String::new(),
            state: swiftly_vm::ServerLogsState::Loading,
        })
    }
    fn send_logs(&self, _intent: ServerLogsIntent) {}
    fn images(&self) -> Option<ImageAddress> {
        None
    }
}

/// The administrator answers of this run, by account key.
fn known() -> &'static Mutex<HashMap<String, bool>> {
    static KNOWN: OnceLock<Mutex<HashMap<String, bool>>> = OnceLock::new();
    KNOWN.get_or_init(|| Mutex::new(HashMap::new()))
}

/// The Profile entry of the active account for the Seerr pages (`PageScreen`): the same `profile_entry` the Profile row
/// shows, from the account's server kind, the remembered administrator answer and the hub's answer.
pub fn entry_for(core: &Arc<Core>, hub: &SeerrHubInfo) -> Option<ProfileEntry> {
    let account = core.account()?;
    let administrator = known()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .get(&account.key())
        .copied()
        .unwrap_or(false);
    profile_entry(
        &core.host().locale,
        account.server_kind,
        administrator,
        Some(hub),
    )
}

/// The page of one Jellyfin account.
pub struct LiveAdmin<T: HttpTransport + 'static> {
    vm: ServerAdminVm<T>,
    logs: ServerLogsVm<T>,
    key: String,
    images: Option<ImageAddress>,
    locale: Locale,
}

impl<T: HttpTransport + 'static> LiveAdmin<T> {
    /// The page over the two core objects; `administrator` is the answer already known (tests, the cache).
    pub fn with(
        vm: ServerAdminVm<T>,
        logs: ServerLogsVm<T>,
        key: &str,
        administrator: Option<bool>,
        images: Option<ImageAddress>,
        locale: Locale,
    ) -> LiveAdmin<T> {
        if let Some(a) = administrator {
            known()
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .insert(key.to_owned(), a);
        }
        LiveAdmin {
            vm,
            logs,
            key: key.to_owned(),
            images,
            locale,
        }
    }
}

impl LiveAdmin<Shared> {
    /// The page of the active account, or `None` for an account whose server has none (Emby, Plex) or when nobody is
    /// signed in. Asks the server once whether the account is an administrator (a remembered answer counts at once).
    pub fn new(core: &Arc<Core>) -> Option<LiveAdmin<Shared>> {
        let account = core.account()?;
        if !server_admin_offered(&account) {
            return None;
        }
        let transport = Arc::new(Shared(Arc::clone(&core.net)));
        let vm = ServerAdminVm::new(
            Arc::clone(&transport),
            core.host(),
            core.sleeper(),
            &account,
        )
        .ok()?;
        let logs = ServerLogsVm::new(transport, core.host(), &account).ok()?;
        let key = account.key();
        let images = swiftly_images::Url::parse(&account.base_url)
            .ok()
            .map(|base| ImageAddress::new(base, Some(account.token.clone()), account.server_kind));
        let answer = known()
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(&key)
            .copied();
        if answer.is_none() {
            let (core, asked_key) = (Arc::clone(core), key.clone());
            let ask = Arc::clone(&core);
            core.spawn(async move {
                let Ok(server) = ask.server_for(&account) else {
                    return;
                };
                // A missing answer (offline) is not remembered: the next visit asks again.
                if let Some(gift) = server.account_defaults().await {
                    known()
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .insert(asked_key, gift.is_administrator.unwrap_or(false));
                }
            });
        }
        Some(LiveAdmin {
            vm,
            logs,
            key,
            images,
            locale: core.host().locale,
        })
    }
}

impl<T: HttpTransport + 'static> AdminLink for LiveAdmin<T> {
    fn administrator(&self) -> Option<bool> {
        known()
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(&self.key)
            .copied()
    }
    fn entry(&self, seerr: Option<&SeerrHubInfo>) -> Option<ProfileEntry> {
        // Until the server answered, an administrator's row is not offered (no row that would change its mind).
        profile_entry(
            &self.locale,
            ServerKind::Jellyfin,
            self.administrator().unwrap_or(false),
            seerr,
        )
    }
    fn start(&self) {
        self.vm.send(ServerAdminIntent::Start);
    }
    fn stop(&self) {
        self.vm.send(ServerAdminIntent::Stop);
    }
    fn part(&self) -> Arc<ServerAdminPart> {
        self.vm.part()
    }
    fn send(&self, intent: ServerAdminIntent) {
        self.vm.send(intent);
    }
    fn logs_part(&self) -> Arc<ServerLogsPart> {
        self.logs.part()
    }
    fn send_logs(&self, intent: ServerLogsIntent) {
        self.logs.send(intent);
    }
    fn images(&self) -> Option<ImageAddress> {
        self.images.clone()
    }
}

/// The address of a poster (`Items/{id}/Images/Primary`) at `edge` points of height, in pixels twice that.
pub fn poster_address(
    images: &ImageAddress,
    id: &str,
    tag: Option<&str>,
    edge: f32,
) -> Option<String> {
    images
        .construct(
            id,
            ImageKind::Poster,
            tag,
            ImageMetric::AtMostHigh((edge * 2.0).round() as i64),
        )
        .map(|u| u.to_string())
}

/// The address of a viewer's picture, `edge` points square.
pub fn user_address(
    images: &ImageAddress,
    id: &str,
    tag: Option<&str>,
    edge: f32,
) -> Option<String> {
    images
        .user(id, tag, (edge * 2.0).round() as i64)
        .map(|u| u.to_string())
}
