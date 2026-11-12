#![allow(missing_docs)]
//! The server-side download calls of the old Android facade (`Kern.downloadItem`, `downloadAudioOptions`,
//! `downloadWithAudio`, `downloadHeaderImage`, `downloadSections`, the pending reports) on the title/series object of one
//! account, plus the two typed helpers the `DownloadHost` needs (`download_follow_fetch`, `download_successor`). The
//! queue, the watch-state catch-up and the successor rules themselves are the core's `DownloadsVm` (`DownloadsIntent::
//! ServerFollow`, `SuccessorFound`, `SectionsFetched`), not repeated here.

use std::collections::{HashMap, HashSet};
use std::sync::PoisonError;
use std::sync::atomic::Ordering;

use serde_json::{Value, json};
use swiftly_downloads::item::{audio_streams, first_source};
use swiftly_downloads::rules::DownloadRules;
use swiftly_downloads::{
    Art, AudioStream, AudioTrackRules, DownloadAudioChoice, DownloadItem, decode_list, encode_list,
};
use swiftly_images::{ImageKind, ImageMetric, ImageSelection};
use swiftly_jellyfin::{ItemsQuery, PendingReport, PostReportRules};
use swiftly_model::{MediaSource, MediaStream, UserItemData};
use swiftly_net::{ErrorKind, HttpTransport};
use swiftly_playback::sections::Segment;

use crate::legacy_detail::{DetailOf, DetailServer, LegacyDetail};

fn now_unix() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

fn items_text(items: &[DownloadItem]) -> String {
    String::from_utf8(encode_list(items).unwrap_or_default()).unwrap_or_else(|_| "[]".into())
}

fn choice_id(c: &DownloadAudioChoice) -> String {
    match c {
        DownloadAudioChoice::All => "all".into(),
        DownloadAudioChoice::Track(i) => format!("track:{i}"),
        DownloadAudioChoice::Language(k) => format!("lang:{k}"),
    }
}

fn choice_of(id: &str) -> DownloadAudioChoice {
    if let Some(n) = id
        .strip_prefix("track:")
        .and_then(|n| n.parse::<i64>().ok())
    {
        return DownloadAudioChoice::Track(n);
    }
    if let Some(k) = id.strip_prefix("lang:") {
        return DownloadAudioChoice::Language(k.to_owned());
    }
    DownloadAudioChoice::All
}

fn audio_of(streams: &[MediaStream]) -> Vec<AudioStream> {
    audio_streams(Some(&MediaSource {
        media_streams: Some(streams.to_vec()),
        ..MediaSource::default()
    }))
}

fn pending_read(raw: &str) -> Vec<PendingReport> {
    serde_json::from_str(raw).unwrap_or_default()
}

fn pending_text(list: &[PendingReport]) -> String {
    serde_json::to_string(list).unwrap_or_else(|_| "[]".into())
}

/// `Kern.pendingReportRecord`: one per title and account, the newer wins. A message that does not read leaves the store.
pub fn pending_report_record(store: &str, message: &str) -> String {
    let Ok(m) = serde_json::from_str::<PendingReport>(message) else {
        return store.to_owned();
    };
    pending_text(&PostReportRules::record(m, &pending_read(store)))
}

