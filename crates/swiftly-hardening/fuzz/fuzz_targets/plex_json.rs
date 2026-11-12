#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let _ = swiftly_plex::wire::PlexListing::from_body(data);
});
