//! **The one Profile entry for requests, reports and the server**, and the sections of the page behind it.
//!
//! Profile shows at most ONE row of this kind, decided here for every host:
//!
//! - an administrator (a Jellyfin administrator, or an account that manages Seerr requests or reports) gets
//!   "Verwaltung" with the sections "Anfragen" (the Seerr queue), "Meldungen" (the Seerr reports) and "Server" (the
//!   server page); a section the account has no right or no connection for is not listed;
//! - everyone else with a Seerr connection gets "Meine Anfragen" with their own requests and, inside, "Meldungen";
//! - no Seerr connection and no administrator: no row at all.
//!
//! The host draws the row from [`ProfileEntry`] and the page behind it as a tab bar over [`ProfileEntry::sections`]
//! (one section alone: no tab bar). What a section shows is the Seerr screens and the server page, as before.

use swiftly_jellyfin::ServerKind;
use swiftly_l10n::{Arg, Locale, Translator};

use crate::seerr_lists::{HubState, SeerrHubInfo};

/// Which role the entry is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProfileEntryKind {
    /// "Verwaltung": a Jellyfin administrator or a Seerr manager.
    Admin,
    /// "Meine Anfragen": the account's own requests and reports.
    Mine,
}

/// One section of the page behind the entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HubSectionKind {
    /// The Seerr queue for a manager, the account's own requests otherwise.
    Requests,
    /// The Seerr reports (everyone's for a manager, the account's own otherwise).
    Issues,
    /// The server page (dashboard, tasks, streams, logs).
    Server,
}

/// A section: its tab and the number on it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HubSection {
    /// Which.
    pub kind: HubSectionKind,
    /// "Anfragen", "Meldungen", "Server".
    pub title: String,
    /// What waits (queue, open reports) or runs (own requests); 0 shows no number.
    pub count: i64,
    /// The account decides here (queue, everyone's reports) and not only reads its own.
    pub manage: bool,
}

/// **The Profile entry.**
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileEntry {
    /// The role.
    pub kind: ProfileEntryKind,
    /// "Verwaltung" or "Meine Anfragen" ("Meine Meldungen" when only reports are open to the account).
    pub title: String,
    /// The second line: what waits ("3 Anfragen · 1 Problem"), what runs ("3 laufen"), or the section names.
    pub under: Option<String>,
    /// The number for the count mark (what waits for a manager).
    pub count: i64,
    /// The page's sections, in order; never empty.
    pub sections: Vec<HubSection>,
}

