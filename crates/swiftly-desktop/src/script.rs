//! `--script FILE`: a scripted pointer run for live checks in a nested compositor (nothing touches the user's real
//! input: every step goes straight into the window's own input path). One step per line, in order:
//!
//! ```text
//! wait MS                  pause the script
//! until player MS          wait until the player screen is open (at most MS, then the script stops)
//! move FX FY               pointer to a fraction of the window (0.5 0.5 = centre)
//! move-label TEXT          pointer to the centre of the control whose accessible name contains TEXT
//! type TEXT               commit TEXT into the focused field, as an input method does
//! key enter|tab|escape|right|left|up|down   one shell key: into the focused field when one has the keyboard, else to the focus engine (escape is Back)
//! down | up | click        primary button at the pointer (`click` = down, 60 ms, up)
//! rclick                  secondary button at the pointer (opens a context menu)
//! key NAME                 a player shortcut: Space, Left, Right, Up, Down, Enter, Escape
//! until-label TEXT MS      wait until a control whose accessible name contains TEXT exists (at most MS, then the script stops)
//! wheel DY                 mouse wheel, lines
//! fullscreen               toggle the window's fullscreen
//! fill-images              fill the rest of the image page, as a long session of posters and icons does
//! shot PATH                write the frame the swapchain presents next
//! mark TAG                 print a timestamped line to stderr
//! labels [TEXT]            print the accessible nodes (name, role and frame in window points) whose name contains TEXT (all without)
//! quit
//! ```
//! Lines starting with `#` and empty lines are skipped.

use std::sync::OnceLock;
use std::time::Instant;

/// One step of a script.
#[derive(Clone, Debug, PartialEq)]
pub enum Step {
    /// Pause.
    Wait(f64),
    /// Wait for the player screen, with a time limit.
    UntilPlayer(f64),
    /// Pointer to a fraction of the window.
    Move(f64, f64),
    /// Pointer to the centre of a control by its accessible name.
    MoveLabel(String),
    /// Primary button down.
    Down,
    /// A right click at the pointer (opens context menus).
    RightClick,
    /// Primary button up.
    Up,
    /// Wait for a control by accessible name, with a time limit in ms.
    UntilLabel(String, f64),
    /// Wheel lines.
    Wheel(f32),
    /// Text committed into the focused field.
    Type(String),
    /// One key. Lowercase names (`right`, `left`, `up`, `down`, `tab`, `enter`, `escape`) go to the shell
    /// (focus and text); capitalised names (`Space`, `Left`, `Right`, `Up`, `Down`, `Enter`, `Escape`) are
    /// the player's shortcuts.
    Key(String),
    /// Toggle fullscreen.
    Fullscreen,
    /// Ask the window manager for this inner size in points (`resize WxH`: a step of a scripted edge drag).
    Resize(u32, u32),
    /// Fill the rest of the image page (a long session's worth of pictures).
    FillImages,
    /// Dump the next presented frame.
    Shot(String),
    /// Print a timestamped line.
    Mark(String),
    /// Print the accessible nodes with their frames.
    Labels(String),
    /// Show a message in the strip at the bottom of the content (the shell's toast).
    Toast(String),
    /// Open the shell's version dialog over two sample versions.
    AskVersions,
    /// Leave.
    Quit,
}

/// Whether `name` is a key a script can press. Every one goes through the same path as the real keyboard, so the case
/// of the name does not matter to the app.
fn is_key_name(name: &str) -> bool {
    matches!(
        name,
        "enter"
            | "tab"
            | "escape"
            | "right"
            | "left"
            | "up"
            | "down"
            | "Space"
            | "Left"
            | "Right"
            | "Up"
            | "Down"
            | "Enter"
            | "Escape"
            | "space"
    )
}

