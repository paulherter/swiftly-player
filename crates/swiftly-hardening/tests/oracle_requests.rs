//! Differential oracle, outgoing requests of the Jellyfin / Emby client: the Rust client over a recording transport
//! must send exactly the requests the REAL Swift `JellyfinClient` sends over a URLProtocol stub (Tools/Oracle,
//! Domain_Requests.swift): method, encoded path, query (decoded pairs in order, and raw), headers, body, and
//! the addresses built without a request.
#![allow(clippy::expect_used, clippy::unwrap_used)]

use std::sync::Mutex;

use serde_json::{Value, json};
use swiftly_hardening::oracle::assert_equal;
use swiftly_jellyfin::{
    ClientConfig, ItemsQuery, JellyfinClient, LoginCode, PlayMethod, PublicUser, ReportPlan,
    ServerKind, Session, TrackIndices,
};
use swiftly_model::Item;
use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, HttpTransport};
use swiftly_playback::device_profile::DeviceProfile;
use swiftly_playback::endpoints::PlaybackEndpoints;
use swiftly_rules::download_quality::DownloadQuality;

fn decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while at < bytes.len() {
        if bytes[at] == b'%'
            && let Some(hex) = text.get(at + 1..at + 3)
            && let Ok(b) = u8::from_str_radix(hex, 16)
        {
            out.push(b);
            at += 3;
        } else {
            out.push(bytes[at]);
            at += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

struct Mock {
    status: u16,
    body: Mutex<Vec<u8>>,
    seen: Mutex<Vec<Value>>,
}

impl HttpTransport for Mock {
    fn send(
        &self,
        request: HttpRequest,
    ) -> impl std::future::Future<Output = Result<HttpResponse, ErrorKind>> + Send {
        // Percent-decoded pairs like Foundation's `queryItems`: a plus sign stays a plus sign (`query_pairs` would
        // turn it into a space, which is a form-encoding rule neither client applies).
        let query: Vec<Value> = request
            .url
            .query()
            .filter(|q| !q.is_empty())
            .map(|q| {
                q.split('&')
                    .map(|p| {
                        let (k, v) = p.split_once('=').unwrap_or((p, ""));
                        json!([decode(k), decode(v)])
                    })
                    .collect()
            })
            .unwrap_or_default();
        let body = request.body.as_deref().map_or(Value::Null, |b| {
            serde_json::from_slice::<Value>(b)
                .unwrap_or_else(|_| Value::String(String::from_utf8_lossy(b).into_owned()))
        });
        let mut headers = serde_json::Map::new();
        for (k, v) in &request.headers {
            headers.insert(k.to_lowercase(), json!(v));
        }
        let method = format!("{:?}", request.method).to_uppercase();
        self.seen.lock().unwrap().push(json!({
            "method": method, "path": request.url.path(), "query": query, "raw_query": request.url.query().unwrap_or(""),
            "headers": headers, "body": body,
        }));
        let status = self.status;
        let body = self.body.lock().unwrap().clone();
        async move {
            Ok(HttpResponse {
                status,
                headers: vec![("Content-Type".into(), "application/json".into())],
                body,
                url: None,
            })
        }
    }
}

impl HttpTransport for &Mock {
    fn send(
        &self,
        request: HttpRequest,
    ) -> impl std::future::Future<Output = Result<HttpResponse, ErrorKind>> + Send {
        (**self).send(request)
    }
}

fn s(a: &Value, k: &str) -> Option<String> {
    a[k].as_str().map(str::to_owned)
}

fn sv(a: &Value, k: &str) -> String {
    s(a, k).unwrap_or_default()
}

fn list(a: &Value, k: &str) -> Vec<String> {
    a[k].as_array()
        .map(|l| {
            l.iter()
                .filter_map(|x| x.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
}

fn i(a: &Value, k: &str) -> Option<i64> {
    a[k].as_i64()
}

fn plan(a: &Value) -> ReportPlan {
    ReportPlan {
        play_session_id: s(a, "play"),
        media_source_id: s(a, "source"),
        method: match a["method"].as_str().unwrap_or("") {
            "direct_stream" => PlayMethod::DirectStream,
            "transcode" => PlayMethod::Transcode,
            _ => PlayMethod::DirectPlay,
        },
    }
}

fn profile(a: &Value) -> DeviceProfile {
    let max = i(a, "max_bitrate").unwrap_or(1_000_000_000);
    if a["profile"] == "airplay" {
        DeviceProfile::airplay(max, a["av1"] == true)
    } else {
        DeviceProfile::vlc(max)
    }
}

fn item(a: &Value) -> Item {
    let mut o = json!({ "Id": sv(a, "id"), "Name": "n" });
    if let Some(t) = s(a, "primary") {
        o["ImageTags"] = json!({ "Primary": t });
    }
    if let Some(t) = s(a, "backdrop") {
        o["BackdropImageTags"] = json!([t]);
    }
    serde_json::from_value(o).unwrap()
}

fn quality(a: &Value) -> DownloadQuality {
    match a["quality"].as_str().unwrap_or("original") {
        "hd1080" => DownloadQuality::Hd1080,
        "hd720" => DownloadQuality::Hd720,
        "sd480" => DownloadQuality::Sd480,
        _ => DownloadQuality::Original,
    }
}

fn url_text<E>(r: Result<Option<url::Url>, E>) -> Value {
    match r {
        Ok(u) => json!(u.map(|u| u.to_string())),
        Err(_) => json!("err"),
    }
}

#[test]
fn requests_http() {
    assert_equal("requests_http", |c| {
        let default_body = "{\"Items\":[],\"TotalRecordCount\":0}";
        let mock = Mock {
            status: c["status"].as_u64().unwrap_or(200) as u16,
            body: Mutex::new(
                c["body"]
                    .as_str()
                    .unwrap_or(default_body)
                    .as_bytes()
                    .to_vec(),
            ),
            seen: Mutex::new(vec![]),
        };
        let base = c["base"].as_str().unwrap_or("http://example.test:8096");
        let kind = if c["kind"] == "emby" {
            ServerKind::Emby
        } else {
            ServerKind::Jellyfin
        };
        let config = ClientConfig::new(
            c["dev"].as_str().unwrap_or("dev"),
            c["dname"].as_str().unwrap_or("dn"),
            c["ver"].as_str().unwrap_or("1.0"),
        )
        .program(c["prog"].as_str().unwrap_or("Swiftly Player"))
        .kind(kind);
        let Ok(client) = JellyfinClient::new(&mock, base, config) else {
            return json!({ "urls": [], "seen": [], "bad_base": true });
        };
        if c["no_session"] != true {
            client.set_session(Some(Session {
                access_token: c["tok"].as_str().unwrap_or("tok").into(),
                user_id: c["uid"].as_str().unwrap_or("uid").into(),
                user_name: "nm".into(),
                server_url: base.into(),
                kind,
            }));
        }
        let a = &c["a"];
        let id = sv(a, "id");
        let urls = futures_executor::block_on(async {
            if let Some(perm) = c["perm"].as_str() {
                *mock.body.lock().unwrap() = format!(
                    "{{\"Policy\":{{\"EnableContentDownloading\":{}}}}}",
                    perm == "allowed"
                )
                .into_bytes();
                let _ = client.account_defaults().await;
                *mock.body.lock().unwrap() = c["body"]
                    .as_str()
                    .unwrap_or(default_body)
                    .as_bytes()
                    .to_vec();
                mock.seen.lock().unwrap().clear();
            }
            match c["op"].as_str().unwrap() {
                "system_info" => drop(client.public_system_info().await),
                "reachability" => drop(client.check_reachability().await),
                "authenticate" => drop(client.authenticate(&sv(a, "user"), &sv(a, "pw")).await),
                "sign_off" => client.sign_off().await,
                "still" => drop(client.session_applies_still().await),
                "views" => drop(client.user_views(a["hidden"] == true).await),
                "items" => {
                    let q = ItemsQuery {
                        parent_id: s(a, "parent"),
                        limit: i(a, "limit").unwrap_or(100),
                        start_index: i(a, "start").unwrap_or(0),
                        sort_by: s(a, "sort_by").unwrap_or_else(|| "SortName".into()),
                        sort_order: s(a, "sort_order").unwrap_or_else(|| "Ascending".into()),
                        filters: list(a, "filters"),
                        is_watched: a["watched"].as_bool(),
                        recursive: a["recursive"] == true,
                        include_item_types: list(a, "types"),
                        ids: list(a, "ids"),
                        person_ids: list(a, "people"),
                        genres: list(a, "genres"),
                        slim: a["slim"] == true,
                    };
                    drop(client.items(&q).await);
                }
                "count" => drop(client.count(&id, &list(a, "types")).await),
                "title_ids" => drop(
                    client
                        .title_ids(
                            &id,
                            &list(a, "types"),
                            &list(a, "filters"),
                            a["watched"].as_bool(),
                        )
                        .await,
                ),
                "identifiers" => drop(client.identifiers(&list(a, "ids")).await),
                "ancestors" => drop(client.ancestors(&id).await),
                "remembered" => drop(
                    client
                        .remembered_ids(&list(a, "types"), &sv(a, "sort_by"), &sv(a, "sort_order"))
                        .await,
                ),
                "collection" => drop(client.collection_members(&id).await),
                "playlist" => drop(client.playlist_entries(&id, a["lean"] == true).await),
                "playback_info" => {
                    let p = profile(a);
                    let max = i(a, "override").unwrap_or(p.max_streaming_bitrate);
                    drop(
                        client
                            .playback_info(
                                &id,
                                &p,
                                max,
                                i(a, "audio"),
                                i(a, "subtitle"),
                                s(a, "source").as_deref(),
                            )
                            .await,
                    );
                }
                "item" => drop(client.item(&id).await),
                "genres" => drop(client.genres().await),
                "similar" => drop(client.similar(&id, i(a, "limit").unwrap_or(12)).await),
                "extras" => drop(client.extras(&id).await),
                "trailers" => drop(client.trailers(&id).await),
                "search" => drop(
                    client
                        .search(&sv(a, "term"), i(a, "limit").unwrap_or(40))
                        .await,
                ),
                "user_record" => drop(client.user_record(&id).await),
                "last_play" => drop(
                    client
                        .last_play_set(&id, i(a, "ms").unwrap_or(0) as f64 / 1000.0)
                        .await,
                ),
                "point_back" => drop(client.point_back_set(&id).await),
                "user_data_raw" => drop(client.user_data_raw(&id).await),
                "user_data_put" => drop(
                    client
                        .user_data_back_put(&id, sv(a, "raw").into_bytes())
                        .await,
                ),
                "watchlist" => drop(client.set_watchlist(&id, a["on"] == true).await),
                "watched" => drop(client.set_watched(&id, a["on"] == true).await),
                "watchers" => drop(client.watchers(&id).await),
                "seasons" => drop(client.seasons(&id).await),
                "episodes" => drop(client.episodes(&id, s(a, "season").as_deref()).await),
                "first_episode" => drop(client.first_episode(&id).await),
                "refresh" => drop(client.metadata_refresh(&id).await),
                "next_series" => drop(client.next_episode_series(&id).await),
                "episode_post" => drop(client.episode_post(&id, &sv(a, "series")).await),
                "resume" => drop(client.resume_items(i(a, "limit").unwrap_or(20)).await),
                "next_up" => drop(client.next_up(i(a, "limit").unwrap_or(20)).await),
                "newly" => drop(
                    client
                        .newly_joined(
                            s(a, "parent").as_deref(),
                            i(a, "limit").unwrap_or(20),
                            a["slim"] == true,
                            &s(a, "types").unwrap_or_else(|| "Movie,Episode".into()),
                        )
                        .await,
                ),
                "sessions" => drop(client.remote_sessions().await),
                "foreign" => {
                    let cmd = match a["cmd"].as_str().unwrap_or("") {
                        "Unpause" => swiftly_jellyfin::ForeignCommand::Proceed,
                        "Stop" => swiftly_jellyfin::ForeignCommand::Finish,
                        _ => swiftly_jellyfin::ForeignCommand::Halt,
                    };
                    drop(client.foreign_command(cmd, &id).await);
                }
                "hint" => drop(client.handoff_hint(&id, &sv(a, "device")).await),
                "capabilities" => drop(client.report_capabilities().await),
                "account_defaults" => drop(client.account_defaults().await),
                "sections" => drop(client.sections(&id).await),
                "trickplay" => drop(client.trickplay(&id, s(a, "source").as_deref(), 320).await),
                "chapters" => drop(client.chapters(&id, s(a, "source").as_deref()).await),
                "report_start" => drop(
                    client
                        .report_start(
                            &id,
                            &plan(a),
                            i(a, "ticks").unwrap_or(0),
                            TrackIndices {
                                audio: i(a, "audio"),
                                subtitle: i(a, "subtitle"),
                            },
                        )
                        .await,
                ),
                "report_progress" => drop(
                    client
                        .report_progress(
                            &id,
                            &plan(a),
                            i(a, "ticks").unwrap_or(0),
                            a["paused"] == true,
                            TrackIndices {
                                audio: i(a, "audio"),
                                subtitle: i(a, "subtitle"),
                            },
                        )
                        .await,
                ),
                "report_stopped" => drop(
                    client
                        .report_stopped(&id, &plan(a), i(a, "ticks").unwrap_or(0))
                        .await,
                ),
                "stop_encoding" => client.stop_encoding(&sv(a, "play")).await,
                "qc_start" => drop(client.quick_connect_start().await),
                "qc_released" => drop(
                    client
                        .quick_connect_released(&LoginCode {
                            code: sv(a, "code"),
                            confidential: sv(a, "secret"),
                        })
                        .await,
                ),
                "qc_enabled" => drop(client.quick_connect_enabled().await),
                "qc_share" => drop(client.quick_connect_share(&sv(a, "code")).await),
                "qc_public" => drop(client.public_users().await),
                "qc_signin" => drop(
                    client
                        .sign_in_with_quick_connect(&LoginCode {
                            code: sv(a, "code"),
                            confidential: sv(a, "secret"),
                        })
                        .await,
                ),
                "u_stream" => {
                    return vec![url_text(
                        client
                            .stream_url(&id, s(a, "source").as_deref(), s(a, "play").as_deref())
                            .map(Some),
                    )];
                }
                "u_download" => {
                    return vec![url_text(
                        client
                            .download_url(&id, s(a, "source").as_deref(), None, None)
                            .map(Some),
                    )];
                }
                "u_download_q" => {
                    return vec![url_text(
                        client
                            .download_url_for(
                                &id,
                                s(a, "source").as_deref(),
                                quality(a),
                                i(a, "audio"),
                            )
                            .map(Some),
                    )];
                }
                "u_image" => {
                    return vec![url_text::<()>(Ok(
                        client.image_url(&item(a), i(a, "size").unwrap_or(480))
                    ))];
                }
                "u_backdrop" => {
                    return vec![url_text::<()>(Ok(
                        client.backdrop_url(&item(a), i(a, "size").unwrap_or(1200))
                    ))];
                }
                "u_trickplay" => {
                    return vec![url_text::<()>(Ok(client.trickplay_url(
                        &id,
                        s(a, "source").as_deref(),
                        i(a, "width").unwrap_or(320),
                        i(a, "sheet").unwrap_or(0),
                    )))];
                }
                "u_user_image" => {
                    let user: PublicUser = serde_json::from_value(
                        json!({ "Id": id, "Name": "n", "PrimaryImageTag": a["mark"] }),
                    )
                    .unwrap();
                    return vec![url_text::<()>(Ok(
                        client.user_image(&user, i(a, "border").unwrap_or(180))
                    ))];
                }
                other => panic!("bad op {other}"),
            }
            vec![]
        });
        let seen = mock.seen.lock().unwrap().clone();
        // Intended deviation (5387e046): Rust also asks for `ChildCount` in the item list fields, so the core can hide
        // series without seasons; the Swift app does not. Everything else must stay equal.
        let seen: Value = serde_json::from_str(
            &serde_json::to_string(&seen)
                .unwrap()
                .replace(",ChildCount", ""),
        )
        .unwrap();
        json!({ "urls": urls, "seen": seen })
    });
}
