//! The entries of one playlist (`PlaylistView`, PlaylistPage.swift:13): the video entries in the
//! playlist's order, the empty and failure states, and "play from the start".

use swiftly_l10n::{Locale, Translator};
use swiftly_library::VideoPlaylist;
use swiftly_model::Item;

/// The empty state when a playlist has no entries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlaylistEmpty {
    /// Headline.
    pub headline: String,
    /// Explanation.
    pub text: String,
    /// The quiet button that reloads.
    pub button: String,
}

/// What the view draws.
#[derive(Debug, Clone, PartialEq)]
pub struct PlaylistPart {
    /// Grows with every change.
    pub version: u64,
    /// The playlist's name.
    pub title: String,
    /// What is shown: the entries of the section (`art`), in order.
    pub shown: Vec<Item>,
    /// How many are shown, for the count mark on wide screens; `None` while empty.
    pub count: Option<usize>,
    /// The first load is under way.
    pub loading: bool,
    /// The server did not answer and nothing was loaded before.
    pub disrupted: bool,
    /// Set when there is nothing to show and the server did answer.
    pub empty: Option<PlaylistEmpty>,
}

/// The playlist page model.
pub struct PlaylistVm {
    translator: Translator,
    playlist: Item,
    art: Option<String>,
    entries: Vec<Item>,
    part: PlaylistPart,
}

impl PlaylistVm {
    /// A page for `playlist`; `art` is the section it was opened from (`movies`, `tvshows`).
    pub fn new(locale: Locale, playlist: Item, art: Option<String>) -> Self {
        let mut vm = Self {
            translator: Translator::new(locale),
            part: PlaylistPart {
                version: 0,
                title: playlist.name.clone(),
                shown: Vec::new(),
                count: None,
                loading: true,
                disrupted: false,
                empty: None,
            },
            playlist,
            art,
            entries: Vec::new(),
        };
        vm.refresh();
        vm
    }

    /// What the view draws.
    pub fn part(&self) -> &PlaylistPart {
        &self.part
    }

    /// The playlist's id, for the load.
    pub fn playlist_id(&self) -> &str {
        &self.playlist.id
    }

    fn refresh(&mut self) {
        let shown = VideoPlaylist::shown(&self.entries, self.art.as_deref());
        let p = &mut self.part;
        p.count = (!shown.is_empty()).then_some(shown.len());
        p.empty = (shown.is_empty() && !p.loading && !p.disrupted).then(|| PlaylistEmpty {
            headline: self.translator.t("Hier ist noch nichts"),
            text: self
                .translator
                .t("Sobald in dieser Wiedergabeliste etwas liegt, taucht es hier auf."),
            button: self.translator.t("Aktualisieren"),
        });
        p.shown = shown;
        p.version += 1;
    }

    /// The load is back (`load`). `None` = the server did not answer: entries already there stay;
    /// the page is disrupted only when it has nothing.
    pub fn loaded(&mut self, found: Option<Vec<Item>>) {
        match found {
            Some(entries) => {
                self.entries = entries;
                self.part.disrupted = false;
            }
            None => self.part.disrupted = self.entries.is_empty(),
        }
        self.part.loading = false;
        self.refresh();
    }

    /// "Play": the first shown entry, the start of the run (`playlistStart`).
    pub fn start(&self) -> Option<&Item> {
        self.part.shown.first()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: &str, kind: &str) -> Item {
        serde_json::from_value(serde_json::json!({"Id": id, "Name": id, "Type": kind})).unwrap()
    }

    fn vm(art: Option<&str>) -> PlaylistVm {
        PlaylistVm::new(
            Locale::parse("de"),
            item("pl", "Playlist"),
            art.map(Into::into),
        )
    }

    #[test]
    fn it_starts_loading_without_an_empty_message() {
        let vm = vm(None);
        assert!(vm.part().loading && vm.part().empty.is_none() && !vm.part().disrupted);
        assert_eq!(vm.part().title, "pl");
    }

    #[test]
    fn entries_keep_their_order_and_the_section_filters_them() {
        let mut vm = vm(Some("movies"));
        vm.loaded(Some(vec![
            item("b", "Movie"),
            item("a", "Episode"),
            item("c", "Movie"),
        ]));
        let ids: Vec<&str> = vm.part().shown.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(ids, ["b", "c"]);
        assert_eq!(vm.part().count, Some(2));
        assert_eq!(vm.start().map(|i| i.id.as_str()), Some("b"));
    }

    #[test]
    fn an_empty_list_offers_the_reload() {
        let mut vm = vm(None);
        vm.loaded(Some(Vec::new()));
        let empty = vm.part().empty.clone().unwrap();
        assert_eq!(empty.headline, "Hier ist noch nichts");
        assert_eq!(empty.button, "Aktualisieren");
        assert!(vm.start().is_none() && vm.part().count.is_none());
    }

    #[test]
    fn a_silent_server_is_a_failure_only_when_nothing_was_loaded_before() {
        let mut vm = vm(None);
        vm.loaded(None);
        assert!(vm.part().disrupted && vm.part().empty.is_none());
        vm.loaded(Some(vec![item("a", "Movie")]));
        assert!(!vm.part().disrupted);
        vm.loaded(None);
        assert!(!vm.part().disrupted, "what was loaded stays");
        assert_eq!(vm.part().shown.len(), 1);
    }
}
