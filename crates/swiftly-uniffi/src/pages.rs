//! The person page and the playlist page (`PersonView`, `PlaylistView`): the sans-I/O view
//! models of `swiftly-vm` plus the loads the Swift screens do (details, filmography pages,
//! playlist entries, the Seerr filmography).

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use swiftly_jellyfin::{ItemsQuery, JellyfinClient};
use swiftly_l10n::Locale;
use swiftly_library::{ListRules, client_ext};
use swiftly_model::{Item, Person};
use swiftly_vm::{
    AccountRef, Host, PERSON_PAGE_SIZE, PersonDetail, PersonVm, PlaylistVm, RequestableHit, Shared,
    Tile,
};

use crate::error::CoreError;
use crate::seerr::SeerrModel;
use crate::transport::CoreTransport;
use swiftly_seerr::SeerrHit;

type Client = JellyfinClient<Shared<CoreTransport>>;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The cast entry the person page opens from.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PersonInfo {
    /// Person id.
    pub id: String,
    /// Name.
    pub name: String,
    /// The role played in the title the tap came from.
    pub role: Option<String>,
    /// `Actor`, `Director` ...
    pub kind: Option<String>,
    /// Tag of the portrait.
    pub image_tag: Option<String>,
}

/// Formats a birthday for the language ("1. Mai 1980": `date.formatted(date: .long)`).
#[uniffi::export(with_foreign)]
pub trait DateText: Send + Sync {
    /// The long date for an ISO timestamp from the server, in the device's language; `None`
    /// when it cannot be read.
    fn long_date(&self, iso: String) -> Option<String>;
}

/// What the person page draws.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PersonPage {
    /// Grows with every change.
    pub version: u64,
    /// The name.
    pub name: String,
    /// "Rolle in Titel".
    pub role_line: Option<String>,
    /// "Geboren ...".
    pub born_line: Option<String>,
    /// First production place.
    pub place: Option<String>,
    /// The biography.
    pub biography: Option<String>,
    /// Shown in full.
    pub biography_expanded: bool,
    /// "Mehr" or "Weniger".
    pub biography_toggle: String,
    /// "Auf deinem Server".
    pub rail_title: String,
    /// Titles on the own server.
    pub titles: Vec<Tile>,
    /// Server total.
    pub total: i64,
    /// "Kann angefragt werden".
    pub requestable_title: String,
    /// Seerr ids that can be requested.
    pub requestable: Vec<String>,
    /// The same titles as full Seerr hits (for the tiles), in the same order.
    pub requestable_hits: Vec<SeerrHit>,
    /// Address of the banner picture (first landscape image of the titles); `None` = no banner.
    pub banner: Option<String>,
    /// The server answered.
    pub loaded: bool,
    /// The server did not answer and nothing is shown.
    pub disrupted: bool,
    /// The empty text.
    pub empty_text: Option<String>,
}

/// One person page.
#[derive(uniffi::Object)]
pub struct PersonModel {
    vm: Mutex<PersonVm>,
    client: Client,
    locale: Locale,
    hits: Mutex<Vec<SeerrHit>>,
}

impl PersonModel {
    pub(crate) fn build(
        transport: CoreTransport,
        host: &Host,
        account: &AccountRef,
        person: PersonInfo,
        origin: Option<String>,
    ) -> Result<Arc<Self>, CoreError> {
        let client = swiftly_vm::account_client(&Arc::new(transport), host, account)?;
        let person = Person {
            id: person.id,
            name: person.name,
            role: person.role,
            type_: person.kind,
            primary_image_tag: person.image_tag,
        };
        Ok(Arc::new(Self {
            vm: Mutex::new(PersonVm::new(host.locale.clone(), person, origin)),
            client,
            locale: host.locale.clone(),
            hits: Mutex::new(Vec::new()),
        }))
    }

    async fn page(&self, id: &str, since: i64) -> Option<(Vec<Item>, i64)> {
        let q = ItemsQuery {
            limit: PERSON_PAGE_SIZE,
            start_index: since,
            sort_by: "ProductionYear,SortName".into(),
            sort_order: "Descending".into(),
            recursive: true,
            include_item_types: vec!["Movie".into(), "Series".into()],
            person_ids: vec![id.to_owned()],
            ..ItemsQuery::default()
        };
        let answer = self.client.items(&q).await.ok()?;
        Some((
            ListRules::without_double(&answer.items),
            answer.total_record_count,
        ))
    }

    fn part_of(&self) -> PersonPage {
        let vm = lock(&self.vm);
        let p = vm.part();
        PersonPage {
            version: p.version,
            name: p.name.clone(),
            role_line: p.role_line.clone(),
            born_line: p.born_line.clone(),
            place: p.place.clone(),
            biography: p.biography.clone(),
            biography_expanded: p.biography_expanded,
            biography_toggle: p.biography_toggle.clone(),
            rail_title: p.rail_title.clone(),
            titles: swiftly_vm::poster_tiles(&p.titles, &self.client, self.locale.clone()),
            total: p.total,
            requestable_title: p.requestable_title.clone(),
            requestable: p.requestable.clone(),
            requestable_hits: {
                let all = lock(&self.hits);
                p.requestable
                    .iter()
                    .filter_map(|id| all.iter().find(|h| h.id.to_string() == *id).cloned())
                    .collect()
            },
            banner: swiftly_vm::banner_of(&p.titles, &self.client),
            loaded: p.loaded,
            disrupted: p.disrupted,
            empty_text: p.empty_text.clone(),
        }
    }
}

