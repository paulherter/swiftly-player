//! The person page (`PersonView.swift`): who this is and what the server has of them. The view
//! draws [`PersonPart`]; the host loads the details and the filmography and feeds the results
//! back. Sans-I/O: the paging rule (`loadMore`), the Seerr filter and the texts live here.

use swiftly_images::{ImageAddress, ImageKind as Art, ImageMetric};
use swiftly_l10n::{Arg, Locale, Translator};
use swiftly_library::ListRules;
use swiftly_model::{Item, Person};

use crate::parts::{ImageKind, ImageRef};

/// Entries per page of the filmography (`AppModel.pagesSize`).
pub const PAGE_SIZE: i64 = 60;
/// Height of the portrait in pixels (`personImage(_, maxHeight: 300)`).
const PORTRAIT_HEIGHT: i64 = 300;

/// What the server knows of the person beyond the cast entry.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PersonDetail {
    /// The birthday, already formatted for the language.
    pub born: Option<String>,
    /// Places of production; the first is shown.
    pub places: Vec<String>,
    /// The biography.
    pub biography: Option<String>,
    /// The TMDB id, for the Seerr filmography.
    pub tmdb_id: Option<i64>,
}

/// A title Seerr offers to request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestableHit {
    /// Seerr's id.
    pub id: String,
    /// The title.
    pub title: String,
    /// The server has it already (Seerr's state).
    pub already_present: bool,
}

/// What the view draws.
#[derive(Debug, Clone, PartialEq)]
pub struct PersonPart {
    /// Grows with every change.
    pub version: u64,
    /// The name (banner and header).
    pub name: String,
    /// "Rolle in Titel", from the tap that opened the page.
    pub role_line: Option<String>,
    /// "Geboren ..." (empty until loaded).
    pub born_line: Option<String>,
    /// The first production place.
    pub place: Option<String>,
    /// The biography.
    pub biography: Option<String>,
    /// The biography is shown in full.
    pub biography_expanded: bool,
    /// "Mehr" or "Weniger".
    pub biography_toggle: String,
    /// Heading of the own rail: "Auf deinem Server".
    pub rail_title: String,
    /// The titles of the person on the own server.
    pub titles: Vec<Item>,
    /// How many entries the server has in total (the count badge).
    pub total: i64,
    /// Heading of the Seerr rail: "Kann angefragt werden".
    pub requestable_title: String,
    /// Ids of the titles that can be requested.
    pub requestable: Vec<String>,
    /// The server answered (before that the rows are placeholders).
    pub loaded: bool,
    /// The server did not answer and there is nothing to show.
    pub disrupted: bool,
    /// "Auf deinem Server gibt es sonst nichts mit {name}." when nothing at all is left.
    pub empty_text: Option<String>,
}

/// The page model of one person.
pub struct PersonVm {
    translator: Translator,
    person: Person,
    origin: Option<String>,
    detail: Option<PersonDetail>,
    retrieved: i64,
    loading_more: bool,
    seerr_ready: bool,
    part: PersonPart,
}

impl PersonVm {
    /// A page for a cast entry. `origin` is the title the tap came from.
    pub fn new(locale: Locale, person: Person, origin: Option<String>) -> Self {
        let translator = Translator::new(locale);
        let mut vm = Self {
            part: PersonPart {
                version: 0,
                name: person.name.clone(),
                role_line: None,
                born_line: None,
                place: None,
                biography: None,
                biography_expanded: false,
                biography_toggle: translator.t("Mehr"),
                rail_title: translator.t("Auf deinem Server"),
                titles: Vec::new(),
                total: 0,
                requestable_title: translator.t("Kann angefragt werden"),
                requestable: Vec::new(),
                loaded: false,
                disrupted: false,
                empty_text: None,
            },
            translator,
            person,
            origin,
            detail: None,
            retrieved: 0,
            loading_more: false,
            seerr_ready: false,
        };
        vm.part.role_line = vm.role_line();
        vm
    }

    /// What the view draws.
    pub fn part(&self) -> &PersonPart {
        &self.part
    }

    /// The person's id, for the loads.
    pub fn person_id(&self) -> &str {
        &self.person.id
    }

    fn role_line(&self) -> Option<String> {
        let role = self.person.role.as_deref().filter(|r| !r.is_empty())?;
        let origin = self.origin.as_deref()?;
        Some(self.translator.t_args(
            "%@ in %@",
            &[Arg::Str(role.into()), Arg::Str(origin.into())],
        ))
    }

    /// The portrait (`personImage(_, maxHeight: 300)`); `None` without a picture tag.
    pub fn portrait(&self, addresses: &ImageAddress) -> Option<ImageRef> {
        let mark = self.person.primary_image_tag.as_deref()?;
        addresses
            .construct(
                &self.person.id,
                Art::Poster,
                Some(mark),
                ImageMetric::AtMostHigh(PORTRAIT_HEIGHT),
            )
            .map(|url| ImageRef {
                address: url.into(),
                kind: ImageKind::Poster,
                wanted_width: PORTRAIT_HEIGHT as u32,
                wanted_height: PORTRAIT_HEIGHT as u32,
            })
    }

