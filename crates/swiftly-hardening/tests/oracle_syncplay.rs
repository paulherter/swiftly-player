//! Differential oracle, SyncPlay: the Rust output (`swiftly-sync`) must equal the real Swift output
//! (Tools/Oracle, Domain_SyncPlay.swift). The session itself (`SyncPlaySession`, an actor with network
//! client and timers) has no oracle.
#![allow(clippy::expect_used, clippy::unwrap_used)]

use serde_json::{Value, json};
use swiftly_hardening::oracle::assert_equal;
use swiftly_sync::syncplay::{
    BufferGuard, BufferMessage, CommandArt, Phase, Reading, Step, SyncPlay, SyncPlayCommand,
    SyncPlayExecution, SyncPlayGroup, SyncPlayPostDirection, SyncPlayQueue, SyncPlayRight,
    TimeReconcile,
};

fn ms(t: Option<f64>) -> Value {
    t.map_or(Value::Null, |t| {
        json!(format!("{}", (t * 1000.0).round() as i64))
    })
}

fn phase_raw(p: Phase) -> &'static str {
    match p {
        Phase::Empty => "Idle",
        Phase::Waits => "Waiting",
        Phase::Halted => "Paused",
        Phase::Running => "Playing",
    }
}

fn group(g: &SyncPlayGroup) -> Value {
    json!({
        "id": g.id, "name": g.name, "condition": g.condition.map(phase_raw),
        "participant": g.participant, "state": ms(g.state),
    })
}

fn render(d: Option<SyncPlayPostDirection>) -> Value {
    let Some(d) = d else { return Value::Null };
    match d {
        SyncPlayPostDirection::Command(c) => json!({
            "k": "command", "group": c.group, "entry": c.entry_record, "art": c.art.raw(),
            "moment": ms(Some(c.moment)), "spot": c.spot, "emitted": ms(c.emitted),
        }),
        SyncPlayPostDirection::Joined(g) => json!({ "k": "joined", "group": group(&g) }),
        SyncPlayPostDirection::Leave => json!({ "k": "leave" }),
        SyncPlayPostDirection::NotInGroup => json!({ "k": "not_in_group" }),
        SyncPlayPostDirection::DoesNotExist => json!({ "k": "does_not_exist" }),
        SyncPlayPostDirection::NoAccess => json!({ "k": "no_access" }),
        SyncPlayPostDirection::SomeoneJoined(n) => json!({ "k": "joined_user", "name": n }),
        SyncPlayPostDirection::SomeoneLeft(n) => json!({ "k": "left_user", "name": n }),
        SyncPlayPostDirection::Condition(p, r) => {
            json!({ "k": "condition", "phase": phase_raw(p), "reason": r })
        }
        SyncPlayPostDirection::Queue(q) => json!({
            "k": "queue", "reason": q.reason, "state": ms(q.state),
            "entries": q.entries.iter().map(|e| json!([e.title, e.entry_record])).collect::<Vec<_>>(),
            "index": q.index, "start": q.start_point, "running": q.running,
        }),
        SyncPlayPostDirection::ConnectionLost => json!({ "k": "lost" }),
        SyncPlayPostDirection::ConnectionAgain => json!({ "k": "again" }),
    }
}

#[test]
fn syncplay_read() {
    assert_equal("syncplay_read", |c| {
        let text = c["text"].as_str().unwrap();
        if c["kind"] == "list" {
            return match SyncPlayGroup::list_from_json(text.as_bytes()) {
                Some(l) => json!(l.iter().map(group).collect::<Vec<_>>()),
                None => Value::Null,
            };
        }
        render(SyncPlayPostDirection::read(text))
    });
}

