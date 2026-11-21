//! Keeps a verified supporter key on the device (direct builds): the key text, the supporter status that comes
//! from it and the plan. Same rules as `SupporterKeyKeeper.kt` / `SupporterKeyKeeper.swift` without the renewal
//! call to the shop: `activate` checks and stores a pasted key, `apply_expiry` runs at every start and withdraws a
//! status that came from a key that has run out.

use crate::support::{Source, SupportPlan, SupportStatus, SupportStore};
use crate::supporter_key::{self, APP_SWIFTLY, Failure, License};
use swiftly_settings::{KeyValueStore, StoreError, Value};

/// `SupporterKeyKeeper.keyStorageKey`; never change.
pub const KEY: &str = "support.key";
/// `SupporterKeyKeeper.checkedStorageKey`; never change.
pub const CHECKED: &str = "support.keyChecked";

/// The key store of one device.
pub struct KeyKeeper<S: KeyValueStore> {
    store: S,
    public_key: Vec<u8>,
    allow_test: bool,
}

impl<S: KeyValueStore + Clone> KeyKeeper<S> {
    /// Checks against the production key.
    pub fn new(store: S) -> Self {
        Self::with_public_key(store, supporter_key::public_key().to_vec(), false)
    }

    /// Checks against another key (tests; a build made only to prove the accepted state).
    pub fn with_public_key(store: S, public_key: Vec<u8>, allow_test: bool) -> Self {
        Self {
            store,
            public_key,
            allow_test,
        }
    }

    fn support(&self) -> SupportStore<S> {
        SupportStore::new(self.store.clone())
    }

    /// The stored key text.
    pub fn stored_key(&self) -> Option<String> {
        match self.store.get(KEY)? {
            Value::Str(s) => Some(s),
            Value::Data(d) => String::from_utf8(d).ok(),
            _ => None,
        }
    }

    /// The stored key read without the expiry check (an expired monthly key is still shown, so it can be renewed).
    pub fn license(&self) -> Option<License> {
        let text = self.stored_key()?;
        supporter_key::read(&text, &self.public_key, APP_SWIFTLY, self.allow_test).ok()
    }

    /// Checks a pasted key; when it counts, stores it and makes the owner a supporter.
    pub fn activate(&self, text: &str, now_ms: i64) -> Result<License, Failure> {
        let license =
            supporter_key::verify(text, &self.public_key, APP_SWIFTLY, self.allow_test, now_ms)?;
        let _ = self.store.set(KEY, Value::Str(text.trim().to_owned()));
        let _ = self
            .store
            .set(CHECKED, Value::Str((now_ms / 1000).to_string()));
        let _ = self.grant(&license);
        Ok(license)
    }

    /// At start: the stored key still counts, so the status stays (and is restored if it was lost); a key that has
    /// run out withdraws the status, but only when that status came from a key.
    pub fn apply_expiry(&self, now_ms: i64) {
        let Some(license) = self.license() else {
            return;
        };
        if !self.may_touch_status() {
            return;
        }
        if license.is_active(now_ms) {
            let _ = self.grant(&license);
        } else {
            let _ = self.withdraw();
        }
    }

    fn may_touch_status(&self) -> bool {
        match self.support().status() {
            SupportStatus::None => true,
            SupportStatus::Supporter { source, .. } => source == Source::Key,
        }
    }

    fn grant(&self, license: &License) -> Result<(), StoreError> {
        let support = self.support();
        support.set_status(SupportStatus::Supporter {
            source: Source::Key,
            since: Some(license.issued_at_ms as f64 / 1000.0),
        })?;
        support.set_plan(Some(match license.plan {
            "monthly" => SupportPlan::Monthly,
            _ => SupportPlan::Lifetime,
        }))
    }

    fn withdraw(&self) -> Result<(), StoreError> {
        let support = self.support();
        support.set_status(SupportStatus::None)?;
        support.set_plan(None)
    }
}
