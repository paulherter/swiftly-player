//! The card calls of the old Android facade (`Kern.handoffStates`, `handoffLane`, `handoffToTop`,
//! `Android/core/.../Handoff.swift`) from the core, with the same JSON answers (German keys). Timings, springs and
//! dimensions come from `swiftly_playback::handoff_card`; this only emits them as sample points, 120 per second.
//! Units are dp; on TV the card is computed in tvOS points (twice the dp) and halved again.

use serde_json::{Map, Value, json};
use swiftly_playback::handoff_card as k;
use swiftly_playback::handoff_card::{Direction, Metrics, Status, UserInterface};

fn scale(tv: bool) -> f64 {
    if tv { 0.5 } else { 1.0 }
}

fn metrics(tv: bool) -> Metrics {
    if tv { k::TV } else { k::IPHONE }
}

fn times() -> Value {
    json!({
        "seiteBis": k::PAGE_UNTIL, "kartenStart": k::CARDS_START, "schweben": k::FLOAT,
        "ladelinieAb": k::LOADING_BAR_OUT, "ladelinieEinblenden": k::LOADING_BAR_SHOW,
        "ladelinieTakt": k::LOADING_BAR_TICK, "zeilenAus": k::ROWS_OUT, "schwarzDauer": k::BLACK_DURATION,
        "kartenAusVon": k::CARDS_OUT_FROM, "ende": k::END, "hoechstensWarten": k::AT_MOST_WAIT, "blende": k::FADE,
        "blendeAus": k::FADE_OUT, "abgangStart": k::EXIT_START, "abgangReduziertEnde": k::EXIT_REDUCED_END,
        "wartenBis": k::FLOAT + k::AT_MOST_WAIT + 8.0,
    })
}

/// `Kern.handoffStates`: dimensions, positions and times for a screen of `width` x `height` dp.
#[uniffi::export]
pub fn legacy_handoff_states(width: f64, height: f64, tv: bool) -> String {
    let (s, m) = (scale(tv), metrics(tv));
    let (b, h) = (width / s, height / s);
    let (v, r) = (k::fullscreen(b, h), k::idle_status(b, h, m));
    json!({
        "voll": [v.x * s, v.y * s, v.width * s], "ruhe": [r.x * s, r.y * s, r.width * s],
        "masse": {"breite": m.width * s, "ecke": m.corner * s, "titel": m.title * s, "klein": m.small * s, "abstand": m.spacing * s},
        "zeiten": times(),
    })
    .to_string()
}

/// `Kern.handoffToTop`: where the giver's card flies (`HandoffCard.departurePostTop`).
#[uniffi::export]
pub fn legacy_handoff_to_top(from: String, to: String) -> bool {
    k::departure_post_top(&from, &to)
}

struct Input {
    art: String,
    tv: bool,
    from: Option<Vec<f64>>,
    idle: Option<Vec<f64>>,
    full: Option<Vec<f64>>,
    transition_out: Option<f64>,
    since: Option<f64>,
    until: Option<f64>,
    screen: Option<Vec<f64>>,
    to_top: Option<bool>,
    gravity: Option<Vec<f64>>,
    surface: Option<String>,
}

impl Input {
    /// Like the Swift `Decodable`: `art` and `fernseher` are required, a wrong type anywhere fails the whole input.
    fn parse(text: &str) -> Option<Self> {
        let v: Value = serde_json::from_str(text).ok()?;
        let o = v.as_object()?;
        fn opt<T>(
            o: &Map<String, Value>,
            k: &str,
            f: impl Fn(&Value) -> Option<T>,
        ) -> Option<Option<T>> {
            match o.get(k) {
                None | Some(Value::Null) => Some(None),
                Some(x) => f(x).map(Some),
            }
        }
        let nums = |x: &Value| {
            x.as_array()?
                .iter()
                .map(Value::as_f64)
                .collect::<Option<Vec<f64>>>()
        };
        Some(Self {
            art: o.get("art")?.as_str()?.to_owned(),
            tv: o.get("fernseher")?.as_bool()?,
            from: opt(o, "von", nums)?,
            idle: opt(o, "ruhe", nums)?,
            full: opt(o, "voll", nums)?,
            transition_out: opt(o, "flugAb", Value::as_f64)?,
            since: opt(o, "ab", Value::as_f64)?,
            until: opt(o, "bis", Value::as_f64)?,
            screen: opt(o, "schirm", nums)?,
            to_top: opt(o, "nachOben", Value::as_bool)?,
            gravity: opt(o, "schwerkraft", nums)?,
            surface: opt(o, "oberflaeche", |x| x.as_str().map(str::to_owned))?,
        })
    }
}

#[derive(Default)]
struct Reply {
    t0: f64,
    dt: f64,
    l: Vec<f64>,
    d: Vec<f64>,
    dn: usize,
    out: Option<f64>,
    status: Option<Vec<f64>>,
}

