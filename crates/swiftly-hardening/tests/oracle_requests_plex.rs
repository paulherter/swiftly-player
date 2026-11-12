//! Differential oracle, Plex requests: the Rust Plex client must send the same HTTP requests (method, address, ordered
//! query, headers, timeout, body) and build the same URLs as the real Swift `PlexClient` / `PlexAccountService` /
//! `PlexConnector` / `PlexPlayback` (Tools/Oracle, Domain_RequestsPlex.swift) over a stubbed transport.
#![allow(clippy::expect_used, clippy::unwrap_used)]

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};
use swiftly_hardening::oracle::assert_equal;
use swiftly_jellyfin::{ItemsQuery, TrackIndices};
use swiftly_library::home::HomePageSource;
use swiftly_library::library_filter::{LibraryFilter, Sorting};
use swiftly_model::Item;
use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, HttpTransport};
use swiftly_playback::media_server::MediaServer;
use swiftly_plex::{
    ImageKind, PlexAccountService, PlexClient, PlexConnector, PlexHomeUser, PlexIdentity, PlexPin,
    PlexPlayback, PlexStream, TimelineState,
};
use url::Url;

const SKIP: [&str; 9] = [
    "accept-encoding",
    "accept-language",
    "user-agent",
    "connection",
    "host",
    "content-length",
    "cookie",
    "cache-control",
    "pragma",
];

