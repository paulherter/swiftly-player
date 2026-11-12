//! The typed-value rules of `key.rs`: what a stored value reads as, what a default is, what is stored
//! and which keys are removed. A stored value of the wrong type must fall back to the default (as
//! `object(forKey:) as? T ?? default` does in Swift), never panic and never convert silently.

use std::collections::BTreeMap;
use swiftly_settings::{
    Key, Scope, SettingValue, Value, ValueType, jellyfin_server, plex_server, server_key,
};

#[test]
fn bool_reads_only_a_bool() {
    assert_eq!(bool::from_value(&Value::Bool(true)), Some(true));
    assert_eq!(bool::from_value(&Value::Int(1)), None);
    assert_eq!(bool::from_value(&Value::Str("true".into())), None);
    assert_eq!(true.to_value(), Some(Value::Bool(true)));
    assert!(bool::from_const(true));
    assert_eq!(bool::TYPE, ValueType::Bool);
}

#[test]
fn int_accepts_whole_doubles_only() {
    assert_eq!(i64::from_value(&Value::Int(-4)), Some(-4));
    assert_eq!(i64::from_value(&Value::Double(30.0)), Some(30));
    assert_eq!(i64::from_value(&Value::Double(-7.0)), Some(-7));
    // A fraction is not an Int: the default applies.
    assert_eq!(i64::from_value(&Value::Double(10.5)), None);
    // Too large to be exact in a double: refused instead of rounded.
    assert_eq!(i64::from_value(&Value::Double(1.0e16)), None);
    assert_eq!(i64::from_value(&Value::Double(f64::NAN)), None);
    assert_eq!(i64::from_value(&Value::Double(f64::INFINITY)), None);
    assert_eq!(i64::from_value(&Value::Bool(true)), None);
    assert_eq!(i64::from_value(&Value::Str("5".into())), None);
    assert_eq!(7_i64.to_value(), Some(Value::Int(7)));
    assert_eq!(i64::from_const(12), 12);
    assert_eq!(i64::TYPE, ValueType::Int);
}

#[test]
fn double_widens_an_int_but_not_a_string() {
    assert!((f64::from_value(&Value::Double(0.25)).expect("double") - 0.25).abs() < f64::EPSILON);
    assert!((f64::from_value(&Value::Int(3)).expect("int widens") - 3.0).abs() < f64::EPSILON);
    assert_eq!(f64::from_value(&Value::Str("1.0".into())), None);
    assert_eq!(f64::from_value(&Value::Bool(false)), None);
    assert_eq!(1.5_f64.to_value(), Some(Value::Double(1.5)));
    assert!((f64::from_const(2.5) - 2.5).abs() < f64::EPSILON);
    assert_eq!(f64::TYPE, ValueType::Double);
}

#[test]
fn string_reads_text_and_valid_utf8_data_only() {
    assert_eq!(
        String::from_value(&Value::Str("a".into())),
        Some("a".to_owned())
    );
    assert_eq!(
        String::from_value(&Value::Data(b"hello".to_vec())),
        Some("hello".to_owned())
    );
    // Data that is not UTF-8 is not a string.
    assert_eq!(String::from_value(&Value::Data(vec![0xff, 0xfe])), None);
    assert_eq!(String::from_value(&Value::Int(1)), None);
    assert_eq!("x".to_owned().to_value(), Some(Value::Str("x".into())));
    assert_eq!(String::from_const("dflt"), "dflt");
    assert_eq!(String::TYPE, ValueType::String);
}

#[test]
fn data_reads_bytes_and_text_as_bytes() {
    assert_eq!(
        Vec::<u8>::from_value(&Value::Data(vec![1, 2])),
        Some(vec![1, 2])
    );
    assert_eq!(
        Vec::<u8>::from_value(&Value::Str("ab".into())),
        Some(b"ab".to_vec())
    );
    assert_eq!(
        Vec::<u8>::from_value(&Value::StrList(vec!["a".into()])),
        None
    );
    assert_eq!(vec![9_u8].to_value(), Some(Value::Data(vec![9])));
    assert_eq!(Vec::<u8>::from_const(b"{}"), b"{}".to_vec());
    assert_eq!(Vec::<u8>::TYPE, ValueType::Data);
}