/// `Kern.stoppsProcess`: what the stops since the last pickup mean. Every stop of a download records position, watched state
/// and time on the item (`DownloadItem::post_playback`); one that reached the server clears the pending catch-up report of the
/// same title; one that watched to the end with a successor marks the next episode as due (`nextAuto`). Answer
/// `{"ablage": <store text>, "posten": [<changed entries>]}`.
pub fn stops_process(
    store: &str,
    list: &str,
    next_auto: bool,
    stops: &[crate::LegacyStop],
) -> String {
    let mut messages = pending_read(store);
    let mut entries: Vec<DownloadItem> = serde_json::from_str(list).unwrap_or_default();
    let mut changed: HashSet<String> = HashSet::new();
    for s in stops {
        if s.sent {
            messages = PostReportRules::over_fetches(&s.item_id, &s.account, &messages);
        }
        if let Some(i) = entries
            .iter()
            .position(|e| e.id == s.item_id && e.account == s.account)
        {
            entries[i] = entries[i].post_playback(s.ticks, s.moment);
            if next_auto
                && DownloadRules::has_successor(&entries[i])
                && DownloadRules::reached_end(s.ticks, entries[i].runtime_ticks)
            {
                entries[i].next_pending = Some(true);
            }
            changed.insert(entries[i].id.clone());
        }
    }
    let posten: Vec<&DownloadItem> = entries.iter().filter(|e| changed.contains(&e.id)).collect();
    json!({"ablage": pending_text(&messages), "posten": posten}).to_string()
}

/// `Kern.pendingDone`: removes the settled reports from the store.
pub fn pending_done(store: &str, completed: &str) -> String {
    let ids: Vec<String> = serde_json::from_str(completed).unwrap_or_default();
    if ids.is_empty() {
        return store.to_owned();
    }
    pending_text(&PostReportRules::completed(&ids, &pending_read(store)))
}

/// What the server said about the downloaded titles: the ids it knows and the watch state of each.
pub struct FollowFetch {
    pub available: Vec<String>,
    pub states: Vec<(String, UserItemData)>,
}

impl<S: DetailServer> DetailOf<S> {
    /// The external text subtitles that travel with a finished download, as `[{"index","adresse","endung"}]`
    /// (`SubtitleFile::with_load`): the files next to the film and, for a built file, the server-extracted embedded
    /// text tracks. Empty without an answer. The host stores each as `<index>.<endung>` in the file's subtitle folder.
    pub async fn download_subtitle_files(
        &self,
        id: &str,
        source: Option<&str>,
        converted: bool,
    ) -> String {
        let plan = match DetailServer::plan(&*self.client, id, 200_000_000).await {
            Ok(Some(plan)) => plan,
            _ => return "[]".into(),
        };
        let Some(media) = plan.source.as_ref() else {
            return "[]".into();
        };
        let streams = media.media_streams.clone().unwrap_or_default();
        let source = source
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .or_else(|| media.id.clone());
        let a = &self.addresses;
        download_subtitle_rows(
            &streams,
            id,
            source.as_deref(),
            a.base.as_str(),
            a.token.as_deref(),
            a.token_name,
            converted,
        )
    }

    /// `Kern.downloadAddress`: the file address of a download from the server (Plex: the original file; Jellyfin and Emby
    /// build it without a request in `Core::download_address`).
    pub async fn download_address(
        &self,
        id: &str,
        source: Option<&str>,
        quality: &str,
        audio_index: Option<i64>,
    ) -> Result<String, ErrorKind> {
        let level = swiftly_rules::download_quality::DownloadQuality::from_raw_value(quality)
            .unwrap_or(swiftly_rules::download_quality::DownloadQuality::Original);
        DetailServer::download_url(
            &*self.client,
            id,
            source.filter(|s| !s.is_empty()),
            level,
            audio_index.filter(|i| *i >= 0),
        )
        .await
    }

    /// `Kern.downloadSections` as the stored segments; `None` is no answer (asked again on the next contact).
    pub async fn download_sections_typed(&self, id: &str) -> Option<Vec<Segment>> {
        DetailServer::segments_to_store(&*self.client, id).await
    }

    /// `Kern.downloadSections`: the segments as JSON, empty without an answer.
    pub async fn download_sections(&self, id: &str) -> String {
        match self.download_sections_typed(id).await {
            Some(parts) => serde_json::to_string(&parts).unwrap_or_default(),
            None => String::new(),
        }
    }

