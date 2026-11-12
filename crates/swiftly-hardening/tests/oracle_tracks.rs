//! Differential oracle, group "track selection and mapping": Rust must equal the recorded output of
//! the real Swift code (Tools/Oracle, Domain_Tracks.swift).
#![allow(clippy::expect_used, clippy::unwrap_used)]

use serde_json::{Value, json};
use swiftly_hardening::oracle::assert_equal;
use swiftly_model::MediaStream;
use swiftly_playback::original_audio;
use swiftly_playback::track_mapping::{PlayerTrack, SubtitleFile, TrackImprint, TrackMapping};
use swiftly_playback::track_rule::{self, Choice, StartInput, Subtitle, SubtitleInput};
use swiftly_rules::language;

fn streams(v: &Value) -> Vec<MediaStream> {
    serde_json::from_value(v.clone()).expect("streams")
}
fn imprint(v: &Value) -> Option<TrackImprint> {
    (!v.is_null()).then(|| serde_json::from_value(v.clone()).expect("imprint"))
}
fn choice(v: &Value) -> Option<Choice> {
    match v["kind"].as_str()? {
        "off" => Some(Choice::Off),
        "track" => imprint(&v["imprint"]).map(Choice::Track),
        _ => Some(Choice::Name(v["name"].as_str().unwrap_or("").to_owned())),
    }
}
fn s(v: &Value) -> &str {
    v.as_str().unwrap_or("")
}
fn tracks(v: &Value) -> Vec<PlayerTrack> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|t| {
            PlayerTrack::new(
                s(&t["identifier"]),
                s(&t["name"]),
                t["language"].as_str(),
                t["codec"].as_str(),
                t["channels"].as_i64(),
            )
        })
        .collect()
}
fn subtitle_json(v: Subtitle) -> Value {
    match v {
        Subtitle::Off => json!("off"),
        Subtitle::Feed(i) => json!(i),
    }
}

#[test]
fn language_rules() {
    assert_equal("language_rules", |c| {
        let text = s(&c["text"]);
        json!({
            "detected": language::detected(text),
            "fits": language::fits(text, s(&c["toward"])),
            "forced": language::sounds_forced(text),
        })
    });
}

#[test]
fn track_language() {
    // The built-in names (no host installed): the Swift answer of every code in de, en and ru.
    assert_equal("track_language", |c| {
        let words = swiftly_vm::LabelWords::new(swiftly_l10n::Locale::parse(s(&c["locale"])));
        json!(swiftly_playback::track_label::language(
            c["raw"].as_str(),
            &words
        ))
    });
}

#[test]
fn original_audio() {
    assert_equal("original_audio", |c| {
        let stream: Option<MediaStream> =
            (!c["stream"].is_null()).then(|| serde_json::from_value(c["stream"].clone()).unwrap());
        json!(original_audio::is_original(
            c["language"].as_str(),
            stream.as_ref(),
            c["original"].as_str()
        ))
    });
}

#[test]
fn color_selection() {
    assert_equal("color_selection", |c| {
        let (a, b, d) = (
            c["a"].as_f64().unwrap(),
            c["b"].as_f64().unwrap(),
            c["c"].as_f64().unwrap(),
        );
        match s(&c["op"]) {
            "oklab" => {
                let (l, a2, b2) = swiftly_images::color::oklab(a, b, d);
                json!([l, a2, b2])
            }
            "lab_to_srgb" => match swiftly_images::color::srgb_from_lab(a, b, d) {
                Some((r, g, bl)) => json!([r, g, bl]),
                None => Value::Null,
            },
            _ => {
                let (r, g, bl) = swiftly_images::color::srgb_lch(a, b, d);
                json!([r, g, bl])
            }
        }
    });
}

#[test]
fn track_rule() {
    assert_equal("track_rule", |c| {
        let st = streams(&c["streams"]);
        let remembered_audio = imprint(&c["remembered_audio"]);
        let remembered_sub = choice(&c["remembered_sub"]);
        let (pref_audio, pref_sub) = (s(&c["pref_audio"]), s(&c["pref_sub"]));
        let audio = track_rule::audio(
            &st,
            remembered_audio.as_ref(),
            pref_audio,
            c["server_audio"].as_i64(),
            c["ordered_audio"].as_i64(),
        );
        let sub = track_rule::subtitle(
            &st,
            &SubtitleInput {
                remembered: remembered_sub.clone(),
                server_default: c["server_sub"].as_i64(),
                automatic: c["automatic"].as_bool().unwrap(),
                audio_index: c["audio_index"].as_i64(),
                audio_wish: s(&c["tonwunsch"]),
                preferred_language: pref_sub,
                ordered: c["ordered_sub"].as_i64(),
            },
        );
        let start = track_rule::start_indices(
            &st,
            &StartInput {
                remembered_audio,
                remembered_subtitle: remembered_sub,
                server_audio: c["server_audio"].as_i64(),
                server_subtitle: c["server_sub"].as_i64(),
                automatic: c["automatic"].as_bool().unwrap(),
                audio_language: pref_audio,
                subtitle_language: pref_sub,
            },
        );
        let imprint_json =
            match c["imprint_of"].as_u64() {
                Some(k) if (k as usize) < st.len() => serde_json::to_value(
                    TrackImprint::from_feed(&st[k as usize], &st, c["imprint_name"].as_str()),
                )
                .unwrap(),
                _ => Value::Null,
            };
        json!({
            "audio": audio,
            "subtitle": subtitle_json(sub),
            "start": [start.audio, start.subtitle],
            "imprint": imprint_json,
        })
    });
}

#[test]
fn track_mapping() {
    assert_equal("track_mapping", |c| {
        let st = streams(&c["streams"]);
        let audio = tracks(&c["audio"]);
        let subtitle = tracks(&c["subtitle"]);
        let files: Vec<SubtitleFile> = c["files"]
            .as_array()
            .unwrap()
            .iter()
            .map(|f| {
                let index = f["index"].as_i64().unwrap();
                SubtitleFile {
                    index,
                    address: format!("https://host/s/{index}"),
                    attribute: f["attribute"].as_str().map(str::to_owned),
                }
            })
            .collect();
        let mapping = TrackMapping::compose(&audio, &subtitle, &st, &files);
        let mut replaced: Vec<usize> = TrackMapping::replaced_positions(&subtitle, &st, &files)
            .into_iter()
            .collect();
        replaced.sort_unstable();
        let start_sub = c["start_sub"]
            .as_i64()
            .map_or(Subtitle::Off, Subtitle::Feed);
        let start =
            TrackMapping::start_positions(&st, c["start_audio"].as_i64(), start_sub, &files);
        let first_audio = c["start_audio"]
            .as_i64()
            .and_then(|i| mapping.audio_position(i));
        let first_sub = c["start_sub"]
            .as_i64()
            .and_then(|i| mapping.subtitle_position(i));
        let addition_ids: Vec<Option<&str>> = audio
            .iter()
            .chain(subtitle.iter())
            .map(PlayerTrack::addition_id)
            .collect();
        let imprint_json = subtitle.first().map_or(Value::Null, |t| {
            serde_json::to_value(TrackImprint::from_track(t)).unwrap()
        });
        json!({
            "audio": mapping.audio,
            "subtitle": mapping.subtitle,
            "replaced": replaced,
            "start": [start.0, start.1],
            "positions": [first_audio, first_sub],
            "addition_ids": addition_ids,
            "imprint": imprint_json,
        })
    });
}