#[test]
fn string_list_reads_only_a_list() {
    let list = vec!["a".to_owned(), "b".to_owned()];
    assert_eq!(
        Vec::<String>::from_value(&Value::StrList(list.clone())),
        Some(list.clone())
    );
    assert_eq!(Vec::<String>::from_value(&Value::Str("a".into())), None);
    assert_eq!(list.to_value(), Some(Value::StrList(list)));
    assert_eq!(
        Vec::<String>::from_const(&["x", "y"]),
        vec!["x".to_owned(), "y".to_owned()]
    );
    assert!(Vec::<String>::from_const(&[]).is_empty());
    assert_eq!(Vec::<String>::TYPE, ValueType::StringList);
}

#[test]
fn string_map_reads_only_a_map_and_defaults_empty() {
    let mut map = BTreeMap::new();
    map.insert("k".to_owned(), "v".to_owned());
    assert_eq!(
        BTreeMap::<String, String>::from_value(&Value::StrMap(map.clone())),
        Some(map.clone())
    );
    assert_eq!(
        BTreeMap::<String, String>::from_value(&Value::StrList(vec![])),
        None
    );
    assert_eq!(map.to_value(), Some(Value::StrMap(map)));
    assert!(BTreeMap::<String, String>::from_const(()).is_empty());
    assert_eq!(BTreeMap::<String, String>::TYPE, ValueType::StringMap);
}

#[test]
fn option_is_unset_by_default_and_none_removes_the_key() {
    assert_eq!(Option::<i64>::from_const(()), None);
    assert_eq!(Option::<i64>::from_value(&Value::Int(4)), Some(Some(4)));
    // A value of the wrong type is "not readable", not "unset".
    assert_eq!(Option::<i64>::from_value(&Value::Str("4".into())), None);
    assert_eq!(Some(4_i64).to_value(), Some(Value::Int(4)));
    assert_eq!(None::<i64>.to_value(), None);
    // The stored type is the inner one.
    assert_eq!(Option::<String>::TYPE, ValueType::String);
    assert_eq!(Option::<bool>::TYPE, ValueType::Bool);
}

#[test]
fn scope_flags_split_into_synced_and_per_server() {
    assert!(!Scope::Device.is_synced());
    assert!(!Scope::DevicePerServer.is_synced());
    assert!(Scope::Synced.is_synced());
    assert!(Scope::SyncedPerServer.is_synced());
    assert!(!Scope::Device.is_per_server());
    assert!(!Scope::Synced.is_per_server());
    assert!(Scope::DevicePerServer.is_per_server());
    assert!(Scope::SyncedPerServer.is_per_server());
}

#[test]
fn a_key_builds_its_default_from_the_const() {
    const NAME: Key<String> = Key::new("name", "fallback", Scope::Synced, "x.swift:1");
    const LIST: Key<Vec<String>> =
        Key::new("list", &["a", "b"] as &[&str], Scope::Device, "x.swift:2");
    const OPT: Key<Option<i64>> = Key::new("opt", (), Scope::DevicePerServer, "x.swift:3");
    assert_eq!(NAME.default_value(), "fallback");
    assert_eq!(NAME.name, "name");
    assert_eq!(NAME.scope, Scope::Synced);
    assert_eq!(NAME.source, "x.swift:1");
    assert_eq!(LIST.default_value(), vec!["a".to_owned(), "b".to_owned()]);
    assert_eq!(OPT.default_value(), None);
}

#[test]
fn server_keys_join_with_a_bar_and_empty_server_stays_plain() {
    assert_eq!(server_key("immerDirectPlay", ""), "immerDirectPlay");
    assert_eq!(
        server_key("immerDirectPlay", "https://h:8096"),
        "immerDirectPlay|https://h:8096"
    );
    assert_eq!(server_key("k", &plex_server("M1")), "k|plex:M1");
    assert_eq!(jellyfin_server("https://h:8096/"), "https://h:8096/");
    assert_eq!(plex_server(""), "plex:");
}
