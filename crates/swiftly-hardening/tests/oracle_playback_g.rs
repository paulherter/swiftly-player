//! Differential oracle, group G "playback profile and plan": Rust must equal the recorded output of
//! the real Swift code (Tools/Oracle, Domain_PlaybackG.swift).
#![allow(clippy::expect_used, clippy::unwrap_used)]

use serde_json::{Value, json};
use swiftly_hardening::oracle::assert_equal;
use swiftly_model::{Item, MediaUrl, PlaybackInfoResponse};
use swiftly_playback::device_profile::DeviceProfile;
use swiftly_playback::playback_plan::{
    PlanError, PlaybackPlan, ReasonDetail, TranscodeReason, diagnose,
};
use swiftly_vm::{TrailerCandidate, trailer_candidates, web_address};

fn profile(c: &Value) -> DeviceProfile {
    let max = c["max"].as_i64().unwrap_or(1_000_000_000);
    if c["kind"] == "airplay" {
        DeviceProfile::airplay(max, c["av1"].as_bool().unwrap_or(false))
    } else {
        DeviceProfile::vlc(max)
    }
}

fn reasons(list: &[TranscodeReason]) -> Value {
    Value::Array(
        list.iter()
            .map(|r| {
                // The oracle process runs under the English catalog.
                let detail = r.detail.as_ref().map_or(Value::Null, |d| match d {
                    ReasonDetail::Channels(n) => json!(format!("{n} channels")),
                    ReasonDetail::NotDeclared => json!("not declared in the profile"),
                    ReasonDetail::WouldBurnIn => json!("would be burned in"),
                });
                json!([r.kind.raw_value(), r.codec, detail])
            })
            .collect(),
    )
}

#[test]
fn device_profile() {
    assert_equal("device_profile", |c| profile(c).to_json());
}

#[test]
fn download_right() {
    use swiftly_rules::download_right::DownloadPermission;
    assert_equal("download_right", |c| {
        let rights = DownloadPermission::from_server(c["server"].as_bool());
        json!({
            "rights": rights.raw_value(), "may_load": rights.may_load(),
            "offer": DownloadPermission::offer(rights, c["on"].as_bool().unwrap()),
        })
    });
}

#[test]
fn bitrates_limit() {
    assert_equal("bitrates_limit", |c| {
        json!(swiftly_rules::playback_levels::bitrate_limit_of(
            c["direct"].as_bool().unwrap(),
            c["megabit"].as_i64().unwrap()
        ))
    });
}

#[test]
fn play_time() {
    assert_equal("play_time", |c| {
        let v = match c["v"].as_str() {
            Some("nan") => f64::NAN,
            Some("inf") => f64::INFINITY,
            Some(_) => f64::NEG_INFINITY,
            None => c["v"].as_f64().unwrap(),
        };
        json!(swiftly_rules::playback_levels::play_time_text(v))
    });
}

#[test]
fn trailer_choice() {
    assert_equal("trailer_choice", |c| {
        if c["op"] == "web" {
            return web_address(c["text"].as_str()).map_or(Value::Null, |u| json!(u.as_str()));
        }
        let local: Vec<Item> = serde_json::from_value(c["local"].clone()).unwrap();
        let remote: Option<Vec<MediaUrl>> = serde_json::from_value(c["remote"].clone()).unwrap();
        let list = trailer_candidates(&local, remote.as_deref(), c["web"].as_bool().unwrap());
        Value::Array(
            list.iter()
                .map(|t| match t {
                    TrailerCandidate::File(i) => json!(format!("file:{}", i.id)),
                    TrailerCandidate::Web(u) => json!(format!("web:{}", u.as_str())),
                })
                .collect(),
        )
    });
}

#[test]
fn playback_plan() {
    assert_equal("playback_plan", |c| {
        let response: PlaybackInfoResponse = serde_json::from_value(c["response"].clone()).unwrap();
        let profile = profile(c);
        if c["op"] == "diagnose" {
            return response
                .media_sources
                .first()
                .map_or(Value::Null, |s| reasons(&diagnose(s, &profile)));
        }
        let made = PlaybackPlan::make(
            &response,
            c["item"].as_str().unwrap(),
            &profile,
            |item, source, session| {
                Ok(format!(
                    "https://s.example/{item}/{}/{}",
                    source.unwrap_or("-"),
                    session.unwrap_or("-")
                ))
            },
            c["base"].as_str().unwrap(),
            c["preferred"].as_str(),
        );
        match made {
            Ok(None) => json!({ "none": true }),
            Err(PlanError::PlaybackRejected(r)) => json!({ "rejected": r }),
            Err(PlanError::InvalidServerUrl) => json!({ "invalid_url": true }),
            Ok(Some(p)) => json!({
                "url": p.url, "method": p.method.raw_value(), "source_id": p.media_source_id, "session": p.play_session_id,
                "container": p.container, "item": p.item_id, "reasons": reasons(&p.reasons),
            }),
        }
    });
}
