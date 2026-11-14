//! From a server `Item` to display-ready tile data. All text goes through `swiftly-l10n`.

use std::sync::atomic::{AtomicU32, Ordering};

use swiftly_jellyfin::JellyfinClient;
use swiftly_l10n::{Arg, Catalog, Locale, Translator};
use swiftly_library::StartRail;
use swiftly_model::{Item, ItemKind, Localizer};
use swiftly_net::HttpTransport;

use crate::parts::{Badge, ImageKind, ImageRef, RailKind, Tile, TileFacts};
use swiftly_images::{ImageAddress, ImageSelection};

/// The words of the page in the user's language.
pub(crate) struct Words {
    translator: Translator,
    labels: crate::language_names::LabelWords,
}

impl Words {
    pub(crate) fn new(locale: Locale) -> Self {
        Self {
            labels: crate::language_names::LabelWords::new(locale.clone()),
            translator: Translator::new(locale),
        }
    }

    /// The readable sentence for an error (`readableError`).
    pub(crate) fn error(&self, error: &swiftly_net::ErrorKind) -> String {
        swiftly_l10n::error_text::readable_error(&self.translator, error)
    }

    /// The text of a German key without arguments.
    pub(crate) fn title(&self, key: &str) -> String {
        self.translator.t(key)
    }

    /// The line under a continue-watching tile: "S2 · F5 · noch 12 Min.", "2019 · noch 1 Std. 4 Min." or nothing
    /// (`Item.continueWatchingRow`). `year` is the context line of a movie.
    pub(crate) fn continue_row(&self, item: &Item, year: Option<String>) -> Option<String> {
        let total = item.runtime_seconds().filter(|t| *t > 0.0)?;
        let since = crate::title_text::resume_from(item)?;
        let left = total - since;
        let minutes = if left.is_finite() && left > 0.0 {
            ((left / 60.0).ceil() as i64).max(1)
        } else {
            1
        };
        let (h, m) = (minutes / 60, minutes % 60);
        let rest = if h == 0 {
            self.text("noch %lld Min.", &[m])
        } else if m == 0 {
            self.text("noch %lld Std.", &[h])
        } else {
            self.text("noch %lld Std. %lld Min.", &[h, m])
        };
        match (item.kind(), item.parent_index_number, item.index_number) {
            (ItemKind::Episode, Some(s), Some(e)) => {
                Some(format!("{} · {rest}", self.text("S%lld · F%lld", &[s, e])))
            }
            (ItemKind::Movie, _, _) => Some(year.map_or(rest.clone(), |y| format!("{y} · {rest}"))),
            _ => Some(rest),
        }
    }
}

impl Localizer for Words {
    fn text(&self, key: &str, args: &[i64]) -> String {
        let plural = Catalog::builtin()
            .get(key)
            .and_then(|e| e.text(self.translator.locale().language()))
            .is_some_and(swiftly_l10n::Text::is_plural);
        let rest = |from: usize| {
            args.iter()
                .skip(from)
                .map(|n| Arg::Int(*n))
                .collect::<Vec<_>>()
        };
        match args.first() {
            Some(first) if plural => self.translator.plural(key, *first, &rest(1)),
            _ => self.translator.t_args(key, &rest(0)),
        }
    }

    /// `MediaStream.languageName` is `TrackLabel.language`: interface language, the host's names first.
    fn language_name(&self, raw: Option<&str>) -> Option<String> {
        swiftly_playback::track_label::language(raw, &self.labels)
    }
}

/// Height of a poster tile in points; backdrop tiles are 16:9 at 640 wide. A host with larger
/// tiles (the TV) asks for more through [`set_tile_image_sizes`] once at start.
const DEFAULT_POSTER_HEIGHT: u32 = 360;
const DEFAULT_BACKDROP_WIDTH: u32 = 640;

static POSTER_HEIGHT_NOW: AtomicU32 = AtomicU32::new(DEFAULT_POSTER_HEIGHT);
static BACKDROP_WIDTH_NOW: AtomicU32 = AtomicU32::new(DEFAULT_BACKDROP_WIDTH);

