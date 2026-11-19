//! The proof line's answer ("Direct Play" or the delivery hint), kept per account and title so a page shows it in its
//! first frame instead of asking the server again on every open.
//!
//! The answer depends on the title's versions and on the delivery rules the device asks under (the engine's profile and
//! the bitrate limit), so a stored mark carries both and is used only while they still match. The fresh plan replaces it
//! in the background and a part that comes out equal is not redrawn. Lists on screen warm the marks of their titles
//! ([`warm`]) so even the first open of a title has it most of the time.
use std::sync::{Arc, Mutex, PoisonError};

use swiftly_cache::Ticket;
use swiftly_model::Item;
use swiftly_net::HttpTransport;
use swiftly_playback::playback_plan::PlaybackPlan;

use crate::account::AccountRef;
use crate::cache::ViewCache;
use crate::detail::{Server, clients};
use crate::host::Host;

/// The kind a mark is stored under.
pub(crate) const KIND: &str = "proof-mark";

/// Titles warmed per call of a list.
const WARM_LIMIT: usize = 6;

/// What the proof line of one title says.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub(crate) struct ProofMark {
    /// The title (or episode) the answer is for.
    pub(crate) item_id: String,
    /// The delivery rules it was asked under: the core's version (it carries the engine's profile) and the bitrate limit.
    pub(crate) profile: String,
    /// The title's versions when the answer was made (empty when they were not known yet).
    pub(crate) version: String,
    /// Delivery loses nothing.
    pub(crate) direct_play: bool,
    /// How the server delivers it otherwise.
    pub(crate) hint: Option<String>,
}

/// The delivery rules a plan asked with `max_bitrate` stands under.
pub(crate) fn profile(max_bitrate: i64) -> String {
    format!("{}|{max_bitrate}", env!("CARGO_PKG_VERSION"))
}

/// A fingerprint of the title's versions (id and size of each file); empty while the title's files are not known.
pub(crate) fn version_of(item: &Item) -> String {
    item.media_sources
        .iter()
        .flatten()
        .map(|s| format!("{}:{}", s.id.as_deref().unwrap_or(""), s.size.unwrap_or(0)))
        .collect::<Vec<_>>()
        .join(",")
}

impl ProofMark {
    /// The mark of `plan`, asked for `item_id` under `max_bitrate`.
    pub(crate) fn of(
        plan: &PlaybackPlan,
        item_id: &str,
        max_bitrate: i64,
        version: String,
    ) -> Self {
        Self {
            item_id: item_id.to_owned(),
            profile: profile(max_bitrate),
            version,
            direct_play: plan.is_lossless(),
            hint: (!plan.is_lossless()).then(|| plan.method.raw_value().to_owned()),
        }
    }

    /// Whether the page may show it for `item_id`: same delivery rules, and the versions have not changed since (known
    /// on both sides and different means the file was replaced).
    pub(crate) fn usable(
        &self,
        item_id: &str,
        max_bitrate: i64,
        fresh_version: Option<&str>,
    ) -> bool {
        self.item_id == item_id
            && self.profile == profile(max_bitrate)
            && fresh_version
                .is_none_or(|v| v.is_empty() || self.version.is_empty() || v == self.version)
    }
}

/// What the proof line shows: the plan once it answered, else the stored mark, else nothing.
pub(crate) fn shown(
    plan: Option<&PlaybackPlan>,
    answered: bool,
    mark: Option<&ProofMark>,
) -> (bool, Option<String>) {
    if let Some(p) = plan {
        let lossless = p.is_lossless();
        (
            lossless,
            (!lossless).then(|| p.method.raw_value().to_owned()),
        )
    } else if !answered && let Some(m) = mark {
        (m.direct_play, m.hint.clone())
    } else {
        (false, None)
    }
}

/// The stored mark of a title, whatever it was asked under (the page checks that with [`ProofMark::usable`]).
pub(crate) fn read(
    cache: &ViewCache,
    scope: &swiftly_cache::Scope,
    item_id: &str,
) -> Option<ProofMark> {
    cache.read_json::<ProofMark>(scope, KIND, item_id)
}

/// Stores the mark of a plan that just answered.
pub(crate) fn write(
    cache: &ViewCache,
    ticket: &Ticket,
    item_id: &str,
    max_bitrate: i64,
    plan: &PlaybackPlan,
    version: String,
) {
    cache.write_json(
        ticket,
        KIND,
        item_id,
        &ProofMark::of(plan, item_id, max_bitrate, version),
    );
}

