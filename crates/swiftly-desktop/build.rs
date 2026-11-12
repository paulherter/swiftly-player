//! Windows target (native or cross-compiled): embeds the program icon and the version details ("Swiftly Player")
#![allow(clippy::unwrap_used)] // a build script: failing to embed the icon must stop the build
//! into the exe. The decision uses the target, not the build host, so `cargo xwin build` from Linux gets the icon too.
fn main() {
    println!("cargo:rerun-if-changed=assets/swiftly-player.rc");
    println!("cargo:rerun-if-changed=assets/swiftly-player.ico");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        embed_resource::compile("assets/swiftly-player.rc", embed_resource::NONE)
            .manifest_optional()
            .unwrap();
    }
}
