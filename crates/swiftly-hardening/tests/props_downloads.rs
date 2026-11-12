//! Model-based random sequences for `DownloadManagerState`. A failure prints the seed; replay
//! with `HARDENING_SEED=<n>`.

mod common;

use std::collections::HashMap;

use swiftly_downloads::{
    Art, DownloadItem, DownloadManagerState, DownloadState, Effect, Intent, TaskParts,
};
use swiftly_hardening::Rng;
use swiftly_rules::download_audio::AudioTrackRules;

struct Fake;

impl AudioTrackRules for Fake {
    fn language_key(&self, language: Option<&str>) -> Option<String> {
        language.map(str::to_owned)
    }
    fn language_label(&self, key: &str) -> Option<String> {
        Some(key.to_owned())
    }
    fn audio_label(&self, l: Option<&str>, c: Option<&str>, _: Option<i64>) -> Option<String> {
        Some(format!("{}{}", l.unwrap_or("?"), c.unwrap_or("?")))
    }
    fn distinct(&self, labels: Vec<String>) -> Vec<String> {
        labels
    }
    fn preferred_audio_index(
        &self,
        _: &[swiftly_rules::download_audio::AudioStream],
        _: &str,
    ) -> Option<i64> {
        None
    }
    fn all_label(&self) -> String {
        "all".into()
    }
    fn track_word(&self) -> String {
        "track".into()
    }
}

const POOL: usize = 7;

fn label(i: &Intent) -> String {
    match i {
        Intent::Add { items, .. } => format!(
            "Add{:?}",
            items.iter().map(|i| i.id.as_str()).collect::<Vec<_>>()
        ),
        Intent::Halt(x) => format!("Halt({x})"),
        Intent::Resume(x) => format!("Resume({x})"),
        Intent::Remove(x) => format!("Remove({x:?})"),
        Intent::AddressReady { id, generation, .. } => format!("AddressReady({id},{generation})"),
        Intent::AddressFailed { id, generation, .. } => format!("AddressFailed({id},{generation})"),
        Intent::Progress {
            parts,
            loaded,
            total,
            ..
        } => format!(
            "Progress({},{},{loaded}/{total})",
            parts.id, parts.generation
        ),
        Intent::TransferFinished { parts, worked, .. } => {
            format!("Finished({},{},{worked})", parts.id, parts.generation)
        }
        Intent::TransferFailed { parts, resume, .. } => format!(
            "Failed({},{},resume={})",
            parts.id,
            parts.generation,
            resume.is_some()
        ),
        Intent::NetworkChanged { wlan, none } => format!("Network(wlan={wlan},none={none})"),
        Intent::AllHalt => "AllHalt".into(),
        Intent::AllRemove => "AllRemove".into(),
        Intent::Tick => "Tick".into(),
        _ => "other".into(),
    }
}

fn id(n: usize) -> String {
    format!("d{n}")
}

fn fresh(rng: &mut Rng, n: usize, now: f64) -> DownloadItem {
    let art = if rng.chance(30) {
        Art::Episode
    } else {
        Art::Film
    };
    let mut it = DownloadItem::new(
        id(n),
        "u1",
        art,
        format!("T{n}"),
        rng.range(0, 3_000_000) * 1000,
        now,
    );
    it.container = Some("mkv".into());
    it
}