    /// What the server says about the downloaded titles (the first half of `Kern.downloadsCatchUp`; the rule that puts it
    /// into the entries is the core's). `None` when any answer is missing, so nothing changes.
    pub async fn download_follow_fetch(&self, ids: &[String]) -> Option<FollowFetch> {
        let mut available = Vec::new();
        let mut states = Vec::new();
        for piece in ids.chunks(100) {
            let q = ItemsQuery {
                limit: i64::try_from(piece.len()).unwrap_or(100),
                ids: piece.to_vec(),
                ..ItemsQuery::default()
            };
            let answer = DetailServer::items(&*self.client, &q).await.ok()?;
            for t in answer.items {
                available.push(t.id.clone());
                if let Some(u) = t.user_data {
                    states.push((t.id, u));
                }
            }
        }
        Some(FollowFetch { available, states })
    }

    /// The series' episodes (`{"Items":[...]}`) and the next episode's landscape image for a watched download
    /// (`Kern.downloadFollowing`'s server half). `None`: no answer (offline), the entry stays pending.
    pub async fn download_successor(&self, watched: &str) -> Option<(String, Option<String>)> {
        let item: DownloadItem = serde_json::from_str(watched).ok()?;
        let series = item.series_identifier.clone()?;
        let episodes = DetailServer::episodes(&*self.client, &series, None)
            .await
            .ok()?;
        let image = match DownloadRules::following_episode(&item, &episodes) {
            Some(n) => DetailServer::episode_image(&*self.client, n, 220).await,
            None => None,
        };
        Some((json!({ "Items": episodes }).to_string(), image))
    }
}

impl<S: DetailServer> DetailOf<S> {
    fn streams_cache<R>(&self, f: impl FnOnce(&mut HashMap<String, Vec<MediaStream>>) -> R) -> R {
        f(&mut self
            .audio_streams
            .lock()
            .unwrap_or_else(PoisonError::into_inner))
    }

    /// `Kern.downloadItem`: a post for a download with the images that go to disk too. The source is the one the player
    /// would take: the title's first one, otherwise the one from the playback plan.
    pub async fn download_item(&self, ids: &[String]) -> String {
        let c = &*self.client;
        let account = self.account.clone();
        let limit = self.limit();
        let fetched = futures_util::future::join_all(ids.iter().map(|id| async move {
            let item = DetailServer::item(c, id).await.ok()?;
            let source = match first_source(&item).cloned() {
                Some(q) => Some(q),
                None => DetailServer::plan(c, id, limit)
                    .await
                    .ok()
                    .flatten()
                    .and_then(|p| p.source),
            };
            Some((id.clone(), item, source))
        }))
        .await;
        let mut found = HashMap::new();
        for (id, item, source) in fetched.into_iter().flatten() {
            let streams = source
                .as_ref()
                .and_then(|s| s.media_streams.clone())
                .unwrap_or_default();
            self.streams_cache(|m| m.insert(id.clone(), streams));
            found.insert(id, (item, source));
        }
        let now = now_unix();
        let mut answer = Vec::new();
        for id in ids {
            let Some((i, q)) = found.get(id) else {
                continue;
            };
            let episode = i.type_.as_deref() == Some("Episode");
            let mut post = DownloadItem::new(
                i.id.clone(),
                account.clone(),
                if episode { Art::Episode } else { Art::Film },
                i.name.clone(),
                q.as_ref().and_then(|s| s.size).unwrap_or(0),
                now,
            )
            .with_watch_state(
                i.user_data.as_ref(),
                q.as_ref().and_then(|s| s.video_codec().map(str::to_owned)),
            );
            if episode {
                post.series = i.series_name.clone();
                post.series_identifier = i.series_id.clone();
                post.season = i.parent_index_number;
                post.episode = i.index_number;
            }
            post.runtime_ticks = i.run_time_ticks;
            post.container = q.as_ref().and_then(|s| s.container.clone());
            post.source = q.as_ref().and_then(|s| s.id.clone());
            let image = if episode {
                DetailServer::episode_image(c, i, 220).await
            } else {
                let mark = i
                    .image_tags
                    .as_ref()
                    .and_then(|t| t.get("Primary"))
                    .map(String::as_str);
                self.addresses
                    .construct(&i.id, ImageKind::Poster, mark, ImageMetric::AtMostHigh(600))
                    .map(|u| u.to_string())
            };
            let series_image = if episode {
                i.series_id
                    .as_deref()
                    .and_then(|s| {
                        self.addresses.construct(
                            s,
                            ImageKind::Poster,
                            None,
                            ImageMetric::AtMostHigh(600),
                        )
                    })
                    .map(|u| u.to_string())
            } else {
                None
            };
            let mut o = serde_json::Map::new();
            o.insert(
                "posten".into(),
                serde_json::to_value(&post).unwrap_or(Value::Null),
            );
            if let Some(v) = image {
                o.insert("bild".into(), v.into());
            }
            if let Some(v) = series_image {
                o.insert("serienbild".into(), v.into());
            }
            answer.push(Value::Object(o));
        }
        Value::Array(answer).to_string()
    }

