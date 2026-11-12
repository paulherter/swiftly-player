//! `ImageKeyTests.swift` (4), `ImageStoreKeyTests.swift` (3), `ImageSlabTests.swift` (5), plus
//! tests of the memory cache and the tone cache that Swift did not have.

#![allow(clippy::expect_used, clippy::unwrap_used)]

use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, SystemTime};
use swiftly_images::{
    Device, DiskCache, FolderPlate, MemoryImageCache, MemoryPlate, ToneCache, file_name, image_key,
    name, store_key,
};
use url::Url;

fn url(text: &str) -> Url {
    Url::parse(text).expect("url")
}

// MARK: ImageKeyTests

#[test]
fn token_falls_out_of_the_key() {
    let key = image_key(&url(
        "https://tv.example.de/Items/abc/Images/Primary?tag=xyz&maxHeight=450&ApiKey=GEHEIM",
    ));
    assert!(!key.contains("GEHEIM"));
    // `tag` stays: without it a changed version of the image would go unnoticed.
    assert!(key.contains("tag=xyz"));
    assert!(key.contains("maxHeight=450"));
    assert!(key.contains("/Items/abc/Images/Primary"));
}

#[test]
fn lower_case_spelling_too() {
    assert!(!image_key(&url("https://x.de/i?api_key=G&tag=1")).contains('G'));
}

#[test]
fn two_accounts_one_key() {
    let a = url("https://x.de/i?tag=1&ApiKey=AAA");
    let b = url("https://x.de/i?tag=1&ApiKey=BBB");
    assert_eq!(image_key(&a), image_key(&b));
}

#[test]
fn address_without_query_stays() {
    assert_eq!(image_key(&url("https://x.de/i")), "https://x.de/i");
}

// MARK: ImageStoreKeyTests

#[test]
fn without_host_and_access() {
    let at_home = url(
        "http://192.168.1.5:8096/Items/abc/Images/Primary?fillHeight=600&tag=f00&ApiKey=geheim",
    );
    let on_the_go = url(
        "https://tv.example.org/Items/abc/Images/Primary?fillHeight=600&tag=f00&api_key=anders",
    );
    let a = store_key(&at_home);
    assert_eq!(
        a.as_deref(),
        Some("/Items/abc/Images/Primary?fillHeight=600&tag=f00")
    );
    assert_eq!(a, store_key(&on_the_go));
}

#[test]
fn another_tag_is_another_image() {
    let old = store_key(&url("https://s/Items/abc/Images/Primary?tag=1"));
    let new = store_key(&url("https://s/Items/abc/Images/Primary?tag=2"));
    assert_ne!(old, new);
}

#[test]
fn without_tag_no_room_on_disk() {
    assert_eq!(
        store_key(&url("https://s/Items/abc/Images/Primary?fillHeight=600")),
        None
    );
    assert_eq!(
        store_key(&url("https://s/Items/abc/Images/Primary?tag=")),
        None
    );
}

// MARK: ImageSlabTests

static COUNTER: AtomicU32 = AtomicU32::new(0);

fn fresh_folder() -> PathBuf {
    std::env::temp_dir().join(format!(
        "bildplatte-{}-{}",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    ))
}

fn set_date(plate: &FolderPlate, file: &str, seconds_ago: u64) {
    let when = SystemTime::now() - Duration::from_secs(seconds_ago);
    let handle = std::fs::OpenOptions::new()
        .write(true)
        .open(plate.folder().join(file))
        .expect("open");
    handle.set_modified(when).expect("set date");
}

#[test]
fn file_name_is_stable() {
    assert_eq!(file_name(""), "cbf29ce484222325");
    assert_eq!(file_name("a"), file_name("a"));
    assert_ne!(file_name("a"), file_name("b"));
}

#[test]
fn name_hits_the_same_file() {
    let at_home = url("http://192.168.1.5:8096/Items/x/Images/Primary?tag=1&ApiKey=a");
    let on_the_go = url("https://s.example/Items/x/Images/Primary?tag=1&api_key=b");
    assert!(name(&at_home).is_some());
    assert_eq!(name(&at_home), name(&on_the_go));
    assert_eq!(name(&url("https://s/Items/x/Images/Primary")), None);
}

#[test]
fn written_is_read_never_empty() {
    let plate = FolderPlate::new(fresh_folder(), 1_000);
    plate.write(&[1, 2, 3], "a");
    assert_eq!(plate.read("a"), Some(vec![1, 2, 3]));
    plate.write(&[], "leer");
    assert_eq!(plate.read("leer"), None);
    assert_eq!(plate.read("fehlt"), None);
    let _ = std::fs::remove_dir_all(plate.folder());
}