/// The picture sizes tiles ask the server for: poster height and backdrop width (both in
/// points). Called once by a host whose tiles are larger than a phone's (Apple TV: 600 and 900,
/// what its Swift tiles always asked for). Zero keeps the default of that value.
pub fn set_tile_image_sizes(poster_height: u32, backdrop_width: u32) {
    let pick = |wanted: u32, default: u32| if wanted == 0 { default } else { wanted };
    POSTER_HEIGHT_NOW.store(
        pick(poster_height, DEFAULT_POSTER_HEIGHT),
        Ordering::Relaxed,
    );
    BACKDROP_WIDTH_NOW.store(
        pick(backdrop_width, DEFAULT_BACKDROP_WIDTH),
        Ordering::Relaxed,
    );
}

fn poster_height() -> u32 {
    POSTER_HEIGHT_NOW.load(Ordering::Relaxed)
}

fn backdrop_width() -> u32 {
    BACKDROP_WIDTH_NOW.load(Ordering::Relaxed)
}

/// The tile of an item in a rail of this kind.
pub(crate) fn tile<T: HttpTransport>(
    item: &Item,
    kind: RailKind,
    client: &JellyfinClient<T>,
    words: &Words,
) -> Tile {
    let addresses = client.current_session().map(|s| {
        ImageAddress::new(
            client.base_url().clone(),
            Some(s.access_token),
            client.server_kind(),
        )
    });
    tile_at(item, kind, addresses, words)
}

/// The tile of an item of any server kind: the picture rules are `ImageSelection`'s, which
/// know the Plex path addresses.
pub(crate) fn tile_at(
    item: &Item,
    kind: RailKind,
    addresses: Option<ImageAddress>,
    words: &Words,
) -> Tile {
    let landscape = matches!(kind, RailKind::ContinueWatching);
    let (poster_height, backdrop_width) = (poster_height(), backdrop_width());
    // The same rules as the Swift code (`ImageSelection`): an episode shows its series' poster,
    // only "continue watching" is landscape ("next episode" is a poster rail); it walks the chain series backdrop -> own backdrop -> thumb -> still.
    let image = addresses.as_ref().and_then(|addresses| {
        if landscape
            && let Some(hit) = ImageSelection::landscape(item, addresses, i64::from(backdrop_width))
        {
            return Some(ImageRef {
                address: hit.url.into(),
                kind: ImageKind::Backdrop,
                wanted_width: backdrop_width,
                wanted_height: backdrop_width * 9 / 16,
            });
        }
        ImageSelection::portrait(item, addresses, i64::from(poster_height)).map(|url| ImageRef {
            address: url.into(),
            kind: ImageKind::Poster,
            wanted_width: poster_height * 2 / 3,
            wanted_height: poster_height,
        })
    });
    build_tile(item, kind, image, words)
}

/// The tile of a Plex title in a poster grid: the picture comes from the Plex client.
pub(crate) fn plex_grid_tile<T: HttpTransport + 'static>(
    item: &Item,
    client: &swiftly_plex::PlexClient<T>,
    words: &Words,
) -> Tile {
    let poster_height = poster_height();
    let image = client
        .image_url_for(
            item,
            swiftly_plex::ImageKind::Poster,
            Some(i64::from(poster_height)),
            None,
        )
        .map(|url| ImageRef {
            address: url.to_string(),
            kind: ImageKind::Poster,
            wanted_width: poster_height * 2 / 3,
            wanted_height: poster_height,
        });
    build_tile(item, RailKind::Genre, image, words)
}