    fn bump(&mut self) {
        self.part.version += 1;
        let p = &mut self.part;
        p.empty_text = (p.loaded
            && !p.disrupted
            && p.titles.is_empty()
            && p.requestable.is_empty()
            && self.seerr_ready)
            .then(|| {
                self.translator.t_args(
                    "Auf deinem Server gibt es sonst nichts mit %@.",
                    &[Arg::Str(p.name.clone())],
                )
            });
    }

    /// Both requests are back (`load`): the details and the first page of the filmography
    /// (`None` = the server did not answer; the page keeps what it had and says so).
    pub fn loaded(&mut self, detail: Option<PersonDetail>, page: Option<(Vec<Item>, i64)>) {
        if let Some(d) = &detail {
            self.part.born_line = d
                .born
                .as_ref()
                .map(|b| self.translator.t_args("Geboren %@", &[Arg::Str(b.clone())]));
            self.part.place = d.places.first().filter(|p| !p.is_empty()).cloned();
            self.part.biography = d.biography.clone();
        }
        self.detail = detail;
        self.part.disrupted = page.is_none();
        if let Some((items, total)) = page {
            self.part.titles = items;
            self.part.total = total;
            self.retrieved = PAGE_SIZE;
        }
        self.part.loaded = true;
        self.bump();
    }

    /// The TMDB id for the Seerr filmography, once the details are in.
    pub fn tmdb_id(&self) -> Option<i64> {
        self.detail.as_ref().and_then(|d| d.tmdb_id)
    }

    /// Seerr answered (possibly with nothing, or not connected). Only what the own server does not
    /// have stays: Seerr knows what it manages itself, the name catches the rest.
    pub fn seerr_loaded(&mut self, hits: &[RequestableHit]) {
        let own: Vec<String> = self
            .part
            .titles
            .iter()
            .map(|i| i.name.to_lowercase())
            .collect();
        self.part.requestable = hits
            .iter()
            .filter(|h| !h.already_present && !own.contains(&h.title.to_lowercase()))
            .map(|h| h.id.clone())
            .collect();
        self.seerr_ready = true;
        self.bump();
    }

    /// "Mehr" / "Weniger".
    pub fn toggle_biography(&mut self) {
        self.part.biography_expanded = !self.part.biography_expanded;
        self.part.biography_toggle = self.translator.t(if self.part.biography_expanded {
            "Weniger"
        } else {
            "Mehr"
        });
        self.bump();
    }

    /// A title came into view (`onAppear`): the start index of the next page to load, if this
    /// is the end of the list and there is more.
    pub fn title_visible(&mut self, id: &str) -> Option<i64> {
        if self.retrieved >= self.part.total
            || self.loading_more
            || !self.part.loaded
            || !ListRules::post_load_section(id, &self.part.titles, 1)
        {
            return None;
        }
        self.loading_more = true;
        Some(self.retrieved)
    }