    /// The streams of the given titles; missing ones are fetched and kept.
    pub async fn download_audio_streams(&self, ids: &[String]) -> Vec<Vec<MediaStream>> {
        let c = &*self.client;
        let missing: Vec<String> = {
            let have = self.streams_cache(|m| m.keys().cloned().collect::<HashSet<_>>());
            let mut seen = HashSet::new();
            ids.iter()
                .filter(|i| !have.contains(*i) && seen.insert((*i).clone()))
                .cloned()
                .collect()
        };
        if !missing.is_empty() {
            let got = futures_util::future::join_all(missing.iter().map(|id| async move {
                let item = DetailServer::item(c, id).await.ok()?;
                Some((
                    id.clone(),
                    first_source(&item)
                        .and_then(|s| s.media_streams.clone())
                        .unwrap_or_default(),
                ))
            }))
            .await;
            self.streams_cache(|m| m.extend(got.into_iter().flatten()));
        }
        self.streams_cache(|m| {
            ids.iter()
                .map(|i| m.get(i).cloned().unwrap_or_default())
                .collect()
        })
    }

    /// `Kern.downloadAudioOptions`: one title offers its tracks, a selection of episodes offers languages.
    pub fn download_audio_options(
        &self,
        rules: &dyn AudioTrackRules,
        streams: &[Vec<MediaStream>],
        preferred: &str,
    ) -> String {
        use swiftly_rules::download_audio as audio;
        let ids = streams;
        let all: Vec<Vec<AudioStream>> = streams.iter().map(|s| audio_of(s)).collect();
        let out = |offered: bool,
                   options: &[swiftly_downloads::DownloadAudioOption],
                   preset: &DownloadAudioChoice| {
            json!({
                "angeboten": offered,
                "optionen": options.iter().map(|o| json!({"id": choice_id(&o.choice), "text": o.label})).collect::<Vec<_>>(),
                "vorgabe": choice_id(preset),
            })
            .to_string()
        };
        if ids.len() == 1
            && let Some(streams) = all.first()
        {
            let options = audio::track_options(rules, streams);
            let preset = audio::preselected(rules, &options, streams, preferred);
            return out(audio::offered_for_streams(streams), &options, &preset);
        }
        let options = audio::language_options(rules, &all);
        let wished = DownloadAudioChoice::Language(preferred.to_owned());
        let offered = audio::offered_for_selection(rules, &all);
        let preset = if offered && options.iter().any(|o| o.choice == wished) {
            wished
        } else {
            DownloadAudioChoice::All
        };
        out(offered, &options, &preset)
    }

