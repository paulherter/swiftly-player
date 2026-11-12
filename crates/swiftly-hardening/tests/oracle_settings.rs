//! Differential oracle, domain `settings_sync`: both Rust copies of `SettingsSync` (`swiftly-settings` and
//! `swiftly-sync`) must equal the real Swift output (Tools/Oracle, Domain_Settings.swift).
#![allow(clippy::expect_used, clippy::unwrap_used)]

use serde_json::{Value, json};
use std::collections::BTreeMap;
use swiftly_hardening::oracle::assert_equal;

fn prefs(v: &Value) -> BTreeMap<String, String> {
    v.as_object()
        .unwrap()
        .iter()
        .filter_map(|(k, x)| x.as_str().map(|s| (k.clone(), s.to_owned())))
        .collect()
}

fn strings(v: &Value) -> Vec<String> {
    v.as_array()
        .unwrap()
        .iter()
        .filter_map(|x| x.as_str().map(str::to_owned))
        .collect()
}

mod settings_crate {
    use super::*;
    use swiftly_settings::sync::{self as s, Kind, SyncValue};

    fn kind(name: &str) -> Kind {
        match name {
            "bool" => Kind::Bool,
            "int" => Kind::Int,
            "list" => Kind::List,
            "json" => Kind::Json,
            _ => Kind::Text,
        }
    }
    fn kind_name(k: Kind) -> &'static str {
        match k {
            Kind::Bool => "bool",
            Kind::Int => "int",
            Kind::Text => "text",
            Kind::List => "list",
            Kind::Json => "json",
        }
    }
    fn value(v: &SyncValue) -> Value {
        let k = match v {
            SyncValue::Bool(_) => "bool",
            SyncValue::Int(_) => "int",
            SyncValue::Text(_) => "text",
            SyncValue::List(_) => "list",
            SyncValue::Json(_) => "json",
        };
        json!([k, v.encoded()])
    }
    fn values(m: &BTreeMap<String, SyncValue>) -> Value {
        Value::Object(m.iter().map(|(k, v)| (k.clone(), value(v))).collect())
    }

    pub fn run(c: &Value) -> Value {
        match c["op"].as_str().unwrap() {
            "decode" => SyncValue::decode(
                c["text"].as_str().unwrap(),
                kind(c["kind"].as_str().unwrap()),
            )
            .map_or(Value::Null, |v| value(&v)),
            "entry" => s::entry_for_device_key(c["key"].as_str().unwrap())
                .map_or(Value::Null, |e| {
                    json!([e.name, kind_name(e.kind), e.per_server])
                }),
            "remote" => {
                let r = s::remote_from(&prefs(&c["prefs"]));
                json!({ "present": r.present(), "changed": r.changed, "values": values(&r.values) })
            }
            "fields" => {
                let mut m = BTreeMap::new();
                for (name, d) in c["values"].as_object().unwrap() {
                    let v = &d["v"];
                    m.insert(
                        name.clone(),
                        match d["k"].as_str().unwrap() {
                            "bool" => SyncValue::Bool(v.as_bool().unwrap()),
                            "int" => SyncValue::Int(v.as_i64().unwrap()),
                            "list" => SyncValue::List(strings(v)),
                            "json" => SyncValue::Json(v.as_str().unwrap().as_bytes().to_vec()),
                            _ => SyncValue::Text(v.as_str().unwrap().to_owned()),
                        },
                    );
                }
                json!(s::fields_for(&m, c["changed"].as_i64().unwrap()))
            }
            "decide" => {
                let r = s::remote_from(&prefs(&c["prefs"]));
                json!(
                    match s::decide(&r, c["local"].as_i64(), c["other"].as_bool().unwrap()) {
                        s::Decision::Apply => "apply",
                        s::Decision::Push => "push",
                        s::Decision::Nothing => "nothing",
                    }
                )
            }
            "change_time" => json!(s::change_time(
                c["now"].as_i64().unwrap(),
                c["last"].as_i64()
            )),
            _ => {
                let present = prefs(&c["present"]);
                let server = c["suffix"].as_str().unwrap().trim_start_matches('|');
                values(&s::collect(server, |key, k| {
                    present.get(key).and_then(|t| SyncValue::decode(t, k))
                }))
            }
        }
    }
}

