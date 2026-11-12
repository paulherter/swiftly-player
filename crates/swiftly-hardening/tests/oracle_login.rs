//! Differential oracle, login / Quick Connect / accounts: the Rust output must equal the real Swift output
//! (Tools/Oracle, Domain_Login.swift) for the error texts (`ErrorText.swift`), Quick Connect state and wait
//! (`Login.swift`, `QuickConnectWait.swift`), the real client over a stubbed transport (`Login.swift`,
//! `QuickConnect.swift`), account keys and bundles (`AccountBundle.swift`, `ServerBundles.swift`), server kind
//! detection, Emby paths and the address check (`Models.swift`, `EmbyPaths.swift`, `AddressCheck.swift`).
#![allow(clippy::expect_used, clippy::unwrap_used)]

use std::sync::Mutex;

use serde_json::{Value, json};
use swiftly_accounts::{
    Account, AccountBundle, MemorySecretStore, SecretStore, ServerBundles, bundle_storage_key,
    save_bundles,
};
use swiftly_hardening::oracle::{assert_equal, read};
use swiftly_jellyfin::{
    CheckState, ClientConfig, JellyfinClient, LoginCode, PublicUser, QuickConnectDeadline,
    QuickConnectState, QuickConnectWait, ServerKind, Session, WaitEvent, emby_rewrite, token_name,
};
use swiftly_l10n::error_text::{quick_connect_end_text, readable_error, readable_url_error_system};
use swiftly_l10n::{Locale, Translator};
use swiftly_model::PublicSystemInfo;
use swiftly_net::{
    CertificateReason, ErrorKind, HttpRequest, HttpResponse, HttpTransport, TransportReason,
};

fn lang() -> String {
    let swift = read("login_error.swift.json").expect("swift output of login_error");
    swift["results"][0].as_str().expect("language").to_owned()
}

fn translator() -> Translator {
    let probe = lang();
    let pick = ["de", "en", "ru"]
        .into_iter()
        .find(|l| Translator::new(Locale::parse(l)).t("Keine Verbindung.") == probe);
    Translator::new(Locale::parse(pick.expect("language of the Swift run")))
}

fn error_kind(e: &Value) -> ErrorKind {
    match e["t"].as_str().unwrap() {
        "network" => ErrorKind::Network {
            code: e["code"].as_i64().unwrap() as i32,
        },
        "certificate" => ErrorKind::Certificate(match e["reason"].as_str().unwrap() {
            "not_trusted" => CertificateReason::NotTrusted,
            "expired" => CertificateReason::Expired,
            "not_yet" => CertificateReason::AppliesNotYet,
            "other_address" => CertificateReason::OtherAddress,
            _ => CertificateReason::Otherwise,
        }),
        "transport" => ErrorKind::Transport(TransportReason::Other(
            e["text"].as_str().unwrap().to_owned(),
        )),
        "transport_special" => ErrorKind::Transport(match e["which"].as_str().unwrap() {
            "no_http" => TransportReason::NoHttpResponse,
            "login_page" => TransportReason::LoginPage,
            "qc_disabled" => TransportReason::QuickConnectDisabled,
            "refresh" => TransportReason::RefreshRejected,
            _ => TransportReason::RemoteDeviceSilent,
        }),
        "not_auth" => ErrorKind::NotAuthenticated,
        "two_factor" => ErrorKind::TwoFactor,
        "invalid_url" => ErrorKind::InvalidServerUrl,
        "http" => ErrorKind::Http {
            status: e["status"].as_i64().unwrap() as u16,
            body: e["body"].as_str().map(str::to_owned),
        },
        "decoding" => ErrorKind::Decoding(e["text"].as_str().unwrap().to_owned()),
        "no_source" => ErrorKind::NoPlayableSource,
        "rejected" => ErrorKind::PlaybackRejected(e["reason"].as_str().unwrap().to_owned()),
        "url" => ErrorKind::Network {
            code: e["code"].as_i64().unwrap() as i32,
        },
        other => panic!("bad error kind {other}"),
    }
}

