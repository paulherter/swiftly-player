//! Account flows on the stored bundles: signing out a revoked account (`AppModel.signOutRevoked`,
//! AppModel.swift:2709) and adding an account (`AppModel.sessionAdopt`, :1174-1217). Pure
//! functions on [`ServerBundles`]; the host reads and writes the secret store around them.

use swiftly_jellyfin::ServerKind;

use crate::{Account, ServerBundles};

/// What happened when a revoked account was signed out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RevokedOutcome {
    /// The user name of the account that was dropped.
    pub dropped_name: String,
    /// The user name of the account that is active now; `None` when none is left (back to the
    /// server sign-in).
    pub now_name: Option<String>,
    /// The key of the account that is active now.
    pub now_key: Option<String>,
}

/// Drops the account `checked_key` whose token the server no longer accepts.
///
/// **Only if this account is still the active one.** The check can be slow; whoever switched
/// to another account in the meantime would otherwise be signed out by its result. Returns
/// `None` (and changes nothing) when `checked_key` is not the active account. Otherwise the next
/// account of the same server takes over, else another server, else none is left.
pub fn sign_out_revoked(all: &mut ServerBundles, checked_key: &str) -> Option<RevokedOutcome> {
    let kind = all.active_kind();
    let bundle = all.active()?;
    if bundle.active_id() != checked_key {
        return None;
    }
    let dropped_name = bundle.active().session.user_name.clone();
    let rest = bundle.removed(checked_key);
    all.set(rest, kind);
    let now = all.active().map(|b| b.active());
    Some(RevokedOutcome {
        dropped_name,
        now_name: now.map(|a| a.session.user_name.clone()),
        now_key: now.map(Account::account_key),
    })
}

/// What adding an account did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AddOutcome {
    /// There already was a bundle of this kind, so this was a switch between accounts (the
    /// caller cleans up and reloads) and not a first sign-in.
    pub was_switch: bool,
    /// The new account lives at a server none of the stored accounts belongs to.
    pub new_server: bool,
}

/// Records `account` as the active one of its kind (`ServerBundles` + `AccountBundle.record_in`).
/// The same account (same key) is replaced in place.
pub fn add_account(all: &mut ServerBundles, account: Account) -> AddOutcome {
    let kind: ServerKind = account.session.kind;
    let identity = account.server_identity();
    let new_server = !all
        .kinds()
        .into_iter()
        .filter_map(|k| all.bundle(k))
        .flat_map(|b| b.accounts().iter())
        .any(|a| a.server_identity() == identity);
    let (bundle, was_switch) = crate::AccountBundle::record_in(account, all.bundle(kind).cloned());
    all.set(Some(bundle), kind);
    all.switch_to(kind);
    AddOutcome {
        was_switch,
        new_server,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_jellyfin::Session;

    fn account(user: &str, server: &str, kind: ServerKind) -> Account {
        Account::new(Session {
            access_token: format!("t-{user}"),
            user_id: format!("id-{user}"),
            user_name: user.into(),
            server_url: server.into(),
            kind,
        })
    }

    fn with(accounts: &[Account]) -> ServerBundles {
        let mut all = ServerBundles::default();
        for a in accounts {
            add_account(&mut all, a.clone());
        }
        all
    }

    #[test]
    fn revoked_active_account_is_dropped_and_the_next_takes_over() {
        let (anna, ben) = (
            account("Anna", "http://a:8096", ServerKind::Jellyfin),
            account("Ben", "http://a:8096", ServerKind::Jellyfin),
        );
        let mut all = with(&[anna.clone(), ben.clone()]);
        let out = sign_out_revoked(&mut all, &ben.account_key()).unwrap();
        assert_eq!(out.dropped_name, "Ben");
        assert_eq!(out.now_name.as_deref(), Some("Anna"));
        assert_eq!(all.active().unwrap().accounts().len(), 1);
    }

    #[test]
    fn revoked_answer_for_a_switched_away_account_changes_nothing() {
        let (anna, ben) = (
            account("Anna", "http://a:8096", ServerKind::Jellyfin),
            account("Ben", "http://a:8096", ServerKind::Jellyfin),
        );
        let mut all = with(&[anna.clone(), ben]);
        let before = all.clone();
        assert!(sign_out_revoked(&mut all, &anna.account_key()).is_none());
        assert_eq!(
            all.active().unwrap().accounts(),
            before.active().unwrap().accounts()
        );
        assert_eq!(
            all.active().unwrap().active_id(),
            before.active().unwrap().active_id()
        );
    }

    #[test]
    fn the_last_account_leaves_nobody_signed_in() {
        let anna = account("Anna", "http://a:8096", ServerKind::Jellyfin);
        let mut all = with(std::slice::from_ref(&anna));
        let out = sign_out_revoked(&mut all, &anna.account_key()).unwrap();
        assert_eq!((out.now_name, out.now_key), (None, None));
        assert!(all.is_empty());
    }

    #[test]
    fn after_the_last_one_of_a_kind_another_server_takes_over() {
        let jelly = account("Anna", "http://a:8096", ServerKind::Jellyfin);
        let emby = account("Eva", "http://e:8096", ServerKind::Emby);
        let mut all = with(&[jelly, emby.clone()]);
        assert_eq!(all.active_kind(), ServerKind::Emby);
        let out = sign_out_revoked(&mut all, &emby.account_key()).unwrap();
        assert_eq!(out.now_name.as_deref(), Some("Anna"));
        assert_eq!(all.active_kind(), ServerKind::Jellyfin);
    }

    #[test]
    fn adding_tells_first_sign_in_from_switch_and_new_server() {
        let mut all = ServerBundles::default();
        let first = add_account(
            &mut all,
            account("Anna", "http://a:8096", ServerKind::Jellyfin),
        );
        assert_eq!((first.was_switch, first.new_server), (false, true));
        let same_server = add_account(
            &mut all,
            account("Ben", "http://A:8096/", ServerKind::Jellyfin),
        );
        assert_eq!(
            (same_server.was_switch, same_server.new_server),
            (true, false)
        );
        let other = add_account(
            &mut all,
            account("Cem", "http://b:8096", ServerKind::Jellyfin),
        );
        assert_eq!((other.was_switch, other.new_server), (true, true));
        assert_eq!(all.active().unwrap().active().session.user_name, "Cem");
    }

    #[test]
    fn adding_the_same_account_again_replaces_it() {
        let mut all = ServerBundles::default();
        add_account(
            &mut all,
            account("Anna", "http://a:8096", ServerKind::Jellyfin),
        );
        add_account(
            &mut all,
            account("Anna", "http://a:8096", ServerKind::Jellyfin),
        );
        assert_eq!(all.active().unwrap().accounts().len(), 1);
    }
}
