//! Differential oracle, downloads: `swiftly-downloads` and `swiftly-rules::download_audio` against the
//! real Swift code (Tools/Oracle, Domain_Downloads.swift). Labels of the audio options are not compared
//! (language names come from the system locale and the string catalog). `DownloadRules.size` (process
//! locale), `ProgressEstimator` (Date clock) and `followUp` (stamps `Date()`) have no oracle.
#![allow(clippy::expect_used, clippy::unwrap_used)]

use serde_json::{Value, json};
use swiftly_downloads::DownloadRules;
use swiftly_downloads::item::audio_streams;
use swiftly_downloads::rules::{FootSpace, NetworkVerdict};
use swiftly_downloads::{DownloadGroup, DownloadItem, DownloadQuality, PathPart};
use swiftly_hardening::oracle::assert_equal;
use swiftly_model::{Item, MediaSource, MediaStream, UserItemData};
use swiftly_playback::track_mapping::language_key;
use swiftly_playback::track_rule;
use swiftly_rules::download_audio::{
    AudioStream, AudioTrackRules, DownloadAudioChoice, DownloadAudioOption, index_for,
    language_key_of, language_options, offered_for_selection, offered_for_streams, preselected,
    track_options,
};

const OFFSET: f64 = 978_307_200.0;

struct Rules;

impl AudioTrackRules for Rules {
    fn language_key(&self, language: Option<&str>) -> Option<String> {
        language_key(language)
    }
    fn language_label(&self, key: &str) -> Option<String> {
        Some(key.to_owned())
    }
    fn audio_label(&self, _: Option<&str>, _: Option<&str>, _: Option<i64>) -> Option<String> {
        None
    }
    fn distinct(&self, labels: Vec<String>) -> Vec<String> {
        labels
    }
    fn preferred_audio_index(&self, streams: &[AudioStream], preferred: &str) -> Option<i64> {
        let media: Vec<MediaStream> = streams
            .iter()
            .map(|s| MediaStream {
                index: s.index,
                type_: Some(s.kind.clone()),
                language: s.language.clone(),
                codec: s.codec.clone(),
                channels: s.channels,
                display_title: s.display_title.clone(),
                is_default: s.is_default,
                ..MediaStream::default()
            })
            .collect();
        track_rule::audio(&media, None, preferred, None, None)
    }
    fn all_label(&self) -> String {
        "all".into()
    }
    fn track_word(&self) -> String {
        "track".into()
    }
}

fn audio(v: &Value) -> Vec<AudioStream> {
    let streams: Vec<MediaStream> = serde_json::from_value(v.clone()).expect("streams");
    audio_streams(Some(&MediaSource {
        media_streams: Some(streams),
        ..MediaSource::default()
    }))
}
fn choice_json(c: &DownloadAudioChoice) -> Value {
    match c {
        DownloadAudioChoice::All => json!({ "k": "all" }),
        DownloadAudioChoice::Track(i) => json!({ "k": "track", "i": i }),
        DownloadAudioChoice::Language(k) => json!({ "k": "language", "key": k }),
    }
}
fn choices(o: &[DownloadAudioOption]) -> Value {
    json!(o.iter().map(|o| choice_json(&o.choice)).collect::<Vec<_>>())
}

#[test]
fn download_audio() {
    assert_equal("download_audio", |c| {
        let streams = audio(&c["streams"]);
        let selection: Vec<Vec<AudioStream>> = c["selection"]
            .as_array()
            .unwrap()
            .iter()
            .map(audio)
            .collect();
        let choice = match c["choice"]["k"].as_str().unwrap() {
            "track" => DownloadAudioChoice::Track(c["choice"]["i"].as_i64().unwrap()),
            "language" => {
                DownloadAudioChoice::Language(c["choice"]["key"].as_str().unwrap().to_owned())
            }
            _ => DownloadAudioChoice::All,
        };
        let options = if c["mode"] == "track" {
            track_options(&Rules, &streams)
        } else {
            language_options(&Rules, std::slice::from_ref(&streams))
        };
        let pref = preselected(&Rules, &options, &streams, c["pref"].as_str().unwrap());
        json!({
            "offered": offered_for_streams(&streams),
            "offered_sel": offered_for_selection(&Rules, &selection),
            "track_options": choices(&track_options(&Rules, &streams)),
            "language_options": choices(&language_options(&Rules, &selection)),
            "preselected": choice_json(&pref),
            "index": index_for(&Rules, &choice, &streams),
            "language_key": language_key_of(&Rules, c["index"].as_i64().unwrap(), &streams),
        })
    });
}

fn item(v: &Value) -> DownloadItem {
    serde_json::from_value(v.clone()).expect("item")
}
fn items(v: &Value) -> Vec<DownloadItem> {
    v.as_array().unwrap().iter().map(item).collect()
}
fn ids(l: &[DownloadItem]) -> Value {
    json!(l.iter().map(|i| i.id.clone()).collect::<Vec<_>>())
}
fn item_json(i: &DownloadItem) -> Value {
    serde_json::to_value(i).unwrap()
}
fn opt_i64(v: &Value) -> Option<i64> {
    v.as_i64()
}
fn sep(locale: &str) -> &'static str {
    if locale == "de_DE" { "," } else { "." }
}

