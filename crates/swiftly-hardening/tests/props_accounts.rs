//! Model-based random sequences for the saved accounts (`ServerBundles`, `AccountBundle`,
//! `add_account`, `sign_out_revoked`, the secret store round trip and the bundle JSON).
//! A failure prints the seed; replay with `HARDENING_SEED=<n>`.
//!
//! The model is written from the documented rules, not from the code: the key of an account is
//! `<prefix><identity>|<user>`, the same key is never stored twice, a removed active account
//! hands over to its successor (same place, last one steps back), the last one of a kind drops
//! the kind and another kind takes over, a revoked answer for an account that is no longer the
//! active one changes nothing, and what is saved is what loads.
#![allow(clippy::expect_used, clippy::unwrap_used)]

mod common;

use swiftly_accounts::{
    Account, AccountBundle, MemorySecretStore, POINTER_KEY, SecretStore, ServerBundles,
    add_account, bundle_storage_key, load_bundles, save_bundles, sign_out_revoked,
};
use swiftly_hardening::Rng;
use swiftly_jellyfin::{ServerKind, Session};
use swiftly_plex::PlexSessionDetails;

const KINDS: [ServerKind; 3] = [ServerKind::Jellyfin, ServerKind::Emby, ServerKind::Plex];
const SERVERS: [&str; 5] = [
    "http://a:8096",
    "HTTP://A:8096/",
    "http://b",
    "https://c/x/",
    "http://a:8096//",
];
const USERS: [&str; 4] = ["u0", "u1", "u2", "u3"];

fn slot(k: ServerKind) -> usize {
    KINDS.iter().position(|x| *x == k).unwrap()
}

fn identity(url: &str) -> String {
    url.to_lowercase().trim_end_matches('/').to_string()
}

/// Key and server of an account by the written rules.
fn key_of(a: &Account) -> String {
    let user = &a.session.user_id;
    match (a.session.kind, &a.plex) {
        (ServerKind::Plex, Some(p)) => format!("plex:{}|{user}", p.machine_identifier),
        (kind, _) => {
            let prefix = match kind {
                ServerKind::Jellyfin => "",
                ServerKind::Emby => "emby:",
                ServerKind::Plex => "plex:",
            };
            format!("{prefix}{}|{user}", identity(&a.session.server_url))
        }
    }
}

fn server_of(a: &Account) -> String {
    match (a.session.kind, &a.plex) {
        (ServerKind::Plex, Some(p)) => format!("plex:{}", p.machine_identifier),
        _ => identity(&a.session.server_url),
    }
}

#[derive(Clone)]
struct MBundle {
    accounts: Vec<Account>,
    active: String,
}

impl MBundle {
    /// An account by key, else by bare user id (older bundles).
    fn find(&self, id: &str) -> Option<usize> {
        self.accounts
            .iter()
            .position(|a| key_of(a) == id)
            .or_else(|| self.accounts.iter().position(|a| a.session.user_id == id))
    }
}

struct Model {
    bundles: [Option<MBundle>; 3],
    kind: ServerKind,
}

impl Model {
    fn first_kind(&self) -> Option<ServerKind> {
        KINDS.into_iter().find(|k| self.bundles[slot(*k)].is_some())
    }

    fn fix_kind(&mut self) {
        if self.bundles[slot(self.kind)].is_none()
            && let Some(k) = self.first_kind()
        {
            self.kind = k;
        }
    }

    fn is_empty(&self) -> bool {
        self.first_kind().is_none()
    }

    fn add(&mut self, acc: Account) -> (bool, bool) {
        let id = server_of(&acc);
        let new_server = !self
            .bundles
            .iter()
            .flatten()
            .flat_map(|b| b.accounts.iter())
            .any(|a| server_of(a) == id);
        let kind = acc.session.kind;
        let key = key_of(&acc);
        let was_switch = self.bundles[slot(kind)].is_some();
        match &mut self.bundles[slot(kind)] {
            None => {
                self.bundles[slot(kind)] = Some(MBundle {
                    accounts: vec![acc],
                    active: key,
                });
            }
            Some(b) => {
                match b.accounts.iter().position(|a| key_of(a) == key) {
                    Some(i) => b.accounts[i] = acc,
                    None => b.accounts.push(acc),
                }
                b.active = key;
            }
        }
        self.kind = kind;
        (was_switch, new_server)
    }

