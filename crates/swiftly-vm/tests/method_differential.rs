//! Every client method the screens use, on one recorded world, against the golden the real Swift
//! code produced (`MethodDifferentialTests.swift`). The router is the twin of the Swift one
//! (`../../swiftly-library/tests/common/world.rs`). Where the Rust screens compose several calls
//! (search, similar, filmography), the same composition is repeated here from the VM code.
#![allow(clippy::expect_used, clippy::unwrap_used)]

#[path = "../../swiftly-library/tests/common/world.rs"]
mod world;

use std::collections::HashMap;

use futures_executor::block_on;
use serde_json::{Value, json};
use swiftly_jellyfin::ItemsQuery;
use swiftly_library::ListRules;
use swiftly_library::client_ext::{
    collection_directory, items_in_times, library_shares, natural_list, natural_page,
    playlist_directory, playlist_entries_video, remembered_items, state_in_series_checked,
    title_genre, title_genre_page, title_person_page,
};
use swiftly_model::{Item, Items, ItemsResponse};
use swiftly_rules::natural_order::{NaturalCollator, NaturalOrder};

fn num(d: Option<f64>) -> String {
    match d {
        None => "-".into(),
        Some(d) if d == d.round() && d.abs() < 1e15 => format!("{}", d as i64),
        Some(d) => format!("{d}"),
    }
}

fn opt<T: ToString>(v: &Option<T>) -> String {
    v.as_ref().map_or("-".into(), ToString::to_string)
}

fn sig(i: &Item) -> String {
    let u = i.user_data.as_ref();
    let mut ids: Vec<String> = i
        .provider_ids
        .iter()
        .flatten()
        .map(|(k, v)| format!("{k}={v}"))
        .collect();
    ids.sort();
    let fields = [
        i.id.clone(),
        i.name.clone(),
        i.type_.clone().unwrap_or("-".into()),
        opt(&i.production_year),
        opt(&i.run_time_ticks),
        opt(&i.index_number),
        opt(&i.parent_index_number),
        i.sort_name.clone().unwrap_or("-".into()),
        u.and_then(|u| u.played)
            .map_or("-", |p| if p { "P" } else { "u" })
            .into(),
        u.and_then(|u| u.is_favorite)
            .map_or("-", |p| if p { "F" } else { "n" })
            .into(),
        num(u.and_then(|u| u.played_percentage)),
        opt(&u.and_then(|u| u.playback_position_ticks)),
        num(i.community_rating),
        opt(&i.child_count),
        i.genres.clone().unwrap_or_default().join(";"),
        ids.join(";"),
        i.series_id.clone().unwrap_or("-".into()),
        i.season_id.clone().unwrap_or("-".into()),
    ];
    fields.join("|")
}

fn sigs(l: &[Item]) -> Value {
    json!(l.iter().map(sig).collect::<Vec<_>>())
}

fn page(r: &ItemsResponse) -> Value {
    json!({"items": sigs(&r.items), "total": r.total_record_count})
}

fn res<T>(r: Result<T, swiftly_net::ErrorKind>, f: impl FnOnce(T) -> Value) -> Value {
    r.map_or(json!("ERR"), f)
}

fn opt_item(r: Result<Option<Item>, swiftly_net::ErrorKind>) -> Value {
    res(r, |o| o.map_or(json!("NIL"), |i| json!(sig(&i))))
}

fn q() -> ItemsQuery {
    ItemsQuery::default()
}

fn strs(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| (*s).into()).collect()
}

fn with_total(x: Option<(Vec<Item>, i64)>) -> Value {
    x.map_or(
        json!("NIL"),
        |(i, t)| json!({"items": sigs(&i), "total": t}),
    )
}

