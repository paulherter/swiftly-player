//! The Rust twin of the router in `MethodDifferentialTests.swift`: answers the recorded world
//! (`fixtures/method_diff/world.json`) with exactly the same rules, so a difference in a result is
//! a difference in the client code, not in the server.
#![allow(dead_code, clippy::expect_used, clippy::unwrap_used)]

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::path::PathBuf;

use serde_json::{Value, json};
use swiftly_jellyfin::{ClientConfig, JellyfinClient, ServerKind, Session};
use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, HttpTransport};

pub const BASE: &str = "https://tv.example.de";

pub fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../swiftly-library/tests")
        .canonicalize()
        .expect("library tests dir")
}

pub struct World {
    world: Value,
    catalog: Vec<Value>,
}

impl World {
    pub fn load() -> Self {
        let p = dir().join("fixtures/method_diff/world.json");
        let world: Value =
            serde_json::from_slice(&std::fs::read(&p).expect("world.json")).expect("json");
        let catalog = world["catalog"].as_array().cloned().unwrap_or_default();
        Self { world, catalog }
    }

    pub fn catalog(&self) -> &[Value] {
        &self.catalog
    }

    fn entry(&self, id: &str) -> Option<Value> {
        self.catalog
            .iter()
            .find(|e| e["Id"].as_str() == Some(id))
            .cloned()
    }

    fn list(&self, key: &str, id: &str) -> Vec<String> {
        self.world[key][id]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default()
    }

    fn descendants(&self, id: &str) -> Vec<String> {
        self.list("children", id)
            .into_iter()
            .flat_map(|c| {
                let mut v = vec![c.clone()];
                v.extend(self.descendants(&c));
                v
            })
            .collect()
    }

    fn ids(&self, list: &[String]) -> Vec<Value> {
        list.iter().filter_map(|i| self.entry(i)).collect()
    }

    fn key(e: &Value, field: &str) -> String {
        match field {
            "SortName" => e["SortName"]
                .as_str()
                .or_else(|| e["Name"].as_str())
                .unwrap_or("")
                .to_lowercase(),
            "DateCreated" => e["DateCreated"].as_str().unwrap_or("").to_string(),
            _ => String::new(),
        }
    }

    fn year(e: &Value) -> f64 {
        e["ProductionYear"].as_f64().unwrap_or(0.0)
    }

    fn played(e: &Value) -> bool {
        e["UserData"]["Played"].as_bool().unwrap_or(false)
    }

    pub fn answer(&self, r: &HttpRequest) -> (u16, String) {
        let q: HashMap<String, String> = r
            .url
            .query_pairs()
            .map(|(k, v)| (k.to_lowercase(), v.into_owned()))
            .fold(HashMap::new(), |mut m, (k, v)| {
                m.entry(k).or_insert(v);
                m
            });
        let parts: Vec<&str> = r.url.path().split('/').filter(|s| !s.is_empty()).collect();
        let wrap = |l: Vec<Value>| json!({"Items": l, "TotalRecordCount": l.len()}).to_string();
        let limited = |l: Vec<Value>| -> Vec<Value> {
            let n = q
                .get("limit")
                .and_then(|v| v.parse().ok())
                .unwrap_or(l.len());
            l.into_iter().take(n).collect()
        };
        let last = parts.last().copied().unwrap_or("");
        let n = parts.len();
        let at = |back: usize| -> &str { if n >= back { parts[n - back] } else { "" } };

        if last == "UserViews" {
            return (
                200,
                wrap(self.world["views"].as_array().cloned().unwrap_or_default()),
            );
        }
        if n >= 2 && at(2) == "UserItems" && last == "Resume" {
            let l = self.list_of("resume");
            return (200, wrap(limited(self.ids(&l))));
        }
        if n >= 2 && at(2) == "Shows" && last == "NextUp" {
            let l = match q.get("seriesid") {
                Some(s) => self.list("nextup_series", s),
                None => self.list_of("nextup"),
            };
            return (200, wrap(limited(self.ids(&l))));
        }
        if last == "Ancestors" {
            let list = self.world["ancestors"][at(2)].clone();
            let list = if list.is_null() { json!([]) } else { list };
            return (200, list.to_string());
        }
        if last == "Seasons" && n >= 3 && at(3) == "Shows" {
            return (200, wrap(self.ids(&self.list("seasons", at(2)))));
        }
        if last == "Episodes" && n >= 3 && at(3) == "Shows" {
            let mut l = self.ids(&self.list("episodes", at(2)));
            if let Some(s) = q.get("seasonid") {
                l.retain(|e| e["SeasonId"].as_str() == Some(s));
            }
            if q.get("filters")
                .is_some_and(|f| f.split(',').any(|x| x == "IsUnplayed"))
            {
                l.retain(|e| !Self::played(e));
            }
            if let Some(adj) = q.get("adjacentto")
                && let Some(i) = l.iter().position(|e| e["Id"].as_str() == Some(adj))
            {
                l = l[i.saturating_sub(1)..=(i + 1).min(l.len() - 1)].to_vec();
            }
            return (200, wrap(limited(l)));
        }
        if last == "Similar" {
            return (200, wrap(limited(self.ids(&self.list("similar", at(2))))));
        }
        if last == "SpecialFeatures" || last == "LocalTrailers" {
            let key = if last == "SpecialFeatures" {
                "extras"
            } else {
                "trailers"
            };
            return (
                200,
                Value::Array(self.ids(&self.list(key, at(2)))).to_string(),
            );
        }
        if last == "Items" && n >= 3 && at(3) == "Playlists" {
            return (200, wrap(limited(self.ids(&self.list("playlists", at(2))))));
        }
        if last == "Genres" {
            return (
                200,
                wrap(self.world["genres"].as_array().cloned().unwrap_or_default()),
            );
        }
        if last == "Items" {
            return (200, self.items(&q));
        }
        if n >= 2 && at(2) == "Items" {
            return match self.entry(last) {
                Some(e) => (200, e.to_string()),
                None => (404, String::new()),
            };
        }
        (200, wrap(Vec::new()))
    }

