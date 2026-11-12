//! Things the app asks the host to do outside its own window: open an address in the browser, share the log. The
//! screens only record the request ([`Effect`]); the window shell performs it ([`perform`]). That keeps the screens
//! testable (the test reads the effect) and the platform calls in one place.

/// "Swiftly bewerten" (`Community.appStoreRating`).
pub const RATE_URL: &str = "https://apps.apple.com/app/id6806824067?action=write-review";
/// "Discord beitreten" (`Community.discord`).
pub const DISCORD_URL: &str = "https://discord.gg/MeGwfv3UwN";
/// Base of "Fehler melden" (`Community.errorReport`).
pub const ISSUES_NEW_URL: &str = "https://github.com/paulherter/swiftly-player/issues/new";

/// A request for the host.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Effect {
    /// Open an address in the default browser.
    OpenUrl(String),
    /// Hand the log file to the system (reveal it in the file manager; there is no share sheet on the desktop).
    ShareLog,
}

thread_local! {
    static OUTBOX: std::cell::RefCell<Vec<Effect>> = const { std::cell::RefCell::new(Vec::new()) };
}

/// Hands an effect to the shell (read by [`take`]).
pub fn post(e: Effect) {
    OUTBOX.with(|o| o.borrow_mut().push(e));
}

/// The effects posted since the last call.
pub fn take() -> Vec<Effect> {
    OUTBOX.with(|o| std::mem::take(&mut *o.borrow_mut()))
}

/// Percent-encodes a query value.
fn encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
            out.push(char::from(b));
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// The new-issue address with version and system filled in (`Community.errorReport`).
pub fn error_report_url(version: &str, platform: &str) -> String {
    let body = format!("Version: {version}\nSystem: {platform}\n\n");
    format!("{ISSUES_NEW_URL}?body={}", encode(&body))
}

/// The operating system as the report names it.
pub fn platform_name() -> &'static str {
    if cfg!(target_os = "macos") {
        "macOS"
    } else if cfg!(target_os = "windows") {
        "Windows"
    } else {
        "Linux"
    }
}

/// Runs the effect with the platform's own opener (the sign-in's `open_url` for addresses, which only lets web
/// addresses through). Failures are ignored: nothing in the app depends on the answer.
pub fn perform(effect: &Effect) {
    match effect {
        Effect::OpenUrl(u) => {
            let _ = crate::signin_flows::open_url(u);
        }
        Effect::ShareLog => {
            let dir = crate::store::config_dir();
            let _ = if cfg!(target_os = "macos") {
                std::process::Command::new("open").arg(&dir).spawn()
            } else if cfg!(target_os = "windows") {
                std::process::Command::new("explorer.exe").arg(&dir).spawn()
            } else {
                std::process::Command::new("xdg-open").arg(&dir).spawn()
            };
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn report_address_carries_version_and_system() {
        let u = error_report_url("1.0 (1)", "Windows");
        assert!(u.starts_with("https://github.com/paulherter/swiftly-player/issues/new?body="));
        assert!(u.contains("Version%3A%201.0%20%281%29"));
        assert!(u.contains("System%3A%20Windows"));
    }

    #[test]
    fn posted_effects_are_read_once() {
        post(Effect::ShareLog);
        assert_eq!(take(), vec![Effect::ShareLog]);
        assert!(take().is_empty());
    }
}