fn case(seed: u64) {
    let mut rng = Rng::new(seed ^ 0xD0);
    let mut m = DownloadManagerState::new(1000, rng.chance(30), rng.chance(50), Box::new(Fake));
    let mut now = 1_000_000.0f64;
    let mut open_addr: Vec<(String, i64)> = Vec::new();
    let mut open_tx: Vec<TaskParts> = Vec::new();
    let stored: Vec<DownloadItem> = (0..rng.below(3) as usize)
        .map(|n| {
            let mut it = fresh(&mut rng, n, now);
            it.state = *rng.pick(&DownloadState::ALL);
            if it.state == DownloadState::Done {
                it.loaded = it.bytes;
            }
            it
        })
        .collect();
    let mut log: Vec<String> = Vec::new();
    let absorb = |effects: Vec<Effect>,
                  open_addr: &mut Vec<(String, i64)>,
                  open_tx: &mut Vec<TaskParts>| {
        for e in effects {
            match e {
                Effect::RequestAddress { id, generation, .. } => open_addr.push((id, generation)),
                Effect::StartTransfer { parts, .. } => open_tx.push(parts),
                Effect::CancelTransfer { id, .. } => open_tx.retain(|p| p.id != id),
                _ => {}
            }
        }
    };
    let fx = m.handle(Intent::SignIn {
        account: Some("u1".into()),
        stored,
        client: true,
    });
    absorb(fx, &mut open_addr, &mut open_tx);
    let fx = m.handle(Intent::RunningTransfers(vec![]));
    absorb(fx, &mut open_addr, &mut open_tx);
    let fx = m.handle(Intent::SpaceChanged(500_000_000_000));
    absorb(fx, &mut open_addr, &mut open_tx);

    let mut prev: HashMap<String, DownloadState> =
        m.entries().into_iter().map(|e| (e.id, e.state)).collect();
    for step in 0..150 {
        now += rng.range(1, 30) as f64;
        // Ids an explicit user intent touches this step (retry / re-add is allowed to move them).
        let mut explicit: Vec<String> = Vec::new();
        let intent = match rng.below(100) {
            0..=14 => {
                let items: Vec<DownloadItem> = (0..rng.range(1, 3))
                    .map(|_| {
                        let n = rng.below(POOL as u64) as usize;
                        fresh(&mut rng, n, now)
                    })
                    .collect();
                // Adding an id that already exists is a retry request of that id.
                explicit.extend(items.iter().map(|i| i.id.clone()));
                Intent::Add {
                    items,
                    images: HashMap::new(),
                    check_space: rng.chance(30),
                }
            }
            15..=22 => {
                let i = id(rng.below(POOL as u64) as usize);
                explicit.push(i.clone());
                Intent::Halt(i)
            }
            23..=32 => {
                let i = id(rng.below(POOL as u64) as usize);
                explicit.push(i.clone());
                Intent::Resume(i)
            }
            33..=38 => {
                let ids: Vec<String> = (0..rng.range(1, 3))
                    .map(|_| id(rng.below(POOL as u64) as usize))
                    .collect();
                explicit.extend(ids.iter().cloned());
                Intent::Remove(ids)
            }
            39..=40 => {
                explicit.extend((0..POOL).map(id));
                Intent::AllHalt
            }
            41 if rng.chance(30) => Intent::AllRemove,
            42..=46 => Intent::Tick,
            47..=60 if !open_addr.is_empty() => {
                let (i, g) = rng.pick(&open_addr).clone();
                open_addr.retain(|(x, _)| *x != i);
                let g = if rng.chance(20) { g - 1 } else { g };
                if rng.chance(75) {
                    Intent::AddressReady {
                        id: i,
                        generation: g,
                        address: "https://srv/x".into(),
                    }
                } else {
                    Intent::AddressFailed {
                        id: i,
                        generation: g,
                        reason: "no".into(),
                    }
                }
            }
            61..=78 if !open_tx.is_empty() => {
                let mut p = rng.pick(&open_tx).clone();
                if rng.chance(15) {
                    p.generation -= 1;
                }
                match rng.below(4) {
                    0 | 1 => {
                        let total = rng.range(0, 3_000_000_000);
                        Intent::Progress {
                            parts: p,
                            loaded: rng.range(0, total.max(1)),
                            total,
                            now,
                        }
                    }
                    2 => {
                        open_tx.retain(|q| q.id != p.id);
                        Intent::TransferFinished {
                            parts: p,
                            worked: rng.chance(85),
                            real_size: rng.chance(50).then(|| rng.range(0, 3_000_000_000)),
                        }
                    }
                    _ => {
                        open_tx.retain(|q| q.id != p.id);
                        Intent::TransferFailed {
                            parts: p,
                            reason: "boom".into(),
                            resume: rng.chance(50).then(|| vec![1, 2, 3]),
                        }
                    }
                }
            }
            79..=82 => Intent::NetworkChanged {
                wlan: rng.chance(50),
                none: rng.chance(30),
            },
            83 => Intent::SetOnlyOverWlan(rng.chance(50)),
            84 => Intent::SpaceChanged(rng.range(0, 8_000_000_000)),
            85 => Intent::SetNextAuto(rng.chance(50)),
            86 => Intent::ResumeData {
                id: id(rng.below(POOL as u64) as usize),
                generation: rng.range(990, 1100),
                data: vec![9],
            },
            _ => Intent::Tick,
        };
        let label = label(&intent);
        log.push(label.clone());
        let fx = m.handle(intent);
        absorb(fx, &mut open_addr, &mut open_tx);

        let entries = m.entries();
        let mut seen = std::collections::HashSet::new();
        let tail = || log[log.len().saturating_sub(6)..].join(" | ");
        let mut loading = 0;
        for e in &entries {
            assert!(
                seen.insert(e.id.clone()),
                "step {step}: duplicate id {} after {label}",
                e.id
            );
            assert!(
                e.bytes >= 0 && e.loaded >= 0,
                "step {step}: negative bytes/loaded for {} after {label}",
                e.id
            );
            if e.state == DownloadState::Loads {
                loading += 1;
            }
            if let Some(&was) = prev.get(&e.id) {
                // A finished download stays finished unless the user acts on it. (Error and
                // Halted are not pinned: late transfer reports legitimately move them, and the
                // driver cannot tell a late report from a lost one.)
                if !explicit.contains(&e.id) && was == DownloadState::Done {
                    assert!(
                        e.state == DownloadState::Done,
                        "step {step}: {} moved Done -> {:?} without an explicit intent; tail: {}",
                        e.id,
                        e.state,
                        tail()
                    );
                }
            }
        }
        assert!(
            loading <= 1,
            "step {step}: {loading} downloads load at once; tail: {}",
            tail()
        );
        prev = entries.into_iter().map(|e| (e.id, e.state)).collect();
    }
    // Closing: halting everything leaves nothing loading.
    let _ = m.handle(Intent::AllHalt);
    assert!(
        m.entries().iter().all(|e| e.state != DownloadState::Loads),
        "AllHalt left something loading"
    );
}

#[test]
fn download_manager_random_sequences() {
    common::for_seeds("props_downloads", 300, case);
}
