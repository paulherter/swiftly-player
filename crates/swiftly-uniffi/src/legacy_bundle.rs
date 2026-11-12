//! The account bundle statics of the old Android facade (`Kern.bundle*`), answered with the same JSON strings.
//! The "bundle" is one JSON object of text values (one entry per kind plus the pointer), which the host stores
//! and never reads. Compared with the Swift answers by `LegacyBundleParityTest` (`Android/golden`).

use serde_json::{Value, json};
use swiftly_accounts::{
    Account, AccountBundle, MemorySecretStore, POINTER_KEY, SecretStore, ServerBundles,
    bundle_storage_key, load_bundles, save_bundles,
};
use swiftly_jellyfin::ServerKind;

const KINDS: [ServerKind; 3] = [ServerKind::Jellyfin, ServerKind::Emby, ServerKind::Plex];

fn kind_raw(kind: ServerKind) -> &'static str {
    match kind {
        ServerKind::Jellyfin => "jellyfin",
        ServerKind::Emby => "emby",
        ServerKind::Plex => "plex",
    }
}

/// `readBundles`: the object of parts, or the Jellyfin bundle as it was stored before kinds existed.
fn read(raw: &str) -> ServerBundles {
    if raw.is_empty() {
        return ServerBundles::default();
    }
    if let Ok(parts) = serde_json::from_str::<std::collections::BTreeMap<String, String>>(raw) {
        let store = MemorySecretStore::new();
        for (k, v) in &parts {
            store.set(k, v);
        }
        return load_bundles(&store);
    }
    if let Ok(old) = serde_json::from_str::<AccountBundle>(raw) {
        return ServerBundles::new(vec![(ServerKind::Jellyfin, old)], ServerKind::Jellyfin);
    }
    ServerBundles::default()
}

/// `writeBundles`: empty text when no kind is left.
fn write(all: &ServerBundles) -> String {
    if all.is_empty() {
        return String::new();
    }
    let store = MemorySecretStore::new();
    save_bundles(&store, all);
    let mut parts = serde_json::Map::new();
    for key in KINDS
        .map(bundle_storage_key)
        .into_iter()
        .chain([POINTER_KEY])
    {
        if let Some(v) = store.get(key) {
            parts.insert(key.to_owned(), Value::String(v));
        }
    }
    Value::Object(parts).to_string()
}

fn session_of(json: &str) -> Option<Account> {
    serde_json::from_str(json).ok()
}

fn find_kind(all: &ServerBundles, id: &str) -> Option<ServerKind> {
    all.kinds()
        .into_iter()
        .find(|k| all.bundle(*k).is_some_and(|b| b.account(id).is_some()))
}

/// Adds a session to the bundle of its kind (`Kern.bundleRecord`).
#[uniffi::export]
pub fn legacy_bundle_record(session: String, bundle: String) -> String {
    let Some(s) = session_of(&session) else {
        return bundle;
    };
    let kind = s.session.kind;
    let mut all = read(&bundle);
    let (one, _) = AccountBundle::record_in(s, all.bundle(kind).cloned());
    all.set(Some(one), kind);
    all.switch_to(kind);
    write(&all)
}

/// Switches to another account of the bundle (`Kern.bundleSwitch`).
#[uniffi::export]
pub fn legacy_bundle_switch(bundle: String, identifier: String) -> String {
    let mut all = read(&bundle);
    let Some(kind) = find_kind(&all, &identifier) else {
        return bundle;
    };
    let Some(mut one) = all.bundle(kind).cloned() else {
        return bundle;
    };
    one.switch_to(&identifier);
    all.set(Some(one), kind);
    all.switch_to(kind);
    write(&all)
}

/// Without the account; empty if it was the last one of all kinds (`Kern.bundleRemoved`).
#[uniffi::export]
pub fn legacy_bundle_removed(bundle: String, identifier: String) -> String {
    let mut all = read(&bundle);
    let Some(kind) = find_kind(&all, &identifier) else {
        return write(&all);
    };
    let rest = all.bundle(kind).and_then(|b| b.removed(&identifier));
    all.set(rest, kind);
    write(&all)
}

