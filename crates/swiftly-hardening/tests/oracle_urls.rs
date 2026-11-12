//! Differential oracle, group "address rules": Rust must equal the recorded output of the real Swift
//! code (Tools/Oracle, Domain_Urls.swift).
#![allow(clippy::expect_used, clippy::unwrap_used)]

use serde_json::{Value, json};
use std::sync::Mutex;
use swiftly_hardening::oracle::assert_equal;
use swiftly_jellyfin::discovery::{self, FoundServer, StandardCollator};
use swiftly_jellyfin::{
    OwnHeader, OwnHeaders, ZonedAddress, image_key, is_home_network, normalize_server_url_zoned,
    reversed_server_url_string, without_secret,
};
use swiftly_net::Url;

static TABLE: Mutex<()> = Mutex::new(());

fn s(v: &Value) -> &str {
    v.as_str().unwrap_or("")
}

/// The address as the Swift `URL` reports it (no slash for a bare host); a zone id (`fe80::1%25en0`) is part of text and host.
fn parts(a: &ZonedAddress) -> Value {
    let u = &a.url;
    json!({
        "absolute": absolute_zoned(a),
        "scheme": u.scheme(),
        "host": a.host().map(|h| h.to_lowercase()),
        "port": u.port().or(a.explicit_default_port),
    })
}

fn absolute_zoned(a: &ZonedAddress) -> String {
    let text = a.with_zone(&a.url);
    match a.url.path() {
        "/" if a.url.query().is_none() && a.url.fragment().is_none() => {
            text.trim_end_matches('/').to_string()
        }
        _ => text,
    }
}

#[test]
fn server_url() {
    assert_equal("server_url", |c| {
        let raw = s(&c["raw"]);
        let url = normalize_server_url_zoned(raw);
        json!({
            "url": url.as_ref().map_or(Value::Null, parts),
            "home": is_home_network(raw),
            "reversed": reversed_server_url_string(raw).map_or(Value::Null, |u| json!(u)),
        })
    });
}

#[test]
fn server_relative() {
    assert_equal("server_relative", |c| {
        let base = s(&c["base"]);
        if Url::parse(base).is_err() {
            return json!({ "base": false });
        }
        json!({ "base": true, "result": swiftly_playback::playback_plan::server_relative(s(&c["detail"]), base) })
    });
}

#[test]
fn address_secret() {
    assert_equal("address_secret", |c| {
        let Ok(url) = Url::parse(s(&c["url"])) else {
            return json!({ "parsed": false });
        };
        json!({ "parsed": true, "log": without_secret(&url), "key": image_key(&url) })
    });
}

fn headers(v: &Value) -> Vec<OwnHeader> {
    v.as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
        .iter()
        .map(|h| OwnHeader::new(s(&h["name"]), s(&h["value"])))
        .collect()
}
fn headers_json(list: &[OwnHeader]) -> Value {
    json!(
        list.iter()
            .map(|h| json!({ "name": h.name, "value": h.value }))
            .collect::<Vec<_>>()
    )
}

#[test]
fn own_headers_clean() {
    assert_equal("own_headers_clean", |c| {
        let list = headers(&c["headers"]);
        json!({
            "cleaned": headers_json(&OwnHeaders::cleaned(&list)),
            "names": OwnHeaders::names(&list),
            "locked": list.iter().map(|h| OwnHeaders::is_locked(&h.name)).collect::<Vec<_>>(),
            "suits": list.iter().map(|h| OwnHeaders::name_suits(&h.name)).collect::<Vec<_>>(),
        })
    });
}

#[test]
fn own_headers_table() {
    let _guard = TABLE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    assert_equal("own_headers_table", |c| {
        OwnHeaders::load(None);
        let mut registered = vec![];
        for e in c["entries"].as_array().unwrap() {
            let Ok(base) = Url::parse(s(&e["base"])) else {
                registered.push(Value::Null);
                continue;
            };
            OwnHeaders::set_down(&headers(&e["headers"]), &base);
            registered.push(headers_json(&OwnHeaders::registered(&base)));
        }
        let answers: Vec<Value> = c["queries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|q| Url::parse(s(q)).map_or(Value::Null, |u| headers_json(&OwnHeaders::of(&u))))
            .collect();
        let stored: Value = serde_json::from_str(&OwnHeaders::store()).unwrap();
        let text = OwnHeaders::store();
        OwnHeaders::load(Some(&text));
        let again: Value = serde_json::from_str(&OwnHeaders::store()).unwrap();
        OwnHeaders::load(None);
        json!({ "registered": registered, "answers": answers, "store": stored, "roundtrip": stored == again })
    });
}

fn server(v: &Value) -> FoundServer {
    FoundServer {
        id: s(&v["id"]).into(),
        name: s(&v["name"]).into(),
        address: s(&v["address"]).into(),
    }
}
fn server_json(f: &FoundServer) -> Value {
    json!({ "id": f.id, "name": f.name, "address": f.address })
}
fn servers(v: &Value) -> Vec<FoundServer> {
    v.as_array().unwrap().iter().map(server).collect()
}

#[test]
fn server_discovery() {
    assert_equal("server_discovery", |c| match s(&c["kind"]) {
        "read" => {
            discovery::read(s(&c["text"]).as_bytes()).map_or(Value::Null, |f| server_json(&f))
        }
        "short" => json!(server(&c["server"]).short_address()),
        "merged" => {
            let collator = StandardCollator::new(s(&c["locale"])).expect("collator");
            json!(
                discovery::merged_localized(&servers(&c["known"]), &servers(&c["new"]), &collator)
                    .iter()
                    .map(server_json)
                    .collect::<Vec<_>>()
            )
        }
        _ => {
            let except: Vec<Option<&str>> = c["except"]
                .as_array()
                .unwrap()
                .iter()
                .map(Value::as_str)
                .collect();
            json!(
                discovery::shown(&servers(&c["found"]), &except)
                    .iter()
                    .map(server_json)
                    .collect::<Vec<_>>()
            )
        }
    });
}

/// `String.localizedStandardCompare` (-1, 0, 1), recorded by Swift in a process of each language.
fn standard_compare(language: &str) {
    let collator = StandardCollator::new(language).expect("collator");
    assert_equal(&format!("standard_compare_{language}"), |c| {
        json!(collator.compare(s(&c["a"]), s(&c["b"])) as i32)
    });
}

#[test]
fn standard_compare_de() {
    standard_compare("de");
}

#[test]
fn standard_compare_en() {
    standard_compare("en");
}

#[test]
fn standard_compare_ru() {
    standard_compare("ru");
}
