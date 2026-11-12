//! Plex requests (`PlexClient*.swift`, `PlexAccount.swift`, `PlexConnections.swift`, `PlexPlayback.swift`): the
//! requests the client sends and the URLs it builds. Cases are read by `Domain_RequestsPlex.swift` (Tools/Oracle)
//! and `tests/oracle_requests_plex.rs`. Every case names an `op`, a server `base`, a `token`, the device `ident`,
//! canned answers by path (`reply`) and the op's own parameters.
use crate::Rng;
use serde_json::{Map, Value, json};

const LISTING: &str = r#"{"MediaContainer":{"size":0}}"#;
const SECTIONS: &str = r#"{"MediaContainer":{"size":3,"Directory":[{"key":"1","type":"movie","title":"Filme"},{"key":"2","type":"show","title":"Serien"},{"key":"3","type":"artist","title":"Musik"}]}}"#;
const GENRES: &str = r#"{"MediaContainer":{"size":2,"Directory":[{"key":"11","title":"Action"},{"key":"12","title":"Drama"}]}}"#;
const PAGE: &str = r#"{"MediaContainer":{"size":2,"totalSize":5,"offset":0,"Metadata":[{"ratingKey":"101","type":"movie","title":"A","titleSort":"a","addedAt":5},{"ratingKey":"102","type":"movie","title":"B","titleSort":"b","addedAt":4}]}}"#;
const COLLECTIONS: &str = r#"{"MediaContainer":{"size":1,"Metadata":[{"ratingKey":"50","type":"collection","title":"C"}]}}"#;
const PLAYLISTS: &str = r#"{"MediaContainer":{"size":1,"Metadata":[{"ratingKey":"60","type":"playlist","playlistType":"video","title":"P"}]}}"#;
const EPISODES: &str = r#"{"MediaContainer":{"size":3,"Metadata":[{"ratingKey":"301","type":"episode","title":"E1","viewCount":1},{"ratingKey":"302","type":"episode","title":"E2","viewCount":1},{"ratingKey":"303","type":"episode","title":"E3"}]}}"#;

const BASES: [&str; 12] = [
    "http://plex.test:32400",
    "http://plex.test:32400/",
    "https://plex.test",
    "http://192.168.1.5:32400",
    "http://plex.test:32400//",
    "http://plex.test/prefix",
    "http://[::1]:32400",
    "https://plex.test:443",
    "http://plex.test:80",
    "http://PLEX.Test:32400",
    "http://plex.test:32400/sub/",
    "http://plex.test:32400/a%20b",
];
const TOKENS: [&str; 9] = [
    "tok",
    "",
    "a b",
    "ünï-tök",
    "t&k=1",
    "a+b",
    "x#y",
    "100%",
    "very-long-token-0123456789",
];
const IDS: [&str; 18] = [
    "1",
    "42",
    "",
    " ",
    "a b",
    "a/b",
    "a?b=c",
    "a#b",
    "a%20b",
    "a%",
    "ä ö ü",
    "日本語",
    "👨‍👩‍👧",
    "../x",
    "a&b=c",
    "a+b",
    ":",
    "1,2,3",
];
const TERMS: [&str; 16] = [
    "matrix",
    "",
    "  ",
    " x ",
    "tab\tx",
    "ünï",
    "日本",
    "a&b=c#d",
    "100%",
    "a+b",
    "x y",
    "😀",
    "\u{a0}x\u{a0}",
    "a\u{200b}b",
    "\u{85}x\u{2028}",
    "Ä",
];
const NAMES: [&str; 8] = [
    "dn",
    "Wohn\nzimmer",
    "TV \t 1",
    "",
    "Pauls iPhone 📱",
    "a\u{7f}b",
    "日本",
    "x\u{85}y",
];
const PATHS: [&str; 16] = [
    "/library/metadata/1/thumb/2",
    "/library/parts/9/1/file.mkv",
    "library/x",
    "",
    "/",
    "/a b/c",
    "/a?x=1",
    "/a#f",
    "/ä/日本",
    "/library/streams/5",
    "http://img.test/x.jpg",
    "https://img.test/a b.jpg",
    "/:/x",
    "/a%2Fb",
    "/a%zz",
    "//double",
];

fn long(rng: &mut Rng) -> String {
    "x".repeat(rng.range(500, 4000) as usize)
}

