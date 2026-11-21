//! Every way out of the window loop that the user or a script starts goes through `Running::leave`, which stops a running
//! player and lets its report (position, stop) go out first. A path that only called `exit` left the server with a film
//! that never stopped (a quit while paused sent Playing and Progress, no Stopped).

mod common;

#[test]
fn only_startup_failures_and_leave_call_exit_directly() {
    let source = std::fs::read_to_string(common::manifest_dir().join("src/app.rs"))
        .expect("app.rs is readable");
    let lines: Vec<&str> = source.lines().collect();
    let mut stray = Vec::new();
    for (i, line) in lines.iter().enumerate() {
        if !line.contains("event_loop.exit()") {
            continue;
        }
        // Allowed: the one `leave` body, the fallback when there is no window yet (`None =>`), a start-up or GPU failure
        // (a `self.failure` line just above), and the dump-and-exit of a headless frame.
        let above = lines[i.saturating_sub(3)..i].join("\n");
        let fine = line.trim() == "event_loop.exit();" && above.contains("sleep")
            || line.contains("None =>")
            || above.contains("self.failure")
            || above.contains("exit_after_dump");
        if !fine {
            stray.push(format!("app.rs:{}: {}", i + 1, line.trim()));
        }
    }
    assert!(
        stray.is_empty(),
        "leave the loop through `Running::leave` so a playing film reports its stop: {stray:?}"
    );
}

#[test]
fn leave_stops_the_player_before_it_exits() {
    let source = std::fs::read_to_string(common::manifest_dir().join("src/app.rs"))
        .expect("app.rs is readable");
    let at = source.find("fn leave(").expect("Running::leave exists");
    let body = &source[at..at + 400];
    let closing = body
        .find("window_closing")
        .expect("leave closes the player");
    let exit = body.find("event_loop.exit()").expect("leave exits");
    assert!(closing < exit, "the player closes first");
}
