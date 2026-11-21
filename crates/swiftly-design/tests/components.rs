//! The component catalogue in `design/tokens.json` must only name tokens that exist,
//! have one usage doc each, and be listed in `design/DESIGN.md`.

// Test helpers may panic on a broken fixture.
#![allow(clippy::expect_used, clippy::unwrap_used)]

use serde_json::Value;
use std::collections::HashSet;
use std::path::PathBuf;

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn load() -> Value {
    let text = std::fs::read_to_string(root().join("design/tokens.json")).expect("tokens.json");
    serde_json::from_str(&text).expect("valid json")
}

fn token_names(d: &Value) -> HashSet<String> {
    ["colors", "type", "layout", "motion", "shadows", "state"]
        .iter()
        .flat_map(|k| d[*k].as_array().into_iter().flatten())
        .filter_map(|t| t["name"].as_str().map(str::to_owned))
        .collect()
}

#[test]
fn every_component_token_exists() {
    let d = load();
    let names = token_names(&d);
    let comps = d["components"].as_array().expect("components array");
    assert!(!comps.is_empty(), "catalogue is empty");
    for c in comps {
        let cname = c["name"].as_str().expect("component name");
        for t in c["tokens"].as_object().expect("tokens object").keys() {
            assert!(names.contains(t), "{cname} uses unknown token {t}");
        }
    }
}

#[test]
fn every_component_has_unique_name_doc_and_platform_keys() {
    let d = load();
    let mut seen = HashSet::new();
    let design_md = std::fs::read_to_string(root().join("design/DESIGN.md")).expect("DESIGN.md");
    for c in d["components"].as_array().expect("components array") {
        let n = c["name"].as_str().expect("component name");
        assert!(seen.insert(n.to_owned()), "duplicate component {n}");
        for key in ["swift", "kotlin", "rust"] {
            assert!(c.get(key).is_some(), "{n} lacks the {key} key (use null)");
        }
        assert!(
            root().join(format!("design/components/{n}.md")).is_file(),
            "{n} has no usage doc"
        );
        assert!(
            design_md.contains(&format!("components/{n}.md")),
            "{n} is not listed in DESIGN.md"
        );
    }
}