#[test]
fn login_error() {
    let lang = lang();
    let tr = translator();
    assert_equal("login_error", |c| {
        if c["op"] == "lang" {
            return json!(lang);
        }
        let e = &c["e"];
        if e["t"] == "url" {
            return json!(readable_url_error_system(
                &tr,
                e["code"].as_i64().unwrap() as i32,
                e["desc"].as_str().unwrap()
            ));
        }
        json!(readable_error(&tr, &error_kind(e)))
    });
}

fn state_name(s: QuickConnectState) -> &'static str {
    match s {
        QuickConnectState::Opened => "opened",
        QuickConnectState::Released => "released",
        QuickConnectState::Expired => "expired",
        QuickConnectState::Failed => "failed",
    }
}

fn state_of(name: &str) -> QuickConnectState {
    match name {
        "released" => QuickConnectState::Released,
        "expired" => QuickConnectState::Expired,
        "failed" => QuickConnectState::Failed,
        _ => QuickConnectState::Opened,
    }
}

#[test]
fn login_quick() {
    let tr = translator();
    assert_equal("login_quick", |c| match c["op"].as_str().unwrap() {
        "from_error" => {
            let s = QuickConnectState::from_error(&if c["expired"] == true {
                ErrorKind::QuickConnectExpired
            } else {
                ErrorKind::Network { code: -1001 }
            });
            json!([state_name(s), s.ended_wait()])
        }
        "ended" => {
            let s = state_of(c["state"].as_str().unwrap());
            json!([state_name(s), s.ended_wait()])
        }
        "consts" => json!([
            QuickConnectDeadline::SECONDS,
            QuickConnectDeadline::TICK,
            QuickConnectDeadline::attempts()
        ]),
        "end_text" => json!(quick_connect_end_text(
            &tr,
            QuickConnectDeadline::end_is_failure(state_of(c["state"].as_str().unwrap()))
        )),
        "expired_text" => json!(quick_connect_end_text(&tr, false)),
        "remaining" => {
            let ms = c["ms"].as_i64().unwrap();
            let WaitEvent::Rest(n) =
                QuickConnectWait::with(0.0, ms as f64 / 1000.0, 1.0).first(0.0)
            else {
                panic!("first is a rest")
            };
            json!(n)
        }
        "outcome" => {
            let script: Vec<QuickConnectState> = c["script"]
                .as_array()
                .unwrap()
                .iter()
                .map(|s| state_of(s.as_str().unwrap()))
                .collect();
            let deadline = c["deadline_ms"].as_f64().unwrap() / 1000.0;
            let tick = c["tick_ms"].as_f64().unwrap() / 1000.0;
            let poll = c["poll_ms"].as_f64().unwrap() / 1000.0;
            let mut wait = QuickConnectWait::with(0.0, deadline, poll);
            let WaitEvent::Rest(first) = wait.first(0.0) else {
                panic!("first is a rest")
            };
            let mut now = 0.0;
            let mut asked = 0;
            let mut out = "none".to_owned();
            for _ in 0..10_000 {
                now += tick;
                let step = wait.tick(now);
                if let Some(WaitEvent::End(last)) = step.event {
                    out = format!("end:{}", state_name(last));
                    break;
                }
                if step.ask {
                    let state = script[asked.min(script.len() - 1)];
                    asked += 1;
                    match wait.answer(state) {
                        Some(WaitEvent::Released) => {
                            out = "released".into();
                            break;
                        }
                        Some(WaitEvent::End(last)) => {
                            out = format!("end:{}", state_name(last));
                            break;
                        }
                        _ => {}
                    }
                }
            }
            json!([out, first])
        }
        other => panic!("bad op {other}"),
    });
}

// A transport with one canned answer that records every request (method, path, sorted query, JSON body).
struct Mock {
    reply: Result<(u16, Vec<u8>), ErrorKind>,
    seen: Mutex<Vec<Value>>,
}