#[test]
fn every_client_method_equals_the_swift_golden() {
    let golden: Value = serde_json::from_slice(
        &std::fs::read(world::dir().join("golden/method_diff/swift_expected.json"))
            .expect("golden"),
    )
    .expect("json");
    let w = world::World::load();
    let catalog = w.catalog().to_vec();
    let c = world::client(w);
    let collator =
        NaturalCollator::new(golden["locale"].as_str().unwrap_or("en")).expect("collator");
    let mut r = serde_json::Map::new();
    r.insert("locale".into(), golden["locale"].clone());
    let mut put = |k: &str, v: Value| {
        r.insert(k.into(), v);
    };

    block_on(async {
        put("views", res(c.user_views(false).await, |v| sigs(&v)));
        put("views_hidden", res(c.user_views(true).await, |v| sigs(&v)));

        for (n, start) in [0, 7, 14, 21, 28, 35, 100].into_iter().enumerate() {
            put(
                &format!("page_movies_{n}"),
                res(
                    c.items(&ItemsQuery {
                        parent_id: Some("L-MOV".into()),
                        limit: 7,
                        start_index: start,
                        recursive: true,
                        include_item_types: strs(&["Movie"]),
                        ..q()
                    })
                    .await,
                    |r| page(&r),
                ),
            );
        }
        let movies = |extra: ItemsQuery| ItemsQuery {
            parent_id: Some("L-MOV".into()),
            recursive: true,
            include_item_types: strs(&["Movie"]),
            ..extra
        };
        put(
            "page_desc_created",
            res(
                c.items(&movies(ItemsQuery {
                    limit: 10,
                    sort_by: "DateCreated".into(),
                    sort_order: "Descending".into(),
                    ..q()
                }))
                .await,
                |r| page(&r),
            ),
        );
        put(
            "page_unwatched",
            res(
                c.items(&movies(ItemsQuery {
                    limit: 50,
                    is_watched: Some(false),
                    ..q()
                }))
                .await,
                |r| page(&r),
            ),
        );
        put(
            "page_watched",
            res(
                c.items(&movies(ItemsQuery {
                    limit: 50,
                    is_watched: Some(true),
                    ..q()
                }))
                .await,
                |r| page(&r),
            ),
        );
        put(
            "page_favorites",
            res(
                c.items(&ItemsQuery {
                    limit: 50,
                    filters: strs(&["IsFavorite"]),
                    recursive: true,
                    include_item_types: strs(&["Movie", "Series"]),
                    ..q()
                })
                .await,
                |r| page(&r),
            ),
        );
        put(
            "page_resumable",
            res(
                c.items(&ItemsQuery {
                    limit: 50,
                    filters: strs(&["IsResumable"]),
                    recursive: true,
                    include_item_types: strs(&["Movie"]),
                    ..q()
                })
                .await,
                |r| page(&r),
            ),
        );
        put(
            "page_series",
            res(
                c.items(&ItemsQuery {
                    parent_id: Some("L-TV".into()),
                    limit: 50,
                    recursive: true,
                    include_item_types: strs(&["Series"]),
                    ..q()
                })
                .await,
                |r| page(&r),
            ),
        );
        put(
            "page_series_nonrec",
            res(
                c.items(&ItemsQuery {
                    parent_id: Some("L-TV".into()),
                    limit: 50,
                    ..q()
                })
                .await,
                |r| page(&r),
            ),
        );
        put(
            "page_genre_comma",
            res(
                c.items(&ItemsQuery {
                    limit: 50,
                    recursive: true,
                    include_item_types: strs(&["Movie", "Series"]),
                    genres: strs(&["Action,Adventure"]),
                    ..q()
                })
                .await,
                |r| page(&r),
            ),
        );
        put(
            "page_person",
            res(
                c.items(&ItemsQuery {
                    limit: 50,
                    sort_by: "ProductionYear,SortName".into(),
                    sort_order: "Descending".into(),
                    recursive: true,
                    include_item_types: strs(&["Movie", "Series"]),
                    person_ids: strs(&["p1"]),
                    ..q()
                })
                .await,
                |r| page(&r),
            ),
        );
        put(
            "page_slim",
            res(
                c.items(&movies(ItemsQuery {
                    limit: 3,
                    slim: true,
                    ..q()
                }))
                .await,
                |r| page(&r),
            ),
        );
        put(
            "page_ids",
            res(
                c.items(&ItemsQuery {
                    limit: 5,
                    ids: strs(&[
                        "m05", "w01", "w02", "w03", "w04", "w05", "w06", "w07", "w08", "nope",
                    ]),
                    ..q()
                })
                .await,
                |r| page(&r),
            ),
        );
        put(
            "count_movies",
            res(c.count("L-MOV", &strs(&["Movie"])).await, |n| json!(n)),
        );
        put(
            "count_mix_series",
            res(c.count("L-MIX", &strs(&["Series"])).await, |n| json!(n)),
        );
        put(
            "title_ids",
            res(
                c.title_ids("L-MOV", &strs(&["Movie"]), &strs(&["IsFavorite"]), None)
                    .await,
                |v| sigs(&v),
            ),
        );
        put(
            "title_ids_unwatched",
            res(
                c.title_ids("L-MOV", &strs(&["Movie"]), &[], Some(false))
                    .await,
                |v| sigs(&v),
            ),
        );
        put(
            "identifiers",
            res(
                c.identifiers(&strs(&["s0", "s1", "m00b", "w05"])).await,
                |v| sigs(&v),
            ),
        );
        put("ancestors", res(c.ancestors("m00b").await, |v| sigs(&v)));

        // natural order
        let list = |order: &'static str, filters: &'static [&'static str]| {
            let (c, collator) = (&c, &collator);
            async move {
                natural_list(
                    c,
                    collator,
                    Some("L-MOV"),
                    order,
                    &strs(filters),
                    None,
                    true,
                    &["Movie"],
                )
                .await
            }
        };
        put(
            "natural_list",
            res(list("Ascending", &[]).await, |v| sigs(&v)),
        );
        put(
            "natural_list_desc",
            res(list("Descending", &["IsFavorite"]).await, |v| sigs(&v)),
        );
        let all = list("Ascending", &[]).await.unwrap_or_default();
        let mut pages = Vec::new();
        for (since, count) in [(0, 6), (6, 9), (28, 100), (500, 10)] {
            pages.push(
                natural_page(&c, &all, since, count)
                    .await
                    .map_or(json!("ERR"), |r| page(&r)),
            );
        }
        put("natural_pages", json!(pages));

        // search as the search screen composes it
        for term in ["a", "x-men", "the", "ice", "", "zzz", "wire"] {
            let hits = match c.search(term, 40).await {
                Ok(main) => {
                    let works = items_in_times(&c, &main, false, None).await;
                    sigs(&NaturalOrder::sorted(works, &collator, |i| {
                        (i.name.as_str(), i.sort_name.as_deref())
                    }))
                }
                Err(_) => json!("ERR"),
            };
            put(&format!("search_{term}"), hits);
        }
        let main = c.search("e", 3).await.unwrap_or_default();
        let works = items_in_times(&c, &main, false, None).await;
        put(
            "search_limit3",
            sigs(&NaturalOrder::sorted(works, &collator, |i| {
                (i.name.as_str(), i.sort_name.as_deref())
            })),
        );

        // series
        put("seasons_s0", res(c.seasons("s0").await, |v| sigs(&v)));
        put("seasons_none", res(c.seasons("nope").await, |v| sigs(&v)));
        put(
            "episodes_s1",
            res(c.episodes("s1", None).await, |v| sigs(&v)),
        );
        put(
            "episodes_s1_season2",
            res(c.episodes("s1", Some("s1-2")).await, |v| sigs(&v)),
        );
        put(
            "episodes_s1_specials",
            res(c.episodes("s1", Some("s1-0")).await, |v| sigs(&v)),
        );
        put("first_episode", opt_item(c.first_episode("s0").await));
        put(
            "first_episode_none",
            opt_item(c.first_episode("nope").await),
        );
        put("next_s0", opt_item(c.next_episode_series("s0").await));
        put("next_s1", opt_item(c.next_episode_series("s1").await));
        put("post_mid", opt_item(c.episode_post("s1-2-3", "s1").await));
        put(
            "post_s2e10",
            opt_item(c.episode_post("s1-2-10", "s1").await),
        );
        put("post_last", opt_item(c.episode_post("s1-2-11", "s1").await));
        put("post_unknown", opt_item(c.episode_post("zz", "s1").await));
        put(
            "state_s0",
            opt_item(state_in_series_checked(&c, "s0").await),
        );
        put(
            "state_s1",
            opt_item(state_in_series_checked(&c, "s1").await),
        );
        put(
            "state_none",
            opt_item(state_in_series_checked(&c, "nope").await),
        );
        let raw = c.resume_items(20).await;
        put(
            "resume",
            match raw {
                Ok(raw) => sigs(&items_in_times(&c, &raw, false, None).await),
                Err(_) => json!("ERR"),
            },
        );
        let raw = c.next_up(20).await;
        put(
            "next_up",
            match raw {
                Ok(raw) => sigs(&items_in_times(&c, &raw, false, None).await),
                Err(_) => json!("ERR"),
            },
        );

        // similar: raw answer, then the VM's `similar_cleaned`
        let cleaned = |raw: &[Item], own: Option<&Item>, id: &str, limit: usize| -> Vec<Item> {
            let own_key = own.map(ListRules::title_key);
            let rest: Vec<Item> = raw
                .iter()
                .filter(|i| i.id != id && Some(ListRules::title_key(i)) != own_key)
                .cloned()
                .collect();
            ListRules::je_title_in_times(&rest, limit)
        };
        let own = c.item("m00").await.ok();
        let raw = c.similar("m00", 12).await.unwrap_or_default();
        put("similar_m00", sigs(&cleaned(&raw, own.as_ref(), "m00", 12)));
        let raw = c.similar("m00", 3).await.unwrap_or_default();
        put("similar_m00_plain", sigs(&cleaned(&raw, None, "m00", 3)));
        let own = c.item("s0").await.ok();
        let raw = c.similar("s0", 12).await.unwrap_or_default();
        put("similar_s0", sigs(&cleaned(&raw, own.as_ref(), "s0", 12)));
        put("extras", res(c.extras("m00").await, |v| sigs(&v)));
        put("trailers", res(c.trailers("m00").await, |v| sigs(&v)));

        // collections, playlists
        put(
            "collection_members",
            res(c.collection_members("bs1").await, |v| sigs(&v)),
        );
        put(
            "collection_directory",
            match c.user_views(false).await {
                Ok(views) => res(collection_directory(&c, &views).await, |d| {
                    json!(
                        d.all
                            .iter()
                            .map(|x| {
                                let mut m: Vec<_> = x.movies.iter().cloned().collect();
                                let mut s: Vec<_> = x.series_list.iter().cloned().collect();
                                m.sort();
                                s.sort();
                                json!([x.item.id, m, s])
                            })
                            .collect::<Vec<_>>()
                    )
                }),
                Err(_) => json!("ERR"),
            },
        );
        put(
            "playlist_entries",
            res(playlist_entries_video(&c, "pl1", false).await, |v| sigs(&v)),
        );
        put(
            "playlist_entries_lean",
            res(playlist_entries_video(&c, "pl1", true).await, |v| sigs(&v)),
        );
        put(
            "playlist_entries_audio",
            res(playlist_entries_video(&c, "pl2", false).await, |v| sigs(&v)),
        );
        put(
            "playlist_directory",
            res(playlist_directory(&c).await, |d| {
                json!(
                    d.all
                        .iter()
                        .map(|p| json!([p.item.id, p.movies, p.episodes]))
                        .collect::<Vec<_>>()
                )
            }),
        );
        let views = c.user_views(false).await.unwrap_or_default();
        let shares = library_shares(&c, &views).await;
        put(
            "library_shares",
            json!(
                shares
                    .iter()
                    .map(|(k, v)| (k.clone(), json!([v.movies, v.series_list])))
                    .collect::<serde_json::Map<_, _>>()
            ),
        );

        // genres, people
        put("genres", res(c.genres().await, |v| json!(v)));
        put(
            "title_genre",
            title_genre(&c, "Action", 24)
                .await
                .map_or(json!("NIL"), |x| sigs(&x)),
        );
        put(
            "title_genre_comma",
            title_genre(&c, "Action,Adventure", 24)
                .await
                .map_or(json!("NIL"), |x| sigs(&x)),
        );
        // `title(person:)` has no cinema-times merge: each work once, nothing more
        let person = c
            .items(&ItemsQuery {
                limit: 60,
                sort_by: "ProductionYear,SortName".into(),
                sort_order: "Descending".into(),
                recursive: true,
                include_item_types: strs(&["Movie", "Series"]),
                person_ids: strs(&["p1"]),
                ..q()
            })
            .await;
        put(
            "title_person",
            person.map_or(json!("NIL"), |a| sigs(&ListRules::without_double(&a.items))),
        );
        for (n, start) in [0, 5, 10].into_iter().enumerate() {
            put(
                &format!("title_person_n{n}"),
                with_total(title_person_page(&c, "p1", 5, start).await),
            );
            put(
                &format!("title_genre_n{n}"),
                with_total(title_genre_page(&c, "Action", 5, start).await),
            );
        }

        // watchlist, duplicates, version merging
        put(
            "remembered_ids",
            res(
                c.remembered_ids(&strs(&["Movie", "Series"]), "SortName", "Ascending")
                    .await,
                |v| sigs(&v),
            ),
        );
        for (n, start) in [0, 3, 6, 40].into_iter().enumerate() {
            put(
                &format!("remembered_{n}"),
                res(
                    remembered_items(
                        &c,
                        &strs(&["Movie", "Series"]),
                        "SortName",
                        "Ascending",
                        start,
                        3,
                        None,
                    )
                    .await,
                    |r| page(&r),
                ),
            );
        }
        let everything: Vec<Item> = catalog
            .iter()
            .filter_map(|v| serde_json::from_value::<Item>(v.clone()).ok())
            .collect();
        put(
            "decoded_ids",
            json!(everything.iter().map(|i| i.id.clone()).collect::<Vec<_>>()),
        );
        for per in [false, true] {
            put(
                &format!("in_times_{per}"),
                sigs(&items_in_times(&c, &everything, per, None).await),
            );
            let movies: Vec<Item> = everything
                .iter()
                .filter(|i| i.type_.as_deref() == Some("Movie"))
                .cloned()
                .collect();
            put(
                &format!("in_times_movies_{per}"),
                sigs(&items_in_times(&c, &movies, per, None).await),
            );
            let eps: Vec<Item> = everything
                .iter()
                .filter(|i| i.type_.as_deref() == Some("Episode"))
                .cloned()
                .collect();
            put(
                &format!("in_times_episodes_{per}"),
                sigs(&items_in_times(&c, &eps, per, None).await),
            );
        }
        put(
            "without_double",
            sigs(&ListRules::without_double(&everything)),
        );
        put(
            "title_in_times",
            sigs(&ListRules::je_title_in_times(&everything, 40)),
        );
        let eps: Vec<Item> = everything
            .iter()
            .filter(|i| i.type_.as_deref() == Some("Episode"))
            .cloned()
            .collect();
        put(
            "series_in_times",
            sigs(&ListRules::je_series_in_times(&eps)),
        );
        put(
            "with_double_ep",
            sigs(&Items::with_double(&everything, &HashMap::new(), true)),
        );
        put(
            "with_double_ep_false",
            sigs(&Items::with_double(&everything, &HashMap::new(), false)),
        );
    });

    let got = Value::Object(r);
    let mut wrong = Vec::new();
    for (k, want) in golden.as_object().unwrap() {
        if got.get(k) != Some(want) {
            wrong.push(k.clone());
        }
    }
    for k in got.as_object().unwrap().keys() {
        if golden.get(k).is_none() {
            wrong.push(format!("{k} (not in golden)"));
        }
    }
    if !wrong.is_empty() {
        let mut detail = String::new();
        for k in &wrong {
            let k = k.trim_end_matches(" (not in golden)");
            detail += &format!("\n== {k}\n swift: {}\n rust:  {}\n", golden[k], got[k]);
        }
        panic!("{} methods differ: {:?}{}", wrong.len(), wrong, detail);
    }
}