/// Asks the server for the plan of `item_id` and stores its mark.
pub(crate) async fn remember<T: HttpTransport + 'static>(
    server: &Server<T>,
    cache: &ViewCache,
    ticket: &Ticket,
    item_id: &str,
    max_bitrate: i64,
) {
    if let Ok(Some(plan)) = server.plan(item_id, max_bitrate, None).await {
        write(cache, ticket, item_id, max_bitrate, &plan, String::new());
    }
}

fn warming() -> &'static Mutex<std::collections::HashSet<String>> {
    static SET: std::sync::OnceLock<Mutex<std::collections::HashSet<String>>> =
        std::sync::OnceLock::new();
    SET.get_or_init(|| Mutex::new(std::collections::HashSet::new()))
}

/// Stores the proof mark of the films and episodes among `items` (the titles a list on screen shows) that have none yet,
/// so their pages open with the proof line in frame 1. At most [`WARM_LIMIT`] per call, never one already stored or on
/// its way. Series are warmed with their shape (`series::warm`).
pub(crate) fn warm<T: HttpTransport + 'static>(
    transport: &Arc<T>,
    host: &Host,
    account: &AccountRef,
    items: &[Item],
) {
    let Some(cache) = host.cache.clone() else {
        return;
    };
    let scope = ViewCache::scope(account);
    let Ok((jelly, plex)) = clients(transport, host, Some(account)) else {
        return;
    };
    let Some(server) = plex.map(Server::Plex).or_else(|| jelly.map(Server::Jelly)) else {
        return;
    };
    let bitrate = crate::detail::DetailOptions::default().max_bitrate;
    let mut seen = std::collections::HashSet::new();
    let wanted: Vec<String> = items
        .iter()
        .filter(|i| {
            matches!(i.type_.as_deref(), Some("Movie" | "Episode")) && seen.insert(i.id.clone())
        })
        .filter(|i| read(&cache, &scope, &i.id).is_none_or(|m| m.profile != profile(bitrate)))
        .map(|i| i.id.clone())
        .take(WARM_LIMIT)
        .collect();
    for id in wanted {
        let key = format!("{}|{id}", scope.0);
        if !warming()
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(key.clone())
        {
            continue;
        }
        let (cache, scope, server) = (cache.clone(), scope.clone(), server.clone());
        host.spawner.spawn(Box::pin(async move {
            let ticket = cache.ticket(&scope);
            remember(&server, &cache, &ticket, &id, bitrate).await;
            warming()
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .remove(&key);
        }));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mark(version: &str) -> ProofMark {
        ProofMark {
            item_id: "m1".into(),
            profile: profile(1_000_000_000),
            version: version.into(),
            direct_play: true,
            hint: None,
        }
    }

    #[test]
    fn a_mark_is_used_only_for_its_title_and_its_delivery_rules() {
        let m = mark("a:1");
        assert!(m.usable("m1", 1_000_000_000, None));
        assert!(!m.usable("m2", 1_000_000_000, None));
        assert!(!m.usable("m1", 4_000_000, None));
    }

    #[test]
    fn a_replaced_file_drops_the_mark_but_unknown_versions_do_not() {
        let m = mark("a:1");
        assert!(m.usable("m1", 1_000_000_000, Some("a:1")));
        assert!(!m.usable("m1", 1_000_000_000, Some("a:2")));
        assert!(m.usable("m1", 1_000_000_000, Some("")));
        assert!(mark("").usable("m1", 1_000_000_000, Some("a:2")));
    }

    #[test]
    fn a_mark_round_trips_through_the_store_format() {
        let m = mark("a:1");
        let bytes = serde_json::to_vec(&m).expect("encode");
        assert_eq!(
            serde_json::from_slice::<ProofMark>(&bytes).expect("decode"),
            m
        );
    }

    #[test]
    fn the_answer_wins_over_the_mark_once_it_is_there() {
        let m = mark("");
        assert_eq!(shown(None, false, Some(&m)), (true, None));
        assert_eq!(shown(None, true, Some(&m)), (false, None));
        assert_eq!(shown(None, false, None), (false, None));
    }
}