mod sync_crate {
    use super::*;
    use swiftly_sync::{Decision, Kind, SettingsSync, Value as V};

    fn kind(name: &str) -> Kind {
        match name {
            "bool" => Kind::Bool,
            "int" => Kind::Int,
            "list" => Kind::List,
            "json" => Kind::Json,
            _ => Kind::Text,
        }
    }
    fn kind_name(k: Kind) -> &'static str {
        match k {
            Kind::Bool => "bool",
            Kind::Int => "int",
            Kind::Text => "text",
            Kind::List => "list",
            Kind::Json => "json",
        }
    }
    fn value(v: &V) -> Value {
        let k = match v {
            V::Bool(_) => "bool",
            V::Int(_) => "int",
            V::Text(_) => "text",
            V::List(_) => "list",
            V::Json(_) => "json",
        };
        json!([k, v.encoded()])
    }
    fn values(m: &BTreeMap<String, V>) -> Value {
        Value::Object(m.iter().map(|(k, v)| (k.clone(), value(v))).collect())
    }
    fn seconds(v: &Value) -> Option<f64> {
        v.as_i64().map(|ms| ms as f64 / 1000.0)
    }
    fn millis(x: f64) -> i64 {
        (x * 1000.0).round() as i64
    }

    pub fn run(c: &Value) -> Value {
        match c["op"].as_str().unwrap() {
            "decode" => V::decode(
                c["text"].as_str().unwrap(),
                kind(c["kind"].as_str().unwrap()),
            )
            .map_or(Value::Null, |v| value(&v)),
            "entry" => SettingsSync::entry_for_device_key(c["key"].as_str().unwrap())
                .map_or(Value::Null, |e| {
                    json!([e.name, kind_name(e.kind), e.per_server])
                }),
            "remote" => {
                let r = SettingsSync::remote(&prefs(&c["prefs"]));
                json!({ "present": r.present(), "changed": r.changed.map(millis), "values": values(&r.values) })
            }
            "fields" => {
                let mut m = BTreeMap::new();
                for (name, d) in c["values"].as_object().unwrap() {
                    let v = &d["v"];
                    m.insert(
                        name.clone(),
                        match d["k"].as_str().unwrap() {
                            "bool" => V::Bool(v.as_bool().unwrap()),
                            "int" => V::Int(v.as_i64().unwrap()),
                            "list" => V::List(strings(v)),
                            "json" => V::Json(v.as_str().unwrap().to_owned()),
                            _ => V::Text(v.as_str().unwrap().to_owned()),
                        },
                    );
                }
                json!(SettingsSync::fields(&m, seconds(&c["changed"]).unwrap()))
            }
            "decide" => {
                let r = SettingsSync::remote(&prefs(&c["prefs"]));
                json!(match SettingsSync::decide(
                    &r,
                    seconds(&c["local"]),
                    c["other"].as_bool().unwrap()
                ) {
                    Decision::Apply => "apply",
                    Decision::Push => "push",
                    Decision::Nothing => "nothing",
                })
            }
            "change_time" => json!(millis(SettingsSync::change_time(
                seconds(&c["now"]).unwrap(),
                seconds(&c["last"])
            ))),
            _ => {
                let present = prefs(&c["present"]);
                values(&SettingsSync::collect(
                    c["suffix"].as_str().unwrap(),
                    |key, k| present.get(key).and_then(|t| V::decode(t, k)),
                ))
            }
        }
    }
}

#[test]
fn settings_sync_settings_crate() {
    assert_equal("settings_sync", settings_crate::run);
}

#[test]
fn settings_sync_sync_crate() {
    assert_equal("settings_sync", sync_crate::run);
}
