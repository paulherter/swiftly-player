//! The page behind the one Profile entry (`swiftly_vm::profile_entry`) on the desktop: which of the core's sections this
//! form can draw, where each one lives, and the tab row that switches between them. The sections themselves are the
//! existing pages: the Seerr screens (`PageScreen`, "Anfragen" and "Meldungen") and the server page of the settings
//! screen ("Server"). A tab of the other host opens that host's page in place; one section alone shows no tab row.

use swiftly_vm::{HubSection, HubSectionKind, ProfileEntry};

/// Where a section is drawn.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Dest {
    /// The account's own requests (`PageScreen`, `Kind::Requests`).
    Requests,
    /// The queue of a manager (`PageScreen`, `Kind::SeerrAdmin`, tab "Anfragen").
    Queue,
    /// The reports of a manager (`PageScreen`, `Kind::SeerrAdmin`, tab "Meldungen").
    Reports,
    /// The server page of the settings screen.
    Server,
}

impl Dest {
    /// Where `section` is drawn; `None` for the account's own reports (no desktop page for them).
    pub fn of(section: &HubSection) -> Option<Dest> {
        match section.kind {
            HubSectionKind::Requests if section.manage => Some(Dest::Queue),
            HubSectionKind::Requests => Some(Dest::Requests),
            HubSectionKind::Issues if section.manage => Some(Dest::Reports),
            HubSectionKind::Issues => None,
            HubSectionKind::Server => Some(Dest::Server),
        }
    }

    /// Whether the section is a Seerr page (the other host of the hub draws it).
    pub fn is_seerr(self) -> bool {
        self != Dest::Server
    }
}

/// The sections this form draws, in the core's order.
pub fn drawn(entry: &ProfileEntry) -> Vec<(Dest, &HubSection)> {
    entry
        .sections
        .iter()
        .filter_map(|s| Dest::of(s).map(|d| (d, s)))
        .collect()
}

/// The page the Profile row opens: the first section; an entry with nothing this form draws still shows the account's
/// own requests.
pub fn first(entry: &ProfileEntry) -> Dest {
    drawn(entry)
        .first()
        .map_or(Dest::Requests, |(dest, _)| *dest)
}

/// A tab's text: the title, with what waits when something does.
pub fn label(section: &HubSection) -> String {
    if section.count > 0 {
        format!("{} {}", section.title, section.count)
    } else {
        section.title.clone()
    }
}

/// The tab row over `entry`'s drawn sections, `selected` on. Empty when one section (or none) is drawn.
pub fn tabs(entry: &ProfileEntry, selected: Dest) -> Vec<(Dest, String, bool)> {
    let d = drawn(entry);
    if d.len() < 2 {
        return Vec::new();
    }
    d.into_iter()
        .map(|(dest, s)| (dest, label(s), dest == selected))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(kind: HubSectionKind, manage: bool) -> HubSection {
        HubSection {
            kind,
            title: format!("{kind:?}"),
            count: 2,
            manage,
        }
    }

    fn entry(sections: Vec<HubSection>) -> ProfileEntry {
        ProfileEntry {
            kind: swiftly_vm::ProfileEntryKind::Admin,
            title: "Verwaltung".into(),
            under: None,
            count: 0,
            sections,
        }
    }

    #[test]
    fn an_administrator_gets_three_tabs_and_opens_on_the_queue() {
        let e = entry(vec![
            s(HubSectionKind::Requests, true),
            s(HubSectionKind::Issues, true),
            s(HubSectionKind::Server, true),
        ]);
        assert_eq!(first(&e), Dest::Queue);
        let t = tabs(&e, Dest::Reports);
        assert_eq!(t.len(), 3);
        assert_eq!(
            t.iter().map(|x| x.2).collect::<Vec<_>>(),
            vec![false, true, false]
        );
        assert_eq!(t[0].1, "Requests 2");
    }

    #[test]
    fn one_drawn_section_has_no_tab_row() {
        let e = entry(vec![s(HubSectionKind::Server, true)]);
        assert!(tabs(&e, Dest::Server).is_empty());
        assert_eq!(first(&e), Dest::Server);
        // Own reports have no desktop page: they do not count as a tab.
        let e = entry(vec![
            s(HubSectionKind::Requests, false),
            s(HubSectionKind::Issues, false),
        ]);
        assert!(tabs(&e, Dest::Requests).is_empty());
        assert_eq!(first(&e), Dest::Requests);
    }
}
