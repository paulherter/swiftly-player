//! Pure rules of the detail page beyond the basics (`ItemDetailView`, `TitleActions`,
//! `TileMenu`, `TrailerChoice`, `FileDetails`): the proof row, the file excerpt, the trailer
//! order and the entries of the More panel and of the tile menu.

use swiftly_model::{Item, MediaSource, MediaStream, MediaUrl, codec_name};
use swiftly_net::Url;

use crate::downloads_vm::{decimal_separator, size_text};
use crate::title_text::TitleText;

/// The line under the title: Direct Play mark or hint, rating, age rating. Hidden until the
/// plan has been answered (`planPresent`), but it keeps its place.
#[derive(Debug, Clone, PartialEq)]
pub struct ProofPart {
    /// The plan has been answered (with or without a result); the view fades the row in.
    pub visible: bool,
    /// The plan loses nothing: show the "Direct Play" mark.
    pub direct_play: bool,
    /// The delivery method when it is not lossless ("Transcode").
    pub hint: Option<String>,
    /// Community rating as "7,5".
    pub rating: Option<String>,
    /// Age rating; a plain number reads "ab 12".
    pub age_rating: Option<String>,
}

/// One row of the file excerpt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileRow {
    /// "Container", "Video", "Ton" or "Untertitel" in the user's language.
    pub label: String,
    /// The value.
    pub value: String,
}

/// The excerpt of the file behind the title ("Datei").
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileExcerpt {
    /// The heading.
    pub title: String,
    /// The rows, in order.
    pub rows: Vec<FileRow>,
}

/// The people who watched the title (Jelly Twiggy plugin).
#[derive(Debug, Clone, PartialEq)]
pub struct WatcherTile {
    /// User id.
    pub user_id: String,
    /// Name.
    pub name: String,
    /// First letter, capital, for the avatar without a picture.
    pub initial: String,
    /// Progress ring, 0 to 1.
    pub ring: f64,
    /// How often, as the server counts.
    pub play_count: i64,
    /// When last, as the server's text.
    pub last_watched: Option<String>,
    /// Series and seasons: episodes watched ("n von m Folgen").
    pub watched_count: Option<i64>,
    /// See `watched_count`.
    pub total_count: Option<i64>,
    /// Profile picture, if the user has one.
    pub image: Option<crate::parts::ImageRef>,
}

/// A "Part of the collection" row.
#[derive(Debug, Clone, PartialEq)]
pub struct CollectionRailPart {
    /// The collection's id.
    pub id: String,
    /// The collection's name.
    pub title: String,
    /// The other titles in it.
    pub tiles: Vec<crate::parts::Tile>,
}

/// State of the download field next to the watchlist, as the host's download manager knows it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum DownloadState {
    /// Nothing on the device.
    Nothing,
    /// Waiting for its turn.
    Queued,
    /// Loading, 0 to 1.
    Loading(f32),
    /// Paused.
    Paused,
    /// On the device.
    Ready,
    /// Failed.
    Failed,
}

/// The "Laden" field; only present where the feature is on and the title is no series.
#[derive(Debug, Clone, PartialEq)]
pub struct DownloadField {
    /// What the ring shows.
    pub state: DownloadState,
    /// "Laden".
    pub caption: String,
}

/// What an entry of a menu does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MenuKind {
    /// Start (resume if begun).
    Play,
    /// Start from zero.
    PlayFromStart,
    /// Open the detail page (continue-watching tiles).
    Overview,
    /// Mark watched.
    MarkWatched,
    /// Mark unwatched.
    MarkUnwatched,
    /// Download.
    Download,
    /// Start on another device in reach.
    PlayOn {
        /// Device id.
        id: String,
        /// Device name.
        name: String,
    },
    /// Watch together.
    Together,
    /// Remove from "Continue Watching".
    RemoveFromContinue,
    /// Put the progress back to zero.
    ResetProgress,
    /// Have the server read the metadata again.
    RefreshMetadata,
    /// Series: play the episode the viewer is at from its start.
    PlayEpisodeFromStart,
    /// Series: play the episode after the one the viewer is at.
    NextEpisode,
    /// Series: play an episode at random (the host holds the shuffle run).
    Shuffle,
    /// Series: mark the shown season watched.
    MarkSeasonWatched {
        /// The season's name, for the label.
        name: String,
    },
    /// Play the trailer.
    Trailer,
}

/// One entry of the More panel or the tile menu.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MenuEntry {
    /// What it does.
    pub kind: MenuKind,
    /// The label in the user's language.
    pub text: String,
}

/// What the host knows that the menu rules need.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MenuContext {
    /// The download button is offered at all (switch and the account's right).
    pub download_button: bool,
    /// A copy of the title is on the device (or queued).
    pub on_device: bool,
    /// Devices in reach to start on.
    pub play_on: Vec<(String, String)>,
    /// Watching together is possible on this platform and account.
    pub together: bool,
    /// The tile sits in "Continue Watching".
    pub continue_watching: bool,
    /// The menu is opened inside the player.
    pub in_player: bool,
}