    /// `AccountBundle::switch_to`: unknown ids change nothing.
    fn switch_account(&mut self, kind: ServerKind, id: &str) {
        if let Some(b) = &mut self.bundles[slot(kind)]
            && let Some(i) = b.find(id)
        {
            b.active = key_of(&b.accounts[i]);
        }
    }

    /// `AccountBundle::removed` put back with `ServerBundles::set`.
    fn remove(&mut self, kind: ServerKind, id: &str) {
        let Some(b) = self.bundles[slot(kind)].clone() else {
            return;
        };
        let Some(i) = b.find(id) else { return };
        let key = key_of(&b.accounts[i]);
        let mut rest = b.accounts.clone();
        rest.remove(i);
        if rest.is_empty() {
            self.bundles[slot(kind)] = None;
        } else {
            let active = if key == b.active {
                key_of(&rest[i.min(rest.len() - 1)])
            } else {
                b.active.clone()
            };
            self.bundles[slot(kind)] = Some(MBundle {
                accounts: rest,
                active,
            });
        }
        self.fix_kind();
    }
}

fn account(rng: &mut Rng, counter: &mut u64) -> Account {
    *counter += 1;
    let kind = *rng.pick(&KINDS);
    let user = *rng.pick(&USERS);
    let mut a = Account::new(Session {
        access_token: format!("tok-{counter}"),
        user_id: user.into(),
        user_name: format!("name-{user}"),
        server_url: (*rng.pick(&SERVERS)).into(),
        kind,
    });
    if kind == ServerKind::Plex && rng.chance(85) {
        let m = *rng.pick(&["m1", "m2"]);
        a.plex = Some(PlexSessionDetails::new(
            m,
            "Box",
            &format!("plex-{counter}"),
        ));
    }
    a
}

fn all_keys(m: &Model) -> Vec<(ServerKind, String)> {
    let mut v = Vec::new();
    for k in KINDS {
        if let Some(b) = &m.bundles[slot(k)] {
            for a in &b.accounts {
                v.push((k, key_of(a)));
            }
        }
    }
    v
}

