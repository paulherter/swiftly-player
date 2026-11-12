//! Saved accounts of the Swiftly core, ported from `AccountBundle.swift`, `ServerBundles.swift`
//! and `AccountSwitchCurve.swift`.
//!
//! The crate knows no keychain and no file: [`SecretStore`] is the seam the host implements
//! (same shape as the foreign trait in `swiftly-uniffi`). JSON keys are the Swift Codable keys
//! (`konten`, `aktiveKennung`), so a bundle written by the app reads here and back.
#![deny(missing_docs)]

mod account;
mod bundle;
mod bundles;
mod curve;
mod flow;
mod session;
mod store;

pub use account::{Account, identity_of_address};
pub use bundle::AccountBundle;
pub use bundles::{POINTER_KEY, ServerBundles, bundle_storage_key};
pub use curve::AccountSwitchCurve;
pub use flow::{AddOutcome, RevokedOutcome, add_account, sign_out_revoked};
pub use session::{Session, SessionEvent, SignInMethod};
pub use store::{MemorySecretStore, SecretStore, load_bundles, save_bundles};
