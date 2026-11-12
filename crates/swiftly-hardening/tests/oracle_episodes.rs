//! Differential oracle, episode / next-up domains: the Rust output must equal the real Swift output
//! (Tools/Oracle, Domain_Episodes.swift).
#![allow(clippy::expect_used, clippy::unwrap_used)]

use serde_json::{Value, json};
use swiftly_hardening::oracle::assert_equal;
use swiftly_jellyfin::Watcher;
use swiftly_library::SeasonSelectionRule;
use swiftly_model::{Item, MediaSource, MediaVersions, VersionStart};
use swiftly_rules::episodes_card as card;
use swiftly_rules::episodes_switch::StopLock;

fn n(v: &Value) -> f64 {
    v.as_f64().unwrap_or(0.0)
}

fn metrics(m: &card::Metrics) -> Vec<f64> {
    vec![m.width, m.corner, m.ring, m.spacing, m.small, m.title]
}

#[test]
fn episode_card() {
    assert_equal("episode_card", |c| match c["op"].as_str().unwrap() {
        "constants" => {
            let mut v = vec![
                card::REMAINING_WINDOW,
                card::APPEAR_OMEGA,
                card::APPEAR_LAG,
                card::DISTANCE_OMEGA,
                card::ZOOM_OMEGA,
                card::DETAILS_OUT,
                card::SWAP,
                card::IMAGE_FADE,
                card::AT_MOST_COVERS,
                card::OFFSET,
                card::START_METRIC,
                card::FOCUS_METRIC,
                card::CLICK_PRESS,
                card::CLICK_DURATION,
                card::AT_MOST_SHARE,
                card::BOTTOM_SPACING,
                card::SWIPE_AWAY,
                card::RESISTANCE,
            ];
            v.extend(metrics(&card::IPHONE));
            v.extend(metrics(&card::TV));
            json!(v)
        }
        "spring" => {
            let (a, b) = card::spring(n(&c["omega"]));
            json!([a, b])
        }
        "travel" => json!(card::spring_travel(n(&c["t"]), n(&c["omega"]))),
        "fade_off" => json!(card::fade_off(n(&c["since"]))),
        "yields" => json!(card::yields(n(&c["since"]), c["image"].as_f64())),
        "width" => {
            let m = if c["tv"].as_bool().unwrap_or(false) {
                &card::TV
            } else {
                &card::IPHONE
            };
            json!(card::width(
                m,
                n(&c["safe"]),
                c["large"].as_bool().unwrap_or(false)
            ))
        }
        "dragged" => {
            let (x, y) = card::dragged(n(&c["x"]), n(&c["y"]));
            json!([x, y])
        }
        "swiped" => json!(card::swiped_away(
            n(&c["x"]),
            n(&c["y"]),
            n(&c["mx"]),
            n(&c["my"])
        )),
        _ => {
            let f = |k: &str| -> Vec<f64> { c[k].as_array().unwrap().iter().map(n).collect() };
            let (card_f, whole) = (f("card"), f("whole"));
            let r = card::frame_rect(
                (card_f[0], card_f[1], card_f[2], card_f[3]),
                (whole[0], whole[1]),
                n(&c["zoom"]),
            );
            json!([r.0, r.1, r.2, r.3])
        }
    });
}

fn items(v: &Value) -> Vec<Item> {
    v.as_array()
        .map(|a| {
            a.iter()
                .filter_map(|x| serde_json::from_value(x.clone()).ok())
                .collect()
        })
        .unwrap_or_default()
}

#[test]
fn season_choice() {
    assert_equal("season_choice", |c| {
        let list = items(&c["list"]);
        let state: Option<Item> = serde_json::from_value(c["state"].clone()).ok();
        let hint_id = c["hintId"].as_str();
        let hint_number = c["hintNumber"].as_i64();
        let chosen = SeasonSelectionRule::choose(&list, hint_id, hint_number, state.as_ref());
        let position = chosen.and_then(|s| {
            list.iter()
                .position(|x| x.id == s.id && x.index_number == s.index_number && x.name == s.name)
        });
        json!({ "id": chosen.map(|s| s.id.clone()), "pos": position, "needs": SeasonSelectionRule::needs_state(hint_id, hint_number) })
    });
}

#[test]
fn watcher_ring() {
    assert_equal("watcher_ring", |c| {
        let Ok(doc) = serde_json::from_str::<Value>(c.as_str().unwrap()) else {
            return json!({ "ok": false });
        };
        let Some(w) = Watcher::read(&doc) else {
            return json!({ "ok": false });
        };
        let pct = w.progress_percent.map_or(Value::Null, |p| {
            if p.is_finite() {
                json!(p)
            } else {
                json!("nonfinite")
            }
        });
        json!({ "ok": true, "user": w.user_id, "name": w.name, "tag": w.image_tag, "play": w.play_count, "pct": pct,
                "w": w.watched_count, "t": w.total_count, "ring": w.ring() })
    });
}

fn sources(v: &Value) -> Option<Vec<MediaSource>> {
    v.as_array().map(|a| {
        a.iter()
            .filter_map(|x| serde_json::from_value(x.clone()).ok())
            .collect()
    })
}

fn out(s: &MediaSource) -> Value {
    json!([s.id, s.name, s.height()])
}

#[test]
fn media_versions() {
    assert_equal("media_versions", |c| match c["op"].as_str().unwrap() {
        "choices" => json!(
            MediaVersions::choices(sources(&c["sources"]).as_deref())
                .iter()
                .map(out)
                .collect::<Vec<_>>()
        ),
        "start" => match MediaVersions::start(
            sources(&c["sources"]).as_deref(),
            c["downloaded"].as_bool().unwrap_or(false),
        ) {
            VersionStart::Wait => json!({ "k": "wait" }),
            VersionStart::Play => json!({ "k": "play" }),
            VersionStart::Choose(l) => {
                json!({ "k": "choose", "l": l.iter().map(out).collect::<Vec<_>>() })
            }
        },
        _ => {
            let Ok(previous) = serde_json::from_value::<MediaSource>(c["previous"].clone()) else {
                return json!("undecodable");
            };
            MediaVersions::matching(&previous, sources(&c["next"]).as_deref())
                .map_or(Value::Null, |s| out(&s))
        }
    });
}

#[test]
fn stop_lock() {
    assert_equal("stop_lock", |c| {
        let lock = StopLock::new();
        let mut result = vec![];
        for e in c.as_array().unwrap() {
            let key = StopLock::key(e["item"].as_str().unwrap_or(""), e["session"].as_str());
            result.push(match e["op"].as_str().unwrap() {
                "started" => {
                    lock.started(&key);
                    json!(key)
                }
                "accept" => json!(lock.stop_accept(&key)),
                "failed" => {
                    lock.stop_failed(&key);
                    json!(key)
                }
                _ => json!(lock.progress_allowed(&key)),
            });
        }
        json!(result)
    });
}
