//! A recorded Jellyfin server for differential tests: the same router as the Swift
//! `HomeDifferentialTests` (`Packages/JellyfinKit/Tests/JellyfinKitTests`), answering from the
//! JSON files in `tests/fixtures/home_diff`.
#![allow(dead_code, clippy::expect_used, clippy::unwrap_used)]

use std::collections::HashMap;
use std::future::Future;
use std::path::PathBuf;

use serde_json::{Value, json};
use swiftly_jellyfin::{ClientConfig, JellyfinClient, ServerKind, Session};
use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, HttpTransport};

pub const BASE: &str = "https://tv.example.de";

pub fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../swiftly-library/tests")
}

fn read(name: &str) -> Value {
    let p = dir().join("fixtures/home_diff").join(name);
    serde_json::from_slice(&std::fs::read(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display())))
        .expect("json")
}

/// Answers like the recorded server; `mode` breaks one part (`ids_fail`, `ancestors_fail`,
/// `views_fail`) the way the Swift test does.
pub struct Recorded {
    pub mode: &'static str,
    files: HashMap<&'static str, Value>,
}

impl Recorded {
    pub fn new(mode: &'static str) -> Self {
        let files = [
            "views",
            "resume",
            "nextup",
            "latest",
            "catalog",
            "ancestors",
        ]
        .into_iter()
        .map(|n| (n, read(&format!("{n}.json"))))
        .collect();
        Self { mode, files }
    }

    fn list(&self, name: &str) -> Vec<Value> {
        self.files[name]["Items"]
            .as_array()
            .cloned()
            .unwrap_or_default()
    }

    fn answer(&self, r: &HttpRequest) -> (u16, String) {
        let q: HashMap<String, String> = r
            .url
            .query_pairs()
            .map(|(k, v)| (k.to_lowercase(), v.into_owned()))
            .fold(HashMap::new(), |mut m, (k, v)| {
                m.entry(k).or_insert(v);
                m
            });
        let wrap = |l: Vec<Value>| json!({"Items": l, "TotalRecordCount": l.len()}).to_string();
        let limited = |l: Vec<Value>| {
            let n = q
                .get("limit")
                .and_then(|v| v.parse().ok())
                .unwrap_or(l.len());
            l.into_iter().take(n).collect::<Vec<_>>()
        };
        let path = r.url.path();
        let empty = (200, wrap(Vec::new()));
        if path.ends_with("/UserViews") {
            if self.mode == "views_fail" {
                return (500, String::new());
            }
            return (200, self.files["views"].to_string());
        }
        if path.ends_with("/UserItems/Resume") {
            return (200, wrap(limited(self.list("resume"))));
        }
        if path.ends_with("/Shows/NextUp") {
            return (200, wrap(limited(self.list("nextup"))));
        }
        if path.ends_with("/Ancestors") {
            if self.mode == "ancestors_fail" {
                return (500, String::new());
            }
            let id = path
                .trim_end_matches("/Ancestors")
                .rsplit('/')
                .next()
                .unwrap_or("");
            return (
                200,
                self.files["ancestors"][id]
                    .to_string()
                    .replace("null", "[]"),
            );
        }
        if path.ends_with("/Items") {
            if let Some(ids) = q.get("ids") {
                if self.mode == "ids_fail" && q.get("fields").is_some_and(|f| f == "ProviderIds") {
                    return (500, String::new());
                }
                let want: Vec<&str> = ids.split(',').collect();
                return (
                    200,
                    wrap(
                        self.list("catalog")
                            .into_iter()
                            .filter(|i| want.contains(&i["Id"].as_str().unwrap_or("")))
                            .collect(),
                    ),
                );
            }
            if q.get("sortby").is_some_and(|s| s.contains("DateCreated"))
                && !q.contains_key("parentid")
            {
                return (200, wrap(limited(self.list("latest"))));
            }
        }
        empty
    }
}

impl HttpTransport for Recorded {
    fn send(
        &self,
        request: HttpRequest,
    ) -> impl Future<Output = Result<HttpResponse, ErrorKind>> + Send {
        let (status, body) = self.answer(&request);
        async move { Ok(HttpResponse::new(status, body)) }
    }
}

pub fn client(transport: Recorded) -> JellyfinClient<Recorded> {
    let c = JellyfinClient::new(transport, BASE, ClientConfig::new("dev", "Test", "1.0"))
        .expect("client");
    c.set_session(Some(Session {
        access_token: "tok".into(),
        user_id: "u1".into(),
        user_name: "t".into(),
        server_url: BASE.into(),
        kind: ServerKind::Jellyfin,
    }));
    c
}