    fn list_of(&self, key: &str) -> Vec<String> {
        self.world[key]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default()
    }

    fn items(&self, q: &HashMap<String, String>) -> String {
        let mut pool: Vec<Value> = if let Some(want) = q.get("ids") {
            let set: HashSet<&str> = want.split(',').collect();
            self.catalog
                .iter()
                .filter(|e| set.contains(e["Id"].as_str().unwrap_or("")))
                .cloned()
                .collect()
        } else if let Some(p) = q.get("parentid") {
            let l = if q.get("recursive").is_some_and(|v| v == "true") {
                self.descendants(p)
            } else {
                self.list("children", p)
            };
            self.ids(&l)
        } else {
            self.catalog.clone()
        };
        if let Some(t) = q.get("includeitemtypes").filter(|t| !t.is_empty()) {
            let set: HashSet<&str> = t.split(',').collect();
            pool.retain(|e| set.contains(e["Type"].as_str().unwrap_or("")));
        }
        if let Some(term) = q.get("searchterm") {
            let term = term.to_lowercase();
            pool.retain(|e| {
                e["Name"]
                    .as_str()
                    .unwrap_or("")
                    .to_lowercase()
                    .contains(&term)
            });
        }
        for f in q
            .get("filters")
            .map(String::as_str)
            .unwrap_or("")
            .split(',')
        {
            match f {
                "IsFavorite" => {
                    pool.retain(|e| e["UserData"]["IsFavorite"].as_bool() == Some(true))
                }
                "IsPlayed" => pool.retain(Self::played),
                "IsUnplayed" => pool.retain(|e| !Self::played(e)),
                "IsResumable" => {
                    pool.retain(|e| {
                        e["UserData"]["PlaybackPositionTicks"].as_i64().unwrap_or(0) > 0
                    });
                }
                _ => {}
            }
        }
        if let Some(p) = q.get("isplayed") {
            let want = p == "true";
            pool.retain(|e| Self::played(e) == want);
        }
        if let Some(g) = q.get("genres") {
            let want: HashSet<&str> = g.split('|').collect();
            pool.retain(|e| {
                e["Genres"]
                    .as_array()
                    .is_some_and(|a| a.iter().any(|x| want.contains(x.as_str().unwrap_or(""))))
            });
        }
        if let Some(p) = q.get("personids") {
            let want: HashSet<&str> = p.split(',').collect();
            pool.retain(|e| {
                e["People"].as_array().is_some_and(|a| {
                    a.iter()
                        .any(|x| want.contains(x["Id"].as_str().unwrap_or("")))
                })
            });
        }
        let sort_by = q.get("sortby").map(String::as_str).unwrap_or("");
        let desc = q.get("sortorder").is_some_and(|s| s == "Descending");
        if ["SortName", "DateCreated", "ProductionYear,SortName"].contains(&sort_by) {
            let mut indexed: Vec<(usize, Value)> = pool.into_iter().enumerate().collect();
            indexed.sort_by(|a, b| {
                let c = if sort_by == "ProductionYear,SortName" {
                    let (ya, yb) = (Self::year(&a.1), Self::year(&b.1));
                    if (ya - yb).abs() > f64::EPSILON {
                        ya.partial_cmp(&yb).unwrap_or(Ordering::Equal)
                    } else {
                        Self::key(&a.1, "SortName")
                            .as_bytes()
                            .cmp(Self::key(&b.1, "SortName").as_bytes())
                    }
                } else {
                    Self::key(&a.1, sort_by)
                        .as_bytes()
                        .cmp(Self::key(&b.1, sort_by).as_bytes())
                };
                if c == Ordering::Equal {
                    a.0.cmp(&b.0)
                } else if desc {
                    c.reverse()
                } else {
                    c
                }
            });
            pool = indexed.into_iter().map(|(_, v)| v).collect();
        }
        let total = pool.len();
        let start = q
            .get("startindex")
            .and_then(|v| v.parse().ok())
            .unwrap_or(0usize);
        let mut pool: Vec<Value> = pool.into_iter().skip(start).collect();
        if let Some(n) = q.get("limit").and_then(|v| v.parse::<usize>().ok()) {
            pool.truncate(n);
        }
        json!({"Items": pool, "TotalRecordCount": total}).to_string()
    }
}

impl HttpTransport for World {
    fn send(
        &self,
        request: HttpRequest,
    ) -> impl Future<Output = Result<HttpResponse, ErrorKind>> + Send {
        let (status, body) = self.answer(&request);
        async move { Ok(HttpResponse::new(status, body)) }
    }
}

pub fn client(world: World) -> JellyfinClient<World> {
    let c =
        JellyfinClient::new(world, BASE, ClientConfig::new("dev", "Test", "1.0")).expect("client");
    c.set_session(Some(Session {
        access_token: "tok".into(),
        user_id: "u1".into(),
        user_name: "t".into(),
        server_url: BASE.into(),
        kind: ServerKind::Jellyfin,
    }));
    c
}