/// The current session as JSON; empty if the bundle is not readable (`Kern.bundleActive`).
#[uniffi::export]
pub fn legacy_bundle_active(bundle: String) -> String {
    read(&bundle)
        .active()
        .and_then(|b| serde_json::to_string(b.active()).ok())
        .unwrap_or_default()
}

/// `Kern.bundleActiveId`.
#[uniffi::export]
pub fn legacy_bundle_active_id(bundle: String) -> String {
    read(&bundle)
        .active()
        .map(|b| b.active().account_key())
        .unwrap_or_default()
}

/// The addresses of the bundle's servers, `["..."]` (`Kern.bundleServers`).
#[uniffi::export]
pub fn legacy_bundle_servers(bundle: String) -> String {
    let all = read(&bundle);
    let list: Vec<String> = all
        .kinds()
        .into_iter()
        .filter_map(|k| all.bundle(k))
        .flat_map(|b| b.servers())
        .collect();
    json!(list).to_string()
}

/// Migration: the old single session as a bundle (`Kern.bundleFromSession`).
#[uniffi::export]
pub fn legacy_bundle_from_session(session: String) -> String {
    let Some(s) = session_of(&session) else {
        return String::new();
    };
    let kind = s.session.kind;
    write(&ServerBundles::new(
        vec![(kind, AccountBundle::new(s))],
        kind,
    ))
}

fn user_image(a: &Account) -> Option<String> {
    user_image_sized(a, 120)
}

fn user_image_sized(a: &Account, border: i64) -> Option<String> {
    let s = &a.session;
    if s.kind == ServerKind::Plex {
        return a.plex.as_ref().and_then(|p| p.user_image.clone());
    }
    let base = swiftly_images::Url::parse(&s.server_url).ok()?;
    swiftly_images::ImageAddress::new(base, Some(s.access_token.clone()), s.kind)
        .user(&s.user_id, None, border)
        .map(|u| u.to_string())
}

/// `Kern.userImage`: the picture of the stored session (Plex: the address plex.tv gave), empty without one.
#[uniffi::export]
pub fn legacy_user_image(session: String, border: i64) -> String {
    session_of(&session)
        .and_then(|a| user_image_sized(&a, border))
        .unwrap_or_default()
}

/// `Kern.subtitleFileStyleAdjustable`: whether the server can hand out ASS as SRT (not Plex).
#[uniffi::export]
pub fn legacy_subtitle_file_style_adjustable(kind: String) -> bool {
    kind != "plex"
}

/// For the account cards: per server its accounts, the active one marked, with picture (`Kern.bundleOverview`).
#[uniffi::export]
pub fn legacy_bundle_overview(bundle: String) -> String {
    let all = read(&bundle);
    let Some(active_bundle) = all.active() else {
        return "[]".into();
    };
    let active = active_bundle.active().account_key();
    let mut cards = Vec::new();
    for kind in all.kinds() {
        let Some(b) = all.bundle(kind) else { continue };
        for url in b.servers() {
            let accounts = b.accounts_on(&url);
            let host = accounts
                .first()
                .and_then(|a| a.plex.as_ref().map(|p| p.server_name.clone()))
                .or_else(|| {
                    swiftly_images::Url::parse(&url)
                        .ok()
                        .and_then(|u| u.host_str().map(str::to_owned))
                })
                .unwrap_or_else(|| url.clone());
            cards.push(json!({
                "adresse": url, "host": host, "art": kind_raw(kind),
                "aktiv": accounts.iter().any(|a| a.account_key() == active),
                "konten": accounts.iter().map(|a| json!({
                    "kennung": a.account_key(), "name": a.session.user_name,
                    "aktiv": a.account_key() == active, "bild": user_image(a),
                })).collect::<Vec<_>>(),
            }));
        }
    }
    Value::Array(cards).to_string()
}

