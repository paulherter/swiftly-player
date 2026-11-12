//! The picture sizes of tiles and the wide picture for a head that follows the focus. Its own
//! test binary: the sizes are process-wide (one host, one screen class), so this must not share
//! a process with the tests that assert the phone defaults.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::clone_on_ref_ptr)]

mod common;

use std::sync::Arc;

use common::{Net, rig, until};
use swiftly_library::MemoryStore;
use swiftly_vm::{HomeIntent, ImageKind, set_tile_image_sizes};

#[test]
fn a_tv_host_gets_larger_tile_pictures_and_a_wide_hero() {
    let rig = rig(
        Net::new(true),
        Arc::new(MemoryStore::new()),
        "de",
        Some("TOKEN-A"),
    );
    let vm = &rig.vm;
    vm.send(HomeIntent::Load);
    until(vm, "ready", common::ready);

    // Phone defaults first: poster 360 high, backdrop 640 wide.
    let rails = vm.rails();
    let backdrop = rails.rails[0].tiles[0].image.as_ref().unwrap();
    assert_eq!((backdrop.wanted_width, backdrop.wanted_height), (640, 360));
    assert!(backdrop.address.contains("640"), "{}", backdrop.address);
    let poster = rails.rails[2].tiles[0].image.as_ref().unwrap();
    assert_eq!(
        (poster.kind, poster.wanted_height),
        (ImageKind::Poster, 360)
    );

    // The TV asks once for what its tiles always asked for: 600 high posters, 900 wide backdrops.
    set_tile_image_sizes(600, 900);
    let backdrop = vm.tiles(&rails.rails[0].id, 0, 1)[0].image.clone().unwrap();
    assert_eq!((backdrop.wanted_width, backdrop.wanted_height), (900, 506));
    assert!(backdrop.address.contains("900"), "{}", backdrop.address);
    let poster = vm.tiles(&rails.rails[2].id, 0, 1)[0].image.clone().unwrap();
    assert_eq!(
        (poster.kind, poster.wanted_height),
        (ImageKind::Poster, 600)
    );
    assert!(poster.address.contains("600"), "{}", poster.address);

    // The hero of a title on the page: the wide picture at the asked width; not for a stranger.
    let hero = vm.hero_image("r1", 1600).unwrap();
    assert_eq!((hero.kind, hero.wanted_width), (ImageKind::Backdrop, 1600));
    assert!(
        hero.address.contains("/Items/r1/Images/Backdrop"),
        "{}",
        hero.address
    );
    assert!(hero.address.contains("1600"), "{}", hero.address);
    assert!(vm.hero_image("nobody", 1600).is_none());

    // Zero means the default again.
    set_tile_image_sizes(0, 0);
    let again = vm.tiles(&rails.rails[0].id, 0, 1)[0].image.clone().unwrap();
    assert_eq!(again.wanted_width, 640);
}
