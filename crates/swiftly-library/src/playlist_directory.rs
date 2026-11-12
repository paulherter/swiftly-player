//! `VideoPlaylist` and `PlaylistDirectory` (Swift `PlaylistDirectory.swift:1-70`): the video
//! playlists of an account. The fetch (`playlistDirectory`) is in `client_ext`.

use swiftly_model::Item;

/// A Jellyfin playlist that holds video, with what it contains (:4-27).
#[derive(Debug, Clone, PartialEq)]
pub struct VideoPlaylist {
    /// The playlist itself.
    pub item: Item,
    /// Number of movies.
    pub movies: usize,
    /// Number of episodes and series.
    pub episodes: usize,
}

impl VideoPlaylist {
    /// `init(item:members:)`.
    pub fn new(item: Item, members: &[Item]) -> Self {
        let n = |f: &dyn Fn(&str) -> bool| {
            members
                .iter()
                .filter(|m| m.type_.as_deref().is_some_and(f))
                .count()
        };
        Self {
            item,
            movies: n(&|t| t == "Movie"),
            episodes: n(&|t| t == "Episode" || t == "Series"),
        }
    }
    /// The playlist's id.
    pub fn id(&self) -> &str {
        &self.item.id
    }
    /// How many entries count in this section (`movies` or `tvshows`).
    pub fn count(&self, art: &str) -> usize {
        match art.to_lowercase().as_str() {
            "movies" => self.movies,
            "tvshows" => self.episodes,
            _ => 0,
        }
    }
    /// What a section shows of a playlist's entries (:38-44); without a section everything.
    pub fn shown(entries: &[Item], art: Option<&str>) -> Vec<Item> {
        let keep = |types: &[&str]| -> Vec<Item> {
            entries
                .iter()
                .filter(|e| e.type_.as_deref().is_some_and(|t| types.contains(&t)))
                .cloned()
                .collect()
        };
        match art {
            Some("movies") => keep(&["Movie", "Video"]),
            Some("tvshows") => keep(&["Episode", "Series"]),
            _ => entries.to_vec(),
        }
    }
    /// An entry that can be shown and played here; songs in a mixed list drop out (:51-56).
    pub fn is_video_entry(entry: &Item) -> bool {
        match entry.type_.as_deref() {
            Some("Movie" | "Episode" | "Series" | "Video" | "MusicVideo") => true,
            _ => entry.media_type.as_deref() == Some("Video"),
        }
    }
    /// Whether the list is video at all (:58-60).
    pub fn is_video(playlist: &Item) -> bool {
        playlist.type_.as_deref() == Some("Playlist")
            && matches!(playlist.media_type.as_deref(), None | Some("Video"))
    }
}

/// The video playlists of an account (:70-86).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct PlaylistDirectory {
    /// The playlists, in server order.
    pub all: Vec<VideoPlaylist>,
}

