//! The seed of a title page: what the list tile and the stored copy already know of the title.
//!
//! A page opens from a stand-in made of the few facts the host's tile carries (name, year, ids, resume position). The
//! list answer that made the tile, and the full title stored on an earlier visit, know much more: description, genres,
//! ratings, picture tags and BlurHashes. The page takes both before its first frame, so the text and the head picture
//! stand in frame 1 and nothing arrives later that was already known. The stand-in always wins where it has a value (it
//! carries the newest resume position and watched state); the stored copy only fills what the stand-in lacks.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use serde_json::Value;
use swiftly_model::{Item, UserItemData};

use crate::cache::ViewCache;
use crate::parts::{Badge, ImageKind, ImageRef, Tile};
use swiftly_cache::Scope;

/// How many titles the picture memory keeps; the oldest part goes when it is full (a title seen again is noted again).
const TILE_IMAGES_LIMIT: usize = 800;

fn tile_memory() -> &'static Mutex<HashMap<String, Vec<ImageRef>>> {
    static MEMORY: OnceLock<Mutex<HashMap<String, Vec<ImageRef>>>> = OnceLock::new();
    MEMORY.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Remembers the picture a tile of `id` asked for (one per kind: a poster tile and a continue-watching tile of the same
/// title both count). The page of that title shows it in frame 1, from the host's picture memory, until its own head
/// picture is there.
pub(crate) fn note_tile_image(id: &str, image: &ImageRef) {
    if id.is_empty() {
        return;
    }
    let Ok(mut memory) = tile_memory().lock() else {
        return;
    };
    if memory.len() >= TILE_IMAGES_LIMIT && !memory.contains_key(id) {
        memory.clear();
    }
    let slot = memory.entry(id.to_owned()).or_default();
    slot.retain(|known| known.kind != image.kind);
    slot.push(image.clone());
}

/// The pictures tiles of `id` showed so far, the landscape one first (it is the closest to a page head).
pub(crate) fn tile_images(id: &str) -> Vec<ImageRef> {
    let Ok(memory) = tile_memory().lock() else {
        return Vec::new();
    };
    let mut images = memory.get(id).cloned().unwrap_or_default();
    images.sort_by_key(|image| !matches!(image.kind, ImageKind::Backdrop));
    images
}

/// The tile pictures that may stand in for a page's HEAD picture until its own is there: only landscape ones. The head
/// is a wide frame; a portrait poster standing in for it is drawn zoomed far past its edges and cut (on the first open,
/// before the backdrop was ever loaded, the page showed a blown-up slice of the poster, and a reopen looked right because
/// the backdrop was in the picture memory by then). Without a landscape tile picture the head shows its BlurHash in the
/// final frame, which the sharp picture replaces in place.
pub(crate) fn head_stand_ins(id: &str) -> Vec<ImageRef> {
    tile_images(id)
        .into_iter()
        .filter(|image| matches!(image.kind, ImageKind::Backdrop))
        .collect()
}

/// The stand-in a title page opens from: what the tile that was tapped knows. Every host builds its page seed here, so
/// a page never starts poorer on one platform than on another.
///
/// The tile's marks carry over into `user_data` (watched, favourite, unseen count, progress, resume position) so the
/// page words its Play button ("Fortsetzen ab 20 Min."), draws the bar and shows the checkmark and bookmark from the
/// first frame (`Item(rust:)` on the Apple side).
#[must_use]
pub fn tile_item(tile: &Tile) -> Item {
    let mut watched = false;
    let mut favorite = false;
    let mut unplayed = None;
    for badge in &tile.badges {
        match badge {
            Badge::Watched => watched = true,
            Badge::Favorite => favorite = true,
            Badge::Unplayed { count } => unplayed = Some(i64::from(*count)),
            Badge::Seasons { .. } => {}
        }
    }
    let position = tile.facts.position_ticks;
    let user_data = (watched
        || favorite
        || unplayed.is_some()
        || tile.progress.is_some()
        || position.is_some())
    .then(|| UserItemData {
        played: Some(watched),
        is_favorite: Some(favorite),
        played_percentage: tile.progress.map(|p| f64::from(p) * 100.0),
        unplayed_item_count: unplayed,
        playback_position_ticks: position,
        ..UserItemData::default()
    });
    Item {
        id: tile.id.clone(),
        name: tile.facts.name.clone(),
        type_: tile.facts.kind.clone(),
        production_year: tile.facts.year.map(i64::from),
        series_id: tile.facts.series_id.clone(),
        season_id: tile.facts.season_id.clone(),
        parent_index_number: tile.facts.season_number.map(i64::from),
        index_number: tile.facts.episode_number.map(i64::from),
        child_count: tile.facts.child_count.map(i64::from),
        run_time_ticks: tile.facts.run_time_ticks,
        user_data,
        ..Item::default()
    }
}

/// The seed of a page opened from `tile`, with `fetched` (a full title fetched ahead, e.g. while the pointer rested on
/// the tile) filling what the tile lacks. The tile always wins: it carries the newest resume position and watched
/// state, a title fetched earlier may be minutes old (the Play label flipped "Abspielen" -> "Fortsetzen ab ..." when
/// the fetched copy or nothing at all seeded the page).
#[must_use]
pub fn page_seed(tile: &Tile, fetched: Option<Item>) -> Item {
    seeded(tile_item(tile), fetched)
}

/// `stand_in` completed by `stored`. Different ids never mix; the stored copy's file versions are dropped because a
/// page without a fresh answer must not treat them as current.
pub(crate) fn seeded(stand_in: Item, stored: Option<Item>) -> Item {
    let Some(mut stored) = stored else {
        return stand_in;
    };
    if stored.id != stand_in.id {
        return stand_in;
    }
    stored.media_sources = None;
    let (Ok(Value::Object(mut base)), Ok(Value::Object(extra))) = (
        serde_json::to_value(&stand_in),
        serde_json::to_value(&stored),
    ) else {
        return stand_in;
    };
    for (key, value) in extra {
        base.entry(key).or_insert(value);
    }
    serde_json::from_value(Value::Object(base)).unwrap_or(stand_in)
}

/// The stand-in completed from the account's stored copies: the full title of an earlier visit, else the list entry.
pub(crate) fn from_store(stand_in: Item, cache: Option<&ViewCache>, scope: Option<&Scope>) -> Item {
    let (Some(cache), Some(scope)) = (cache, scope) else {
        return stand_in;
    };
    let stored = cache
        .read_title(scope, &stand_in.id)
        .or_else(|| cache.read_tile(scope, &stand_in.id));
    seeded(stand_in, stored)
}

/// What the account stored of the title `id`, for a host that has no stand-in of its own (the Android pages): the list
/// entry (the newest resume position and watched state) completed by the stored full title. `None`: nothing stored.
pub(crate) fn stored_item(id: &str, cache: &ViewCache, scope: &Scope) -> Option<Item> {
    let tile = cache.read_tile(scope, id);
    let title = cache.read_title(scope, id);
    match (tile, title) {
        (Some(tile), title) => Some(seeded(tile, title)),
        (None, Some(mut title)) => {
            title.media_sources = None;
            Some(title)
        }
        (None, None) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(json: &str) -> Item {
        serde_json::from_str(json).expect("item")
    }

    #[test]
    fn the_stand_in_wins_and_the_stored_copy_fills_what_it_lacks() {
        let stand_in = item(
            r#"{"Id":"a","Name":"Tile name","UserData":{"Played":false,"PlaybackPositionTicks":50}}"#,
        );
        let stored = item(
            r#"{"Id":"a","Name":"Old name","Overview":"Text","Genres":["Drama"],"CommunityRating":7.5,
            "UserData":{"Played":true},"ImageBlurHashes":{"Backdrop":{"t":"LEHV6nWB2yk8pyo0adR*.7kCMdnj"}},
            "MediaSources":[{"Id":"m"}]}"#,
        );
        let out = seeded(stand_in, Some(stored));
        assert_eq!(out.name, "Tile name");
        assert_eq!(out.overview.as_deref(), Some("Text"));
        assert_eq!(out.genres, Some(vec!["Drama".to_owned()]));
        assert_eq!(out.community_rating, Some(7.5));
        assert_eq!(
            out.user_data.and_then(|d| d.playback_position_ticks),
            Some(50)
        );
        assert!(out.image_blur_hashes.is_some());
        assert!(
            out.media_sources.is_none(),
            "file versions are never seeded"
        );
    }

    fn tile(badges: Vec<Badge>, progress: Option<f32>) -> Tile {
        Tile {
            id: "e1".into(),
            title: "Folge".into(),
            subtitle: None,
            progress,
            image: None,
            badges,
            remaining: None,
            facts: crate::parts::TileFacts {
                kind: Some("Episode".into()),
                name: "Folge".into(),
                year: None,
                series_id: Some("s1".into()),
                season_id: None,
                season_number: Some(1),
                episode_number: Some(2),
                child_count: Some(3),
                position_ticks: None,
                run_time_ticks: None,
            },
        }
    }

    #[test]
    fn the_tile_state_reaches_the_item() {
        let item = tile_item(&tile(
            vec![
                Badge::Watched,
                Badge::Favorite,
                Badge::Unplayed { count: 4 },
            ],
            Some(0.25),
        ));
        let data = item.user_data.expect("user data");
        assert_eq!(data.played, Some(true));
        assert_eq!(data.is_favorite, Some(true));
        assert_eq!(data.unplayed_item_count, Some(4));
        assert!((data.played_percentage.unwrap() - 25.0).abs() < 1e-6);
        assert_eq!(item.child_count, Some(3));
    }

    #[test]
    fn the_resume_position_and_runtime_reach_the_item() {
        let mut stopped = tile(Vec::new(), Some(0.4));
        stopped.facts.position_ticks = Some(25_000_000_000);
        stopped.facts.run_time_ticks = Some(60_000_000_000);
        let item = tile_item(&stopped);
        assert_eq!(
            item.user_data.expect("user data").playback_position_ticks,
            Some(25_000_000_000)
        );
        assert_eq!(item.run_time_ticks, Some(60_000_000_000));
    }

    #[test]
    fn a_plain_tile_has_no_user_data() {
        assert!(tile_item(&tile(Vec::new(), None)).user_data.is_none());
        let begun = tile_item(&tile(Vec::new(), Some(0.5)))
            .user_data
            .expect("progress");
        assert_eq!(begun.played, Some(false));
        assert_eq!(begun.is_favorite, Some(false));
    }

    #[test]
    fn a_page_opened_from_a_tile_keeps_the_tiles_resume_over_an_older_fetched_copy() {
        // The title fetched while the pointer rested on the tile is older than the tile: it knows no resume point (or
        // an old one). The page must word its Play button from the tile.
        let mut stopped = tile(Vec::new(), Some(0.25));
        stopped.facts.position_ticks = Some(3_000_000_000);
        let fetched = item(
            r#"{"Id":"e1","Name":"Folge","Overview":"Text","UserData":{"Played":false,"PlaybackPositionTicks":10}}"#,
        );
        let seed = page_seed(&stopped, Some(fetched));
        assert_eq!(
            seed.user_data.and_then(|d| d.playback_position_ticks),
            Some(3_000_000_000),
            "the tile's resume point, not the fetched copy's"
        );
        assert_eq!(
            seed.overview.as_deref(),
            Some("Text"),
            "the copy still fills the text"
        );
        // The pure resume wording follows the seed: "Fortsetzen" needs the tile's point.
        let none = page_seed(&stopped, None);
        assert_eq!(
            none.user_data.and_then(|d| d.playback_position_ticks),
            Some(3_000_000_000)
        );
    }

    #[test]
    fn the_tile_pictures_of_a_title_are_kept_one_per_kind_landscape_first() {
        let image = |address: &str, kind| ImageRef {
            address: address.to_owned(),
            kind,
            wanted_width: 10,
            wanted_height: 10,
        };
        note_tile_image("seed-test-a", &image("poster-1", ImageKind::Poster));
        note_tile_image("seed-test-a", &image("backdrop-1", ImageKind::Backdrop));
        note_tile_image("seed-test-a", &image("poster-2", ImageKind::Poster));
        let kept = tile_images("seed-test-a");
        let addresses: Vec<&str> = kept.iter().map(|i| i.address.as_str()).collect();
        assert_eq!(addresses, ["backdrop-1", "poster-2"]);
        assert!(tile_images("seed-test-unknown").is_empty());
    }

    #[test]
    fn the_stored_item_is_none_without_a_cache_entry_and_never_carries_file_versions() {
        let tile = item(r#"{"Id":"a","Name":"Tile","UserData":{"Played":false}}"#);
        let title =
            item(r#"{"Id":"a","Name":"Full","Overview":"Text","MediaSources":[{"Id":"m"}]}"#);
        let merged = seeded(tile, Some(title));
        assert_eq!(merged.name, "Tile");
        assert_eq!(merged.overview.as_deref(), Some("Text"));
        assert!(merged.media_sources.is_none());
    }

    #[test]
    fn another_title_never_mixes_in() {
        let out = seeded(
            item(r#"{"Id":"a","Name":"A"}"#),
            Some(item(r#"{"Id":"b","Name":"B","Overview":"Other"}"#)),
        );
        assert!(out.overview.is_none());
    }

    #[test]
    fn a_poster_never_stands_in_for_the_head() {
        let poster = ImageRef {
            address: "p".into(),
            kind: ImageKind::Poster,
            wanted_width: 200,
            wanted_height: 300,
        };
        note_tile_image("seed-test-head", &poster);
        assert!(
            head_stand_ins("seed-test-head").is_empty(),
            "a portrait tile picture must not fill the landscape head"
        );
        assert_eq!(tile_images("seed-test-head").len(), 1);
        let wide = ImageRef {
            address: "b".into(),
            kind: ImageKind::Backdrop,
            wanted_width: 640,
            wanted_height: 360,
        };
        note_tile_image("seed-test-head", &wide);
        let head = head_stand_ins("seed-test-head");
        assert_eq!(head.len(), 1);
        assert_eq!(head[0].address, "b");
    }
}