/// The real state against the model, field by field.
fn check(step: usize, tail: &str, m: &Model, all: &ServerBundles) {
    let ctx = |what: &str| format!("step {step}: {what}; tail: {tail}");
    assert_eq!(all.is_empty(), m.is_empty(), "{}", ctx("is_empty"));
    let kinds: Vec<ServerKind> = KINDS
        .into_iter()
        .filter(|k| m.bundles[slot(*k)].is_some())
        .collect();
    assert_eq!(all.kinds(), kinds, "{}", ctx("kinds"));
    if !m.is_empty() {
        assert_eq!(all.active_kind(), m.kind, "{}", ctx("active kind"));
    }
    for k in KINDS {
        match (&m.bundles[slot(k)], all.bundle(k)) {
            (None, None) => {}
            (Some(mb), Some(rb)) => {
                assert_eq!(
                    rb.accounts(),
                    mb.accounts.as_slice(),
                    "{}",
                    ctx("accounts of a kind")
                );
                assert_eq!(rb.active_id(), mb.active, "{}", ctx("active id"));
                let keys: Vec<String> = mb.accounts.iter().map(key_of).collect();
                let mut sorted = keys.clone();
                sorted.sort();
                sorted.dedup();
                assert_eq!(sorted.len(), keys.len(), "{}", ctx("duplicate account key"));
                assert!(
                    keys.contains(&mb.active),
                    "{}",
                    ctx("active key points nowhere")
                );
                // The active account is the one with the active key; every key leads to its
                // own account and token (account A never reads account B's secret).
                assert_eq!(key_of(rb.active()), mb.active, "{}", ctx("active()"));
                for a in &mb.accounts {
                    let got = rb.account(&key_of(a)).expect("account by key");
                    assert_eq!(
                        got.session.access_token,
                        a.session.access_token,
                        "{}",
                        ctx("token by key")
                    );
                }
                // Servers: each once, accounts_on partitions the accounts.
                let servers = rb.servers();
                let mut ids: Vec<String> = servers.iter().map(|s| identity(s)).collect();
                // A Plex account's server is the machine, so only count the non-Plex-machine ones.
                ids.sort();
                let on_total: usize = mb
                    .accounts
                    .iter()
                    .map(server_of)
                    .collect::<std::collections::BTreeSet<_>>()
                    .len();
                assert_eq!(servers.len(), on_total, "{}", ctx("servers() each once"));
                let counted: usize = mb
                    .accounts
                    .iter()
                    // Swift `accounts(on:)`: the same server identity OR the same address (a Plex account matches by address).
                    .filter(|a| {
                        server_of(a) == server_of(&mb.accounts[0])
                            || identity(&a.session.server_url)
                                == identity(&mb.accounts[0].session.server_url)
                    })
                    .count();
                if mb.accounts[0].session.kind != ServerKind::Plex || mb.accounts[0].plex.is_none()
                {
                    assert_eq!(
                        rb.accounts_on(&mb.accounts[0].session.server_url).len(),
                        counted,
                        "{}",
                        ctx("accounts_on")
                    );
                }
            }
            (a, b) => panic!(
                "{}",
                ctx(&format!(
                    "bundle presence of {k:?}: model {} real {}",
                    a.is_some(),
                    b.is_some()
                ))
            ),
        }
    }
    let _ = all_keys(m);
}

/// What the store must hold after a save.
fn check_store(step: usize, tail: &str, store: &MemorySecretStore, m: &Model, all: &ServerBundles) {
    for k in KINDS {
        let has = store.get(bundle_storage_key(k)).is_some();
        assert_eq!(
            has,
            m.bundles[slot(k)].is_some(),
            "step {step}: store key of {k:?}; tail: {tail}"
        );
    }
    assert_eq!(
        store.get(POINTER_KEY).is_some(),
        !m.is_empty(),
        "step {step}: pointer; tail: {tail}"
    );
    let back = load_bundles(store);
    if m.is_empty() {
        assert!(
            back.is_empty(),
            "step {step}: empty save loads something; tail: {tail}"
        );
    } else {
        assert_eq!(
            &back, all,
            "step {step}: restore after save differs; tail: {tail}"
        );
    }
}