fn pick_id(rng: &mut Rng, wild: bool) -> String {
    if !wild {
        return rng.pick(&IDS[..2]).to_string();
    }
    if rng.chance(8) {
        return long(rng);
    }
    rng.pick(&IDS).to_string()
}

fn pick_num(rng: &mut Rng, wild: bool) -> i64 {
    if !wild {
        return *rng.pick(&[0, 1, 20, 50, 100]);
    }
    *rng.pick(&[
        0,
        1,
        2,
        7,
        20,
        24,
        40,
        50,
        99,
        100,
        101,
        250,
        1000,
        100_000,
        9_007_199_254_740_991,
        -1,
        -50,
    ])
}

fn opt_num(rng: &mut Rng, wild: bool) -> Value {
    if rng.chance(40) {
        Value::Null
    } else {
        json!(pick_num(rng, wild))
    }
}

fn opt_id(rng: &mut Rng, wild: bool) -> Value {
    if rng.chance(40) {
        Value::Null
    } else {
        json!(pick_id(rng, wild))
    }
}

fn term(rng: &mut Rng, wild: bool) -> String {
    if !wild {
        return "matrix".into();
    }
    if rng.chance(6) {
        return long(rng);
    }
    rng.pick(&TERMS).to_string()
}

fn ok(body: &str) -> Value {
    json!({ "status": 200, "body": body })
}

fn route(map: &mut Map<String, Value>, path: &str, body: &str) {
    map.insert(path.into(), ok(body));
}

/// The part key of a detail answer (what the player gets).
fn meta(part_key: &str, indexes: bool) -> String {
    let part = if indexes {
        json!({ "id": 21, "key": part_key, "container": "mkv", "indexes": "sd" })
    } else {
        json!({ "id": 21, "key": part_key, "container": "mkv" })
    };
    json!({ "MediaContainer": { "size": 1, "Metadata": [ {
        "ratingKey": "1", "type": "movie", "title": "T", "duration": 6_000_000,
        "Media": [ { "id": 11, "container": "mkv", "Part": [ part ] } ]
    } ] } })
    .to_string()
}

fn item_json(rng: &mut Rng) -> Value {
    let mut tags = Map::new();
    for k in ["Primary", "Logo", "Thumb"] {
        if rng.chance(60) {
            tags.insert(k.into(), json!(*rng.pick(&PATHS)));
        }
    }
    let mut item = json!({ "Id": "1", "Name": "n", "Type": "Movie", "ImageTags": tags });
    if rng.chance(60) {
        item["BackdropImageTags"] = json!([*rng.pick(&PATHS), "/b"]);
    }
    if rng.chance(40) {
        item["ParentBackdropImageTags"] = json!([*rng.pick(&PATHS)]);
    }
    item
}

/// Every operation with the number of cases it gets and whether its requests run concurrently (order not fixed).
const OPS: &[(&str, usize, bool)] = &[
    ("info", 12, false),
    ("token_works", 10, false),
    ("sections", 8, false),
    ("views", 8, false),
    ("list", 70, false),
    ("genres_section", 20, false),
    ("continue", 20, false),
    ("on_deck", 20, false),
    ("recent", 30, false),
    ("hubs", 20, false),
    ("search", 50, false),
    ("detail", 30, false),
    ("item", 12, false),
    ("children", 25, false),
    ("episodes", 30, false),
    ("similar", 30, false),
    ("collections", 20, false),
    ("collection_items", 20, false),
    ("playlists", 8, false),
    ("playlist_items", 20, false),
    ("titles", 40, false),
    ("watched", 40, false),
    ("favorite", 30, false),
    ("tracks", 40, false),
    ("plan", 40, false),
    ("download", 40, false),
    ("previews", 40, false),
    ("segments", 10, false),
    ("timeline", 70, false),
    ("report", 40, false),
    ("image_path", 80, false),
    ("image_item", 60, false),
    ("image_server", 20, false),
    ("sub_stream", 50, false),
    ("sub_path", 40, false),
    ("playback_url", 80, false),
    ("items", 120, true),
    ("genres_all", 10, true),
    ("last_added", 40, false),
    ("new_arrivals", 20, false),
    ("new_series", 25, true),
    ("latest_title", 30, true),
    ("playlist_dir", 10, true),
    ("playlist_entries", 15, false),
    ("collection_dir", 10, true),
    ("remembered", 30, true),
    ("title_person", 30, true),
    ("title_genre", 30, true),
    ("next_episode", 15, false),
    ("episode_post", 15, false),
    ("state_in_series", 15, false),
    ("refresh", 15, false),
    ("watchlist", 20, false),
    ("watched_ms", 20, false),
    ("point_back", 15, false),
    ("trickplay", 20, false),
    ("sheet", 15, false),
    ("chapter", 10, false),
    ("extras", 15, false),
    ("trailer", 15, false),
    ("similar_ms", 20, false),
    ("public_info", 10, false),
    ("applies", 10, false),
    ("signoff_sections", 6, false),
    ("pin_start", 20, false),
    ("pin_check", 30, false),
    ("auth_url", 40, false),
    ("link_page", 4, false),
    ("validate", 20, false),
    ("servers", 20, false),
    ("home_users", 15, false),
    ("switch_user", 40, false),
    ("probe", 30, false),
];