// The same hand-written percent decoding and URL split as Domain_RequestsPlex.swift.
fn decode(s: &str) -> String {
    let u = s.as_bytes();
    let hex = |b: u8| -> Option<u8> {
        match b {
            b'0'..=b'9' => Some(b - b'0'),
            b'A'..=b'F' => Some(b - b'A' + 10),
            b'a'..=b'f' => Some(b - b'a' + 10),
            _ => None,
        }
    };
    let mut out = Vec::new();
    let mut i = 0;
    while i < u.len() {
        if u[i] == b'%'
            && i + 2 < u.len()
            && let (Some(a), Some(b)) = (hex(u[i + 1]), hex(u[i + 2]))
        {
            out.push(a * 16 + b);
            i += 3;
        } else {
            out.push(u[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn split(url: &str) -> serde_json::Map<String, Value> {
    let mut rest = url;
    let mut fragment = Value::Null;
    if let Some(h) = rest.find('#') {
        fragment = json!(&rest[h + 1..]);
        rest = &rest[..h];
    }
    let mut raw_query = Value::Null;
    let mut pairs: Vec<Value> = vec![];
    if let Some(q) = rest.find('?') {
        let rq = &rest[q + 1..];
        raw_query = json!(rq);
        rest = &rest[..q];
        for part in rq.split('&') {
            match part.find('=') {
                Some(e) => pairs.push(json!([decode(&part[..e]), decode(&part[e + 1..])])),
                None => pairs.push(json!([decode(part), ""])),
            }
        }
    }
    let mut origin = String::new();
    let mut path = rest.to_owned();
    if let Some(r) = rest.find("://") {
        let after = &rest[r + 3..];
        match after.find('/') {
            Some(slash) => {
                origin = rest[..r + 3 + slash].to_owned();
                path = after[slash..].to_owned();
            }
            None => {
                origin = rest.to_owned();
                path = String::new();
            }
        }
    }
    let mut m = serde_json::Map::new();
    m.insert("url".into(), json!(url));
    m.insert("origin".into(), json!(origin));
    m.insert("path".into(), json!(path));
    m.insert("rawQuery".into(), raw_query);
    m.insert("query".into(), json!(pairs));
    m.insert("fragment".into(), fragment);
    m
}

fn record(request: &HttpRequest, sid: &str) -> Value {
    let mut rec = split(request.url.as_str());
    rec.insert(
        "method".into(),
        json!(format!("{:?}", request.method).to_uppercase()),
    );
    let mut headers: Vec<(String, String)> = request
        .headers
        .iter()
        .filter(|(k, _)| !SKIP.contains(&k.to_lowercase().as_str()))
        .map(|(k, v)| {
            (
                k.to_lowercase(),
                if v == sid {
                    "<SID>".to_owned()
                } else {
                    v.clone()
                },
            )
        })
        .collect();
    headers.sort();
    rec.insert(
        "headers".into(),
        json!(
            headers
                .into_iter()
                .map(|(k, v)| json!([k, v]))
                .collect::<Vec<_>>()
        ),
    );
    rec.insert(
        "timeout".into(),
        request
            .timeout
            .map_or(Value::Null, |d| json!(d.as_secs_f64())),
    );
    let body = match &request.body {
        None => Value::Null,
        Some(b) => serde_json::from_slice::<Value>(b)
            .unwrap_or_else(|_| String::from_utf8(b.clone()).map_or(Value::Null, Value::String)),
    };
    rec.insert("body".into(), body);
    Value::Object(rec)
}

// A transport with canned answers by path that records every request in full.
struct Mock {
    routes: HashMap<String, (u16, Vec<u8>)>,
    fallback: (u16, Vec<u8>),
    net: Option<i32>,
    sid: Mutex<String>,
    seen: Mutex<Vec<Value>>,
}

impl HttpTransport for Mock {
    fn send(
        &self,
        request: HttpRequest,
    ) -> impl std::future::Future<Output = Result<HttpResponse, ErrorKind>> + Send {
        let sid = self.sid.lock().unwrap().clone();
        let rec = record(&request, &sid);
        let path = rec["path"].as_str().unwrap().to_owned();
        self.seen.lock().unwrap().push(rec);
        let (status, body) = self.routes.get(&path).unwrap_or(&self.fallback).clone();
        let reply = match self.net {
            Some(code) => Err(swiftly_net::certificate_reason(code, "")
                .map_or(ErrorKind::Network { code }, ErrorKind::Certificate)),
            None => Ok(HttpResponse {
                status,
                headers: vec![("Content-Type".into(), "application/json".into())],
                body,
                url: None,
            }),
        };
        async move { reply }
    }
}

fn answer(v: &Value) -> (u16, Vec<u8>) {
    (
        v["status"].as_u64().unwrap_or(200) as u16,
        v["body"].as_str().unwrap_or("").as_bytes().to_vec(),
    )
}

fn s(c: &Value, k: &str) -> String {
    c[k].as_str().unwrap_or("").to_owned()
}

fn o(c: &Value, k: &str) -> Option<String> {
    c[k].as_str().map(str::to_owned)
}

fn strings(c: &Value, k: &str) -> Vec<String> {
    c[k].as_array()
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
}

fn sorting(name: &str) -> Sorting {
    match name {
        "latest" => Sorting::Latest,
        "rating" => Sorting::Rating,
        "erscheinung" => Sorting::Erscheinung,
        _ => Sorting::Name,
    }
}

fn library_filter(name: &str) -> LibraryFilter {
    match name {
        "begun" => LibraryFilter::Begun,
        "unwatched" => LibraryFilter::Unwatched,
        "watchlist" => LibraryFilter::Watchlist,
        _ => LibraryFilter::All,
    }
}

fn image_kind(name: &str) -> ImageKind {
    match name {
        "background" => ImageKind::Background,
        "logo" => ImageKind::Logo,
        "preview" => ImageKind::Preview,
        _ => ImageKind::Poster,
    }
}

fn timeline_state(name: &str) -> TimelineState {
    match name {
        "paused" => TimelineState::Paused,
        "buffering" => TimelineState::Buffering,
        "stopped" => TimelineState::Stopped,
        _ => TimelineState::Playing,
    }
}

fn url_result(u: Option<Url>) -> Value {
    json!(["url", u.map(|u| u.to_string())])
}

#[test]
fn requests_plex() {
    let run = |c: &Value| -> Value {
        let reply = &c["reply"];
        let mut routes = HashMap::new();
        for (path, v) in reply["routes"].as_object().into_iter().flatten() {
            routes.insert(path.clone(), answer(v));
        }
        let mock = Arc::new(Mock {
            routes,
            fallback: answer(&reply["default"]),
            net: reply["net"].as_i64().map(|n| n as i32),
            sid: Mutex::new(String::new()),
            seen: Mutex::new(vec![]),
        });
        let Ok(base) = Url::parse(c["base"].as_str().unwrap_or("http://plex.test:32400")) else {
            return json!(["bad_base"]);
        };
        let ident = &c["ident"];
        let identity = PlexIdentity {
            client_id: ident["client"].as_str().unwrap_or("cid").into(),
            product: ident["product"].as_str().unwrap_or("Swiftly Player").into(),
            version: ident["version"].as_str().unwrap_or("1.0").into(),
            platform: ident["platform"].as_str().unwrap_or("iOS").into(),
            platform_version: o(ident, "platform_version"),
            device: ident["device"].as_str().unwrap_or("iOS").into(),
            device_name: ident["device_name"].as_str().unwrap_or("dn").into(),
        };
        let token = s(c, "token");
        let client = PlexClient::new(base.clone(), &token, identity.clone(), Arc::clone(&mock));
        *mock.sid.lock().unwrap() = client.session_id.clone();
        let tv = c["tv"].as_str().unwrap_or("http://tv.test");
        let clients = c["clients"].as_str().unwrap_or("http://clients.test");
        let apps = c["app"].as_str().unwrap_or("http://app.test");
        let accounts =
            PlexAccountService::with_bases(identity.clone(), Arc::clone(&mock), tv, clients, apps);

        let op = c["op"].as_str().unwrap();
        let id = s(c, "id");
        let limit = c["limit"].as_i64().unwrap_or(20);
        let start = c["start"].as_i64().unwrap_or(0);
        let size = c["size"].as_i64().unwrap_or(50);
        let on = c["on"].as_bool().unwrap_or(false);
        let opt_h = c["h"].as_i64();
        let opt_w = c["w"].as_i64();
        let source = o(c, "source");
        let tr = c["token2"].as_str().unwrap_or("tok2").to_owned();
        let show = c["show"].as_i64().unwrap_or(24);
        let fetch = c["fetch"].as_i64().unwrap_or(200);
        let library = o(c, "library");
        let item: Option<Item> = serde_json::from_value(c["item"].clone()).ok();

        let result: Value = futures_executor::block_on(async {
            match op {
                "info" => drop(client.info().await),
                "token_works" => drop(client.token_works().await),
                "sections" => drop(client.sections().await),
                "views" => drop(client.views().await),
                "list" => drop(
                    client
                        .list(
                            &id,
                            o(c, "type").as_deref(),
                            sorting(&s(c, "sort")),
                            library_filter(&s(c, "filter")),
                            o(c, "genre").as_deref(),
                            start,
                            size,
                        )
                        .await,
                ),
                "genres_section" => drop(client.genres_of_section(&id).await),
                "continue" => drop(client.continue_watching(limit).await),
                "on_deck" => drop(client.on_deck(limit).await),
                "recent" => drop(
                    client
                        .recently_added(o(c, "section").as_deref(), limit)
                        .await,
                ),
                "hubs" => drop(client.hubs(o(c, "section").as_deref()).await),
                "search" => drop(client.search(&s(c, "term"), limit).await),
                "detail" => drop(client.detail(&id).await),
                "item" => drop(client.item(&id).await),
                "children" => drop(client.children(&id).await),
                "episodes" => drop(client.episodes_of(&id, o(c, "season").as_deref()).await),
                "similar" => drop(client.similar_to(&id, limit).await),
                "collections" => drop(client.collections(&id).await),
                "collection_items" => drop(client.collection_items(&id).await),
                "playlists" => drop(client.playlists().await),
                "playlist_items" => drop(client.playlist_items(&id).await),
                "titles" => drop(
                    client
                        .titles(&id, &s(c, "filter"), &s(c, "value"), start, size)
                        .await,
                ),
                "watched" => drop(client.set_watched_key(&id, on).await),
                "favorite" => drop(client.set_favorite(&id, on).await),
                "tracks" => drop(
                    client
                        .choose_tracks(
                            c["part"].as_i64().unwrap_or(0),
                            c["audio"].as_i64(),
                            c["sub"].as_i64(),
                        )
                        .await,
                ),
                "plan" => {
                    return match client
                        .plan_for(
                            &id,
                            source.as_deref(),
                            c["audio"].as_i64(),
                            c["sub"].as_i64(),
                        )
                        .await
                    {
                        Ok(p) => json!(["plan", p.url.to_string()]),
                        Err(_) => json!(["plan", null]),
                    };
                }
                "download" => {
                    return json!([
                        "download",
                        client
                            .download_url_of(&id, source.as_deref())
                            .await
                            .ok()
                            .map(|u| u.to_string())
                    ]);
                }
                "previews" => drop(client.previews(&id, source.as_deref()).await),
                "segments" => drop(client.segments(&id).await),
                "timeline" => drop(
                    client
                        .report_timeline(
                            &id,
                            timeline_state(&s(c, "state")),
                            c["ticks"].as_i64().unwrap_or(0),
                            c["duration"].as_i64(),
                        )
                        .await,
                ),
                "report" => {
                    let Ok(plan) = client.plan_for(&id, None, None, None).await else {
                        return json!(["no_plan"]);
                    };
                    let ticks = c["ticks"].as_i64().unwrap_or(0);
                    match s(c, "kind").as_str() {
                        "start" => drop(
                            MediaServer::report_start(
                                &client,
                                &id,
                                &plan,
                                ticks,
                                TrackIndices::default(),
                            )
                            .await,
                        ),
                        "progress" => drop(
                            MediaServer::report_progress(
                                &client,
                                &id,
                                &plan,
                                ticks,
                                false,
                                TrackIndices::default(),
                            )
                            .await,
                        ),
                        "paused" => drop(
                            MediaServer::report_progress(
                                &client,
                                &id,
                                &plan,
                                ticks,
                                true,
                                TrackIndices::default(),
                            )
                            .await,
                        ),
                        _ => drop(MediaServer::report_stopped(&client, &id, &plan, ticks).await),
                    }
                }
                "image_path" => {
                    return url_result(client.image_url_path(&s(c, "path"), opt_h, opt_w));
                }
                "image_item" => {
                    let Some(item) = &item else {
                        return json!(["no_item"]);
                    };
                    return url_result(client.image_url_for(
                        item,
                        image_kind(&s(c, "kind")),
                        opt_h,
                        opt_w,
                    ));
                }
                "image_server" => {
                    let Some(item) = &item else {
                        return json!(["no_item"]);
                    };
                    return json!([
                        "url",
                        MediaServer::image_url(&client, item, opt_h.unwrap_or(480)).await
                    ]);
                }
                "sub_stream" => {
                    let Some(stream) = PlexStream::parse(&c["stream"]) else {
                        return json!(["no_stream"]);
                    };
                    return url_result(client.subtitle_url(&stream));
                }
                "sub_path" => return url_result(client.subtitle_url_path(&s(c, "path"))),
                "playback_url" => {
                    let pb = PlexPlayback::new(base.clone(), &token);
                    let query: Vec<(String, String)> = c["query"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .map(|p| {
                            (
                                p[0].as_str().unwrap().to_owned(),
                                p[1].as_str().unwrap().to_owned(),
                            )
                        })
                        .collect();
                    return match s(c, "fn").as_str() {
                        "url" => url_result(pb.url(
                            &s(c, "path"),
                            &query,
                            c["with_token"].as_bool().unwrap_or(false),
                        )),
                        "file" => url_result(
                            pb.file_url(&s(c, "path"), c["download"].as_bool().unwrap_or(false)),
                        ),
                        _ => url_result(pb.preview_index_url(c["part"].as_i64().unwrap_or(0))),
                    };
                }
                "items" => {
                    let q = ItemsQuery {
                        parent_id: o(c, "parent"),
                        limit,
                        start_index: start,
                        sort_by: o(c, "sort_by").unwrap_or_else(|| "SortName".into()),
                        sort_order: o(c, "sort_order").unwrap_or_else(|| "Ascending".into()),
                        filters: strings(c, "filters"),
                        is_watched: c["watched"].as_bool(),
                        recursive: c["recursive"].as_bool().unwrap_or(false),
                        include_item_types: strings(c, "types"),
                        ids: strings(c, "ids"),
                        person_ids: strings(c, "persons"),
                        genres: strings(c, "genres"),
                        slim: false,
                    };
                    drop(client.items_page(&q).await);
                }
                "genres_all" => drop(MediaServer::genres(&client).await),
                "last_added" => drop(
                    client
                        .last_added_kinds(
                            library.as_deref(),
                            fetch,
                            show,
                            c["genres"].as_str().unwrap_or("Movie,Episode"),
                        )
                        .await,
                ),
                "new_arrivals" => drop(
                    HomePageSource::new_arrivals(
                        &client,
                        c["genres"].as_str().unwrap_or("Movie"),
                        fetch,
                        show,
                    )
                    .await,
                ),
                "new_series" => {
                    drop(HomePageSource::new_series(&client, library.as_deref(), show).await)
                }
                "latest_title" => drop(
                    HomePageSource::latest_title(
                        &client,
                        &id,
                        c["collection"].as_bool().unwrap_or(false),
                        show,
                    )
                    .await,
                ),
                "playlist_dir" => drop(MediaServer::playlist_directory(&client).await),
                "playlist_entries" => {
                    drop(MediaServer::playlist_entries(&client, &id, false).await)
                }
                "collection_dir" => drop(MediaServer::collection_directory(&client, &[]).await),
                "remembered" => drop(
                    MediaServer::remembered_items(
                        &client,
                        &strings(c, "types"),
                        c["sort_by"].as_str().unwrap_or("SortName"),
                        c["sort_order"].as_str().unwrap_or("Ascending"),
                        start,
                        limit,
                    )
                    .await,
                ),
                "title_person" => {
                    drop(MediaServer::title_with_number_person(&client, &id, limit, start).await)
                }
                "title_genre" => {
                    drop(MediaServer::title_with_number_genre(&client, &id, limit, start).await)
                }
                "next_episode" => drop(MediaServer::next_episode_series(&client, &id).await),
                "episode_post" => {
                    drop(MediaServer::episode_post(&client, &s(c, "item_id"), &id).await)
                }
                "state_in_series" => drop(MediaServer::state_in_series(&client, &id).await),
                "refresh" => drop(MediaServer::metadata_refresh(&client, &id).await),
                "watchlist" => drop(MediaServer::set_watchlist(&client, &id, on).await),
                "watched_ms" => drop(MediaServer::set_watched(&client, &id, on).await),
                "point_back" => drop(MediaServer::point_back_set(&client, &id).await),
                "trickplay" => {
                    let _ = MediaServer::trickplay(&client, &id, source.as_deref(), 320).await;
                }
                "sheet" => drop(
                    MediaServer::trickplay_sheet(
                        &client,
                        &id,
                        source.as_deref(),
                        320,
                        c["sheet"].as_i64().unwrap_or(0),
                    )
                    .await,
                ),
                "chapter" => drop(MediaServer::chapter(&client, &id, None).await),
                "extras" => drop(MediaServer::extras(&client, &id).await),
                "trailer" => drop(MediaServer::trailer(&client, &id).await),
                "similar_ms" => drop(MediaServer::similar(&client, &id, limit).await),
                "public_info" => drop(MediaServer::public_system_info(&client).await),
                "applies" => drop(MediaServer::session_applies_still(&client).await),
                "signoff_sections" => {
                    MediaServer::sign_off(&client).await;
                    drop(client.sections().await);
                }
                "pin_start" => drop(
                    accounts
                        .start_pin(c["strong"].as_bool().unwrap_or(true))
                        .await,
                ),
                "pin_check" => drop(
                    accounts
                        .check_pin(&PlexPin::new(
                            c["pin_id"].as_i64().unwrap_or(0),
                            &s(c, "code"),
                        ))
                        .await,
                ),
                "auth_url" => {
                    let pin = PlexPin::new(1, &s(c, "code"));
                    let forward = o(c, "forward").filter(|f| Url::parse(f).is_ok());
                    return url_result(accounts.auth_url(&pin, forward.as_deref()));
                }
                "link_page" => return url_result(accounts.link_page()),
                "validate" => drop(accounts.validate(&tr).await),
                "servers" => drop(accounts.servers(&tr).await),
                "home_users" => drop(accounts.home_users(&tr).await),
                "switch_user" => {
                    if let Some(user) =
                        PlexHomeUser::parse(&json!({ "id": "1", "uuid": s(c, "uuid") }))
                    {
                        drop(
                            accounts
                                .switch_user(&user, o(c, "pin").as_deref(), &tr)
                                .await,
                        );
                    }
                }
                "probe" => drop(
                    PlexConnector::identity_matches(
                        mock.as_ref(),
                        &base,
                        &identity,
                        &token,
                        &s(c, "machine"),
                        Duration::from_secs(c["timeout"].as_u64().unwrap_or(3)),
                    )
                    .await,
                ),
                other => panic!("bad op {other}"),
            }
            Value::Null
        });
        let mut seen = mock.seen.lock().unwrap().clone();
        if c["sorted"] == true {
            let key = |r: &Value| {
                format!(
                    "{} {}",
                    r["method"].as_str().unwrap(),
                    r["url"].as_str().unwrap()
                )
                .into_bytes()
            };
            seen.sort_by_key(key);
        }
        json!({ "result": result, "seen": seen })
    };
    assert_equal("requests_plex", run);
}
