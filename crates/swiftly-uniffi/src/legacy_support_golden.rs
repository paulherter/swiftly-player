//! The core's support, what's-new and handover answers against the Swift golden files (`su-*`, `wn-*`, `ho-*`,
//! written by `Android/golden` with TZ=UTC). Skipped without `SWIFTLY_GOLDEN_DIR`.

use crate::legacy_handoff::*;
use crate::legacy_support::*;
use crate::support::version_is_newer;
use serde_json::Value;

fn near(a: &Value, b: &Value, path: &str, bad: &mut Vec<String>) {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => {
            let (x, y) = (x.as_f64().unwrap_or(0.0), y.as_f64().unwrap_or(0.0));
            if (x - y).abs() > 1e-6 * (1.0 + x.abs()) {
                bad.push(format!("{path}: {x} vs {y}"));
            }
        }
        (Value::Array(x), Value::Array(y)) => {
            if x.len() != y.len() {
                bad.push(format!("{path}: length {} vs {}", x.len(), y.len()));
            }
            for (i, (p, q)) in x.iter().zip(y).enumerate() {
                near(p, q, &format!("{path}[{i}]"), bad);
            }
        }
        (Value::Object(x), Value::Object(y)) => {
            for k in x.keys().chain(y.keys()) {
                match (x.get(k), y.get(k)) {
                    (Some(p), Some(q)) => near(p, q, &format!("{path}.{k}"), bad),
                    _ => bad.push(format!("{path}.{k}: key on one side only")),
                }
            }
        }
        _ if a == b => {}
        _ => bad.push(format!("{path}: {a} vs {b}")),
    }
}

struct Check {
    dir: String,
    bad: Vec<String>,
    n: usize,
}

impl Check {
    fn same(&mut self, name: &str, new: String) {
        let old = std::fs::read_to_string(format!("{}/{name}.json", self.dir))
            .unwrap_or_else(|_| panic!("missing {name}"));
        self.n += 1;
        match (
            serde_json::from_str::<Value>(&old),
            serde_json::from_str::<Value>(&new),
        ) {
            (Ok(a @ (Value::Object(_) | Value::Array(_))), Ok(b)) => {
                near(&a, &b, name, &mut self.bad)
            }
            _ if old == new => {}
            _ => self.bad.push(format!("{name}: {old:?} vs {new:?}")),
        }
    }
}

