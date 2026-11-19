//! Every finding id pinned in `oracle/known.json` is listed in `tests/data/known_findings.md`, so a pinned
//! difference always has a written cause (the image selection once pinned `F-oracle-D04-is-a` while the document
//! called the same finding `F-oracle-D05-is-a`).

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

use swiftly_hardening::oracle;

/// Does `doc` name `id` as a whole id (`F-oracle-D04` is not a mention of `F-oracle-D04-is-a`)?
fn mentions(doc: &str, id: &str) -> bool {
    doc.match_indices(id).any(|(at, _)| {
        doc[at + id.len()..]
            .chars()
            .next()
            .is_none_or(|next| !(next.is_alphanumeric() || next == '-'))
    })
}

#[test]
fn mention_needs_the_whole_id() {
    let doc = "- F-oracle-D04 | a\n- F-oracle-L01 | text about F-oracle-L01b, more\n";
    assert!(mentions(doc, "F-oracle-D04"));
    assert!(mentions(doc, "F-oracle-L01b"));
    assert!(!mentions(doc, "F-oracle-D04-is-a"));
    assert!(!mentions(doc, "F-oracle-L0"));
}

#[test]
fn every_pinned_finding_id_is_in_the_findings_list() {
    let known = oracle::read("known.json").expect("known.json");
    let ids: BTreeSet<&str> = known
        .as_object()
        .expect("known.json is an object")
        .values()
        .filter_map(|domain| domain.as_object())
        .flat_map(|domain| domain.values())
        .filter_map(|id| id.as_str())
        .collect();
    assert!(!ids.is_empty(), "known.json pins nothing");
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/data/known_findings.md");
    let doc = fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let missing: Vec<&str> = ids.into_iter().filter(|id| !mentions(&doc, id)).collect();
    assert!(
        missing.is_empty(),
        "pinned in known.json but not in tests/data/known_findings.md: {missing:?}"
    );
}