/// `Kern.handoffLane`: the path as sample points, 120 per second (`HandoffPath.compute`). `{}` for broken input.
#[uniffi::export]
pub fn legacy_handoff_lane(typed_input: String) -> String {
    let Some(e) = Input::parse(&typed_input) else {
        return "{}".to_owned();
    };
    let (s, m) = (scale(e.tv), metrics(e.tv));
    let status = |a: &Option<Vec<f64>>| match a {
        Some(a) if a.len() >= 3 => Status::new(a[0] / s, a[1] / s, a[2] / s),
        _ => Status::new(0.0, 0.0, 1.0),
    };
    let (from, idle, full) = (status(&e.from), status(&e.idle), status(&e.full));
    let transition_out = e.transition_out.unwrap_or(k::CARDS_START);
    let mut answer = Reply::default();
    let mut points = |t0: f64,
                      t1: f64,
                      f: Option<&dyn Fn(f64) -> Status>,
                      g: Option<&dyn Fn(f64) -> Vec<f64>>| {
        let steps = (((t1 - t0) * 120.0).ceil() as i64).max(2);
        answer.t0 = t0;
        answer.dt = (t1 - t0) / steps as f64;
        for i in 0..=steps {
            let t = t0 + (t1 - t0) * i as f64 / steps as f64;
            if let Some(f) = f {
                let l = f(t);
                answer.l.extend([
                    l.x * s,
                    l.y * s,
                    l.width * s,
                    k::corner(l, m, full) * s,
                    k::rows_top(l, m) * s,
                ]);
            }
            if let Some(g) = g {
                let d = g(t);
                answer.dn = d.len();
                answer.d.extend(d);
            }
        }
    };
    match e.art.as_str() {
        "warten" => points(
            e.since.unwrap_or(0.0),
            e.until.unwrap_or(k::FLOAT + k::AT_MOST_WAIT + 8.0),
            Some(&|t| k::wait(t, from, idle, transition_out)),
            None,
        ),
        "deckung" => points(
            0.0,
            1.0,
            None,
            Some(&|t| {
                vec![
                    k::cards_coverage(t),
                    k::pages_coverage(t),
                    k::rows_coverage(t, None),
                ]
            }),
        ),
        "neu" => {
            let l = k::transition(e.since.unwrap_or(0.0), from, idle, transition_out);
            answer.status = Some(vec![l.x * s, l.y * s, l.width * s]);
        }
        "zoom" => {
            let z = e.since.unwrap_or(k::FLOAT);
            let start = k::wait(z, from, idle, transition_out);
            let momentum = k::momentum(z, from, idle, transition_out);
            points(
                0.0,
                k::END,
                Some(&|t| k::zoom(t, start, momentum, full)),
                Some(&|t| vec![k::stage_coverage(t)]),
            );
        }
        "abgang" => {
            let screen = e
                .screen
                .clone()
                .filter(|v| v.len() >= 2)
                .unwrap_or_else(|| vec![full.x * 2.0 * s, full.y * 2.0 * s]);
            let card = k::idle_status(screen[0] / s, screen[1] / s, m);
            let top = e.to_top.unwrap_or(true);
            let mut bearing = if top {
                Direction::TOP
            } else {
                Direction::BOTTOM
            };
            if let Some(g) = e.gravity.as_ref().filter(|g| g.len() >= 2) {
                let o = match e.surface.as_deref() {
                    Some("kopfueber") => UserInterface::UpsideDown,
                    Some("querHomeRechts") => UserInterface::LandscapeHomeRight,
                    Some("querHomeLinks") => UserInterface::LandscapeHomeLeft,
                    _ => UserInterface::Up,
                };
                bearing = k::departure_direction(g[0], g[1], o, top);
            }
            let out = k::exit_out(full, card, bearing);
            points(
                0.0,
                out + 0.1,
                Some(&|t| k::exit(t, full, card, bearing)),
                Some(&|t| vec![k::exit_rows_coverage(t)]),
            );
            answer.out = Some(out);
            answer.status = Some(vec![card.x * s, card.y * s, card.width * s]);
        }
        _ => {}
    }
    let mut o = Map::new();
    o.insert("t0".into(), json!(answer.t0));
    o.insert("dt".into(), json!(answer.dt));
    o.insert("l".into(), json!(answer.l));
    o.insert("d".into(), json!(answer.d));
    o.insert("dn".into(), json!(answer.dn));
    if let Some(v) = answer.out {
        o.insert("raus".into(), json!(v));
    }
    if let Some(v) = answer.status {
        o.insert("lage".into(), json!(v));
    }
    Value::Object(o).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn states_scale_with_the_screen_and_tv() {
        let phone: serde_json::Value =
            serde_json::from_str(&legacy_handoff_states(400.0, 800.0, false)).unwrap();
        let tv: serde_json::Value =
            serde_json::from_str(&legacy_handoff_states(1920.0, 1080.0, true)).unwrap();
        for v in [&phone, &tv] {
            assert_eq!(v["voll"].as_array().unwrap().len(), 3);
            assert_eq!(v["ruhe"].as_array().unwrap().len(), 3);
            assert!(v["masse"]["breite"].as_f64().unwrap() > 0.0);
            assert!(
                v["zeiten"]["wartenBis"].as_f64().unwrap()
                    > v["zeiten"]["hoechstensWarten"].as_f64().unwrap()
            );
        }
        assert_ne!(
            phone["masse"]["breite"], tv["masse"]["breite"],
            "the TV card is measured in its own scale"
        );
    }

    #[test]
    fn departure_direction_is_total() {
        for a in ["", "idle", "player", "x"] {
            for b in ["", "idle", "player", "x"] {
                let _ = legacy_handoff_to_top(a.into(), b.into());
            }
        }
    }

    #[test]
    fn lane_survives_broken_input() {
        for s in ["", "{", "[]", "null", "{\"art\":\"nope\"}"] {
            let _ = legacy_handoff_lane(s.to_owned());
        }
    }
}