    /// The next page is back (`loadMore`). An answer for another start index is dropped.
    pub fn page_loaded(&mut self, since: i64, page: Option<(Vec<Item>, i64)>) {
        self.loading_more = false;
        let Some((items, total)) = page else { return };
        if since != self.retrieved {
            return;
        }
        self.part.titles = ListRules::append(&items, &self.part.titles);
        self.part.total = total;
        self.retrieved = since + PAGE_SIZE;
        self.bump();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn person(role: Option<&str>) -> Person {
        Person {
            id: "p1".into(),
            name: "Anna Beispiel".into(),
            role: role.map(Into::into),
            type_: Some("Actor".into()),
            primary_image_tag: Some("tag".into()),
        }
    }

    fn item(id: &str, name: &str) -> Item {
        serde_json::from_value(serde_json::json!({"Id": id, "Name": name})).unwrap()
    }

    fn vm() -> PersonVm {
        PersonVm::new(
            Locale::parse("de"),
            person(Some("Hauptrolle")),
            Some("Der Film".into()),
        )
    }

    #[test]
    fn the_role_line_comes_with_the_tap_before_anything_loads() {
        let vm = vm();
        assert_eq!(
            vm.part().role_line.as_deref(),
            Some("Hauptrolle in Der Film")
        );
        assert!(!vm.part().loaded && vm.part().born_line.is_none());
        assert!(
            PersonVm::new(Locale::parse("de"), person(None), Some("x".into()))
                .part()
                .role_line
                .is_none()
        );
        assert!(
            PersonVm::new(Locale::parse("de"), person(Some("")), Some("x".into()))
                .part()
                .role_line
                .is_none()
        );
        assert!(
            PersonVm::new(Locale::parse("de"), person(Some("r")), None)
                .part()
                .role_line
                .is_none()
        );
    }

    #[test]
    fn loading_fills_everything_at_once() {
        let mut vm = vm();
        let detail = PersonDetail {
            born: Some("1. Mai 1980".into()),
            places: vec!["Berlin".into()],
            biography: Some("Text".into()),
            tmdb_id: Some(7),
        };
        vm.loaded(Some(detail), Some((vec![item("a", "Eins")], 130)));
        let p = vm.part();
        assert_eq!(p.born_line.as_deref(), Some("Geboren 1. Mai 1980"));
        assert_eq!(
            (p.place.as_deref(), p.biography.as_deref()),
            (Some("Berlin"), Some("Text"))
        );
        assert_eq!(
            (p.titles.len(), p.total, p.loaded, p.disrupted),
            (1, 130, true, false)
        );
        assert_eq!(vm.tmdb_id(), Some(7));
        assert_eq!(p.rail_title, "Auf deinem Server");
    }

    #[test]
    fn a_silent_server_is_disrupted_not_empty() {
        let mut vm = vm();
        vm.loaded(None, None);
        vm.seerr_loaded(&[]);
        let p = vm.part();
        assert!(p.disrupted && p.loaded);
        assert!(
            p.empty_text.is_none(),
            "no statement about a collection the page never saw"
        );
    }

    #[test]
    fn nothing_anywhere_says_so_with_the_name_but_only_after_seerr_answered() {
        let mut vm = vm();
        vm.loaded(Some(PersonDetail::default()), Some((Vec::new(), 0)));
        assert!(vm.part().empty_text.is_none());
        vm.seerr_loaded(&[]);
        assert_eq!(
            vm.part().empty_text.as_deref(),
            Some("Auf deinem Server gibt es sonst nichts mit Anna Beispiel.")
        );
    }

    #[test]
    fn requestable_drops_what_is_present_or_has_the_name_of_an_own_title() {
        let mut vm = vm();
        vm.loaded(None, Some((vec![item("a", "Eins")], 1)));
        let hit = |id: &str, title: &str, present: bool| RequestableHit {
            id: id.into(),
            title: title.into(),
            already_present: present,
        };
        vm.seerr_loaded(&[
            hit("1", "EINS", false),
            hit("2", "Zwei", true),
            hit("3", "Drei", false),
        ]);
        assert_eq!(vm.part().requestable, vec!["3".to_string()]);
        assert!(vm.part().empty_text.is_none());
    }

    #[test]
    fn the_biography_toggles_between_more_and_less() {
        let mut vm = vm();
        assert_eq!(vm.part().biography_toggle, "Mehr");
        vm.toggle_biography();
        assert!(vm.part().biography_expanded);
        assert_eq!(vm.part().biography_toggle, "Weniger");
        vm.toggle_biography();
        assert_eq!(vm.part().biography_toggle, "Mehr");
    }

    #[test]
    fn paging_asks_at_the_end_once_and_drops_stale_answers() {
        let mut vm = vm();
        let first: Vec<Item> = (0..3)
            .map(|i| item(&format!("t{i}"), &format!("T{i}")))
            .collect();
        vm.loaded(None, Some((first, 130)));
        assert_eq!(vm.title_visible("t2"), Some(60));
        assert_eq!(vm.title_visible("t2"), None, "one load at a time");
        vm.page_loaded(60, Some((vec![item("t2", "T2"), item("t9", "T9")], 130)));
        assert_eq!(
            vm.part().titles.len(),
            4,
            "duplicates across pages are caught by id"
        );
        assert_eq!(vm.title_visible("t9"), Some(120));
        vm.page_loaded(60, Some((vec![item("x", "X")], 130)));
        assert_eq!(
            vm.part().titles.len(),
            4,
            "an answer for another start index is dropped"
        );
        vm.page_loaded(120, Some((vec![item("t10", "T10")], 130)));
        assert_eq!(vm.title_visible("t10"), None, "everything is retrieved");
    }

    #[test]
    fn the_portrait_needs_a_picture_tag() {
        use swiftly_jellyfin::ServerKind;
        let addresses = ImageAddress::new(
            swiftly_net::Url::parse("http://h:8096").unwrap(),
            Some("tok".into()),
            ServerKind::Jellyfin,
        );
        let with = vm().portrait(&addresses).unwrap();
        assert!(
            with.address.contains("/Items/p1/Images/Primary") && with.address.contains("tag=tag"),
            "{}",
            with.address
        );
        let mut none = person(None);
        none.primary_image_tag = None;
        assert!(
            PersonVm::new(Locale::parse("de"), none, None)
                .portrait(&addresses)
                .is_none()
        );
    }
}