fn params(
    op: &str,
    rng: &mut Rng,
    wild: bool,
    reply: &mut Map<String, Value>,
) -> Map<String, Value> {
    let mut p = Map::new();
    let mut set = |k: &str, v: Value| {
        p.insert(k.into(), v);
    };
    let id = pick_id(rng, wild);
    let limit = pick_num(rng, wild);
    match op {
        "list" => {
            set("id", json!(id));
            set(
                "type",
                if rng.chance(30) {
                    Value::Null
                } else {
                    json!(
                        *rng.pick(&["Movie", "Series", "Season", "Episode", "Video", "", "movie"])
                    )
                },
            );
            set(
                "sort",
                json!(*rng.pick(&["name", "latest", "rating", "erscheinung"])),
            );
            set(
                "filter",
                json!(*rng.pick(&["all", "begun", "unwatched", "watchlist"])),
            );
            set(
                "genre",
                if rng.chance(50) {
                    Value::Null
                } else {
                    json!(pick_id(rng, wild))
                },
            );
            set("start", json!(pick_num(rng, wild)));
            set("size", json!(pick_num(rng, wild)));
        }
        "genres_section" | "collections" | "collection_items" | "playlist_items" | "detail"
        | "item" | "children" | "segments" | "chapter" | "refresh" | "point_back"
        | "playlist_entries" | "similar_ms" | "extras" | "trailer" => {
            set("id", json!(id));
            set("limit", json!(limit));
        }
        "continue" | "on_deck" => set("limit", json!(limit)),
        "recent" => {
            set("section", opt_id(rng, wild));
            set("limit", json!(limit));
        }
        "hubs" => set("section", opt_id(rng, wild)),
        "search" => {
            set("term", json!(term(rng, wild)));
            set("limit", json!(limit));
        }
        "episodes" => {
            set("id", json!(id));
            set("season", opt_id(rng, wild));
        }
        "similar" => {
            set("id", json!(id));
            set("limit", json!(limit));
        }
        "titles" => {
            set("id", json!(id));
            set(
                "filter",
                json!(*rng.pick(&["actor", "genre", "director", "a b", "ä", "x&y", ""])),
            );
            set("value", json!(term(rng, wild)));
            set("start", json!(pick_num(rng, wild)));
            set("size", json!(pick_num(rng, wild)));
        }
        "watched" | "favorite" | "watchlist" | "watched_ms" => {
            set("id", json!(id));
            set("on", json!(rng.chance(50)));
        }
        "tracks" => {
            set("part", json!(pick_num(rng, wild)));
            set("audio", opt_num(rng, wild));
            set("sub", opt_num(rng, wild));
        }
        "plan" | "download" | "previews" | "trickplay" | "sheet" => {
            set("id", json!(id));
            set(
                "source",
                if rng.chance(50) {
                    Value::Null
                } else {
                    json!(*rng.pick(&["11", "12", "11-2", "", "x y", "ä"]))
                },
            );
            set("audio", opt_num(rng, wild));
            set("sub", opt_num(rng, wild));
            set("sheet", json!(pick_num(rng, wild)));
            let key = if wild {
                *rng.pick(&PATHS)
            } else {
                "/library/parts/21/1/file.mkv"
            };
            let key = if rng.chance(5) {
                long(rng)
            } else {
                key.to_string()
            };
            route(
                reply,
                &format!("/library/metadata/{id}"),
                &meta(&key, rng.chance(70)),
            );
            reply.insert("default".into(), ok(&meta(&key, rng.chance(70))));
        }
        "timeline" => {
            set("id", json!(id));
            set(
                "state",
                json!(*rng.pick(&["playing", "paused", "buffering", "stopped"])),
            );
            set(
                "ticks",
                json!(*rng.pick(&[
                    0,
                    1,
                    9999,
                    10_000,
                    123_456_789,
                    36_000_000_000i64,
                    -5,
                    -10_000_000,
                    9_007_199_254_740_991i64
                ])),
            );
            set(
                "duration",
                if rng.chance(40) {
                    Value::Null
                } else {
                    json!(*rng.pick(&[0, -5, 1, 7_200_000, 9_007_199_254_740_991i64]))
                },
            );
        }
        "report" => {
            set("id", json!(id));
            set(
                "kind",
                json!(*rng.pick(&["start", "progress", "paused", "stopped"])),
            );
            set(
                "ticks",
                json!(*rng.pick(&[0, 1, 9999, 10_000, 123_456_789, 36_000_000_000i64, -5])),
            );
            reply.insert(
                "default".into(),
                ok(&meta("/library/parts/21/1/file.mkv", false)),
            );
        }
        "image_path" => {
            set("path", json!(rng.pick(&PATHS)));
            set("h", opt_num(rng, wild));
            set("w", opt_num(rng, wild));
        }
        "image_item" | "image_server" => {
            set("item", item_json(rng));
            set(
                "kind",
                json!(*rng.pick(&["poster", "background", "logo", "preview"])),
            );
            set("h", opt_num(rng, wild));
            set("w", opt_num(rng, wild));
        }
        "sub_stream" => {
            let mut s = json!({ "id": 7, "streamType": *rng.pick(&[1, 2, 3, 3, 3, 0, 4]) });
            if rng.chance(75) {
                s["key"] = json!(rng.pick(&PATHS));
            }
            set("stream", s);
        }
        "sub_path" => set("path", json!(rng.pick(&PATHS))),
        "playback_url" => {
            set("fn", json!(*rng.pick(&["url", "url", "file", "preview"])));
            set("path", json!(rng.pick(&PATHS)));
            let n = rng.below(4);
            let q: Vec<Value> = (0..n)
                .map(|_| json!([term(rng, wild), term(rng, wild)]))
                .collect();
            set("query", json!(q));
            set("with_token", json!(rng.chance(60)));
            set("download", json!(rng.chance(50)));
            set("part", json!(pick_num(rng, wild)));
        }
        "items" => {
            let parents = [
                Value::Null,
                json!("1"),
                json!("2"),
                json!("3"),
                json!("7"),
                json!("50"),
                json!(id),
            ];
            set("parent", rng.pick(&parents).clone());
            set("limit", json!(limit));
            set("start", json!(pick_num(rng, wild)));
            set(
                "sort_by",
                json!(*rng.pick(&[
                    "SortName",
                    "DateCreated",
                    "CommunityRating",
                    "PremiereDate",
                    "ProductionYear,SortName",
                    "Random",
                    "",
                    "Foo,,Bar",
                    "DateLastContentAdded,CommunityRating"
                ])),
            );
            set(
                "sort_order",
                json!(*rng.pick(&["Ascending", "Descending", "descending", "Desc", "", "x"])),
            );
            let filters: Vec<&str> = ["IsResumable", "IsFavorite", "Foo"]
                .into_iter()
                .filter(|_| rng.chance(40))
                .collect();
            set("filters", json!(filters));
            set(
                "watched",
                match rng.below(3) {
                    0 => Value::Null,
                    1 => json!(true),
                    _ => json!(false),
                },
            );
            set("recursive", json!(rng.chance(50)));
            let all = [
                "Movie", "Series", "Season", "Episode", "Video", "Audio", "BoxSet",
            ];
            let types: Vec<&str> = all.into_iter().filter(|_| rng.chance(25)).collect();
            set("types", json!(types));
            let ids: Vec<String> = if rng.chance(12) {
                (0..rng.range(1, 230)).map(|n| format!("{n}")).collect()
            } else {
                vec![]
            };
            set("ids", json!(ids));
            let persons: Vec<String> = if rng.chance(20) {
                (0..rng.range(1, 4)).map(|_| pick_id(rng, wild)).collect()
            } else {
                vec![]
            };
            set("persons", json!(persons));
            let genres: Vec<&str> = ["action", "DRAMA", "Ä", "nope", "Drama"]
                .into_iter()
                .filter(|_| rng.chance(25))
                .collect();
            set("genres", json!(genres));
            route(reply, "/library/sections", SECTIONS);
            route(reply, "/library/sections/1/genre", GENRES);
            route(reply, "/library/sections/2/genre", GENRES);
            route(reply, "/library/sections/1/all", PAGE);
            route(reply, "/library/sections/2/all", PAGE);
            route(
                reply,
                "/library/metadata/7",
                r#"{"MediaContainer":{"Metadata":[{"ratingKey":"7","type":"show","title":"S"}]}}"#,
            );
            route(
                reply,
                "/library/metadata/50",
                r#"{"MediaContainer":{"Metadata":[{"ratingKey":"50","type":"collection","title":"C"}]}}"#,
            );
            route(reply, "/library/metadata/7/children", EPISODES);
            route(reply, "/library/collections/50/children", EPISODES);
        }
        "genres_all" | "last_added" | "new_arrivals" | "new_series" | "latest_title"
        | "playlist_dir" | "collection_dir" | "remembered" | "title_person" | "title_genre" => {
            set("library", opt_id(rng, wild));
            if rng.chance(60) {
                set("library", json!(*rng.pick(&["1", "2", "3", "9"])));
            }
            set("id", json!(*rng.pick(&["1", "2", "3", "9", "50"])));
            set("fetch", json!(pick_num(rng, wild)));
            set("show", json!(pick_num(rng, wild)));
            set("limit", json!(limit));
            set("start", json!(pick_num(rng, wild)));
            set("collection", json!(rng.chance(50)));
            set(
                "genres",
                json!(*rng.pick(&[
                    "Movie,Episode",
                    "Movie",
                    "Episode",
                    "Series",
                    "Foo",
                    "",
                    "Episode,Movie,Movie",
                    "Movie,"
                ])),
            );
            if op == "title_genre" {
                set(
                    "id",
                    json!(*rng.pick(&["Action", "drama", "Ä", "a b", "x&y", "Nope"])),
                );
            }
            set("types", json!(["Movie"]));
            set("sort_by", json!(*rng.pick(&["DateCreated", "SortName"])));
            set("sort_order", json!("Descending"));
            route(reply, "/library/sections", SECTIONS);
            route(reply, "/library/sections/1/genre", GENRES);
            route(reply, "/library/sections/2/genre", GENRES);
            route(reply, "/library/sections/3/genre", GENRES);
            route(reply, "/library/sections/1/collections", COLLECTIONS);
            route(reply, "/library/sections/2/collections", COLLECTIONS);
            route(reply, "/library/sections/1/all", PAGE);
            route(reply, "/library/sections/2/all", PAGE);
            route(reply, "/library/sections/1/recentlyAdded", PAGE);
            route(reply, "/library/sections/2/recentlyAdded", PAGE);
            route(reply, "/library/collections/50/children", EPISODES);
            route(reply, "/playlists", PLAYLISTS);
            route(reply, "/playlists/60/items", EPISODES);
        }
        "next_episode" | "state_in_series" => {
            set("id", json!(id));
            route(
                reply,
                &format!("/library/metadata/{id}/allLeaves"),
                EPISODES,
            );
        }
        "episode_post" => {
            set("id", json!(id));
            set("item_id", json!(*rng.pick(&["301", "302", "303", "nope"])));
            route(
                reply,
                &format!("/library/metadata/{id}/allLeaves"),
                EPISODES,
            );
        }
        "pin_start" => set("strong", json!(rng.chance(50))),
        "pin_check" => {
            set(
                "pin_id",
                json!(*rng.pick(&[0, 1, 12345, -1, 9_007_199_254_740_991i64])),
            );
            set("code", json!(term(rng, wild)));
        }
        "auth_url" => {
            set("code", json!(term(rng, wild)));
            set(
                "forward",
                if rng.chance(50) {
                    Value::Null
                } else {
                    json!(*rng.pick(&["swiftly://done", "http://a.test", "https://x.test/a&b=c"]))
                },
            );
        }
        "validate" | "servers" | "home_users" => set("token2", json!(rng.pick(&TOKENS))),
        "switch_user" => {
            set(
                "uuid",
                json!(*rng.pick(&["abc-123", "a b", "a/b", "a?b", "ä", "日本", "x%y", ""])),
            );
            set(
                "pin",
                if rng.chance(40) {
                    Value::Null
                } else {
                    json!(*rng.pick(&["1234", "", "a&b=c", "ä ö", "12 34", "+1", "%"]))
                },
            );
            set("token2", json!(rng.pick(&TOKENS)));
        }
        "probe" => {
            set("machine", json!(*rng.pick(&["m", "", "ä"])));
            set("timeout", json!(*rng.pick(&[1, 3, 6, 10])));
            let body = if rng.chance(60) {
                r#"{"MediaContainer":{"machineIdentifier":"m"}}"#
            } else {
                LISTING
            };
            reply.insert(
                "default".into(),
                json!({ "status": *rng.pick(&[200, 200, 401, 500]), "body": body }),
            );
        }
        _ => {}
    }
    // Swift slices (`dropFirst`/`prefix`) and merges pages in memory for these: a negative count traps there and the app
    // never asks for one, so only plausible sizes are compared.
    if matches!(
        op,
        "items"
            | "genres_all"
            | "last_added"
            | "new_arrivals"
            | "new_series"
            | "latest_title"
            | "remembered"
            | "title_person"
            | "title_genre"
    ) {
        for k in ["limit", "start", "fetch", "show"] {
            if let Some(n) = p.get(k).and_then(Value::as_i64) {
                p.insert(k.into(), json!(n.clamp(0, 100_000)));
            }
        }
    }
    p
}

