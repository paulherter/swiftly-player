//! The supporter-key entry of the direct Windows and Linux build: what a pasted key does, around the support core's
//! `KeyKeeper` (the check, the stored key, the status and the plan are the core's; Android direct runs the same rules).
//! The iOS and tvOS shells are built without the `supporter-key` feature: there `AVAILABLE` is false and nothing here
//! checks a key.

use crate::settings_pages::KeyStage;
use swiftly_settings::KeyValueStore;
use swiftly_support::support::{SupportPlan, SupportStore};

/// Whether this build has the key entry.
pub const AVAILABLE: bool = cfg!(feature = "supporter-key");
/// Where a lost key is asked for (`DirectSupport.contactEmail`).
pub const CONTACT: &str = "info@swiftlyplayer.com";

/// The plan word of the stored status ("Monatlich" / "Für immer").
fn plan_word(plan: Option<SupportPlan>) -> &'static str {
    match plan {
        Some(SupportPlan::Monthly) => "Monatlich",
        _ => "Für immer",
    }
}

/// The stage the page opens in: the thanks when a key already counts (the status survives a restart in the settings
/// file), else the ask.
pub fn opening<S: KeyValueStore + Clone>(store: &S, now_ms: i64) -> KeyStage {
    #[cfg(feature = "supporter-key")]
    keeper(store).apply_expiry(now_ms);
    #[cfg(not(feature = "supporter-key"))]
    let _ = now_ms;
    let support = SupportStore::new(store.clone());
    if !support.status().is_supporter() {
        return KeyStage::Intro;
    }
    #[cfg(feature = "supporter-key")]
    let name = keeper(store).license().and_then(|l| l.name);
    #[cfg(not(feature = "supporter-key"))]
    let name = None;
    KeyStage::Thanks {
        plan: plan_word(support.plan()),
        name,
    }
}

/// The pasted key did not count (the page shows one line for every reason).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyRefused;

/// Checks a pasted key and, when it counts, stores it. `Err` when it does not (the page shows one line for every
/// reason, like the Android direct sheet).
pub fn activate<S: KeyValueStore + Clone>(
    store: &S,
    text: &str,
    now_ms: i64,
) -> Result<KeyStage, KeyRefused> {
    #[cfg(feature = "supporter-key")]
    {
        let license = keeper(store)
            .activate(text, now_ms)
            .map_err(|_| KeyRefused)?;
        Ok(KeyStage::Thanks {
            plan: plan_word(SupportStore::new(store.clone()).plan()),
            name: license.name,
        })
    }
    #[cfg(not(feature = "supporter-key"))]
    {
        let _ = (store, text, now_ms);
        Err(KeyRefused)
    }
}

#[cfg(feature = "supporter-key")]
fn keeper<S: KeyValueStore + Clone>(store: &S) -> swiftly_support::supporter_keeper::KeyKeeper<S> {
    use swiftly_support::supporter_keeper::KeyKeeper;
    #[cfg(feature = "test-support-key")]
    {
        // A proof build: the keys of the test pair count.
        use swiftly_support::supporter_key as k;
        let key = k::decode_public_key(k::TEST_PUBLIC_KEY_BASE64).unwrap_or([0; 32]);
        KeyKeeper::with_public_key(store.clone(), key.to_vec(), false)
    }
    #[cfg(not(feature = "test-support-key"))]
    {
        KeyKeeper::new(store.clone())
    }
}

/// The current time in milliseconds since 1970.
pub fn wall_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
