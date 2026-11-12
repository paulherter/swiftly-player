//! `--autoplay`: a scripted run inside the process (no OS events), so frame statistics can be collected without
//! anybody touching the window. It scrolls a rail with wheel events, scrolls the page, opens a detail page by a click
//! on a tile, and goes back. The script repeats every [`PERIOD_MS`].

use crate::shell::{Command, Shell};
use crate::wheel::{WheelDelta, WheelPhase};

/// Length of one round of the script.
pub const PERIOD_MS: f64 = 9000.0;

#[derive(Clone, Copy, Debug)]
enum Step {
    Cursor(f32, f32),
    Wheel(f32, f32, WheelPhase),
    Click,
    Back,
}

/// The scripted run.
pub struct Autoplay {
    steps: Vec<(f64, Step)>,
    started: Option<f64>,
    next: usize,
    round: u32,
}

/// A burst of touchpad events: fingers land, move with decaying speed for `ms`, lift.
fn burst(steps: &mut Vec<(f64, Step)>, t0: f64, ms: f64, dx: f32, dy: f32) {
    steps.push((t0, Step::Wheel(0.0, 0.0, WheelPhase::Started)));
    let n = (ms / 8.0) as usize;
    for i in 0..n {
        let k = 1.0 - i as f32 / n as f32;
        steps.push((
            t0 + 8.0 * (i + 1) as f64,
            Step::Wheel(dx * k, dy * k, WheelPhase::Moved),
        ));
    }
    steps.push((t0 + ms + 8.0, Step::Wheel(0.0, 0.0, WheelPhase::Ended)));
}

impl Autoplay {
    /// A script for a window of `size` points.
    pub fn new(size: (f32, f32)) -> Autoplay {
        let mut steps = Vec::new();
        // The first rail's row is a little below the title; the tile click goes to its first poster.
        let (rail_y, tile_x) = (size.1.min(800.0) * 0.30, 18.0 + 58.0);
        // Click first, while nothing glides under the pointer (a touch on a moving scroll view only stops it).
        steps.push((100.0, Step::Cursor(tile_x, rail_y)));
        steps.push((600.0, Step::Click));
        steps.push((2200.0, Step::Back));
        steps.push((2800.0, Step::Cursor(size.0 * 0.5, rail_y)));
        burst(&mut steps, 2900.0, 400.0, -40.0, 0.0);
        burst(&mut steps, 4600.0, 300.0, 30.0, 0.0);
        steps.push((6000.0, Step::Cursor(size.0 * 0.5, size.1 * 0.5)));
        burst(&mut steps, 6100.0, 500.0, 0.0, -30.0);
        burst(&mut steps, 7600.0, 500.0, 0.0, 30.0);
        Autoplay {
            steps,
            started: None,
            next: 0,
            round: 0,
        }
    }

    /// Runs the steps that are due at `now` (ms).
    pub fn run(&mut self, shell: &mut Shell, now: f64) {
        let t0 = *self.started.get_or_insert(now);
        let t = now - t0 - f64::from(self.round) * PERIOD_MS;
        while let Some(&(at, step)) = self.steps.get(self.next) {
            if at > t {
                break;
            }
            self.next += 1;
            match step {
                Step::Cursor(x, y) => shell.cursor_moved(
                    (
                        f64::from(x) * f64::from(shell_scale(shell)),
                        f64::from(y) * f64::from(shell_scale(shell)),
                    ),
                    now,
                ),
                Step::Wheel(dx, dy, phase) => {
                    shell.wheel(WheelDelta::Points(dx, dy), Some(phase), now);
                }
                Step::Click => {
                    shell.primary_button(true, now);
                    shell.primary_button(false, now + 1.0);
                }
                Step::Back => {
                    shell.command(Command::Back, now);
                }
            }
        }
        if self.next >= self.steps.len() && t >= PERIOD_MS {
            self.round += 1;
            self.next = 0;
        }
    }
}

fn shell_scale(shell: &Shell) -> f32 {
    shell.scale()
}
