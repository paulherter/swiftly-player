//! The collections of an account for a host screen that composes its own menu (the desktop's library page): one
//! directory per account, kept by the core for a minute on the host's clock, not asked again per page that opens.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use common::script::{Script, host};
use common::{Manual, account};
use swiftly_vm::{account_client, account_directory};

fn server() -> std::sync::Arc<Script> {
    Script::new(|r| {
        Some(if r.url.path().ends_with("UserViews") {
            r#"{"Items":[{"Id":"lib-movies","Name":"Filme","Type":"CollectionFolder","CollectionType":"movies"}],"TotalRecordCount":1}"#.to_owned()
        } else {
            r#"{"Items":[],"TotalRecordCount":0}"#.to_owned()
        })
    })
}

#[test]
fn the_directory_is_asked_once_per_minute_and_not_per_page() {
    futures_executor::block_on(async {
        let net = server();
        let clock = Manual::at(1000.0);
        let mut host = host();
        host.clock = clock.clone();
        let account = account("DIRECTORY");
        let client = account_client(&net, &host, &account).unwrap();

        assert!(account_directory(&client, &host, &account).await.is_some());
        let asked = net.count("BoxSet");
        assert_eq!(asked, 1, "{:?}", net.urls());

        // The next library page that opens asks nothing: it takes the account's directory.
        clock.set(1059.0);
        assert!(account_directory(&client, &host, &account).await.is_some());
        assert_eq!(net.count("BoxSet"), asked, "59 s: the shared one");

        // A minute on the host's clock later (also when the device slept): asked again.
        clock.set(1061.0);
        assert!(account_directory(&client, &host, &account).await.is_some());
        assert_eq!(net.count("BoxSet"), asked + 1, "61 s: asked again");
    });
}

#[test]
fn another_account_has_a_directory_of_its_own() {
    futures_executor::block_on(async {
        let net = server();
        let host = host();
        let (a, b) = (account("DIR-A"), account("DIR-B"));
        let (ca, cb) = (
            account_client(&net, &host, &a).unwrap(),
            account_client(&net, &host, &b).unwrap(),
        );
        assert!(account_directory(&ca, &host, &a).await.is_some());
        assert!(account_directory(&cb, &host, &b).await.is_some());
        assert_eq!(net.count("BoxSet"), 2);
    });
}
