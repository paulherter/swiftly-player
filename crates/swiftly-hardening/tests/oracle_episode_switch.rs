//! Differential oracle, `EpisodeSwitch` (EpisodesSwitch.swift): the same script against a fake host, once
//! through the real Swift class (Tools/Oracle, Domain_EpisodeSwitch.swift) and once through
//! `swiftly_rules::episodes_switch`, driven by a hand-made single-threaded poller. Compared: the sequence of
//! host calls and outcomes and the state after every op (cancellations, late answers, missing plans, closes
//! while the stop, the plan or the start are in flight, a second trigger, lookups across switches).
#![allow(clippy::expect_used, clippy::unwrap_used)]

use std::collections::BTreeMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};

use serde_json::{Value, json};
use swiftly_hardening::oracle::assert_equal;
use swiftly_rules::episodes_switch::{EpisodeSwitch, Outcome, Phase, Steps};

#[derive(Default)]
struct Shared {
    log: Mutex<Vec<String>>,
    /// Pending gates: `None` waiting, `Some(v)` answered but not yet taken.
    gates: Mutex<BTreeMap<String, Option<bool>>>,
}

impl Shared {
    fn add(&self, s: String) {
        self.log.lock().unwrap().push(s);
    }
    fn count(&self) -> usize {
        self.log.lock().unwrap().len()
    }
    fn is_waiting(&self, name: &str) -> bool {
        matches!(self.gates.lock().unwrap().get(name), Some(None))
    }
    fn pending(&self) -> Vec<String> {
        self.gates
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, v)| v.is_none())
            .map(|(k, _)| k.clone())
            .collect()
    }
    fn resolve(&self, name: &str, v: bool) -> bool {
        let mut g = self.gates.lock().unwrap();
        match g.get_mut(name) {
            Some(slot @ None) => {
                *slot = Some(v);
                true
            }
            _ => false,
        }
    }
}

struct Gate {
    shared: Arc<Shared>,
    name: String,
}

impl Future for Gate {
    type Output = bool;
    fn poll(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<bool> {
        let mut g = self.shared.gates.lock().unwrap();
        match g.get(&self.name).copied() {
            None => {
                g.insert(self.name.clone(), None);
                Poll::Pending
            }
            Some(None) => Poll::Pending,
            Some(Some(v)) => {
                g.remove(&self.name);
                Poll::Ready(v)
            }
        }
    }
}

fn gate(shared: &Arc<Shared>, name: String) -> Gate {
    Gate {
        shared: Arc::clone(shared),
        name,
    }
}

type Task = Pin<Box<dyn Future<Output = ()> + Send>>;

/// Polls every task until a whole pass changes nothing.
fn quiesce(shared: &Shared, tasks: &mut Vec<Task>) {
    let mut cx = Context::from_waker(Waker::noop());
    loop {
        let before = shared.count();
        let n = tasks.len();
        tasks.retain_mut(|t| t.as_mut().poll(&mut cx).is_pending());
        if shared.count() == before && tasks.len() == n {
            break;
        }
    }
}

fn phase_name(p: Phase) -> &'static str {
    match p {
        Phase::Rests => "rests",
        Phase::StopAndPlant => "stopAndPlant",
        Phase::Starts => "starts",
        Phase::Closed => "closed",
    }
}

fn outcome_name(o: Outcome) -> &'static str {
    match o {
        Outcome::Switched => "switched",
        Outcome::Locked => "locked",
        Outcome::Cancelled => "cancelled",
        Outcome::Failed => "failed",
    }
}