/// The kinds that have accounts (`Kern.bundleKinds`).
#[uniffi::export]
pub fn legacy_bundle_kinds(bundle: String) -> String {
    json!(
        read(&bundle)
            .kinds()
            .into_iter()
            .map(kind_raw)
            .collect::<Vec<_>>()
    )
    .to_string()
}

/// The kind of the current session; empty without one (`Kern.bundleActiveKind`).
#[uniffi::export]
pub fn legacy_bundle_active_kind(bundle: String) -> String {
    read(&bundle)
        .active()
        .map(|b| kind_raw(b.active().session.kind).to_owned())
        .unwrap_or_default()
}

/// `Kern.accountSwitchCurve`: the profile picture's flight as sample points (120 per second until rest) plus the ring.
#[uniffi::export]
pub fn legacy_account_switch_curve(
    from_x: f64,
    from_y: f64,
    size: f64,
    to_x: f64,
    to_y: f64,
    target_size: f64,
) -> String {
    use swiftly_accounts::AccountSwitchCurve as C;
    let k = C::new((from_x, from_y), size, (to_x, to_y), target_size);
    let steps = ((k.swap * 120.0) as i64).max(2);
    let mut lane = Vec::with_capacity((steps as usize + 1) * 3);
    for i in 0..=steps {
        let (x, y, s) = k.status(k.swap * i as f64 / steps as f64);
        lane.extend([x, y, s]);
    }
    let mut ring = Vec::with_capacity(97 * 2);
    for i in 0..=96 {
        let (mass, coverage) = C::ring(0.8 * f64::from(i) / 96.0);
        ring.extend([mass, coverage]);
    }
    json!({"tausch": k.swap, "landung": k.landing, "ringEnde": k.paint_end(), "wechsel": k.change(), "wachsen": C::GROW,
           "zielgroesse": k.target, "bahn": lane, "ring": ring})
    .to_string()
}

/// `Kern.quickConnectDeadline`: `[seconds, tick]`.
#[uniffi::export]
pub fn legacy_quick_connect_deadline() -> String {
    use swiftly_jellyfin::QuickConnectDeadline as D;
    json!([D::SECONDS, D::TICK]).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(id: &str, url: &str, kind: &str) -> String {
        format!(
            r#"{{"accessToken":"t{id}","userID":"{id}","userName":"n{id}","serverURL":"{url}"{kind}}}"#
        )
    }

    // Record, switch and remove on the text bundle, as the app does.
    #[test]
    fn a_bundle_grows_switches_and_shrinks() {
        let b1 = legacy_bundle_record(s("u1", "http://a.test:8096", ""), String::new());
        let b2 = legacy_bundle_record(s("u2", "http://a.test:8096", ""), b1);
        let b3 = legacy_bundle_record(s("e1", "http://c.test", r#","kind":"emby""#), b2.clone());
        assert_eq!(legacy_bundle_kinds(b3.clone()), r#"["jellyfin","emby"]"#);
        assert_eq!(legacy_bundle_active_kind(b3.clone()), "emby");
        assert_eq!(
            legacy_bundle_active_id(legacy_bundle_switch(
                b3.clone(),
                "http://a.test:8096|u1".into()
            )),
            "http://a.test:8096|u1"
        );
        assert_eq!(legacy_bundle_active_id(b2), "http://a.test:8096|u2");
        let rest = legacy_bundle_removed(
            legacy_bundle_removed(legacy_bundle_removed(b3, "e1".into()), "u2".into()),
            "u1".into(),
        );
        assert_eq!(rest, "");
    }

    #[test]
    fn the_curve_and_deadline_have_the_old_shape() {
        let v: Value = serde_json::from_str(&legacy_account_switch_curve(
            300.0, 600.0, 120.0, 40.0, 60.0, 34.0,
        ))
        .unwrap();
        assert_eq!(v["bahn"].as_array().unwrap().len() % 3, 0);
        assert_eq!(v["ring"].as_array().unwrap().len(), 194);
        assert_eq!(legacy_quick_connect_deadline(), "[300,2]");
    }
}
