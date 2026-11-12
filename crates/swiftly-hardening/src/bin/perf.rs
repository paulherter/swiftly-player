//! Rust side of the Rust-vs-Swift benchmarks. Prints one JSON line per operation, same keys as the
//! Swift `bench` target (Tools/Oracle): {"op","input","ms","runs"} (2 warm-up runs, median of 7).
//!
//!   cargo run --release -p swiftly-hardening --bin perf -- --write-inputs      (creates the 10k input file)
//!   cargo run --release -p swiftly-hardening --bin perf                         (JSON lines)
//!   cargo run --release -p swiftly-hardening --bin perf -- --swift swift.jsonl --md <baseline.md>
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::hint::black_box;
use std::time::Instant;

use serde_json::Value;
use swiftly_hardening::soak::{host, server, workload};
use swiftly_images::{ImageAddress, ImageKind, ImageMetric, store_key};
use swiftly_jellyfin::ServerKind;
use swiftly_library::TitleFilter;
use swiftly_model::ItemsResponse;
use swiftly_net::Url;
use swiftly_rules::natural_order::{NaturalCollator, NaturalOrder};

const INPUT: &str = "crates/swiftly-hardening/oracle/perf_library_10k.json";

fn median(mut body: impl FnMut() -> usize) -> (f64, usize) {
    for _ in 0..2 {
        black_box(body());
    }
    let mut t: Vec<f64> = (0..7)
        .map(|_| {
            let t0 = Instant::now();
            black_box(body());
            t0.elapsed().as_secs_f64() * 1000.0
        })
        .collect();
    t.sort_by(|a, b| a.partial_cmp(b).unwrap());
    (t[3], 7)
}

fn line(op: &str, input: &str, r: (f64, usize)) -> Value {
    let v = serde_json::json!({"op": op, "input": input, "ms": (r.0 * 10000.0).round() / 10000.0, "runs": r.1});
    println!("{v}");
    v
}

fn core_startup() -> (f64, usize) {
    let base = server::start(10);
    median(|| {
        let ctl = host::Control::new();
        let core = swiftly_uniffi::Core::new(
            std::sync::Arc::new(host::SoakPlatform(std::sync::Arc::clone(&ctl))),
            std::sync::Arc::new(host::SoakSecrets::new(std::sync::Arc::clone(&ctl))),
            std::sync::Arc::new(host::SoakKv::new(std::sync::Arc::clone(&ctl))),
            std::sync::Arc::new(host::SoakHttp::new(ctl)),
        );
        let vm = core
            .home_vm(workload::account(&base, "u1"), "de".into())
            .unwrap();
        vm.send(swiftly_vm::HomeIntent::Load);
        workload::wait_until(5000, || {
            !vm.rails().rails.is_empty() || matches!(vm.status().status, swiftly_vm::Status::Ready)
        });
        vm.rails().rails.len()
    })
}

