//! A panic on any thread lands in crash.log with its message, its place and a backtrace.

#[test]
fn a_panic_is_written_to_the_crash_log() {
    let dir = std::env::temp_dir().join(format!("swiftly-crash-test-{}", std::process::id()));
    let log = dir.join("nested").join("crash.log");
    swiftly_desktop::crash::install_at(log.clone());
    let r = std::thread::Builder::new()
        .name("fuzz-worker".into())
        .spawn(|| {
            let v: Vec<u8> = Vec::new();
            let i = std::hint::black_box(3);
            v[i]
        });
    assert!(r.unwrap().join().is_err());
    let _ = std::panic::take_hook();
    let text = std::fs::read_to_string(&log).expect("crash.log written");
    assert!(text.contains("panic ("), "{text}");
    assert!(text.contains("thread 'fuzz-worker' panicked at"), "{text}");
    assert!(text.contains("crash_log.rs"), "{text}");
    assert!(text.contains("index out of bounds"), "{text}");
    assert!(text.contains("backtrace:"), "{text}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_log_is_cut_when_it_grows_past_the_limit() {
    let dir = std::env::temp_dir().join(format!("swiftly-crash-cut-{}", std::process::id()));
    let log = dir.join("crash.log");
    swiftly_desktop::crash::append(&log, &"x".repeat(300 * 1024));
    swiftly_desktop::crash::append(&log, "fresh");
    assert_eq!(std::fs::read_to_string(&log).unwrap().trim(), "fresh");
    let _ = std::fs::remove_dir_all(&dir);
}