pub fn requests_plex() -> Vec<Value> {
    let mut rng = Rng::new(0x504c_4558);
    let mut out = Vec::new();
    for &(op, count, sorted) in OPS {
        for n in 0..count {
            let wild = n >= 4;
            let mut reply = Map::new();
            reply.insert("default".into(), ok(LISTING));
            let mut case = params(op, &mut rng, wild, &mut reply);
            // Hostile devices and servers only after the plain ones.
            let ident = if wild {
                json!({
                    "client": if rng.chance(30) { json!(long(&mut rng)) } else { json!(*rng.pick(&["cid", "", "a b", "ünï", "x&y=z", "日本"])) },
                    "product": *rng.pick(&["Swiftly Player", "Swiftly", "", "Pröduct"]),
                    "version": *rng.pick(&["1.0", "26.11.1", "", "1 0", "v+1"]),
                    "platform": *rng.pick(&["iOS", "tvOS", "macOS", "Android", "Linux", "Windows", ""]),
                    "platform_version": if rng.chance(50) { Value::Null } else { json!(*rng.pick(&["26.1", "", "ü"])) },
                    "device": *rng.pick(&["iOS", "iPhone15,2", "", "x y"]),
                    "device_name": *rng.pick(&NAMES),
                })
            } else {
                json!({})
            };
            let status = if wild && rng.chance(20) {
                *rng.pick(&[401, 404, 500, 503, 204, 301, 410])
            } else {
                200
            };
            if status != 200 && !matches!(op, "probe") {
                let default = reply.get("default").cloned().unwrap_or_else(|| ok(LISTING));
                reply.insert(
                    "default".into(),
                    json!({ "status": status, "body": default["body"] }),
                );
            }
            let mut reply_value =
                json!({ "default": reply.get("default").cloned().unwrap_or_else(|| ok(LISTING)) });
            let routes: Map<String, Value> =
                reply.into_iter().filter(|(k, _)| k != "default").collect();
            reply_value["routes"] = Value::Object(routes);
            if wild && rng.chance(8) {
                reply_value["net"] = json!(*rng.pick(&[-1009, -1001, -1202, -1004]));
            }
            case.insert("op".into(), json!(op));
            case.insert("sorted".into(), json!(sorted));
            case.insert(
                "base".into(),
                json!(if wild { *rng.pick(&BASES) } else { BASES[0] }),
            );
            case.insert(
                "token".into(),
                json!(if wild { *rng.pick(&TOKENS) } else { "tok" }),
            );
            case.insert("ident".into(), ident);
            case.insert("reply".into(), reply_value);
            out.push(Value::Object(case));
        }
    }
    out
}