    /// `Kern.downloadWithAudio`: the items cut down to the chosen audio, resolved per file.
    pub fn download_with_audio(
        &self,
        rules: &dyn AudioTrackRules,
        list: &str,
        choice: &str,
    ) -> String {
        let choice = choice_of(choice);
        let cache = self.streams_cache(|m| m.clone());
        let items: Vec<DownloadItem> = decode_list(list.as_bytes()).unwrap_or_default();
        let out: Vec<DownloadItem> = items
            .iter()
            .map(|i| {
                i.with_audio(
                    rules,
                    &choice,
                    &audio_of(cache.get(&i.id).map_or(&[][..], Vec::as_slice)),
                )
            })
            .collect();
        items_text(&out)
    }

    /// `Kern.downloadHeaderImage`: a series' header image in `width` pixels; empty without an image.
    pub async fn download_header_image(&self, series: &str, width: i64) -> String {
        let Ok(item) = DetailServer::item(&*self.client, series).await else {
            return String::new();
        };
        ImageSelection::header(&item, &self.addresses, width)
            .map(|u| u.to_string())
            .unwrap_or_default()
    }
}

impl<T: HttpTransport + 'static> LegacyDetail<T> {
    /// `Kern.pendingSubmit`: sends the reports left over from offline playback, oldest first; the answer is the settled ids as
    /// JSON. Never twice at once.
    pub async fn pending_submit(&self, store: &str) -> String {
        if self.report_later_runs.swap(true, Ordering::SeqCst) {
            return "[]".into();
        }
        let done = async {
            let account = self.client.current_session()?.user_id;
            let opened = PostReportRules::due(&pending_read(store), &account);
            if opened.is_empty() {
                return None;
            }
            Some(self.client.report_later_all(&opened, |_| {}).await)
        }
        .await;
        self.report_later_runs.store(false, Ordering::SeqCst);
        serde_json::to_string(&done.unwrap_or_default()).unwrap_or_else(|_| "[]".into())
    }

    /// `Kern.watchers`: who has watched a title (Jelly Twiggy plugin). `"absent"`: the server has no plugin (or is not
    /// Jellyfin), the caller remembers that per server; `""`: no answer this time; otherwise the list as JSON.
    pub async fn watchers(&self, id: &str) -> String {
        let c = &*self.client;
        if c.server_kind() != swiftly_jellyfin::ServerKind::Jellyfin {
            return "absent".into();
        }
        let Some(list) = c.watchers(id).await else {
            return if c.watchers_plugin_missing() {
                "absent".into()
            } else {
                String::new()
            };
        };
        let rows: Vec<Value> = list
            .iter()
            .map(|w| {
                let mut o = serde_json::Map::new();
                o.insert("id".into(), w.user_id.clone().into());
                o.insert("name".into(), w.name.clone().into());
                if let Some(tag) = &w.image_tag
                    && let Some(u) = self.addresses.user(&w.user_id, Some(tag), 96)
                {
                    o.insert("image".into(), u.to_string().into());
                }
                o.insert("plays".into(), w.play_count.into());
                if let Some(ms) = w
                    .last_watched
                    .as_deref()
                    .and_then(swiftly_model::parse_timestamp)
                {
                    o.insert("last".into(), ((ms * 1000.0) as i64).into());
                }
                o.insert("ring".into(), w.ring().into());
                Value::Object(o)
            })
            .collect();
        Value::Array(rows).to_string()
    }
}