/// The Swift test: four files of 100 bytes, limit 300, "alt" read last.
fn clean_up_scenario(plate: &dyn DiskCache, set: &dyn Fn(&str, u64)) {
    for (i, file) in ["alt", "mittel", "neu", "neuer"].iter().enumerate() {
        plate.write(&[7; 100], file);
        // Swift: now + (i - 4) minutes.
        set(file, (4 - i as u64) * 60);
    }
    // "alt" was just shown, which makes it the most recent.
    let _ = plate.read("alt");
    assert_eq!(plate.clean_up(), 2);
    assert!(plate.read("alt").is_some());
    assert!(plate.read("neuer").is_some());
    assert!(plate.read("mittel").is_none());
    assert!(plate.read("neu").is_none());
}

#[test]
fn clean_up_removes_the_longest_unused_to_three_quarters() {
    let plate = FolderPlate::new(fresh_folder(), 300);
    clean_up_scenario(&plate, &|file, ago| set_date(&plate, file, ago));
    let _ = std::fs::remove_dir_all(plate.folder());
}

#[test]
fn memory_plate_follows_the_same_rule() {
    let plate = MemoryPlate::new(300);
    // Stamps count up with age: the oldest has the smallest.
    clean_up_scenario(&plate, &|file, ago| plate.set_stamp(file, 1_000 - ago));
    assert_eq!(plate.len(), 2);
}

#[test]
fn under_the_limit_everything_stays() {
    let plate = FolderPlate::new(fresh_folder(), 1_000);
    plate.write(&[1; 100], "a");
    assert_eq!(plate.clean_up(), 0);
    assert!(plate.read("a").is_some());
    let _ = std::fs::remove_dir_all(plate.folder());
    let memory = MemoryPlate::new(1_000);
    memory.write(&[1; 100], "a");
    assert_eq!(memory.clean_up(), 0);
}

#[test]
fn clean_up_stops_exactly_at_three_quarters() {
    // 4 x 100 bytes, limit 399: sum 400 > 399, target 399 * 3 / 4 = 299; removing two leaves 200.
    let plate = MemoryPlate::new(399);
    for (i, file) in ["a", "b", "c", "d"].iter().enumerate() {
        plate.write(&[0; 100], file);
        plate.set_stamp(file, i as u64);
    }
    assert_eq!(plate.clean_up(), 2);
    assert!(plate.read("a").is_none() && plate.read("b").is_none());
    // A limit of exactly the sum cleans nothing.
    let exact = MemoryPlate::new(400);
    for file in ["a", "b", "c", "d"] {
        exact.write(&[0; 100], file);
    }
    assert_eq!(exact.clean_up(), 0);
}

// MARK: Memory cache and tone cache (no Swift tests)

#[test]
fn memory_cache_evicts_the_longest_unused() {
    let mut cache: MemoryImageCache<&str> = MemoryImageCache::new(300);
    cache.insert("a", "A", 100);
    cache.insert("b", "B", 100);
    cache.insert("c", "C", 100);
    // A hit moves "a" to the end, so "b" is now the longest unused.
    assert_eq!(cache.get("a"), Some(&"A"));
    cache.insert("d", "D", 100);
    assert_eq!(cache.get("b"), None);
    assert!(cache.get("a").is_some() && cache.get("c").is_some() && cache.get("d").is_some());
    assert_eq!(cache.used(), 300);
    // Replacing an entry counts the difference, not the sum.
    cache.insert("a", "A2", 50);
    assert_eq!(cache.used(), 250);
    cache.wipe();
    assert!(cache.is_empty() && cache.used() == 0);
}

#[test]
fn memory_cache_key_ignores_the_token() {
    let mut cache: MemoryImageCache<()> = MemoryImageCache::new(10);
    let a = cache.key_for(&url("https://x.de/i?tag=1&ApiKey=AAA"));
    let b = cache.key_for(&url("https://x.de/i?tag=1&api_key=BBB"));
    assert_eq!(a, b);
    assert_eq!(Device::Tv.memory_limit(), 64 * 1024 * 1024);
    assert_eq!(Device::Mac.decode_edge(), 1600);
    assert_eq!(Device::Phone.disk_limit(), 512 * 1024 * 1024);
}

#[test]
fn tone_cache_is_capped_and_tells_empty_from_unknown() {
    let mut cache = ToneCache::new();
    assert_eq!(cache.remembered("x"), None);
    cache.insert("x", Vec::new());
    assert_eq!(cache.remembered("x"), Some(&[][..]));
    for i in 0..ToneCache::AT_MOST {
        cache.insert(&format!("k{i}"), vec![i as f64]);
    }
    // 301 entries were inserted: the oldest ("x") dropped out.
    assert_eq!(cache.len(), ToneCache::AT_MOST);
    assert_eq!(cache.remembered("x"), None);
    assert_eq!(cache.remembered("k0"), Some(&[0.0][..]));
}