/// **Which entry Profile shows.** `seerr` is the hub's answer (`None` without a connection; anything but a signed-in
/// hub counts as none). The server section needs a Jellyfin administrator: Plex and Emby never get it.
pub fn profile_entry(
    locale: &Locale,
    server_kind: ServerKind,
    is_administrator: bool,
    seerr: Option<&SeerrHubInfo>,
) -> Option<ProfileEntry> {
    let t = Translator::new(locale.clone());
    let seerr = seerr.filter(|s| s.state == HubState::Ready);
    let server = server_kind == ServerKind::Jellyfin && is_administrator;
    let (manage_requests, manage_issues) = seerr.map_or((false, false), |s| {
        (s.can_manage_requests, s.can_manage_issues)
    });
    let counts = seerr.map(|s| s.counts).unwrap_or_default();

    let mut sections = Vec::new();
    if let Some(s) = seerr {
        if manage_requests || s.can_request_movie || s.can_request_tv || s.can_view_all_requests {
            sections.push(HubSection {
                kind: HubSectionKind::Requests,
                title: t.t("Anfragen (Bereich)"),
                count: if manage_requests {
                    counts.pending
                } else {
                    counts.my_running
                },
                manage: manage_requests,
            });
        }
        if manage_issues || s.can_create_issues || s.can_view_issues {
            sections.push(HubSection {
                kind: HubSectionKind::Issues,
                title: t.t("Meldungen"),
                count: if manage_issues {
                    counts.issues_open
                } else {
                    counts.my_issues
                },
                manage: manage_issues,
            });
        }
    }
    if server {
        sections.push(HubSection {
            kind: HubSectionKind::Server,
            title: t.t("Server"),
            count: 0,
            manage: true,
        });
    }
    if sections.is_empty() {
        return None;
    }

    if server || manage_requests || manage_issues {
        let mut waits = Vec::new();
        if manage_requests && counts.pending > 0 {
            waits.push(plural(&t, counts.pending, "%lld Anfrage", "%lld Anfragen"));
        }
        if manage_issues && counts.issues_open > 0 {
            waits.push(plural(
                &t,
                counts.issues_open,
                "%lld Problem",
                "%lld Probleme",
            ));
        }
        let under = if waits.is_empty() {
            Some(
                sections
                    .iter()
                    .map(|s| s.title.as_str())
                    .collect::<Vec<_>>()
                    .join(" · "),
            )
        } else {
            Some(waits.join(" · "))
        };
        let count = (if manage_requests { counts.pending } else { 0 })
            + (if manage_issues { counts.issues_open } else { 0 });
        return Some(ProfileEntry {
            kind: ProfileEntryKind::Admin,
            title: t.t("Verwaltung"),
            under,
            count,
            sections,
        });
    }
    let has_requests = sections.iter().any(|s| s.kind == HubSectionKind::Requests);
    Some(ProfileEntry {
        kind: ProfileEntryKind::Mine,
        title: t.t(if has_requests {
            "Meine Anfragen"
        } else {
            "Meine Meldungen"
        }),
        under: (has_requests && counts.my_running > 0)
            .then(|| t.t_args("%lld laufen", &[Arg::Int(counts.my_running)])),
        count: counts.my_running,
        sections,
    })
}