/// Parses a script; the error names the line.
pub fn parse(text: &str) -> Result<Vec<Step>, String> {
    let mut out = Vec::new();
    for (i, raw) in text.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let bad = || format!("script line {}: {line:?}", i + 1);
        let (word, rest) = line.split_once(' ').unwrap_or((line, ""));
        // A press lives a few frames, like a real one: the UI's gesture needs a frame between down and up.
        if word == "click" {
            out.extend([Step::Down, Step::Wait(60.0), Step::Up]);
            continue;
        }
        let num = |s: &str| s.trim().parse::<f64>().map_err(|_| bad());
        out.push(match word {
            "wait" => Step::Wait(num(rest)?),
            "until" => {
                let (what, ms) = rest.split_once(' ').ok_or_else(bad)?;
                if what != "player" {
                    return Err(bad());
                }
                Step::UntilPlayer(num(ms)?)
            }
            "move" => {
                let (x, y) = rest.split_once(' ').ok_or_else(bad)?;
                Step::Move(num(x)?, num(y)?)
            }
            "move-label" if !rest.is_empty() => Step::MoveLabel(rest.to_owned()),
            "type" if !rest.is_empty() => Step::Type(rest.to_owned()),
            "key" if is_key_name(rest.trim()) => Step::Key(rest.trim().to_owned()),
            "rclick" => Step::RightClick,
            "until-label" => {
                let (ms, text) = rest.split_once(' ').ok_or_else(bad)?;
                Step::UntilLabel(text.trim().to_owned(), num(ms)?)
            }
            "down" => Step::Down,
            "up" => Step::Up,
            "wheel" => Step::Wheel(num(rest)? as f32),
            "fullscreen" => Step::Fullscreen,
            "resize" => {
                let (w, h) = rest.trim().split_once('x').ok_or_else(bad)?;
                Step::Resize(
                    w.trim().parse().map_err(|_| bad())?,
                    h.trim().parse().map_err(|_| bad())?,
                )
            }
            "fill-images" => Step::FillImages,
            "shot" if !rest.is_empty() => Step::Shot(rest.to_owned()),
            "mark" if !rest.is_empty() => Step::Mark(rest.to_owned()),
            "labels" => Step::Labels(rest.to_owned()),
            "toast" if !rest.is_empty() => Step::Toast(rest.to_owned()),
            "ask-versions" => Step::AskVersions,
            "quit" => Step::Quit,
            _ => return Err(bad()),
        });
    }
    Ok(out)
}

/// Where a script stands: the steps and the one that waits.
#[derive(Debug, Default)]
pub struct Script {
    steps: Vec<Step>,
    next: usize,
    /// The wait that holds the next step, until this time (ms).
    hold_until: Option<f64>,
    /// For `until player`: the time it gives up (ms).
    give_up_at: Option<f64>,
}

impl Script {
    /// A script over `steps`.
    pub fn new(steps: Vec<Step>) -> Script {
        Script {
            steps,
            ..Script::default()
        }
    }

    /// Steps left.
    pub fn pending(&self) -> bool {
        self.next < self.steps.len()
    }

    /// The time (ms) the script sleeps until when it only waits for a pause to end: nothing is due before it, so the
    /// app does not need to draw for the script until then (a script run idles like the real app). `None` when a step
    /// is due or polls (`until` steps look every frame).
    pub fn sleeping_until(&self) -> Option<f64> {
        self.hold_until.filter(|_| self.pending())
    }

    /// The steps due at `now` (ms), given whether the player is open. Stops at a wait or an unmet `until`.
    pub fn due(&mut self, now: f64, player_open: bool) -> Vec<Step> {
        self.due_with(now, player_open, &|_| false)
    }

    /// Like [`Script::due`], with `has_label` answering whether a control with that accessible name exists now.
    pub fn due_with(
        &mut self,
        now: f64,
        player_open: bool,
        has_label: &dyn Fn(&str) -> bool,
    ) -> Vec<Step> {
        let mut out = Vec::new();
        while let Some(step) = self.steps.get(self.next) {
            if let Some(t) = self.hold_until {
                if now < t {
                    break;
                }
                self.hold_until = None;
            }
            match step {
                Step::Wait(ms) => {
                    self.hold_until = Some(now + ms);
                    self.next += 1;
                }
                Step::UntilPlayer(limit) => {
                    let deadline = *self.give_up_at.get_or_insert(now + limit);
                    if player_open {
                        self.give_up_at = None;
                        self.next += 1;
                    } else if now >= deadline {
                        out.push(Step::Mark("until-player-timeout".to_owned()));
                        out.push(Step::Quit);
                        self.next = self.steps.len();
                        break;
                    } else {
                        break;
                    }
                }
                Step::UntilLabel(text, limit) => {
                    let deadline = *self.give_up_at.get_or_insert(now + limit);
                    if has_label(text) {
                        self.give_up_at = None;
                        self.next += 1;
                    } else if now >= deadline {
                        out.push(Step::Mark(format!("until-label-timeout {text}")));
                        out.push(Step::Quit);
                        self.next = self.steps.len();
                        break;
                    } else {
                        break;
                    }
                }
                other => {
                    out.push(other.clone());
                    self.next += 1;
                    // The frame of a shot is drawn after this batch: nothing after it may change the picture first.
                    if matches!(other, Step::Shot(_)) {
                        break;
                    }
                }
            }
        }
        out
    }
}

static ZERO: OnceLock<Instant> = OnceLock::new();

/// Whether `SWIFTLY_TRACE` asks for timestamped trace lines (read once).
fn tracing() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("SWIFTLY_TRACE").is_some_and(|v| v != "0"))
}

/// Prints `trace +<ms since the first call> <tag>` to stderr when `SWIFTLY_TRACE` is set. Live latency measurements
/// (click, engine command, engine report, shown state) read these lines.
pub fn trace(tag: &str) {
    if tracing() {
        let t = ZERO.get_or_init(Instant::now).elapsed().as_secs_f64() * 1000.0;
        eprintln!("trace +{t:.1} {tag}");
    }
}

