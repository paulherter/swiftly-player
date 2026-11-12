//! Differential oracle, group C playback: Delay, BufferLevel, TimeAssumption, FadeTimes,
//! PauseJumpBack, Prebuffer. Swift side: Tools/Oracle/Sources/oracle/Domain_PlaybackC.swift.
#![allow(clippy::expect_used, clippy::unwrap_used)]

use serde_json::{Value, json};
use swiftly_hardening::oracle::assert_equal;
use swiftly_model::DeliveryMethod;
use swiftly_playback::{fade_times, pause_jump_back, prebuffer};
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_rules::delay::{Delay, HoldCounter};
use swiftly_rules::time_assumption;

fn i(v: &Value) -> i64 {
    v.as_i64().unwrap_or(0)
}
/// A JSON number, or the strings "nan" / "inf" / "-inf".
fn f(v: &Value) -> Option<f64> {
    match v.as_str() {
        Some("nan") => Some(f64::NAN),
        Some("inf") => Some(f64::INFINITY),
        Some("-inf") => Some(f64::NEG_INFINITY),
        _ => v.as_f64(),
    }
}
fn sep(locale: &str) -> &'static str {
    match locale {
        "en" | "de-CH" | "en-GB" => ".",
        _ => ",",
    }
}

#[test]
fn delay() {
    assert_equal("delay", |c| match c["op"].as_str().unwrap() {
        "ms" => json!(Delay::from_milliseconds(i(&c["v"])).milliseconds()),
        "us" => json!(Delay::from_microseconds(i(&c["v"])).milliseconds()),
        "shift" => json!(
            Delay::from_milliseconds(i(&c["ms"]))
                .shifted(i(&c["bearing"]), i(&c["steps"]))
                .milliseconds()
        ),
        "steps" => json!(Delay::steps_on_repetition(i(&c["n"]))),
        "text" => json!(
            Delay::from_milliseconds(i(&c["ms"])).text(sep(c["locale"].as_str().unwrap()), " s")
        ),
        "title" => json!(
            Delay::for_new_title(
                Delay::from_milliseconds(i(&c["ms"])),
                c["old_title"].as_str().unwrap(),
                c["old_series"].as_str(),
                c["new_title"].as_str().unwrap(),
                c["new_series"].as_str(),
            )
            .milliseconds()
        ),
        "soft" => json!(Delay::from_milliseconds(i(&c["ms"])).soft_off(i(&c["read"]))),
        "hold" => {
            let mut counter = HoldCounter::new();
            json!(
                c["times"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|t| counter.press(t.as_f64().unwrap()))
                    .collect::<Vec<_>>()
            )
        }
        other => panic!("bad op {other}"),
    });
}

#[test]
fn buffer_level() {
    assert_equal("buffer_level", |c| {
        match BufferLevel::from_raw_value(c["raw"].as_str().unwrap()) {
            None => Value::Null,
            Some(level) => json!({
                "prefetch": level.prefetch_kib(),
                "lead": level.network_lead_milliseconds(),
                "approx": level.approx_seconds(i(&c["bps"])),
            }),
        }
    });
}

#[test]
fn time_assumption() {
    assert_equal("time_assumption", |c| {
        let since = f(&c["since"]).unwrap_or(0.0);
        let b = |k: &str| c[k].as_bool().unwrap();
        match c["op"].as_str().unwrap() {
            "position" => json!(time_assumption::position(
                f(&c["reported"]).unwrap(),
                f(&c["until_from"]).unwrap(),
                0.0,
                b("after_change"),
                since
            )),
            "present" => json!(time_assumption::image_present(
                b("shows"),
                b("seeks"),
                0.0,
                since
            )),
            "belongs" => json!(time_assumption::image_belongs_medium(
                b("video"),
                c["shown"].as_u64().unwrap(),
                b("after_change")
            )),
            other => panic!("bad op {other}"),
        }
    });
}

#[test]
fn fade_times() {
    assert_equal("fade_times", |c| {
        let t = f(&c["t"]).unwrap();
        match c["op"].as_str().unwrap() {
            "in" => json!(fade_times::ease_in(t)),
            "out" => json!(fade_times::ease_out(t)),
            "inout" => json!(fade_times::ease_in_out(t)),
            "pages" => {
                let p = fade_times::pages_switch(t);
                json!([p.alt, p.new])
            }
            "bezier" => json!(fade_times::bezier(
                t,
                f(&c["x1"]).unwrap(),
                f(&c["y1"]).unwrap(),
                f(&c["x2"]).unwrap(),
                f(&c["y2"]).unwrap()
            )),
            other => panic!("bad op {other}"),
        }
    });
}

#[test]
fn pause_prebuffer() {
    assert_equal("pause_prebuffer", |c| match c["op"].as_str().unwrap() {
        "jump" => json!(pause_jump_back::target(
            f(&c["position"]).unwrap(),
            f(&c["paused"]),
            f(&c["now"]).unwrap(),
            c["group"].as_bool().unwrap()
        )),
        "now" => json!(prebuffer::now(
            f(&c["position"]).unwrap(),
            f(&c["duration"]).unwrap(),
            f(&c["credits"]),
            c["favorable"].as_bool().unwrap()
        )),
        "fresh" => json!(prebuffer::fresh_value(
            f(&c["prepared"]).unwrap(),
            f(&c["now"]).unwrap()
        )),
        "load" => {
            let method = match c["method"].as_str().unwrap() {
                "Direct Play" => DeliveryMethod::DirectPlay,
                "Direct Stream" => DeliveryMethod::DirectStream,
                _ => DeliveryMethod::Transcode,
            };
            json!(prebuffer::start_load(c["url"].as_str().unwrap(), method))
        }
        other => panic!("bad op {other}"),
    });
}