fn plural(t: &Translator, n: i64, one: &str, many: &str) -> String {
    t.t_args(if n == 1 { one } else { many }, &[Arg::Int(n)])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::seerr_lists::{HubCounts, SeerrHubVm};
    use swiftly_seerr::types::Me;

    fn hub(perms: i64, counts: HubCounts) -> SeerrHubInfo {
        let me: Me = serde_json::from_str(&format!(
            r#"{{"id":2,"displayName":"Paul","permissions":{perms}}}"#
        ))
        .expect("me");
        let mut hub = SeerrHubVm::new(Locale::parse("de"));
        hub.loaded(Ok(me), None, None);
        hub.counts_loaded(counts);
        hub.info()
    }

    fn entry(kind: ServerKind, admin: bool, seerr: Option<&SeerrHubInfo>) -> Option<ProfileEntry> {
        profile_entry(&Locale::parse("de"), kind, admin, seerr)
    }

    fn kinds(e: &ProfileEntry) -> Vec<HubSectionKind> {
        e.sections.iter().map(|s| s.kind).collect()
    }

    const REQUEST_MOVIE: i64 = 262_144;
    const CREATE_ISSUES: i64 = 4_194_304;
    const SEERR_ADMIN: i64 = 2;

    #[test]
    fn an_administrator_gets_one_row_with_requests_reports_and_the_server() {
        let counts = HubCounts {
            pending: 3,
            issues_open: 1,
            ..HubCounts::default()
        };
        let seerr = hub(SEERR_ADMIN, counts);
        let e = entry(ServerKind::Jellyfin, true, Some(&seerr)).expect("entry");
        assert_eq!(e.kind, ProfileEntryKind::Admin);
        assert_eq!(e.title, "Verwaltung");
        assert_eq!(
            kinds(&e),
            [
                HubSectionKind::Requests,
                HubSectionKind::Issues,
                HubSectionKind::Server
            ]
        );
        assert_eq!(e.under.as_deref(), Some("3 Anfragen · 1 Problem"));
        assert_eq!(e.count, 4);
        assert_eq!(
            e.sections.iter().map(|s| s.count).collect::<Vec<_>>(),
            [3, 1, 0]
        );
        assert!(e.sections.iter().all(|s| s.manage));
    }

    #[test]
    fn an_administrator_without_seerr_gets_the_server_section_alone() {
        let e = entry(ServerKind::Jellyfin, true, None).expect("entry");
        assert_eq!(
            (e.kind, kinds(&e)),
            (ProfileEntryKind::Admin, vec![HubSectionKind::Server])
        );
        assert_eq!(e.under.as_deref(), Some("Server"));
        assert_eq!(e.count, 0);
        // A hub that is not signed in counts as no connection.
        let loading = SeerrHubVm::new(Locale::parse("de")).info();
        assert_eq!(entry(ServerKind::Jellyfin, true, Some(&loading)), Some(e));
    }

    #[test]
    fn a_jellyfin_administrator_who_is_a_plain_seerr_user_keeps_their_own_lists_in_the_hub() {
        let seerr = hub(
            REQUEST_MOVIE | CREATE_ISSUES,
            HubCounts {
                my_running: 2,
                ..HubCounts::default()
            },
        );
        let e = entry(ServerKind::Jellyfin, true, Some(&seerr)).expect("entry");
        assert_eq!(e.kind, ProfileEntryKind::Admin);
        assert_eq!(
            kinds(&e),
            [
                HubSectionKind::Requests,
                HubSectionKind::Issues,
                HubSectionKind::Server
            ]
        );
        assert!(!e.sections[0].manage && !e.sections[1].manage);
        assert_eq!(
            e.sections[0].count, 2,
            "own running requests, not the queue"
        );
    }

    #[test]
    fn a_seerr_manager_who_is_no_server_administrator_gets_verwaltung_without_the_server() {
        let seerr = hub(SEERR_ADMIN, HubCounts::default());
        let e = entry(ServerKind::Jellyfin, false, Some(&seerr)).expect("entry");
        assert_eq!(e.kind, ProfileEntryKind::Admin);
        assert_eq!(
            kinds(&e),
            [HubSectionKind::Requests, HubSectionKind::Issues]
        );
        assert_eq!(e.under.as_deref(), Some("Anfragen · Meldungen"));
        // Plex and Emby never list the server, even for an "administrator" flag.
        let plex = entry(ServerKind::Plex, true, Some(&seerr)).expect("entry");
        assert_eq!(
            kinds(&plex),
            [HubSectionKind::Requests, HubSectionKind::Issues]
        );
        assert!(entry(ServerKind::Emby, true, None).is_none());
    }

    #[test]
    fn everyone_else_gets_one_row_for_their_own_requests_and_reports() {
        let seerr = hub(
            REQUEST_MOVIE | CREATE_ISSUES,
            HubCounts {
                my_running: 3,
                my_issues: 1,
                ..HubCounts::default()
            },
        );
        let e = entry(ServerKind::Jellyfin, false, Some(&seerr)).expect("entry");
        assert_eq!(e.kind, ProfileEntryKind::Mine);
        assert_eq!(e.title, "Meine Anfragen");
        assert_eq!(e.under.as_deref(), Some("3 laufen"));
        assert_eq!(
            kinds(&e),
            [HubSectionKind::Requests, HubSectionKind::Issues]
        );
        assert!(e.sections.iter().all(|s| !s.manage));
        // Reports only: the row is named for them.
        let only_issues = hub(CREATE_ISSUES, HubCounts::default());
        let e = entry(ServerKind::Jellyfin, false, Some(&only_issues)).expect("entry");
        assert_eq!(
            (e.title.as_str(), kinds(&e)),
            ("Meine Meldungen", vec![HubSectionKind::Issues])
        );
    }

    #[test]
    fn no_seerr_and_no_administrator_means_no_row() {
        assert!(entry(ServerKind::Jellyfin, false, None).is_none());
        assert!(entry(ServerKind::Plex, false, None).is_none());
        let loading = SeerrHubVm::new(Locale::parse("de")).info();
        assert!(entry(ServerKind::Jellyfin, false, Some(&loading)).is_none());
        let nothing = hub(0, HubCounts::default());
        assert!(entry(ServerKind::Jellyfin, false, Some(&nothing)).is_none());
    }
}
