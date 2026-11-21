//! An error that reaches the screen is a sentence in the app's words (`live::say`, the core's `readableError`), never the
//! debug text of the error type (`Failed(Transport(Other(..)))`). This scans the sources for the one shape that let it
//! through twice (`format!("{e:?}")` as the whole error text) and allows only the headless smoke runs of `live_play.rs`,
//! which print to a terminal and never to a window.
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

/// File and how many raw error texts it may keep. `live_play.rs`: the `smoke_*` runs (terminal only).
const ALLOWED: &[(&str, usize)] = &[("live_play.rs", 5)];

#[test]
fn no_error_text_reaches_the_screen_as_debug_output() {
    let src = common::manifest_dir().join("src");
    let mut found: Vec<(String, usize)> = Vec::new();
    for entry in std::fs::read_dir(&src).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_none_or(|e| e != "rs") {
            continue;
        }
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        let text = std::fs::read_to_string(&path).unwrap();
        let count = ["{e:?}", "{err:?}", "{error:?}"]
            .iter()
            .map(|spelling| text.matches(&format!("format!(\"{spelling}\")")).count())
            .sum::<usize>();
        if count > 0 {
            found.push((name, count));
        }
    }
    for (name, count) in &found {
        let allowed = ALLOWED
            .iter()
            .find(|(n, _)| n == name)
            .map_or(0, |(_, c)| *c);
        assert!(
            *count <= allowed,
            "{name}: {count} raw error text(s) `format!(\"{{e:?}}\")` (allowed {allowed}); turn the error into words with `crate::live::say(&e)`"
        );
    }
}