/// A press on the tile menu carries only movies, series and episodes (`TileMenu.carries`).
pub fn tile_menu_carries(item: &Item) -> bool {
    matches!(item.type_.as_deref(), Some("Movie" | "Series" | "Episode"))
}

fn begun(item: &Item) -> bool {
    crate::title_text::resume_from(item).is_some()
}

/// The entries of the long-press menu of a tile (`TileMenu.entries`), in order.
pub(crate) fn tile_menu(text: &TitleText, item: &Item, cx: &MenuContext) -> Vec<MenuEntry> {
    if !tile_menu_carries(item) {
        return Vec::new();
    }
    let series = item.type_.as_deref() == Some("Series");
    let mut list = Vec::new();
    if !cx.in_player {
        push(
            &mut list,
            text,
            MenuKind::Play,
            if !series && begun(item) {
                "Fortsetzen"
            } else {
                "Abspielen"
            },
        );
    }
    if cx.continue_watching {
        push(&mut list, text, MenuKind::Overview, "Zur Übersicht");
    }
    let watched = item
        .user_data
        .as_ref()
        .and_then(|d| d.played)
        .unwrap_or(false);
    if series || !watched {
        push(
            &mut list,
            text,
            MenuKind::MarkWatched,
            "Als gesehen markieren",
        );
    }
    if series || watched || begun(item) {
        push(
            &mut list,
            text,
            MenuKind::MarkUnwatched,
            "Als ungesehen markieren",
        );
    }
    if !series && !cx.in_player && cx.download_button && !cx.on_device {
        push(&mut list, text, MenuKind::Download, "Laden");
    }
    if !series && !cx.in_player {
        for (id, name) in &cx.play_on {
            list.push(MenuEntry {
                kind: MenuKind::PlayOn {
                    id: id.clone(),
                    name: name.clone(),
                },
                text: name.clone(),
            });
        }
    }
    if !series && !cx.in_player && cx.together {
        push(&mut list, text, MenuKind::Together, "Gemeinsam schauen");
    }
    if cx.continue_watching {
        push(
            &mut list,
            text,
            MenuKind::RemoveFromContinue,
            "Aus Weiterschauen entfernen",
        );
    }
    list
}

fn push(list: &mut Vec<MenuEntry>, text: &TitleText, kind: MenuKind, key: &str) {
    list.push(MenuEntry {
        kind,
        text: text.key(key),
    });
}

/// The More panel of a movie (`TitleActions.playOn` + `forMovie`).
pub(crate) fn more_menu(
    text: &TitleText,
    item: &Item,
    plan_known: bool,
    cx: &MenuContext,
) -> Vec<MenuEntry> {
    let mut list: Vec<MenuEntry> = Vec::new();
    if plan_known {
        for (id, name) in &cx.play_on {
            list.push(MenuEntry {
                kind: MenuKind::PlayOn {
                    id: id.clone(),
                    name: name.clone(),
                },
                text: text.with(
                    "Abspielen auf „%@“",
                    &[swiftly_l10n::Arg::Str(name.clone())],
                ),
            });
        }
    }
    if plan_known && begun(item) {
        push(
            &mut list,
            text,
            MenuKind::PlayFromStart,
            "Von vorn abspielen",
        );
        push(
            &mut list,
            text,
            MenuKind::ResetProgress,
            "Fortschritt zurücksetzen",
        );
    }
    if plan_known && cx.together {
        push(&mut list, text, MenuKind::Together, "Gemeinsam schauen");
    }
    push(
        &mut list,
        text,
        MenuKind::RefreshMetadata,
        "Metadaten neu einlesen",
    );
    list
}

/// The age rating as the proof row shows it: a plain number reads "ab 12"; empty is none.
pub(crate) fn age_rating_text(text: &TitleText, raw: Option<String>) -> Option<String> {
    raw.filter(|r| !r.is_empty()).map(|r| {
        if r.chars().all(|c| c.is_ascii_digit()) {
            text.with("ab %@", &[swiftly_l10n::Arg::Str(r)])
        } else {
            r
        }
    })
}

/// The community rating as "7,5" (`ProofRow`: a point becomes a comma in every language).
pub(crate) fn rating_text(rating: f64) -> String {
    format!("{rating:.1}").replace('.', ",")
}

/// The rows of the file excerpt (`fileExcerpt`, `FileDetails`).
pub(crate) fn file_excerpt(text: &TitleText, source: &MediaSource, language: &str) -> FileExcerpt {
    let sep = decimal_separator(language);
    let words = crate::tile::Words::new(text.locale());
    let streams = source.media_streams.as_deref().unwrap_or(&[]);
    let of = |kind: &str| -> Vec<&MediaStream> {
        streams
            .iter()
            .filter(|s| s.type_.as_deref() == Some(kind))
            .collect()
    };
    let mut rows = Vec::new();
    if let Some(container) = &source.container {
        let value = match source.size {
            Some(bytes) => format!("{} · {}", container.to_uppercase(), size_text(bytes, sep)),
            None => container.to_uppercase(),
        };
        rows.push(FileRow {
            label: text.key("Container"),
            value,
        });
    }
    if let Some(video) = of("Video").first() {
        let mut parts = Vec::new();
        if let Some(h) = source.height() {
            parts.push(format!("{h}p"));
        }
        if let Some(codec) = &video.codec {
            parts.push(codec_name(codec));
        }
        rows.push(FileRow {
            label: text.key("Video"),
            value: if parts.is_empty() {
                video.short_with(&words)
            } else {
                parts.join(" · ")
            },
        });
    }
    for audio in of("Audio").into_iter().take(2) {
        rows.push(FileRow {
            label: text.key("Ton"),
            value: audio.short_with(&words),
        });
    }
    rows.push(FileRow {
        label: text.key("Untertitel"),
        value: subtitle_summary(text, &of("Subtitle")),
    });
    FileExcerpt {
        title: text.key("Datei"),
        rows,
    }
}