fn build_tile(item: &Item, kind: RailKind, image: Option<ImageRef>, words: &Words) -> Tile {
    let episode = item.kind() == ItemKind::Episode;
    let title = if episode {
        item.series_name
            .clone()
            .unwrap_or_else(|| item.name.clone())
    } else {
        item.name.clone()
    };
    let subtitle = match kind {
        RailKind::ContinueWatching | RailKind::NextEpisode if episode => item
            .episode_code_with(words)
            .or_else(|| Some(item.name.clone())),
        RailKind::NewMovies | RailKind::NewSeries | RailKind::NewArrivals => {
            item.new_arrivals_row_with(words)
        }
        _ => item.production_year.map(|y| y.to_string()),
    };
    let remaining = matches!(kind, RailKind::ContinueWatching)
        .then(|| words.continue_row(item, item.production_year.map(|y| y.to_string())))
        .flatten();
    let mut badges = Vec::new();
    if item.is_watched() {
        badges.push(Badge::Watched);
    }
    if item
        .user_data
        .as_ref()
        .is_some_and(|data| data.is_favorite == Some(true))
    {
        badges.push(Badge::Favorite);
    }
    // The Mac `DisplayRules.tileMark`: the checkmark above, and for a series that was not seen to the end the open
    // episodes beat the season count.
    if !item.is_watched() && item.type_.as_deref() == Some("Series") {
        let open = item
            .user_data
            .as_ref()
            .and_then(|d| d.unplayed_item_count)
            .filter(|n| *n > 0);
        if let Some(n) = open {
            badges.push(Badge::Unplayed {
                count: u32::try_from(n).unwrap_or(u32::MAX),
            });
        } else if let Some(n) = item.child_count.filter(|n| *n > 0) {
            badges.push(Badge::Seasons {
                count: u32::try_from(n).unwrap_or(u32::MAX),
            });
        }
    }
    Tile {
        id: item.id.clone(),
        title,
        subtitle,
        progress: item.watched_share().map(|s| s.clamp(0.0, 1.0) as f32),
        image,
        badges,
        remaining,
        facts: TileFacts {
            kind: item.type_.clone(),
            name: item.name.clone(),
            year: item.production_year.and_then(|y| i32::try_from(y).ok()),
            series_id: item.series_id.clone(),
            season_id: item.season_id.clone(),
            season_number: item.parent_index_number.and_then(|n| i32::try_from(n).ok()),
            episode_number: item.index_number.and_then(|n| i32::try_from(n).ok()),
            child_count: item.child_count.and_then(|n| i32::try_from(n).ok()),
        },
    }
}

/// The rail kind of a fixed start rail.
pub(crate) fn kind_of(rail: StartRail) -> RailKind {
    match rail {
        StartRail::ContinueWatching => RailKind::ContinueWatching,
        StartRail::NextEpisode => RailKind::NextEpisode,
        StartRail::NewMovies => RailKind::NewMovies,
        StartRail::NewSeries => RailKind::NewSeries,
        StartRail::NewArrivals => RailKind::NewArrivals,
    }
}

/// The tile of an item in a plain poster grid (library, genre, collection, search): the year
/// line, a poster, no landscape image.
pub(crate) fn grid_tile<T: HttpTransport>(
    item: &Item,
    client: &JellyfinClient<T>,
    words: &Words,
) -> Tile {
    tile(item, RailKind::Genre, client, words)
}

/// Poster-grid tiles for lists a host screen loads itself (person page, playlists): the same
/// year line and poster as the library grid.
pub fn poster_tiles<T: HttpTransport>(
    items: &[Item],
    client: &JellyfinClient<T>,
    locale: Locale,
) -> Vec<Tile> {
    let words = Words::new(locale);
    items.iter().map(|i| grid_tile(i, client, &words)).collect()
}

/// The collection and playlist cards of a library section's title menu (`LibraryView.collectionTiles` and
/// `playlistTiles`): the same poster tile as the grid; the id says what a tap opens (`collection:<id>` or
/// `playlist:<id>`) and the second line says how many titles of this kind it holds.
pub fn section_cards<T: HttpTransport>(
    art: &str,
    directory: Option<&swiftly_library::CollectionDirectory>,
    playlists: Option<&swiftly_library::PlaylistDirectory>,
    client: &JellyfinClient<T>,
    locale: Locale,
) -> (Vec<Tile>, Vec<Tile>) {
    let words = Words::new(locale);
    cards_from(art, directory, playlists, &words, |i| {
        grid_tile(i, client, &words)
    })
}