impl HttpTransport for Mock {
    fn send(
        &self,
        request: HttpRequest,
    ) -> impl std::future::Future<Output = Result<HttpResponse, ErrorKind>> + Send {
        let mut query: Vec<String> = request
            .url
            .query_pairs()
            .map(|(k, v)| format!("{k}={v}"))
            .collect();
        query.sort();
        let body = request
            .body
            .as_deref()
            .and_then(|b| serde_json::from_slice::<Value>(b).ok())
            .unwrap_or(Value::Null);
        let method = format!("{:?}", request.method).to_uppercase();
        self.seen
            .lock()
            .unwrap()
            .push(json!([method, request.url.path(), query.join("&"), body]));
        let reply = self.reply.clone();
        async move {
            reply.map(|(status, body)| HttpResponse {
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

#[test]
fn login_http() {
    let tr = translator();
    assert_equal("login_http", |c| {
        let reply = &c["reply"];
        let mock = Mock {
            reply: match reply["net"].as_i64() {
                Some(code) => Err(swiftly_net::certificate_reason(code as i32, "").map_or(
                    ErrorKind::Network { code: code as i32 },
                    ErrorKind::Certificate,
                )),
                None => Ok((
                    reply["status"].as_u64().unwrap_or(200) as u16,
                    reply["body"].as_str().unwrap_or("").as_bytes().to_vec(),
                )),
            },
            seen: Mutex::new(vec![]),
        };
        let base = c["base"].as_str().unwrap_or("http://example.test:8096");
        let client =
            JellyfinClient::new(&mock, base, ClientConfig::new("dev", "dn", "1.0")).unwrap();
        if c["no_session"] != true {
            client.set_session(Some(Session {
                access_token: "tok".into(),
                user_id: "uid".into(),
                user_name: "nm".into(),
                server_url: base.into(),
                kind: ServerKind::Jellyfin,
            }));
        }
        let code = LoginCode {
            code: c["code"].as_str().unwrap_or("").to_owned(),
            confidential: c["secret"].as_str().unwrap_or("").to_owned(),
        };
        let text = |e: &ErrorKind| readable_error(&tr, e);
        let result = futures_executor::block_on(async {
            match c["op"].as_str().unwrap() {
                "start" => match client.quick_connect_start().await {
                    Ok(l) => json!(["ok", l.code, l.confidential]),
                    Err(e) => json!(["err", text(&e)]),
                },
                "released" => match client.quick_connect_released(&code).await {
                    Ok(b) => json!(["ok", b]),
                    Err(ErrorKind::QuickConnectExpired) => json!(["expired"]),
                    Err(e) => json!(["err", text(&e)]),
                },
                "ask" => json!([state_name(client.quick_connect_ask_again(&code).await)]),
                "enabled" => json!([client.quick_connect_enabled().await]),
                "share" => match client
                    .quick_connect_share(c["code"].as_str().unwrap())
                    .await
                {
                    Ok(()) => json!(["ok"]),
                    Err(e) => json!(["err", text(&e)]),
                },
                "public" => json!(
                    client
                        .public_users()
                        .await
                        .unwrap_or_default()
                        .iter()
                        .map(|u| json!([u.id, u.name, u.image_mark]))
                        .collect::<Vec<_>>()
                ),
                "signin" => match client.sign_in_with_quick_connect(&code).await {
                    Ok(s) => json!(["ok", s.access_token, s.user_id, s.user_name, s.server_url]),
                    Err(e) => json!(["err", text(&e)]),
                },
                "image" => {
                    let user: PublicUser = serde_json::from_value(
                        json!({ "Id": c["id"], "Name": "n", "PrimaryImageTag": c["mark"] }),
                    )
                    .unwrap();
                    json!([client
                        .user_image(&user, c["border"].as_i64().unwrap())
                        .map(|u| u.to_string())])
                }
                other => panic!("bad op {other}"),
            }
        });
        if c["op"] == "image" {
            return json!({ "result": result, "seen": [] });
        }
        let seen = mock.seen.lock().unwrap().clone();
        json!({ "result": result, "seen": seen })
    });
}

fn account(text: &Value) -> Option<Account> {
    serde_json::from_str(text.as_str()?).ok()
}

fn snapshot(b: Option<&AccountBundle>) -> Value {
    let Some(b) = b else { return Value::Null };
    json!({
        "active": b.active().account_key(), "keys": b.accounts().iter().map(Account::account_key).collect::<Vec<_>>(),
        "servers": b.servers(), "url": b.server_url(), "tokens": b.accounts().iter().map(|a| a.session.access_token.clone()).collect::<Vec<_>>(),
    })
}

fn kind_name(k: ServerKind) -> &'static str {
    match k {
        ServerKind::Jellyfin => "jellyfin",
        ServerKind::Emby => "emby",
        ServerKind::Plex => "plex",
    }
}

fn kind_of(name: &str) -> ServerKind {
    match name {
        "emby" => ServerKind::Emby,
        "plex" => ServerKind::Plex,
        _ => ServerKind::Jellyfin,
    }
}

#[test]
fn login_accounts() {
    assert_equal("login_accounts", |c| match c["op"].as_str().unwrap() {
        "key" => match account(&c["session"]) {
            None => Value::Null,
            Some(a) => {
                let kind = a.session.kind;
                let prefix = match kind {
                    ServerKind::Jellyfin => "",
                    ServerKind::Emby => "emby:",
                    ServerKind::Plex => "plex:",
                };
                json!([
                    a.account_key(),
                    a.server_identity(),
                    prefix,
                    bundle_storage_key(kind)
                ])
            }
        },
        "bundle" => {
            let accounts: Vec<Account> = c["sessions"]
                .as_array()
                .unwrap()
                .iter()
                .map(|s| account(s).unwrap())
                .collect();
            let mut bundle = AccountBundle::from_stored(accounts, c["active"].as_str());
            let mut out = vec![snapshot(bundle.as_ref())];
            for st in c["steps"].as_array().unwrap() {
                let Some(mut b) = bundle.clone() else { break };
                match st["op"].as_str().unwrap() {
                    "record" => {
                        b.record(account(&st["session"]).unwrap());
                        bundle = Some(b);
                    }
                    "switch" => {
                        b.switch_to(st["id"].as_str().unwrap());
                        bundle = Some(b);
                    }
                    "remove" => bundle = b.removed(st["id"].as_str().unwrap()),
                    "record_in" => {
                        let (nb, changed) = AccountBundle::record_in(
                            account(&st["session"]).unwrap(),
                            bundle.clone(),
                        );
                        bundle = Some(nb);
                        out.push(json!(changed));
                    }
                    "on" => out.push(json!(
                        b.accounts_on(st["server"].as_str().unwrap())
                            .iter()
                            .map(|a| a.account_key())
                            .collect::<Vec<_>>()
                    )),
                    "account" => out.push(json!(
                        b.account(st["id"].as_str().unwrap())
                            .map(Account::account_key)
                    )),
                    "fits" => out.push(json!(b.fits_server(&account(&st["session"]).unwrap()))),
                    other => panic!("bad step {other}"),
                }
                out.push(snapshot(bundle.as_ref()));
            }
            json!(out)
        }
        "single" => snapshot(Some(&AccountBundle::new(account(&c["session"]).unwrap()))),
        "from_store" => snapshot(
            AccountBundle::from_store(
                c["bundle"].as_str().map(str::as_bytes),
                c["individual"].as_str().map(str::as_bytes),
            )
            .as_ref(),
        ),
        "old_gtk" => {
            match AccountBundle::from_old_gtk_store(c["data"].as_str().unwrap().as_bytes()) {
                None => Value::Null,
                Some(a) => json!([
                    a.account_key(),
                    a.session.user_name,
                    a.session.access_token,
                    a.session.server_url
                ]),
            }
        }
        "bundles_load" => {
            let map = c["store"].as_object().unwrap();
            let b = ServerBundles::load(|k| {
                map.get(k)
                    .and_then(Value::as_str)
                    .map(|s| s.as_bytes().to_vec())
            });
            json!({ "active_kind": kind_name(b.active_kind()), "kinds": b.kinds().into_iter().map(kind_name).collect::<Vec<_>>(), "active": snapshot(b.active()) })
        }
        "bundles_ops" => {
            let mut b = ServerBundles::default();
            for s in c["sessions"].as_array().unwrap() {
                let a = account(s).unwrap();
                let kind = a.session.kind;
                let existing = b.bundle(kind).cloned();
                b.set(Some(AccountBundle::record_in(a, existing).0), kind);
            }
            let mut out = vec![];
            for st in c["steps"].as_array().unwrap() {
                let kind = kind_of(st["kind"].as_str().unwrap());
                match st["op"].as_str().unwrap() {
                    "switch" => b.switch_to(kind),
                    _ => b.set(None, kind),
                }
                out.push(json!({ "active_kind": kind_name(b.active_kind()), "kinds": b.kinds().into_iter().map(kind_name).collect::<Vec<_>>() }));
            }
            let store = MemorySecretStore::new();
            save_bundles(&store, &b);
            let mut written = serde_json::Map::new();
            for key in ["konten", "konten.emby", "konten.plex", "aktiveArt"] {
                let v = store.get(key).map_or(Value::Null, |t| {
                    serde_json::from_str::<Value>(&t).unwrap_or(Value::String(t))
                });
                written.insert(key.into(), v);
            }
            out.push(Value::Object(written));
            json!(out)
        }
        other => panic!("bad op {other}"),
    });
}

#[test]
fn login_kind() {
    assert_equal("login_kind", |c| match c["op"].as_str().unwrap() {
        "looks_jellyfin" => {
            let info = PublicSystemInfo {
                product_name: c["product"].as_str().map(str::to_owned),
                version: c["version"].as_str().map(str::to_owned),
                ..Default::default()
            };
            json!(info.looks_like_jellyfin())
        }
        "rewrite" => json!(emby_rewrite(
            c["path"].as_str().unwrap(),
            c["user"].as_str()
        )),
        "token_name" => json!(token_name(kind_of(c["kind"].as_str().unwrap()))),
        "deadline" => json!(swiftly_jellyfin::ADDRESS_CHECK_DEADLINE.as_secs_f64()),
        "fallback" => {
            let e = &c["e"];
            let kind = match e["t"].as_str().unwrap() {
                "cancel" => ErrorKind::Cancelled,
                "ns" => ErrorKind::Network {
                    code: e["code"].as_i64().unwrap() as i32,
                },
                "ns_other" => ErrorKind::Decoding("x".into()),
                _ => error_kind(e),
            };
            json!(kind.fallback_pays_off())
        }
        "check" => {
            let mut state = CheckState::new();
            let mut marks = vec![];
            let mut out = vec![];
            for st in c["steps"].as_array().unwrap() {
                match st["op"].as_str().unwrap() {
                    "begin" => {
                        let m = state.begin(st["address"].as_str().unwrap());
                        out.push(json!([m.number, m.address]));
                        marks.push(m);
                    }
                    "applies" => {
                        let i = st["i"].as_u64().unwrap() as usize;
                        out.push(
                            marks
                                .get(i)
                                .map_or(Value::Null, |m| json!(state.applies(m))),
                        );
                    }
                    "complete" => {
                        let i = st["i"].as_u64().unwrap() as usize;
                        out.push(
                            marks
                                .get(i)
                                .map_or(Value::Null, |m| json!(state.complete(m))),
                        );
                    }
                    _ => {
                        state.discard();
                        out.push(json!("discard"));
                    }
                }
                out.push(
                    state
                        .ongoing()
                        .map_or(Value::Null, |m| json!([m.number, m.address])),
                );
            }
            json!(out)
        }
        other => panic!("bad op {other}"),
    });
}