#[test]
fn syncplay_misc() {
    assert_equal("syncplay_misc", |c| match c["op"].as_str().unwrap() {
        "consts" => json!([
            SyncPlay::JUMP_LIMIT,
            SyncPlay::DRIFT_LIMIT,
            SyncPlay::TICKS_PER_SECOND,
            TimeReconcile::KEEP as f64,
            BufferGuard::DEADLINE
        ]),
        "other" => {
            let mut g = SyncPlayGroup::new("g", "n");
            g.participant = c["participant"]
                .as_array()
                .unwrap()
                .iter()
                .map(|x| x.as_str().unwrap().to_owned())
                .collect();
            json!(g.other(c["me"].as_str()))
        }
        "status" => {
            let mut s = swiftly_sync::session::SyncPlayStatus {
                rights: c["rights"].as_str().and_then(SyncPlayRight::from_raw),
                ..Default::default()
            };
            s.group = c["in_group"]
                .as_bool()
                .unwrap()
                .then(|| SyncPlayGroup::new("g", ""));
            s.queue_title = c["queue_title"].as_str().map(str::to_owned);
            json!([
                s.may_create(),
                s.may_join(),
                s.belongs_group(c["title"].as_str().unwrap())
            ])
        }
        "queue" => {
            let n = c["entries"].as_u64().unwrap();
            let q = SyncPlayQueue {
                reason: c["reason"].as_str().unwrap().to_owned(),
                state: None,
                entries: (0..n)
                    .map(|i| swiftly_sync::syncplay::QueueRecord {
                        title: format!("t{i}"),
                        entry_record: format!("e{i}"),
                    })
                    .collect(),
                index: c["index"].as_i64().unwrap(),
                start_point: 0.0,
                running: false,
            };
            json!([q.current().map(|r| r.title.clone()), q.switches_title()])
        }
        "phase" => json!(Phase::from_raw(c["raw"].as_str().unwrap()).map(phase_raw)),
        "art" => {
            let raw = c["raw"].as_str().unwrap();
            json!(
                [
                    CommandArt::Proceed,
                    CommandArt::Pause,
                    CommandArt::Stop,
                    CommandArt::Jump
                ]
                .into_iter()
                .find(|a| a.raw() == raw)
                .map(CommandArt::raw)
            )
        }
        "seconds" => json!(SyncPlay::seconds(c["ticks"].as_i64().unwrap())),
        "ticks" => json!(SyncPlay::ticks(c["seconds"].as_f64().unwrap())),
        "pause" => json!(
            TimeReconcile::pause_to_measurements(c["count"].as_i64().unwrap().max(0) as usize).max(
                if c["count"].as_i64().unwrap() < 0 {
                    1.0
                } else {
                    0.0
                }
            )
        ),
        other => panic!("bad op {other}"),
    });
}

fn f(v: &Value, k: &str) -> f64 {
    v[k].as_f64().unwrap()
}

fn command(v: &Value) -> Option<SyncPlayCommand> {
    if !v.is_object() {
        return None;
    }
    let art = match v["art"].as_str()? {
        "Unpause" => CommandArt::Proceed,
        "Pause" => CommandArt::Pause,
        "Stop" => CommandArt::Stop,
        "Seek" => CommandArt::Jump,
        _ => return None,
    };
    Some(SyncPlayCommand {
        group: "g".into(),
        entry_record: v["entry"].as_str().map(str::to_owned),
        art,
        moment: f(v, "moment"),
        spot: v["spot"].as_f64(),
        emitted: None,
    })
}

#[test]
fn syncplay_clock() {
    assert_equal("syncplay_clock", |c| {
        let mut rec = TimeReconcile::new();
        for r in c["readings"].as_array().unwrap() {
            rec.record(Reading {
                sent: f(r, "sent"),
                server_receive: f(r, "server_receive"),
                server_sent: f(r, "server_sent"),
                receive: f(r, "receive"),
            });
        }
        let now = f(c, "now");
        let local_point = f(c, "local_point");
        let best = rec.best().map_or(Value::Null, |b| {
            json!([b.sent, b.server_receive, b.server_sent, b.receive])
        });
        let mut out = json!({
            "count": rec.measurements().len(), "ready": rec.ready(), "offset": rec.offset(),
            "ping": rec.ping_milliseconds(), "best": best,
            "local_only": rec.local_only(f(c, "server_time")), "server": rec.server(f(c, "local_time")),
            "ready_point": SyncPlayExecution::ready_point(f(c, "target"), f(c, "actual")),
        });
        if let Some(cmd) = command(&c["command"]) {
            let x = SyncPlayExecution::of(&cmd, now, &rec, local_point);
            let step = match x.step {
                Step::Proceed => "proceed",
                Step::Pause => "pause",
                Step::Jump => "jump",
                Step::Stop => "stop",
            };
            out["exec"] = json!([step, x.spot, x.wait]);
            out["estimated"] = json!(SyncPlayExecution::estimated_point(
                f(c, "target"),
                cmd.moment,
                now,
                &rec
            ));
        }
        let last = command(&c["last"]);
        out["bring"] = json!(SyncPlayExecution::bring_up_to_date(
            last.as_ref(),
            c["entry"].as_str(),
            now,
            &rec,
            local_point
        ));
        out
    });
}

#[test]
fn syncplay_buffer() {
    assert_equal("syncplay_buffer", |c| {
        let mut g = BufferGuard::new();
        let mut out = vec![];
        for t in c["ticks"].as_array().unwrap() {
            if t["reset"].as_bool().unwrap() {
                g.reset();
            }
            let m = g.tick(f(t, "spot"), t["run"].as_bool().unwrap(), f(t, "now"));
            let name = m.map(|m| {
                if m == BufferMessage::Buffers {
                    "buffers"
                } else {
                    "ready"
                }
            });
            out.push(json!([name, g.buffers()]));
        }
        json!(out)
    });
}

#[test]
fn syncplay_time() {
    assert_equal("syncplay_time", |c| json!(SyncPlay::time_text(f(c, "t"))));
}