impl PlaylistDirectory {
    /// The playlists with entries of this section, in server order.
    pub fn playlists(&self, art: &str) -> Vec<&VideoPlaylist> {
        self.all.iter().filter(|p| p.count(art) > 0).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decode(json: &str) -> Vec<Item> {
        serde_json::from_str::<swiftly_model::ItemsResponse>(json)
            .map(|r| r.items)
            .unwrap_or_default()
    }
    fn ids(v: &[Item]) -> Vec<&str> {
        v.iter().map(|i| i.id.as_str()).collect()
    }
    fn playlist(id: &str, movies: usize, episodes: usize) -> VideoPlaylist {
        let mut members = Vec::new();
        members.extend((0..movies).map(|i| Item::new(format!("{id}f{i}"), "", Some("Movie"))));
        members.extend((0..episodes).map(|i| Item::new(format!("{id}e{i}"), "", Some("Episode"))));
        VideoPlaylist::new(
            Item {
                media_type: Some("Video".into()),
                ..Item::new(id, id, Some("Playlist"))
            },
            &members,
        )
    }

    #[test]
    fn decoding_reads_type_and_media_type() {
        let list = decode(
            r#"{"Items":[
              {"Id":"p1","Name":"Watchlist","Type":"Playlist","MediaType":"Video","ChildCount":3},
              {"Id":"p2","Name":"Musik","Type":"Playlist","MediaType":"Audio"}],"TotalRecordCount":2}"#,
        );
        assert_eq!(
            list.iter().map(|i| i.type_.as_deref()).collect::<Vec<_>>(),
            [Some("Playlist"); 2]
        );
        assert_eq!(
            list.iter()
                .map(|i| i.media_type.as_deref())
                .collect::<Vec<_>>(),
            [Some("Video"), Some("Audio")]
        );
        let videos: Vec<Item> = list.into_iter().filter(VideoPlaylist::is_video).collect();
        assert_eq!(ids(&videos), ["p1"]);
    }
    #[test]
    fn without_media_type_the_list_counts() {
        assert!(VideoPlaylist::is_video(&Item::new(
            "a",
            "",
            Some("Playlist")
        )));
        let boxset = Item {
            media_type: Some("Video".into()),
            ..Item::new("b", "", Some("BoxSet"))
        };
        assert!(!VideoPlaylist::is_video(&boxset));
        let audio = Item {
            media_type: Some("Audio".into()),
            ..Item::new("c", "", Some("Playlist"))
        };
        assert!(!VideoPlaylist::is_video(&audio));
    }
    #[test]
    fn entries_videos_stay_songs_drop() {
        let list = decode(
            r#"{"Items":[
              {"Id":"m","Name":"Film","Type":"Movie","MediaType":"Video"},
              {"Id":"e","Name":"Folge","Type":"Episode","MediaType":"Video"},
              {"Id":"s","Name":"Lied","Type":"Audio","MediaType":"Audio"},
              {"Id":"v","Name":"Clip","Type":"Trailer","MediaType":"Video"}]}"#,
        );
        let kept: Vec<Item> = list
            .into_iter()
            .filter(VideoPlaylist::is_video_entry)
            .collect();
        assert_eq!(ids(&kept), ["m", "e", "v"]);
    }
    #[test]
    fn shown_by_section() {
        let list = decode(
            r#"{"Items":[{"Id":"e1","Name":"A","Type":"Episode"},{"Id":"m1","Name":"B","Type":"Movie"},
              {"Id":"e2","Name":"C","Type":"Episode"}]}"#,
        );
        assert_eq!(ids(&VideoPlaylist::shown(&list, Some("movies"))), ["m1"]);
        assert_eq!(
            ids(&VideoPlaylist::shown(&list, Some("tvshows"))),
            ["e1", "e2"]
        );
        assert_eq!(ids(&VideoPlaylist::shown(&list, None)), ["e1", "m1", "e2"]);
    }
    #[test]
    fn sections() {
        let d = PlaylistDirectory {
            all: vec![
                playlist("film", 2, 0),
                playlist("folge", 0, 3),
                playlist("beides", 1, 1),
                playlist("leer", 0, 0),
            ],
        };
        assert_eq!(
            d.playlists("movies")
                .iter()
                .map(|p| p.id())
                .collect::<Vec<_>>(),
            ["film", "beides"]
        );
        assert_eq!(
            d.playlists("tvshows")
                .iter()
                .map(|p| p.id())
                .collect::<Vec<_>>(),
            ["folge", "beides"]
        );
        assert!(d.playlists("music").is_empty());
        assert_eq!(
            d.all
                .iter()
                .find(|p| p.id() == "film")
                .map(|p| p.count("movies")),
            Some(2)
        );
    }
    #[test]
    fn start_selection_leaves_out_playlists() {
        let list = Item {
            collection_type: Some("playlists".into()),
            ..Item::new("pl", "", None)
        };
        assert!(!crate::StartLibraries::selectable(&list));
    }
}