#[test]
fn server_factory() {
    use swiftly_jellyfin::ServerKind;
    use swiftly_playback::media_server::ServerCapability;
    use swiftly_vm::capabilities_for;
    fn name(c: ServerCapability) -> String {
        let d = format!("{c:?}");
        let mut chars = d.chars();
        chars
            .next()
            .map(|f| f.to_lowercase().collect::<String>() + chars.as_str())
            .unwrap_or_default()
    }
    assert_equal("server_factory", |c| {
        let kind = match c["kind"].as_str().unwrap() {
            "emby" => ServerKind::Emby,
            "plex" => ServerKind::Plex,
            _ => ServerKind::Jellyfin,
        };
        let mut caps: Vec<String> = capabilities_for(kind).into_iter().map(name).collect();
        caps.sort();
        let prefix = match kind {
            ServerKind::Jellyfin => String::new(),
            ServerKind::Emby => "emby:".to_owned(),
            ServerKind::Plex => "plex:".to_owned(),
        };
        json!({
            "made": true, "kind": c["kind"], "table": caps, "client": caps,
            "bundle_key": swiftly_accounts::bundle_storage_key(kind), "prefix": prefix,
        })
    });
}

#[test]
fn download_rules() {
    assert_equal("download_rules", |c| {
        match c["op"].as_str().unwrap() {
        "next_one" => json!(DownloadRules::next_one(&items(&c["items"]), c["wlan"] == true, c["only"] == true).map(|i| i.id.clone())),
        "network" => json!(match DownloadRules::network_verdict(c["wlan"].as_bool(), c["only"] == true) {
            NetworkVerdict::Load => "load",
            NetworkVerdict::PutBack => "put_back",
            NetworkVerdict::WaitFor => "wait_for",
        }),
        "slot" => {
            let s = DownloadRules::slot(c["bytes"].as_i64().unwrap(), c["free"].as_i64().unwrap(), &items(&c["items"]));
            json!({ "suffices": s.suffices, "free_after": s.free_after, "dispensable": ids(&s.dispensable),
                    "bytes": s.dispensable_bytes, "cleanup": s.suffices_to_clean_up() })
        }
        "foot" => match DownloadRules::foot_space(c["bytes"].as_i64().unwrap(), c["free"].as_i64().unwrap()) {
            FootSpace::Free(v) => json!({ "k": "free", "v": v }),
            FootSpace::Few(v) => json!({ "k": "few", "v": v }),
        },
        "dispensable" => ids(&DownloadRules::dispensable(&items(&c["items"]))),
        "grouped" => json!(
            DownloadRules::grouped(&items(&c["items"]))
                .iter()
                .map(|g| {
                    let (k, list) = match g {
                        DownloadGroup::Single(i) => ("single", vec![i.id.clone()]),
                        DownloadGroup::Series { episodes, .. } => ("series", episodes.iter().map(|e| e.id.clone()).collect()),
                    };
                    json!({ "id": g.id(), "title": g.title(), "bytes": g.bytes(), "created": g.created() - OFFSET, "k": k, "items": list })
                })
                .collect::<Vec<_>>()
        ),
        "progress_show" => json!(DownloadRules::progress_show(
            c["loaded"].as_i64().unwrap(),
            c["total"].as_i64().unwrap(),
            opt_i64(&c["before"]),
            c["elapsed"].as_f64()
        )),
        "progress" => {
            let (a, b) = DownloadRules::progress(c["loaded"].as_i64().unwrap(), c["total"].as_i64().unwrap(), sep(c["locale"].as_str().unwrap()));
            json!([a, b])
        }
        "next_episode" => json!(DownloadRules::next_episode(&items(&c["items"])).map(|i| i.id.clone())),
        "episode_post" => json!(DownloadRules::episode_post(c["id"].as_str().unwrap(), &items(&c["items"])).map(|i| i.id.clone())),
        "reached_end" => json!(DownloadRules::reached_end(c["ticks"].as_i64().unwrap(), opt_i64(&c["runtime"]))),
        "successor" => {
            let i = item(&c["item"]);
            json!({ "has": DownloadRules::has_successor(&i), "replaced": DownloadRules::replaced_one(&i, &items(&c["items"])) })
        }
        "follow" => {
            let ws: Option<UserItemData> = (!c["watch"].is_null()).then(|| serde_json::from_value(c["watch"].clone()).unwrap());
            item_json(&DownloadRules::follow(&item(&c["item"]), ws.as_ref()))
        }
        "following" => {
            let eps: Vec<Item> = serde_json::from_value(c["episodes"].clone()).unwrap();
            json!(DownloadRules::following_episode(&item(&c["item"]), &eps).map(|e| e.id.clone()))
        }
        "allocation" => {
            let (n, b) = DownloadRules::allocation(&items(&c["items"]));
            json!([n, b])
        }
        "item" => {
            let i = item(&c["item"]);
            let mut in_q = serde_json::Map::new();
            for q in DownloadQuality::ALL {
                in_q.insert(q.raw_value().to_owned(), item_json(&i.in_quality(q)));
            }
            let a = i.as_item();
            json!({
                "share": i.share(), "converted": i.converted(), "streamed": i.streamed(), "guete": i.guete().raw_value(),
                "resume": i.resume_from(), "file": i.file_name(), "in_quality": in_q,
                "post": item_json(&i.post_playback(c["ticks"].as_i64().unwrap(), c["moment"].as_f64().unwrap() + OFFSET)),
                "as_item": [a.id, a.name, a.type_, a.run_time_ticks, a.series_name, a.index_number, a.parent_index_number, a.series_id],
            })
        }
        "path" => {
            let t = c["text"].as_str().unwrap();
            json!({
                "safe": PathPart::safe(t), "is_id": PathPart::is_id(t), "suffix": PathPart::suffix(Some(t)),
                "suffix_none": PathPart::suffix(None),
                "image": DownloadItem::image_name(c["other"].as_str().unwrap(), t),
            })
        }
        other => panic!("bad op {other}"),
    }
    });
}