fn case(seed: u64) {
    let mut rng = Rng::new(seed ^ 0xACC0_0001);
    let mut counter = 0u64;
    let mut model = Model {
        bundles: [None, None, None],
        kind: ServerKind::Jellyfin,
    };
    let mut all = ServerBundles::default();
    let store = MemorySecretStore::new();
    let mut log: Vec<String> = Vec::new();
    let steps = 40 + rng.below(60) as usize;

    for step in 0..steps {
        let tail = log
            .iter()
            .rev()
            .take(6)
            .rev()
            .cloned()
            .collect::<Vec<_>>()
            .join(" | ");
        match rng.below(100) {
            0..=34 => {
                let acc = account(&mut rng, &mut counter);
                log.push(format!("add {} {:?}", key_of(&acc), acc.session.kind));
                let (was_switch, new_server) = model.add(acc.clone());
                let out = add_account(&mut all, acc);
                assert_eq!(
                    (out.was_switch, out.new_server),
                    (was_switch, new_server),
                    "step {step}: add outcome; tail: {tail}"
                );
            }
            35..=44 => {
                let kind = *rng.pick(&KINDS);
                log.push(format!("switch kind {kind:?}"));
                all.switch_to(kind);
                if model.bundles[slot(kind)].is_some() {
                    model.kind = kind;
                }
            }
            45..=59 => {
                let kind = *rng.pick(&KINDS);
                let id = pick_id(&mut rng, &model, kind);
                log.push(format!("switch account {kind:?} {id}"));
                if let Some(b) = all.bundle(kind).cloned() {
                    let mut b = b;
                    b.switch_to(&id);
                    all.set(Some(b), kind);
                }
                model.switch_account(kind, &id);
            }
            60..=71 => {
                let kind = *rng.pick(&KINDS);
                let id = pick_id(&mut rng, &model, kind);
                log.push(format!("remove {kind:?} {id}"));
                if let Some(b) = all.bundle(kind) {
                    let rest = b.removed(&id);
                    all.set(rest, kind);
                    model.remove(kind, &id);
                }
            }
            72..=86 => {
                // A revoked answer: for the active account, for another one, or for nobody.
                let kind = model.kind;
                let key = match rng.below(3) {
                    0 => model.bundles[slot(kind)].as_ref().map(|b| b.active.clone()),
                    1 => {
                        let keys = all_keys(&model);
                        (!keys.is_empty()).then(|| rng.pick(&keys).1.clone())
                    }
                    _ => None,
                }
                .unwrap_or_else(|| "nobody|x".to_string());
                log.push(format!("revoked {key}"));
                let expect_drop = !model.is_empty()
                    && model.bundles[slot(kind)]
                        .as_ref()
                        .is_some_and(|b| b.active == key);
                let name_before = model.bundles[slot(kind)]
                    .as_ref()
                    .filter(|_| expect_drop)
                    .map(|b| {
                        b.accounts[b.find(&b.active).unwrap()]
                            .session
                            .user_name
                            .clone()
                    });
                let before_other: Vec<_> = KINDS
                    .into_iter()
                    .filter(|k| *k != kind)
                    .map(|k| all.bundle(k).cloned())
                    .collect();
                let out = sign_out_revoked(&mut all, &key);
                assert_eq!(
                    out.is_some(),
                    expect_drop,
                    "step {step}: revoked verdict; tail: {tail}"
                );
                if let Some(o) = out {
                    assert_eq!(
                        Some(o.dropped_name.clone()),
                        name_before,
                        "step {step}: dropped name; tail: {tail}"
                    );
                    model.remove(kind, &key);
                    let now = model.bundles[slot(model.kind)]
                        .as_ref()
                        .map(|b| &b.accounts[b.find(&b.active).unwrap()]);
                    assert_eq!(
                        o.now_name.as_deref(),
                        now.map(|a| a.session.user_name.as_str()),
                        "step {step}: now_name; tail: {tail}"
                    );
                    assert_eq!(
                        o.now_key,
                        now.map(key_of),
                        "step {step}: now_key; tail: {tail}"
                    );
                    // Other kinds are never touched by a revoked answer.
                    let after_other: Vec<_> = KINDS
                        .into_iter()
                        .filter(|k| *k != kind)
                        .map(|k| all.bundle(k).cloned())
                        .collect();
                    assert_eq!(
                        before_other, after_other,
                        "step {step}: another kind changed; tail: {tail}"
                    );
                }
            }
            87..=93 => {
                // Export a bundle, tamper with the active id like an older app did, import it.
                let kind = *rng.pick(&KINDS);
                let Some(b) = all.bundle(kind) else { continue };
                let json = serde_json::to_string(b).expect("encode");
                assert!(
                    json.contains("\"konten\"") && json.contains("\"aktiveKennung\""),
                    "step {step}: Swift keys; tail: {tail}"
                );
                let back = AccountBundle::from_store(Some(json.as_bytes()), None).expect("import");
                assert_eq!(&back, b, "step {step}: export then import; tail: {tail}");
                let mb = model.bundles[slot(kind)].clone().unwrap();
                let wished = pick_id(&mut rng, &model, kind);
                let mut v: serde_json::Value = serde_json::from_str(&json).unwrap();
                v["aktiveKennung"] = serde_json::Value::String(wished.clone());
                let text = v.to_string();
                let imported = AccountBundle::from_store(Some(text.as_bytes()), None)
                    .expect("import tampered");
                let expect_active = match mb.find(&wished) {
                    Some(i) => key_of(&mb.accounts[i]),
                    None => key_of(&mb.accounts[0]),
                };
                assert_eq!(
                    imported.active_id(),
                    expect_active,
                    "step {step}: imported active id {wished}; tail: {tail}"
                );
                assert_eq!(
                    imported.accounts(),
                    mb.accounts.as_slice(),
                    "step {step}: import keeps accounts; tail: {tail}"
                );
                // Garbage plus a single old session falls back to a one-account bundle.
                let single = serde_json::to_string(&mb.accounts[0]).unwrap();
                let old = AccountBundle::from_store(Some(b"{nope"), Some(single.as_bytes()))
                    .expect("old session");
                assert_eq!(
                    old.accounts().len(),
                    1,
                    "step {step}: old single session; tail: {tail}"
                );
                assert_eq!(
                    old.active().session.access_token,
                    mb.accounts[0].session.access_token
                );
                assert!(AccountBundle::from_store(Some(b"{nope"), Some(b"{}")).is_none());
                // A bundle without accounts never imports.
                assert!(
                    AccountBundle::from_store(Some(br#"{"konten":[],"aktiveKennung":"x"}"#), None)
                        .is_none(),
                    "step {step}: an empty bundle imported; tail: {tail}"
                );
            }
            _ => {
                // A restart: what was saved is what comes back, a broken entry counts as missing.
                log.push("restart".into());
                save_bundles(&store, &all);
                if rng.chance(50) {
                    let kind = *rng.pick(&KINDS);
                    let was = store.get(bundle_storage_key(kind));
                    store.set(bundle_storage_key(kind), "not json");
                    let broken = load_bundles(&store);
                    assert!(
                        broken.bundle(kind).is_none(),
                        "step {step}: broken entry loaded; tail: {tail}"
                    );
                    for k in KINDS.into_iter().filter(|k| *k != kind) {
                        assert_eq!(
                            broken.bundle(k),
                            all.bundle(k),
                            "step {step}: other kind changed by a broken entry; tail: {tail}"
                        );
                    }
                    match was {
                        Some(t) => store.set(bundle_storage_key(kind), &t),
                        None => store.remove(bundle_storage_key(kind)),
                    }
                }
                let back = load_bundles(&store);
                if !model.is_empty() {
                    assert_eq!(back, all, "step {step}: restart differs; tail: {tail}");
                    all = back;
                } else {
                    assert!(back.is_empty());
                }
            }
        }
        check(step, &tail, &model, &all);
        save_bundles(&store, &all);
        check_store(step, &tail, &store, &model, &all);
    }

    // Drain: every account signed out through the revoked path ends with nobody signed in
    // and an empty secret store.
    let total: usize = KINDS
        .into_iter()
        .filter_map(|k| all.bundle(k))
        .map(|b| b.accounts().len())
        .sum();
    for n in 0..total {
        let key = all
            .active()
            .expect("an active bundle while accounts remain")
            .active_id()
            .to_string();
        let out = sign_out_revoked(&mut all, &key);
        assert!(
            out.is_some(),
            "drain {n}: the active account was not signed out"
        );
    }
    assert!(all.is_empty(), "drain left accounts");
    save_bundles(&store, &all);
    for name in ["konten", "konten.emby", "konten.plex", POINTER_KEY] {
        assert!(
            store.get(name).is_none(),
            "drain left `{name}` in the store"
        );
    }
    assert!(sign_out_revoked(&mut all, "anything").is_none());
}

/// A full key, a bare user id or an unknown id, mostly one that exists.
fn pick_id(rng: &mut Rng, m: &Model, kind: ServerKind) -> String {
    match (&m.bundles[slot(kind)], rng.below(10)) {
        (Some(b), 0..=5) => key_of(rng.pick(&b.accounts)),
        (Some(b), 6..=7) => rng.pick(&b.accounts).session.user_id.clone(),
        _ => "nobody".to_string(),
    }
}

#[test]
fn account_bundles_random_sequences() {
    common::for_seeds("props_accounts", 400, case);
}