/// The rows of [`DetailOf::download_subtitle_files`] as JSON (pure, so a test can read it).
pub fn download_subtitle_rows(
    streams: &[MediaStream],
    id: &str,
    source: Option<&str>,
    server: &str,
    key: Option<&str>,
    key_name: &str,
    converted: bool,
) -> String {
    let files = swiftly_playback::track_mapping::SubtitleFile::with_load(
        streams, id, source, server, key, key_name, converted,
    );
    let rows: Vec<Value> = files
        .iter()
        .map(|f| {
            let path = f.address.split(['?', '#']).next().unwrap_or("");
            let name = path.rsplit('/').next().unwrap_or("");
            let ending = name
                .rsplit_once('.')
                .map(|(_, e)| e.to_lowercase())
                .filter(|e| !e.is_empty() && e.len() <= 4);
            let ending = ending.unwrap_or_else(|| {
                let codec = streams
                    .iter()
                    .find(|m| m.index == Some(f.index))
                    .and_then(|m| m.codec.as_deref());
                match codec.map(str::to_lowercase).as_deref() {
                    Some("ass" | "ssa") => "ass",
                    Some("vtt" | "webvtt") => "vtt",
                    _ => "srt",
                }
                .to_owned()
            });
            let meta = streams
                .iter()
                .find(|m| m.index == Some(f.index))
                .map_or_else(
                    || crate::subtitle_sidecar::SubtitleMeta {
                        index: f.index,
                        ..Default::default()
                    },
                    |m| crate::subtitle_sidecar::SubtitleMeta::of(m, f.index),
                );
            json!({"index": f.index, "adresse": f.address, "endung": ending, "meta": meta})
        })
        .collect();
    Value::Array(rows).to_string()
}

#[cfg(test)]
mod subtitle_download_tests {
    use super::download_subtitle_rows;
    use swiftly_model::MediaStream;

    fn sub(index: i64, codec: &str, external: bool, url: Option<&str>) -> MediaStream {
        MediaStream {
            index: Some(index),
            type_: Some("Subtitle".into()),
            codec: Some(codec.into()),
            is_external: Some(external),
            delivery_url: url.map(str::to_owned),
            ..Default::default()
        }
    }

    #[test]
    fn external_files_travel_with_the_download_under_their_ending() {
        let streams = vec![
            sub(3, "srt", true, Some("/Videos/x/q/Subtitles/3/0/Stream.srt")),
            sub(4, "ass", true, Some("/Videos/x/q/Subtitles/4/0/Stream.ass")),
            sub(5, "subrip", false, None),
        ];
        let rows: serde_json::Value = serde_json::from_str(&download_subtitle_rows(
            &streams,
            "x",
            Some("q"),
            "http://h:1",
            Some("k"),
            "ApiKey",
            false,
        ))
        .unwrap();
        let rows = rows.as_array().unwrap();
        assert_eq!(
            rows.len(),
            2,
            "embedded text stays in the file of an original download"
        );
        assert_eq!(rows[0]["endung"], "srt");
        assert_eq!(rows[1]["endung"], "ass");
        assert!(rows[0]["adresse"].as_str().unwrap().contains("ApiKey=k"));
    }

    #[test]
    fn rows_name_what_each_file_is_without_the_key() {
        let mut german = sub(3, "srt", true, Some("/Videos/x/q/Subtitles/3/0/Stream.srt"));
        german.language = Some("ger".into());
        german.is_forced = Some(true);
        let rows = super::download_subtitle_rows(
            &[german],
            "x",
            Some("q"),
            "http://h:1",
            Some("k"),
            "ApiKey",
            false,
        );
        let rows = crate::subtitle_sidecar::parse_rows(&rows);
        assert_eq!(
            (
                rows[0].meta.language.as_deref(),
                rows[0].meta.forced,
                rows[0].meta.codec.as_deref()
            ),
            (Some("ger"), true, Some("srt"))
        );
        assert!(
            !serde_json::to_string(&rows[0].meta)
                .unwrap()
                .contains("ApiKey")
        );
    }

    #[test]
    fn a_built_file_gets_its_embedded_text_as_extracted_files() {
        let streams = vec![sub(5, "subrip", false, None)];
        let rows: serde_json::Value = serde_json::from_str(&download_subtitle_rows(
            &streams,
            "x",
            Some("q"),
            "http://h:1",
            Some("k"),
            "ApiKey",
            true,
        ))
        .unwrap();
        assert_eq!(rows.as_array().unwrap().len(), 1);
        assert_eq!(rows[0]["index"], 5);
    }
}