/// At most three languages, then "+ n"; "Keine" without subtitles (`FileDetails.subtitle`).
fn subtitle_summary(text: &TitleText, streams: &[&MediaStream]) -> String {
    if streams.is_empty() {
        return text.key("Keine");
    }
    let mut unique: Vec<String> = Vec::new();
    for s in streams {
        if let Some(name) = s.language_name(&crate::tile::Words::new(text.locale()))
            && !unique.contains(&name)
        {
            unique.push(name);
        }
    }
    let visible = unique
        .iter()
        .take(3)
        .cloned()
        .collect::<Vec<_>>()
        .join(" · ");
    let rest = unique.len().saturating_sub(3);
    if rest > 0 {
        format!("{visible} + {rest}")
    } else if visible.is_empty() {
        streams.len().to_string()
    } else {
        visible
    }
}

/// One way to show a trailer.
#[derive(Debug, Clone, PartialEq)]
pub enum TrailerCandidate {
    /// A file on the server: plays in the app's own player.
    File(Box<Item>),
    /// A page on the web.
    Web(Url),
}

/// Files first in the server's order, then links (`TrailerChoice.candidates`). Without a
/// browser (`can_open_web == false`) only files.
pub fn trailer_candidates(
    local: &[Item],
    remote: Option<&[MediaUrl]>,
    can_open_web: bool,
) -> Vec<TrailerCandidate> {
    let mut out = Vec::new();
    let mut seen: Vec<&str> = Vec::new();
    for item in local {
        if !item.id.is_empty() && !seen.contains(&item.id.as_str()) {
            seen.push(&item.id);
            out.push(TrailerCandidate::File(Box::new(item.clone())));
        }
    }
    if !can_open_web {
        return out;
    }
    let mut links: Vec<Url> = Vec::new();
    for link in remote.unwrap_or(&[]) {
        if let Some(url) = web_address(link.url.as_deref())
            && !links.contains(&url)
        {
            links.push(url.clone());
            out.push(TrailerCandidate::Web(url));
        }
    }
    out
}

/// The page a link stands for, or `None` if a browser could not open it. Kodi plugin links
/// become the YouTube page (`TrailerChoice.webAddress`).
pub fn web_address(raw: Option<&str>) -> Option<Url> {
    let text = raw?.trim();
    if text.is_empty() {
        return None;
    }
    if text
        .to_lowercase()
        .starts_with("plugin://plugin.video.youtube")
    {
        let id = Url::parse(text).ok().and_then(|u| {
            u.query_pairs()
                .find(|(k, _)| k == "videoid" || k == "video_id")
                .map(|(_, v)| v.into_owned())
        })?;
        if id.is_empty()
            || !id
                .chars()
                .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
        {
            return None;
        }
        return Url::parse(&format!("https://www.youtube.com/watch?v={id}")).ok();
    }
    let url = Url::parse(text).ok()?;
    let scheme = url.scheme().to_lowercase();
    ((scheme == "http" || scheme == "https") && url.host_str().is_some_and(|h| !h.is_empty()))
        .then_some(url)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: &str) -> Item {
        serde_json::from_value(serde_json::json!({"Id": id, "Name": id, "Type": "Video"})).unwrap()
    }

    #[test]
    fn files_lead_links_follow_plugin_links_become_youtube() {
        let remote = vec![
            MediaUrl {
                url: Some("plugin://plugin.video.youtube/?action=play_video&videoid=abc-1".into()),
                name: None,
            },
            MediaUrl {
                url: Some("plugin://other/x".into()),
                name: None,
            },
            MediaUrl {
                url: Some("https://example.org/t".into()),
                name: None,
            },
            MediaUrl {
                url: Some("https://example.org/t".into()),
                name: None,
            },
        ];
        let local = [item("a"), item("a"), item("")];
        let all = trailer_candidates(&local, Some(&remote), true);
        assert_eq!(all.len(), 3);
        assert!(matches!(&all[0], TrailerCandidate::File(i) if i.id == "a"));
        assert!(
            matches!(&all[1], TrailerCandidate::Web(u) if u.as_str() == "https://www.youtube.com/watch?v=abc-1")
        );
        assert_eq!(trailer_candidates(&local, Some(&remote), false).len(), 1);
    }

    #[test]
    fn rating_uses_a_comma() {
        assert_eq!(rating_text(7.54), "7,5");
    }
}