#[test]
fn support_whats_new_and_handoff_match_swift() {
    let Ok(dir) = std::env::var("SWIFTLY_GOLDEN_DIR") else {
        return;
    };
    let mut c = Check {
        dir,
        bad: vec![],
        n: 0,
    };
    let (launch, day) = (1_700_000_000_000_i64, 86_400_000_i64);
    let watched = |u: &str| {
        let mut v: Value = serde_json::from_str(u).unwrap();
        v["watchedSeconds"] = 9000.0.into();
        v.to_string()
    };
    let u0 = legacy_support_record_launch(String::new(), launch);
    c.same("su-launch", u0.clone());
    c.same(
        "su-launch-again",
        legacy_support_record_launch(u0.clone(), launch + 9 * day),
    );
    let uw = watched(&u0);
    let store = legacy_support_store_status(launch + day);
    c.same("su-store", store.clone());
    c.same("su-store-unknown", legacy_support_store_status(0));
    c.same("su-source-store", legacy_support_source(store.clone()));
    c.same("su-source-none", legacy_support_source(String::new()));
    c.same("su-source-garbage", legacy_support_source("garbage".into()));
    c.same("su-tips", legacy_support_tips());
    let mut history = String::new();
    for (i, d) in [1, 4, 8, 400].into_iter().enumerate() {
        let now = launch + d * day;
        for (j, u) in [&u0, &uw].into_iter().enumerate() {
            for tv in [false, true] {
                c.same(
                    &format!("su-decide-{i}-{j}-{tv}"),
                    legacy_support_decide(
                        String::new(),
                        u.clone(),
                        history.clone(),
                        false,
                        120.0,
                        tv,
                        now,
                        0,
                    ),
                );
            }
        }
        c.same(
            &format!("su-decide-playing-{i}"),
            legacy_support_decide(
                String::new(),
                uw.clone(),
                history.clone(),
                true,
                120.0,
                false,
                now,
                0,
            ),
        );
        c.same(
            &format!("su-decide-quiet-{i}"),
            legacy_support_decide(
                String::new(),
                uw.clone(),
                history.clone(),
                false,
                10.0,
                false,
                now,
                0,
            ),
        );
        c.same(
            &format!("su-decide-supporter-{i}"),
            legacy_support_decide(
                store.clone(),
                uw.clone(),
                history.clone(),
                false,
                120.0,
                false,
                now,
                0,
            ),
        );
    }
    for (i, a) in ["snooze", "dismiss", "sheetShown", "bogus", "sheetShown"]
        .into_iter()
        .enumerate()
    {
        let i = i as i64;
        history = legacy_support_history_after(history, a.into(), launch + (8 + i) * day);
        c.same(&format!("su-history-{i}"), history.clone());
        c.same(
            &format!("su-decide-after-{i}"),
            legacy_support_decide(
                String::new(),
                uw.clone(),
                history.clone(),
                false,
                120.0,
                false,
                launch + (9 + i) * day,
                0,
            ),
        );
    }
    let entry = r#"{"version":"1.2","variant":"gift","title":{"de":"Neu","en":"New"},"items":[{"icon":"a","title":{"de":"A","en":"A"}},{"icon":"b","title":{"de":"B","en":"B"}},{"icon":"c","title":{"de":"C","en":"C"}}],"module":{"type":"gift","lookID":"halloween"},"primary":{"label":"continue","action":"dismiss"}}"#;
    let draft = entry.replace(r#""version":"1.2""#, r#""version":"1.2","draft":true"#);
    let short = r#"{"version":"1.2","variant":"standard","title":{"de":"Neu","en":"New"},"items":[],"primary":{"label":"continue","action":"dismiss"}}"#;
    for (i, j) in [entry, &draft, short, "garbage", ""]
        .into_iter()
        .enumerate()
    {
        c.same(&format!("wn-check-{i}"), legacy_whats_new_check(j.into()));
    }
    let decides = [
        ("", false, "1.0", false),
        ("", false, "1.0", true),
        ("", true, "1.0", true),
        ("", true, "1.0", false),
        ("1.0", true, "1.0", true),
        ("1.0", true, "1.1", true),
        ("1.0", false, "1.1", false),
        ("1.9", true, "1.10", true),
    ];
    for (i, (a, b, d, e)) in decides.into_iter().enumerate() {
        c.same(
            &format!("wn-decide-{i}"),
            legacy_whats_new_decide(a.into(), b, d.into(), e),
        );
    }
    for (i, (a, b)) in [
        ("1.0.10", "1.0.9"),
        ("1.0.9", "1.0.10"),
        ("1.0", "1.0"),
        ("2.0", "1.9.9"),
        ("1.0", "1.0.1"),
        ("", "1.0"),
    ]
    .into_iter()
    .enumerate()
    {
        c.same(
            &format!("wn-newer-{i}"),
            version_is_newer(a.into(), b.into()).to_string(),
        );
    }
    for (i, (w, h, tv)) in [
        (1080.0, 2400.0, false),
        (2400.0, 1080.0, false),
        (960.0, 540.0, true),
        (1920.0, 1080.0, false),
    ]
    .into_iter()
    .enumerate()
    {
        c.same(&format!("ho-states-{i}"), legacy_handoff_states(w, h, tv));
    }
    for (i, (a, b)) in [
        ("iPhone", "Apple TV"),
        ("Apple TV", "iPhone"),
        ("Mac", "iPad"),
        ("Pixel 8", "Wohnzimmer"),
        ("", ""),
    ]
    .into_iter()
    .enumerate()
    {
        c.same(
            &format!("ho-top-{i}"),
            legacy_handoff_to_top(a.into(), b.into()).to_string(),
        );
    }
    let o: Value = serde_json::from_str(&legacy_handoff_states(1080.0, 2400.0, false)).unwrap();
    let arr = |k: &str| {
        o[k].as_array()
            .unwrap()
            .iter()
            .map(|v| format!("{:?}", v.as_f64().unwrap()))
            .collect::<Vec<_>>()
            .join(",")
    };
    let (from, idle, full) = (
        "[540,2400,40]".to_string(),
        format!("[{}]", arr("ruhe")),
        format!("[{}]", arr("voll")),
    );
    let lanes = [
        format!(r#"{{"art":"warten","fernseher":false,"von":{from},"ruhe":{idle},"voll":{full},"ab":0,"bis":2}}"#),
        format!(r#"{{"art":"warten","fernseher":false,"von":{from},"ruhe":{idle},"voll":{full}}}"#),
        r#"{"art":"deckung","fernseher":true}"#.into(),
        format!(r#"{{"art":"neu","fernseher":false,"von":{from},"ruhe":{idle},"voll":{full},"ab":0.3,"flugAb":0.2}}"#),
        format!(r#"{{"art":"zoom","fernseher":false,"von":{from},"ruhe":{idle},"voll":{full},"ab":1.1}}"#),
        r#"{"art":"zoom","fernseher":true,"von":[480,1080,20],"ruhe":[480,300,300],"voll":[480,270,960]}"#.into(),
        format!(r#"{{"art":"abgang","fernseher":false,"voll":{full},"nachOben":true}}"#),
        format!(r#"{{"art":"abgang","fernseher":false,"voll":{full},"nachOben":false,"schirm":[1080,2400]}}"#),
        format!(r#"{{"art":"abgang","fernseher":false,"voll":{full},"nachOben":true,"schwerkraft":[0.1,-0.9],"oberflaeche":"hoch"}}"#),
        format!(r#"{{"art":"abgang","fernseher":false,"voll":{full},"nachOben":true,"schwerkraft":[0.9,0.1],"oberflaeche":"querHomeRechts"}}"#),
        format!(r#"{{"art":"abgang","fernseher":false,"voll":{full},"nachOben":false,"schwerkraft":[-0.2,0.8],"oberflaeche":"kopfueber"}}"#),
        r#"{"art":"abgang","fernseher":true,"voll":[480,270,960]}"#.into(),
        r#"{"art":"bogus","fernseher":false}"#.into(),
        "garbage".into(),
    ];
    for (i, l) in lanes.into_iter().enumerate() {
        c.same(&format!("ho-lane-{i}"), legacy_handoff_lane(l));
    }
    assert!(
        c.bad.is_empty(),
        "{} of {} differ:\n{}",
        c.bad.len(),
        c.n,
        c.bad
            .iter()
            .take(25)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
}