#[uniffi::export]
impl PersonModel {
    /// What the page draws now.
    pub fn page_now(&self) -> PersonPage {
        self.part_of()
    }

    /// Loads the details and the first page of the filmography; returns the new page.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn load(&self, dates: Arc<dyn DateText>) -> Result<PersonPage, CoreError> {
        let id = lock(&self.vm).person_id().to_owned();
        let (item, page) =
            futures_util::future::join(self.client.item(&id), self.page(&id, 0)).await;
        let detail = item.ok().map(|i| PersonDetail {
            born: i.premiere_date.clone().and_then(|d| dates.long_date(d)),
            places: i.production_locations.clone().unwrap_or_default(),
            biography: i.overview.clone().filter(|t| !t.is_empty()),
            tmdb_id: i
                .provider_ids
                .as_ref()
                .and_then(|m| m.get("Tmdb"))
                .and_then(|t| t.parse().ok()),
        });
        lock(&self.vm).loaded(detail, page);
        Ok(self.part_of())
    }

    /// Asks Seerr (if connected) for the person's filmography once the details are in; hits the server has
    /// already are dropped by the page.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn load_seerr(
        &self,
        seerr: Option<Arc<SeerrModel>>,
    ) -> Result<PersonPage, CoreError> {
        let tmdb = lock(&self.vm).tmdb_id();
        // Not connected or no TMDB id: Seerr has nothing to say, and the page may say "nothing else".
        let (Some(seerr), Some(tmdb)) = (seerr, tmdb) else {
            lock(&self.vm).seerr_loaded(&[]);
            return Ok(self.part_of());
        };
        {
            let all = seerr.filmography(tmdb).await?;
            let hits: Vec<RequestableHit> = all
                .iter()
                .cloned()
                .map(|h| RequestableHit {
                    id: h.id.to_string(),
                    title: h.title,
                    already_present: h.state == swiftly_seerr::SeerrState::Present,
                })
                .collect();
            lock(&self.vm).seerr_loaded(&hits);
            *lock(&self.hits) = all;
        }
        Ok(self.part_of())
    }

    /// "Mehr" / "Weniger".
    pub fn toggle_biography(&self) -> PersonPage {
        lock(&self.vm).toggle_biography();
        self.part_of()
    }

    /// A title came into view; loads the next page when it is the end of the list.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn title_visible(&self, id: String) -> Result<PersonPage, CoreError> {
        let next = lock(&self.vm).title_visible(&id);
        if let Some(since) = next {
            let person = lock(&self.vm).person_id().to_owned();
            let page = self.page(&person, since).await;
            lock(&self.vm).page_loaded(since, page);
        }
        Ok(self.part_of())
    }
}

/// The empty state of a playlist.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PlaylistEmptyText {
    /// Headline.
    pub headline: String,
    /// Explanation.
    pub text: String,
    /// The quiet button that reloads.
    pub button: String,
}

/// What the playlist page draws.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PlaylistPage {
    /// Grows with every change.
    pub version: u64,
    /// The playlist's name.
    pub title: String,
    /// The shown entries in order.
    pub shown: Vec<Tile>,
    /// The count mark; `None` while empty.
    pub count: Option<u64>,
    /// The first load is under way.
    pub loading: bool,
    /// The server did not answer and nothing was loaded before.
    pub disrupted: bool,
    /// Nothing to show and the server did answer.
    pub empty: Option<PlaylistEmptyText>,
}

/// One playlist page.
#[derive(uniffi::Object)]
pub struct PlaylistModel {
    vm: Mutex<PlaylistVm>,
    client: Client,
    locale: Locale,
}

impl PlaylistModel {
    pub(crate) fn build(
        transport: CoreTransport,
        host: &Host,
        account: &AccountRef,
        playlist: &Tile,
        art: Option<String>,
    ) -> Result<Arc<Self>, CoreError> {
        let client = swiftly_vm::account_client(&Arc::new(transport), host, account)?;
        let item = crate::detail::item_of(playlist);
        Ok(Arc::new(Self {
            vm: Mutex::new(PlaylistVm::new(host.locale.clone(), item, art)),
            client,
            locale: host.locale.clone(),
        }))
    }

    fn part_of(&self) -> PlaylistPage {
        let vm = lock(&self.vm);
        let p = vm.part();
        PlaylistPage {
            version: p.version,
            title: p.title.clone(),
            shown: swiftly_vm::poster_tiles(&p.shown, &self.client, self.locale.clone()),
            count: p.count.map(|c| c as u64),
            loading: p.loading,
            disrupted: p.disrupted,
            empty: p.empty.as_ref().map(|e| PlaylistEmptyText {
                headline: e.headline.clone(),
                text: e.text.clone(),
                button: e.button.clone(),
            }),
        }
    }
}

#[uniffi::export]
impl PlaylistModel {
    /// What the page draws now.
    pub fn page_now(&self) -> PlaylistPage {
        self.part_of()
    }

    /// Loads (or reloads) the entries; returns the new page.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn load(&self) -> Result<PlaylistPage, CoreError> {
        let id = lock(&self.vm).playlist_id().to_owned();
        let found: Option<Vec<Item>> = client_ext::playlist_entries_video(&self.client, &id, true)
            .await
            .ok();
        lock(&self.vm).loaded(found);
        Ok(self.part_of())
    }

    /// "Play": the first shown entry.
    pub fn start(&self) -> Option<Tile> {
        let vm = lock(&self.vm);
        let first = vm.start()?;
        swiftly_vm::poster_tiles(
            std::slice::from_ref(first),
            &self.client,
            self.locale.clone(),
        )
        .into_iter()
        .next()
    }
}
