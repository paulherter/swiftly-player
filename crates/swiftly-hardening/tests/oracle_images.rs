//! Differential oracle, image domains: addresses, cache keys and picks must equal the real Swift
//! output (Tools/Oracle, Domain_Images.swift).
#![allow(clippy::expect_used, clippy::unwrap_used)]

use serde_json::{Value, json};
use swiftly_hardening::oracle::assert_equal;
use swiftly_images::Url;
use swiftly_images::address::{ImageAddress, ImageKind, ImageMetric};
use swiftly_images::selection::ImageSelection;
use swiftly_images::store_key::{image_key, store_key};
use swiftly_jellyfin::ServerKind;
use swiftly_model::Item;

fn url_result(url: Option<&Url>) -> serde_json::Map<String, Value> {
    let mut m = serde_json::Map::new();
    m.insert("url".into(), json!(url.map(Url::to_string)));
    m.insert("key".into(), json!(url.map(image_key)));
    m.insert("store".into(), json!(url.and_then(store_key)));
    m
}

fn address(c: &Value) -> Option<ImageAddress> {
    let base = Url::parse(c["base"].as_str()?).ok()?;
    let kind = match c["kind"].as_str() {
        Some("emby") => ServerKind::Emby,
        Some("plex") => ServerKind::Plex,
        _ => ServerKind::Jellyfin,
    };
    Some(ImageAddress::new(
        base,
        c["token"].as_str().map(str::to_owned),
        kind,
    ))
}

fn mass(v: &Value) -> ImageMetric {
    let n = |i: usize| v[i].as_i64().unwrap_or(0);
    match v[0].as_str() {
        Some("high") => ImageMetric::AtMostHigh(n(1)),
        Some("wide") => ImageMetric::AtMostWide(n(1)),
        _ => ImageMetric::Filling {
            wide: n(1),
            up: n(2),
        },
    }
}

#[test]
fn image_address() {
    assert_equal("image_address", |c| {
        let Some(a) = address(c) else {
            return json!({ "base": false });
        };
        let url = if c["op"] == "user" {
            a.user(
                c["id"].as_str().unwrap(),
                c["mark"].as_str(),
                c["border"].as_i64().unwrap(),
            )
        } else {
            let art = match c["art"].as_str() {
                Some("background") => ImageKind::Background,
                Some("preview") => ImageKind::Preview,
                Some("logo") => ImageKind::Logo,
                _ => ImageKind::Poster,
            };
            a.construct_with(
                c["id"].as_str().unwrap(),
                art,
                c["mark"].as_str(),
                mass(&c["mass"]),
                c["index"].as_i64(),
                c["q"].as_i64().unwrap(),
            )
        };
        let mut m = url_result(url.as_ref());
        m.insert("base".into(), json!(true));
        Value::Object(m)
    });
}

#[test]
fn image_store_key() {
    assert_equal("image_store_key", |c| {
        let Ok(url) = Url::parse(c["url"].as_str().unwrap()) else {
            return json!({ "parsed": false });
        };
        let mut m = url_result(Some(&url));
        m.insert("parsed".into(), json!(true));
        m.insert("abs".into(), json!(url.to_string()));
        Value::Object(m)
    });
}

#[test]
fn image_selection() {
    assert_equal("image_selection", |c| {
        let Some(a) = address(c) else {
            return json!({ "base": false });
        };
        let Ok(it) = serde_json::from_value::<Item>(c["item"].clone()) else {
            return json!({ "decoded": false });
        };
        let width = c["width"].as_i64().unwrap();
        let mut m;
        match c["op"].as_str().unwrap() {
            "landscape" => {
                let hit = ImageSelection::landscape(&it, &a, width);
                m = url_result(hit.as_ref().map(|h| &h.url));
                m.insert("source".into(), json!(hit.map(|h| h.source)));
            }
            "header" => m = url_result(ImageSelection::header(&it, &a, width).as_ref()),
            "header_fb" => {
                let episode = serde_json::from_value::<Item>(c["episode"].clone()).ok();
                m = url_result(
                    ImageSelection::header_with_fallback(&it, episode.as_ref(), &a, width).as_ref(),
                );
            }
            "logo" => m = url_result(ImageSelection::logo(&it, &a, width).as_ref()),
            _ => m = url_result(ImageSelection::portrait(&it, &a, width).as_ref()),
        }
        m.insert("decoded".into(), json!(true));
        Value::Object(m)
    });
}
