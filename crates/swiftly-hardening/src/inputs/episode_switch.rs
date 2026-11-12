//! Domain `episode_switch` (EpisodesSwitch.swift `EpisodeSwitch`): scripts against a fake host. Ops:
//! `exec` (start a switch), `close` (close the player), `lookup` (fetch for the running episode) and
//! `resolve` (answer a pending host call: gate `stop`, `plan`, `start`, `cstop` or `fetch`, number `n`,
//! value `v`: false on `plan` means "no plan"). A resolve that matches no pending call is dropped. The
//! recorded result is the sequence of host calls, outcomes and the state after every op; pending calls
//! are answered at the end in sorted order. Read by `Domain_EpisodeSwitch.swift` and
//! `tests/oracle_episode_switch.rs`.
use crate::Rng;
use serde_json::{Value, json};

pub fn cases() -> Vec<Value> {
    let mut rng = Rng::new(0x4550_5357);
    let mut out = Vec::new();
    for _ in 0..2500 {
        let len = rng.range(2, 16);
        let mut ops = Vec::new();
        for _ in 0..len {
            let op = match rng.below(20) {
                0..=3 => json!({"op": "exec"}),
                4 | 5 => json!({"op": "close"}),
                6 | 7 => json!({"op": "lookup"}),
                _ => {
                    let gate =
                        *rng.pick(&["stop", "plan", "plan", "start", "start", "cstop", "fetch"]);
                    let n = match gate {
                        "cstop" | "fetch" => rng.range(1, 2),
                        _ => rng.range(1, 3),
                    };
                    json!({"op": "resolve", "gate": gate, "n": n, "v": !rng.chance(25)})
                }
            };
            ops.push(op);
        }
        out.push(json!({"ops": ops}));
    }
    out
}