fn home_warm() -> (f64, usize) {
    let base = server::start(10);
    let ctl = host::Control::new();
    let core = swiftly_uniffi::Core::new(
        std::sync::Arc::new(host::SoakPlatform(std::sync::Arc::clone(&ctl))),
        std::sync::Arc::new(host::SoakSecrets::new(std::sync::Arc::clone(&ctl))),
        std::sync::Arc::new(host::SoakKv::new(std::sync::Arc::clone(&ctl))),
        std::sync::Arc::new(host::SoakHttp::new(ctl)),
    );
    median(|| {
        let vm = core
            .home_vm(workload::account(&base, "u1"), "de".into())
            .unwrap();
        vm.send(swiftly_vm::HomeIntent::Load);
        workload::wait_until(5000, || {
            !vm.rails().rails.is_empty() || matches!(vm.status().status, swiftly_vm::Status::Ready)
        });
        vm.rails().rails.len()
    })
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|a| a == "--write-inputs") {
        std::fs::write(INPUT, server::library_json(10_000)).expect("write input");
        println!("wrote {INPUT}");
        return;
    }
    if !std::path::Path::new(INPUT).exists() {
        std::fs::write(INPUT, server::library_json(10_000)).expect("write input");
    }
    let bytes = std::fs::read(INPUT).expect("input");
    let items = serde_json::from_slice::<ItemsResponse>(&bytes)
        .expect("decode")
        .items;
    let mut out = Vec::new();

    out.push(line(
        "json_decode_10k",
        &format!("10000 items, {} bytes", bytes.len()),
        median(|| serde_json::from_slice::<ItemsResponse>(&bytes).map_or(0, |r| r.items.len())),
    ));

    out.push(line(
        "page_assembly_10k",
        "10000 items, 167 pages of 60",
        median(|| {
            let mut filter = TitleFilter::from_identifiers(&items);
            items.chunks(60).map(|page| filter.sift(page).len()).sum()
        }),
    ));

    let names: Vec<String> = items.iter().map(|i| i.name.clone()).collect();
    let collator = NaturalCollator::new("de").expect("collator");
    out.push(line(
        "natural_sort_10k",
        "10000 titles, locale de",
        median(|| {
            let idx: Vec<(usize, &str)> = names.iter().map(String::as_str).enumerate().collect();
            NaturalOrder::sorted(idx, &collator, |t| (t.1, None)).len()
        }),
    ));

    let address = ImageAddress::new(
        Url::parse("http://127.0.0.1:8096").unwrap(),
        Some("t".into()),
        ServerKind::Jellyfin,
    );
    out.push(line(
        "image_key_100k",
        "100000 construct + store key",
        median(|| {
            let mut n = 0;
            for i in 0..100_000 {
                if let Some(url) = address.construct(
                    &format!("m{}", i % 5000),
                    ImageKind::Poster,
                    Some(&format!("p{}", i % 5000)),
                    ImageMetric::AtMostHigh(300),
                ) {
                    n += store_key(&url).map_or(0, |k| k.len());
                }
            }
            n
        }),
    ));

    out.push(line(
        "device_profile_build",
        "1000 builds",
        median(|| {
            (0..1000)
                .map(|_| {
                    black_box(swiftly_playback::device_profile::DeviceProfile::vlc(
                        1_000_000_000,
                    ))
                    .direct_play_profiles
                    .len()
                })
                .sum()
        }),
    ));

    out.push(line(
        "search_history_10k",
        "10000 remember calls",
        median(|| {
            let mut raw = String::new();
            for i in 0..10_000 {
                raw =
                    swiftly_library::search_history::remember(&format!("wort{} {i}", i % 37), &raw);
            }
            raw.len()
        }),
    ));

    out.push(line(
        "home_paint_warm",
        "2nd HomeVm on a warm Core, until rails",
        home_warm(),
    ));

    out.push(line(
        "home_paint_cold",
        "Core::new + HomeVm until first rails",
        core_startup(),
    ));

    if let (Some(swift), Some(md)) = (flag(&args, "--swift"), flag(&args, "--md")) {
        write_table(&out, &swift, &md);
    }
}

fn flag(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1))
        .cloned()
}

fn sh(cmd: &str, args: &[&str]) -> String {
    std::process::Command::new(cmd)
        .args(args)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .unwrap_or_default()
}

fn write_table(rust: &[Value], swift_file: &str, md: &str) {
    let swift: Vec<Value> = std::fs::read_to_string(swift_file)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect();
    let machine = format!(
        "{} ({}), {}",
        sh("sysctl", &["-n", "machdep.cpu.brand_string"]),
        sh("uname", &["-m"]),
        sh("date", &["+%Y-%m-%d"])
    );
    let mut t = String::from(
        "# Performance baseline: Swift (JellyfinKit) against Rust\n\nRelease builds, 2 warm-up runs, median of 7, same machine, same input file (`crates/swiftly-hardening/oracle/perf_library_10k.json`). Ratio = Rust ms / Swift ms (below 1 means Rust is faster). More than 1.5 is a finding (`hardening-findings.md`, F-perf-NN). Regenerate: `cargo xtask hardening --perf` or the commands in `crates/swiftly-hardening/src/bin/perf.rs`.\n\n| Operation | Input | Swift ms | Rust ms | Ratio | Machine / date |\n|---|---|---|---|---|---|\n",
    );
    for r in rust {
        let op = r["op"].as_str().unwrap_or("");
        let s = swift
            .iter()
            .find(|s| s["op"] == r["op"] && s.get("ms").is_some())
            .and_then(|s| s["ms"].as_f64());
        let rs = r["ms"].as_f64().unwrap_or(0.0);
        let (sw, ratio) = match s {
            Some(s) => (format!("{s:.3}"), format!("{:.2}", rs / s)),
            None => ("n/a".to_owned(), "n/a".to_owned()),
        };
        t += &format!(
            "| {op} | {} | {sw} | {rs:.3} | {ratio} | {machine} |\n",
            r["input"].as_str().unwrap_or("")
        );
    }
    std::fs::write(md, t).expect("write table");
    println!("wrote {md}");
}