/// Like [`trace`], but only when the flag `name` changed since the last call (what the screen shows: playing or not).
pub fn trace_flag(name: &str, value: bool) {
    if !tracing() {
        return;
    }
    thread_local! {
        static SEEN: std::cell::RefCell<std::collections::HashMap<String, bool>> = std::cell::RefCell::new(std::collections::HashMap::new());
    }
    let changed = SEEN.with(|m| m.borrow_mut().insert(name.to_owned(), value) != Some(value));
    if changed {
        trace(&format!("{name}={value}"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_script_in_a_pause_sleeps_until_it_ends() -> Result<(), String> {
        let mut s = Script::new(parse("wait 1000\nshot a\n")?);
        assert_eq!(s.sleeping_until(), None, "a step is due: the app draws");
        assert!(s.due(100.0, false).is_empty());
        assert_eq!(s.sleeping_until(), Some(1100.0));
        assert!(s.due(1099.0, false).is_empty());
        assert_eq!(s.due(1100.0, false), vec![Step::Shot("a".to_owned())]);
        assert_eq!(s.sleeping_until(), None, "nothing is left");
        Ok(())
    }

    #[test]
    fn a_right_click_is_a_step_of_its_own() {
        assert_eq!(parse("rclick").unwrap(), vec![Step::RightClick]);
    }

    #[test]
    fn a_script_reads_every_step() -> Result<(), String> {
        let s = parse(
            "# c\nwait 500\nuntil player 9000\nmove 0.5 0.9\nmove-label Pause\nclick\nwheel -3\nfullscreen\nshot /tmp/a.png\nmark x\nquit\n",
        )?;
        assert_eq!(s.len(), 12);
        assert_eq!(parse("fill-images")?, vec![Step::FillImages]);
        assert_eq!(s[1], Step::UntilPlayer(9000.0));
        assert_eq!(s[3], Step::MoveLabel("Pause".into()));
        assert!(parse("jump 3").is_err());
        assert!(parse("until list 3").is_err());
        Ok(())
    }

    #[test]
    fn a_script_types_text_and_presses_keys() -> Result<(), String> {
        assert_eq!(
            parse("type 127.0.0.1:8199\nkey enter\nkey tab")?,
            vec![
                Step::Type("127.0.0.1:8199".into()),
                Step::Key("enter".into()),
                Step::Key("tab".into())
            ]
        );
        assert!(parse("type").is_err());
        assert!(parse("key f5").is_err());
        Ok(())
    }

    #[test]
    fn a_script_can_right_click_press_a_key_and_wait_for_a_label() -> Result<(), String> {
        let s = parse("rclick\nkey Right\nuntil-label 8000 Gemeinsam schauen\n")?;
        assert_eq!(
            s,
            vec![
                Step::RightClick,
                Step::Key("Right".into()),
                Step::UntilLabel("Gemeinsam schauen".into(), 8000.0)
            ]
        );
        let mut run = Script::new(vec![
            Step::UntilLabel("Beitreten".into(), 100.0),
            Step::Down,
        ]);
        assert!(run.due_with(0.0, false, &|_| false).is_empty());
        assert_eq!(
            run.due_with(50.0, false, &|t| t == "Beitreten"),
            vec![Step::Down]
        );
        // A label that never shows ends the run with a mark.
        let mut late = Script::new(vec![Step::UntilLabel("x".into(), 100.0), Step::Down]);
        assert!(late.due_with(0.0, false, &|_| false).is_empty());
        let out = late.due_with(150.0, false, &|_| false);
        assert_eq!(out.last(), Some(&Step::Quit));
        assert!(!late.pending());
        Ok(())
    }

    #[test]
    fn waits_hold_the_steps_behind_them() {
        let mut s = Script::new(vec![Step::Mark("a".into()), Step::Wait(100.0), Step::Down]);
        assert_eq!(s.due(0.0, false), vec![Step::Mark("a".into())]);
        assert!(s.due(50.0, false).is_empty());
        assert_eq!(s.due(100.0, false), vec![Step::Down]);
        assert!(!s.pending());
    }

    #[test]
    fn until_player_waits_then_gives_up() {
        let mut s = Script::new(vec![Step::UntilPlayer(1000.0), Step::Down]);
        assert!(s.due(0.0, false).is_empty());
        assert_eq!(s.due(10.0, true), vec![Step::Down]);
        let mut s = Script::new(vec![Step::UntilPlayer(1000.0), Step::Down]);
        assert!(s.due(0.0, false).is_empty());
        let late = s.due(1000.0, false);
        assert_eq!(late.last(), Some(&Step::Quit));
        assert!(!s.pending());
    }
}
