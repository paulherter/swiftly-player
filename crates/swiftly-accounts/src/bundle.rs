use serde::{Deserialize, Deserializer, Serialize};
use swiftly_jellyfin::Session;

use crate::account::{Account, identity_of_address};

/// Several accounts (of one or more servers) and which one is current (`AccountBundle`).
///
/// Rules: the same account never exists twice (signing in again replaces in place); removing
/// the active account hands over to its successor; removing the last one yields `None`; an
/// active id that points nowhere falls back to the first account.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct AccountBundle {
    #[serde(rename = "konten")]
    accounts: Vec<Account>,
    #[serde(rename = "aktiveKennung")]
    active_id: String,
}

#[derive(Deserialize)]
struct Wire {
    #[serde(rename = "konten")]
    accounts: Vec<Account>,
    #[serde(rename = "aktiveKennung")]
    active_id: String,
}

impl<'de> Deserialize<'de> for AccountBundle {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let w = Wire::deserialize(d)?;
        Self::from_stored(w.accounts, Some(&w.active_id))
            .ok_or_else(|| serde::de::Error::custom("bundle without accounts"))
    }
}

impl AccountBundle {
    /// A single account, as it looks after the first sign-in.
    pub fn new(first: Account) -> Self {
        Self {
            active_id: first.account_key(),
            accounts: vec![first],
        }
    }

    /// From stored values; `None` if there is no account.
    pub fn from_stored(accounts: Vec<Account>, active: Option<&str>) -> Option<Self> {
        let first = accounts.first()?;
        let wished = active.and_then(|a| {
            accounts
                .iter()
                .find(|x| x.account_key() == a)
                .or_else(|| accounts.iter().find(|x| x.session.user_id == a))
        });
        let active_id = wished.unwrap_or(first).account_key();
        Some(Self {
            accounts,
            active_id,
        })
    }

    /// The accounts in the order they were added.
    pub fn accounts(&self) -> &[Account] {
        &self.accounts
    }

    /// The stored active key.
    pub fn active_id(&self) -> &str {
        &self.active_id
    }

    /// The active account; never absent (falls back to the first).
    pub fn active(&self) -> &Account {
        self.account(&self.active_id).unwrap_or(&self.accounts[0])
    }

    /// An account by key, or (older bundles) by bare user id.
    pub fn account(&self, identifier: &str) -> Option<&Account> {
        self.accounts
            .iter()
            .find(|a| a.account_key() == identifier)
            .or_else(|| {
                self.accounts
                    .iter()
                    .find(|a| a.session.user_id == identifier)
            })
    }

    /// The servers of the bundle, each once, in the order of their first account.
    pub fn servers(&self) -> Vec<String> {
        let mut seen = Vec::new();
        let mut out = Vec::new();
        for a in &self.accounts {
            let id = a.server_identity();
            if !seen.contains(&id) {
                seen.push(id);
                out.push(a.session.server_url.clone());
            }
        }
        out
    }

    /// The accounts of one server, in order.
    pub fn accounts_on(&self, server: &str) -> Vec<&Account> {
        let id = identity_of_address(server);
        self.accounts
            .iter()
            .filter(|a| {
                a.server_identity() == id || identity_of_address(&a.session.server_url) == id
            })
            .collect()
    }

    /// The server address of the active account.
    pub fn server_url(&self) -> &str {
        &self.active().session.server_url
    }

    /// Adds an account and makes it active; the same account is replaced in place.
    pub fn record(&mut self, new: Account) {
        let key = new.account_key();
        match self.accounts.iter().position(|a| a.account_key() == key) {
            Some(i) => self.accounts[i] = new,
            None => self.accounts.push(new),
        }
        self.active_id = key;
    }

    /// Adds an account to an optional bundle; the flag says whether it was a switch (a bundle
    /// existed before).
    pub fn record_in(new: Account, available: Option<Self>) -> (Self, bool) {
        match available {
            None => (Self::new(new), false),
            Some(mut b) => {
                b.record(new);
                (b, true)
            }
        }
    }

    /// Switches to an existing account; unknown ids change nothing.
    pub fn switch_to(&mut self, identifier: &str) {
        if let Some(a) = self.account(identifier) {
            self.active_id = a.account_key();
        }
    }

    /// Removes an account and returns what remains; `None` if it was the last one. An
    /// unknown id returns the bundle unchanged.
    pub fn removed(&self, identifier: &str) -> Option<Self> {
        let Some(target) = self.account(identifier) else {
            return Some(self.clone());
        };
        let key = target.account_key();
        let i = self.accounts.iter().position(|a| a.account_key() == key)?;
        let mut rest = self.accounts.clone();
        rest.remove(i);
        if rest.is_empty() {
            return None;
        }
        let was_active = key == self.active().account_key();
        let new_active = if was_active {
            rest[i.min(rest.len() - 1)].account_key()
        } else {
            self.active().account_key()
        };
        Self::from_stored(rest, Some(&new_active))
    }

