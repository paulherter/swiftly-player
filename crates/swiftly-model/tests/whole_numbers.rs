//! Whole numbers as Foundation's `JSONDecoder` reads them (found by the per-method differential
//! `crates/swiftly-vm/tests/method_differential.rs`): `2019.0` and `7.2e10` decode into an integer
//! field, a fraction or a string drops the entry, `null` is nothing.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use swiftly_model::{Item, ItemsResponse, Lenient};

fn item(extra: &str) -> Result<Item, serde_json::Error> {
    serde_json::from_str(&format!(r#"{{"Id":"a","Name":"A"{extra}}}"#))
}

#[test]
fn a_whole_float_is_taken() {
    let i = item(r#","ProductionYear":2019.0,"RunTimeTicks":7.2e10,"ChildCount":3.0"#).unwrap();
    assert_eq!(i.production_year, Some(2019));
    assert_eq!(i.run_time_ticks, Some(72_000_000_000));
    assert_eq!(i.child_count, Some(3));
}

#[test]
fn a_fraction_a_string_or_a_bool_drops_the_entry() {
    assert!(item(r#","ProductionYear":2019.5"#).is_err());
    assert!(item(r#","ProductionYear":"2020""#).is_err());
    assert!(item(r#","IndexNumber":true"#).is_err());
}

#[test]
fn null_is_nothing() {
    let i = item(r#","ProductionYear":null,"UserData":{"PlaybackPositionTicks":null}"#).unwrap();
    assert_eq!(i.production_year, None);
}

#[test]
fn the_list_keeps_the_readable_entries_and_a_float_total() {
    let r: ItemsResponse = serde_json::from_str(
        r#"{"Items":[{"Id":"a","Name":"A","ProductionYear":2019.0},{"Id":"b","Name":"B","ProductionYear":2019.5},{"Id":"c"}],"TotalRecordCount":3.0}"#,
    )
    .unwrap();
    assert_eq!(
        r.items.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(),
        ["a"]
    );
    assert_eq!(r.total_record_count, 3);
    let l: Lenient<Item> =
        serde_json::from_str(r#"[{"Id":"a","Name":"A","IndexNumber":1.0}]"#).unwrap();
    assert_eq!(l.0[0].index_number, Some(1));
}
