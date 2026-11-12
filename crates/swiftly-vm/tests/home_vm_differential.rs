//! The home view model (the layer the Swift app now reads: `RustHomeFeed.rails(of:)` and
//! `HomePageModel.adoptRust`) over the recorded server whose Swift rails are the golden
//! (`HomeDifferentialTests.swift`). The loader level is pinned by `swiftly-library`; this pins the
//! tiles the screen gets: the same ids in the same order per rail, the window plus the rest fetched
//! with `tiles(rail, from, count)` the way the adapter does, no tile twice, ids equal tile ids.
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;
#[path = "../../swiftly-library/tests/common/mod.rs"]
mod recorded;

use std::sync::Arc;

use common::{Manual, Pool, pool};
use serde_json::{Value, json};
use swiftly_l10n::Locale;
use swiftly_library::MemoryStore;
use swiftly_vm::{HomeIntent, HomePrefs, HomeVm, Host, RailKind, Status};

fn run(mode: &'static str) -> (Value, Vec<String>) {
    let host = Host {
        spawner: Arc::new(Pool(pool())),
        clock: Manual::at(1000.0),
        store: Arc::new(MemoryStore::new()),
        locale: Locale::parse("de"),
        device_name: "Test".into(),
        client_version: "0.0.0".into(),
        cache: None,
    };
    let vm = HomeVm::new(
        Arc::new(recorded::Recorded::new(mode)),
        host,
        HomePrefs::default(),
        Some(swiftly_vm::AccountRef {
            base_url: recorded::BASE.into(),
            user_id: "u1".into(),
            token: "tok".into(),
            server_kind: swiftly_jellyfin::ServerKind::Jellyfin,
            device_id: "dev".into(),
            plex_machine_id: None,
            plex_account_token: None,
        }),
    )
    .unwrap();
    vm.send(HomeIntent::Load);
    for _ in 0..5000 {
        let s = vm.status();
        if matches!(s.status, Status::Ready | Status::Offline) && !s.preview && !s.refreshing {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(2));
    }
    let mut out = json!({"continue": [], "next": [], "recent": []});
    let mut problems = Vec::new();
    for rail in &vm.rails().rails {
        // What `RustHomeFeed.rails(of:)` does: the window, then the rest by `tiles(...)`.
        let mut tiles = rail.tiles.clone();
        let rest = rail.ids.len().saturating_sub(tiles.len());
        if rest > 0 {
            tiles.extend(vm.tiles(&rail.id, tiles.len(), rest));
        }
        let ids: Vec<String> = tiles.iter().map(|t| t.id.clone()).collect();
        if ids != rail.ids {
            problems.push(format!(
                "{mode}/{}: tile ids {ids:?} differ from rail ids {:?}",
                rail.id, rail.ids
            ));
        }
        let mut seen = std::collections::HashSet::new();
        if !ids.iter().all(|i| seen.insert(i.clone())) {
            problems.push(format!("{mode}/{}: a tile twice", rail.id));
        }
        let key = match rail.kind {
            RailKind::ContinueWatching => "continue",
            RailKind::NextEpisode => "next",
            RailKind::NewArrivals => "recent",
            _ => continue,
        };
        out[key] = json!(ids);
    }
    out["disrupted"] = json!(vm.status().status == Status::Offline);
    (out, problems)
}

#[test]
fn the_tiles_of_the_home_rails_equal_the_swift_rails() {
    let golden: Value = serde_json::from_slice(
        &std::fs::read(recorded::dir().join("golden/home_diff/swift_expected.json")).unwrap(),
    )
    .unwrap();
    let mut wrong = Vec::new();
    // `ok` is the one that matters for the screen; the broken modes follow the loader level.
    for mode in ["ok", "ids_fail", "ancestors_fail"] {
        let (got, problems) = run(mode);
        wrong.extend(problems);
        for key in ["continue", "next", "recent"] {
            if got[key] != golden[mode][key] {
                wrong.push(format!(
                    "{mode}/{key}: rust {} swift {}",
                    got[key], golden[mode][key]
                ));
            }
        }
    }
    assert!(wrong.is_empty(), "{}", wrong.join("\n"));
}