fn cards_from(
    art: &str,
    directory: Option<&swiftly_library::CollectionDirectory>,
    playlists: Option<&swiftly_library::PlaylistDirectory>,
    words: &Words,
    make: impl Fn(&Item) -> Tile,
) -> (Vec<Tile>, Vec<Tile>) {
    let collections = directory
        .map(|d| d.collections(art))
        .unwrap_or_default()
        .into_iter()
        .map(|c| Tile {
            id: format!("collection:{}", c.id()),
            subtitle: Some(swiftly_library::ItemCollection::count_text(
                art,
                i64::try_from(c.count(art)).unwrap_or(0),
                words,
            )),
            ..make(&c.item)
        })
        .collect();
    let lists = playlists
        .map(|d| d.playlists(art))
        .unwrap_or_default()
        .into_iter()
        .map(|p| Tile {
            id: format!("playlist:{}", p.id()),
            subtitle: Some(words.text("%lld Titel", &[i64::try_from(p.count(art)).unwrap_or(0)])),
            ..make(&p.item)
        })
        .collect();
    (collections, lists)
}

/// The banner of a person page: the first real landscape picture of the titles (`None` = calm
/// background, no portrait is cropped into a banner).
pub fn banner_of<T: HttpTransport>(items: &[Item], client: &JellyfinClient<T>) -> Option<String> {
    let s = client.current_session()?;
    let addresses = ImageAddress::new(
        client.base_url().clone(),
        Some(s.access_token),
        client.server_kind(),
    );
    items
        .iter()
        .find_map(|i| ImageSelection::header(i, &addresses, 1200))
        .map(|u| u.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_series_tile_carries_its_season_count_for_the_mark() {
        let item: Item = serde_json::from_str(
            r#"{"Id":"s1","Name":"Dark Matter","Type":"Series","ChildCount":3}"#,
        )
        .unwrap();
        let words = Words::new(Locale::parse("de"));
        let tile = build_tile(&item, RailKind::Genre, None, &words);
        assert_eq!(tile.facts.child_count, Some(3));
        let movie: Item =
            serde_json::from_str(r#"{"Id":"m1","Name":"A Film","Type":"Movie"}"#).unwrap();
        let tile = build_tile(&movie, RailKind::Genre, None, &words);
        assert_eq!(tile.facts.child_count, None);
    }

    #[test]
    fn collection_and_playlist_cards_carry_what_a_tap_opens_and_their_counts() {
        use swiftly_library::{
            CollectionDirectory, ItemCollection, PlaylistDirectory, VideoPlaylist,
        };
        let item = |id: &str, name: &str, kind: &str| Item::new(id, name, Some(kind));
        let movies = |n: usize| -> Vec<Item> {
            (0..n)
                .map(|i| item(&format!("m{i}"), "x", "Movie"))
                .collect()
        };
        let directory = CollectionDirectory {
            all: vec![
                ItemCollection::new(item("c1", "Marvel", "BoxSet"), &movies(3)),
                ItemCollection::new(item("c2", "Solo", "BoxSet"), &movies(1)),
            ],
        };
        let lists = PlaylistDirectory {
            all: vec![VideoPlaylist::new(
                item("p1", "Wochenende", "Playlist"),
                &movies(4),
            )],
        };
        let words = Words::new(Locale::parse("de"));
        let (cards, playlists) =
            cards_from("movies", Some(&directory), Some(&lists), &words, |i| {
                build_tile(i, RailKind::Genre, None, &words)
            });
        assert_eq!(
            cards.len(),
            1,
            "a collection under the threshold is not offered"
        );
        assert_eq!(cards[0].id, "collection:c1");
        assert_eq!(cards[0].title, "Marvel");
        assert_eq!(cards[0].subtitle.as_deref(), Some("3 Filme"));
        assert_eq!(playlists[0].id, "playlist:p1");
        assert_eq!(playlists[0].subtitle.as_deref(), Some("4 Titel"));
    }
}