fn run(ops: &[Value]) -> Vec<String> {
    let s = Arc::new(Shared::default());
    let sw = Arc::new(EpisodeSwitch::new());
    let mut tasks: Vec<Task> = Vec::new();
    let (mut execs, mut closes, mut lookups) = (0_i64, 0_i64, 0_i64);
    let state = |s: &Shared, sw: &EpisodeSwitch| {
        s.add(format!(
            "st:{}:{}:{}",
            phase_name(sw.phase()),
            sw.running(),
            sw.messages_allowed()
        ))
    };
    let resolve = |s: &Arc<Shared>, tasks: &mut Vec<Task>, name: &str, v: bool| {
        if s.is_waiting(name) {
            s.resolve(name, v);
            quiesce(s, tasks);
        }
    };

    for op in ops {
        match op["op"].as_str().unwrap_or("") {
            "exec" => {
                execs += 1;
                let k = execs;
                let [a, b, c, d, e, f] = std::array::from_fn(|_| Arc::clone(&s));
                let steps = Steps {
                    stop_now: Box::new(move || {
                        Box::pin(async move {
                            gate(&a, format!("stop:{k}")).await;
                            a.add(format!("stop:done:{k}"));
                        })
                    }),
                    plan_out: Box::new(move || {
                        Box::pin(async move {
                            let ok = gate(&b, format!("plan:{k}")).await;
                            b.add(format!("plan:done:{k}:{ok}"));
                            ok.then_some(k)
                        })
                    }),
                    apply: Box::new(move |p: &i64| c.add(format!("apply:{k}:{p}"))),
                    start: Box::new(move |p: i64| {
                        Box::pin(async move {
                            d.add(format!("start:begin:{k}:{p}"));
                            gate(&d, format!("start:{k}")).await;
                            d.add(format!("start:done:{k}"));
                        })
                    }),
                    failed: Box::new(move || e.add(format!("failed:{k}"))),
                };
                let sw2 = Arc::clone(&sw);
                tasks.push(Box::pin(async move {
                    let out = sw2.execute(steps).await;
                    f.add(format!("out:{k}:{}", outcome_name(out)));
                }));
                quiesce(&s, &mut tasks);
            }
            "close" => {
                closes += 1;
                let j = closes;
                let a = Arc::clone(&s);
                let stop: swiftly_rules::episodes_switch::StopFn = Box::new(move || {
                    Box::pin(async move {
                        a.add(format!("cstop:begin:{j}"));
                        gate(&a, format!("cstop:{j}")).await;
                        a.add(format!("cstop:done:{j}"));
                    })
                });
                if let Some(now) = sw.close(stop) {
                    tasks.push(now());
                }
                quiesce(&s, &mut tasks);
            }
            "lookup" => {
                lookups += 1;
                let j = lookups;
                let [a, b] = std::array::from_fn(|_| Arc::clone(&s));
                let sw2 = Arc::clone(&sw);
                tasks.push(Box::pin(async move {
                    sw2.look_up(
                        async move {
                            a.add(format!("fetch:begin:{j}"));
                            gate(&a, format!("fetch:{j}")).await;
                            a.add(format!("fetch:done:{j}"));
                            j
                        },
                        |v| b.add(format!("adopt:{v}")),
                    )
                    .await;
                }));
                quiesce(&s, &mut tasks);
            }
            _ => {
                let name = format!(
                    "{}:{}",
                    op["gate"].as_str().unwrap_or(""),
                    op["n"].as_i64().unwrap_or(0)
                );
                resolve(&s, &mut tasks, &name, op["v"].as_bool().unwrap_or(true));
            }
        }
        state(&s, &sw);
    }

    let mut rounds = 0;
    while let Some(name) = s.pending().first().cloned() {
        rounds += 1;
        if rounds > 400 {
            break;
        }
        resolve(&s, &mut tasks, &name, true);
        state(&s, &sw);
    }
    quiesce(&s, &mut tasks);
    state(&s, &sw);
    s.log.lock().unwrap().clone()
}

#[test]
fn episode_switch() {
    assert_equal("episode_switch", |c| {
        let ops = c["ops"].as_array().cloned().unwrap_or_default();
        json!({"log": run(&ops)})
    });
}