    /// Does the account belong to the same server as the active one?
    pub fn fits_server(&self, s: &Account) -> bool {
        s.server_identity() == self.active().server_identity()
    }

    /// From what is in the store: the bundle, else the single session from before multiple
    /// accounts, else nothing. The old session stays in place.
    pub fn from_store(bundle: Option<&[u8]>, individual: Option<&[u8]>) -> Option<Self> {
        if let Some(b) = bundle.and_then(|b| serde_json::from_slice::<Self>(b).ok()) {
            return Some(b);
        }
        let alt = individual.and_then(|d| serde_json::from_slice::<Account>(d).ok())?;
        Some(Self::new(alt))
    }

    /// The old GTK store: other field names, same meaning (`serverName` is dropped).
    pub fn from_old_gtk_store(data: &[u8]) -> Option<Account> {
        #[derive(Deserialize)]
        struct Stored {
            #[serde(rename = "serverURL")]
            server_url: String,
            token: String,
            #[serde(rename = "benutzerID")]
            user_id: String,
            #[serde(rename = "benutzername")]
            user_name: String,
        }
        let a: Stored = serde_json::from_slice(data).ok()?;
        Some(Account::new(Session {
            access_token: a.token,
            user_id: a.user_id,
            user_name: a.user_name,
            server_url: a.server_url,
            kind: Default::default(),
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SERVER: &str = "https://jellyfin.example.com";
    const SECOND: &str = "https://jellyfin2.example.com";

    fn on(name: &str, id: &str, server: &str) -> Account {
        Account::new(Session {
            access_token: format!("t-{id}"),
            user_id: id.into(),
            user_name: name.into(),
            server_url: server.into(),
            kind: Default::default(),
        })
    }
    fn acc(name: &str, id: &str) -> Account {
        on(name, id, SERVER)
    }
    fn two() -> AccountBundle {
        let mut b = AccountBundle::new(acc("paul", "1"));
        b.record(acc("eltern", "2"));
        b
    }
    fn uid(b: &AccountBundle) -> &str {
        &b.active().session.user_id
    }

    // AccountBundleTests.swift
    #[test]
    fn single_and_second_become_active() {
        let b = AccountBundle::new(acc("paul", "1"));
        assert_eq!(b.accounts().len(), 1);
        assert_eq!(b.active().session.user_name, "paul");
        let b = two();
        assert_eq!(b.accounts().len(), 2);
        assert_eq!(uid(&b), "2");
    }

    #[test]
    fn same_sign_in_replaces_in_place() {
        let mut b = two();
        b.record(acc("oma", "3"));
        let mut again = acc("eltern", "2");
        again.session.access_token = "neu".into();
        b.record(again);
        assert_eq!(b.accounts().len(), 3);
        assert_eq!(b.accounts()[1].session.access_token, "neu");
        assert_eq!(uid(&b), "2");
    }

    #[test]
    fn switch_only_to_existing() {
        let mut b = two();
        b.switch_to("1");
        assert_eq!(uid(&b), "1");
        b.switch_to("gibtsnicht");
        assert_eq!(uid(&b), "1");
    }

    #[test]
    fn removal_rules() {
        let b = two();
        let rest = b.removed("2").expect("rest");
        assert_eq!((rest.accounts().len(), uid(&rest)), (1, "1"));
        assert!(AccountBundle::new(acc("paul", "1")).removed("1").is_none());
        assert_eq!(b.removed("99").expect("rest").accounts().len(), 2);
        let mut three = two();
        three.record(acc("oma", "3"));
        three.switch_to("2");
        assert_eq!(uid(&three.removed("2").expect("rest")), "3");
    }

    #[test]
    fn broken_id_falls_back_and_empty_is_none() {
        let b = AccountBundle::from_stored(vec![acc("paul", "1"), acc("eltern", "2")], Some("weg"))
            .expect("bundle");
        assert_eq!(uid(&b), "1");
        assert!(AccountBundle::from_stored(vec![], None).is_none());
    }

    #[test]
    fn server_fit_ignores_trailing_slash() {
        let b = AccountBundle::new(acc("paul", "1"));
        assert!(b.fits_server(&on("eltern", "2", "https://jellyfin.example.com/")));
        assert!(!b.fits_server(&on("x", "2", "https://anders.example")));
    }

    #[test]
    fn codable_roundtrip() {
        let mut b = two();
        b.switch_to("1");
        let back: AccountBundle =
            serde_json::from_str(&serde_json::to_string(&b).expect("enc")).expect("dec");
        assert_eq!(back, b);
        assert_eq!(uid(&back), "1");
    }

    // AccountBundleStoreTests
    #[test]
    fn record_in_says_whether_it_was_a_switch() {
        let (b, change) = AccountBundle::record_in(acc("paul", "1"), None);
        assert!(!change && b.accounts().len() == 1);
        let (b, change) = AccountBundle::record_in(acc("eltern", "2"), Some(b));
        assert!(change && b.accounts().len() == 2 && uid(&b) == "2");
        let (b, change) = AccountBundle::record_in(acc("eltern", "2"), Some(b));
        assert!(change && b.accounts().len() == 2);
        let (b, change) = AccountBundle::record_in(on("x", "9", "https://anders.example"), Some(b));
        assert!(change && b.servers().len() == 2);
        assert_eq!(b.server_url(), "https://anders.example");
    }

    fn json(a: &Account) -> Vec<u8> {
        serde_json::to_vec(a).expect("enc")
    }

    #[test]
    fn store_order_bundle_then_single_then_nothing() {
        let mut b = two();
        b.switch_to("1");
        let data = serde_json::to_vec(&b).expect("enc");
        let single = json(&acc("wer", "9"));
        assert_eq!(
            AccountBundle::from_store(Some(&data), Some(&single)),
            Some(b)
        );
        let t = AccountBundle::from_store(None, Some(&json(&acc("paul", "1")))).expect("b");
        assert_eq!((t.accounts().len(), uid(&t)), (1, "1"));
        assert!(AccountBundle::from_store(None, None).is_none());
        let broken = AccountBundle::from_store(Some(b"kein JSON"), Some(&json(&acc("p", "1"))));
        assert_eq!(uid(&broken.expect("b")), "1");
    }

    #[test]
    fn old_apple_store_is_read_literally() {
        let alt = br#"{"accessToken":"t-1","userID":"1","userName":"paul",
         "serverURL":"https://jellyfin.example.com"}"#;
        let b = AccountBundle::from_store(None, Some(alt)).expect("bundle");
        assert_eq!(b.active().session.user_name, "paul");
        assert_eq!(b.active().session.access_token, "t-1");
        let foreign = br#"{"token":"t-1","benutzerID":"1","benutzername":"paul",
         "serverURL":"https://jellyfin.example.com"}"#;
        assert!(AccountBundle::from_store(None, Some(foreign)).is_none());
    }

    #[test]
    fn old_gtk_store_is_translated_not_passed_through() {
        let alt = br#"{"serverURL":"https://jellyfin.example.com","token":"t-1",
         "benutzerID":"1","benutzername":"paul","servername":"Testkiste"}"#;
        let s = AccountBundle::from_old_gtk_store(alt).expect("session");
        assert_eq!(s.session.access_token, "t-1");
        assert_eq!(s.session.user_id, "1");
        assert_eq!(s.session.user_name, "paul");
        assert_eq!(s.session.server_url, "https://jellyfin.example.com");
        assert!(AccountBundle::from_store(None, Some(alt)).is_none());
    }

    // AccountBundleServerTests
    #[test]
    fn same_user_id_on_two_servers_is_two_accounts() {
        let mut b = AccountBundle::new(on("paul", "1", SERVER));
        b.record(on("paul", "1", SECOND));
        assert_eq!(b.accounts().len(), 2);
        assert_eq!(b.active().session.server_url, SECOND);
        b.switch_to(&on("paul", "1", SERVER).account_key());
        assert_eq!(b.active().session.server_url, SERVER);
    }

    #[test]
    fn accounts_per_server_and_sign_out_per_server() {
        let mut b = AccountBundle::new(on("paul", "1", SERVER));
        b.record(on("gast", "5", SECOND));
        b.record(on("eltern", "2", SERVER));
        assert_eq!(b.servers(), vec![SERVER, SECOND]);
        let names = |s| {
            b.accounts_on(s)
                .iter()
                .map(|a| a.session.user_name.clone())
                .collect::<Vec<_>>()
        };
        assert_eq!(names(SERVER), ["paul", "eltern"]);
        assert_eq!(names(SECOND), ["gast"]);
        let rest = b
            .removed(&on("gast", "5", SECOND).account_key())
            .expect("rest");
        assert_eq!(rest.active().session.server_url, SERVER);
    }

    #[test]
    fn bundle_with_bare_user_id_still_reads() {
        let json = r#"{"konten":[{"accessToken":"t","userID":"1","userName":"paul","serverURL":"https://jellyfin.example.com"},{"accessToken":"u","userID":"2","userName":"eltern","serverURL":"https://jellyfin.example.com"}],"aktiveKennung":"2"}"#;
        let b: AccountBundle = serde_json::from_str(json).expect("dec");
        assert_eq!(b.active().session.user_name, "eltern");
    }

    #[test]
    fn jellyfin_json_has_no_kind_and_keeps_the_swift_keys() {
        let text = serde_json::to_string(&AccountBundle::new(acc("paul", "1"))).expect("enc");
        assert!(!text.contains("kind") && !text.contains("plex"));
        assert!(text.contains(r#""aktiveKennung":"https://jellyfin.example.com|1""#));
    }
}
