#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::print_stdout,
    missing_docs
)]
//! JSON engines on the real `ItemsResponse` decode path: serde_json (today), serde_json with a
//! strict first pass (no DOM), sonic-rs and simd-json. Every engine's output must equal today's.

use std::hint::black_box;
use std::time::Instant;

use serde::Deserialize;
use swiftly_model::{Item, ItemsResponse};

fn entry(i: usize) -> String {
    let tag = format!("{:032x}", i * 7919);
    let kind = ["Movie", "Series", "Episode"][i % 3];
    format!(
        r#"{{"Name":"Title number {i}","ServerId":"0123456789abcdef0123456789abcdef","Id":"{i:032x}","HasSubtitles":true,"Container":"mkv","PremiereDate":"2019-01-11T00:00:00.0000000Z","CommunityRating":7.5,"RunTimeTicks":{rt},"ProductionYear":{y},"IsFolder":false,"Type":"{kind}","UserData":{{"PlaybackPositionTicks":0,"PlayCount":1,"IsFavorite":false,"Played":false,"Key":"tmdb{i}","ItemId":"00000000000000000000000000000000","PlayedPercentage":12.5}},"PrimaryImageAspectRatio":0.6666666666666666,"SortName":"title number {i:08}","DateCreated":"2023-02-03T12:00:00.0000000Z","ProviderIds":{{"Tmdb":"{i}","Imdb":"tt{i:07}"}},"Genres":["Action","Drama"],"SeriesId":"{i:032x}","ImageTags":{{"Primary":"{tag}"}},"MediaType":"Video"}}"#,
        rt = 5_400_000_000i64 + i as i64,
        y = 1980 + i % 44,
    )
}

fn page(n: usize) -> Vec<u8> {
    let items: Vec<String> = (0..n).map(entry).collect();
    format!(
        r#"{{"Items":[{}],"TotalRecordCount":{n}}}"#,
        items.join(",")
    )
    .into_bytes()
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct Strict {
    items: Vec<Item>,
    total_record_count: i64,
}

fn time<T>(runs: usize, mut f: impl FnMut() -> T) -> f64 {
    let mut v: Vec<f64> = (0..runs)
        .map(|_| {
            let t = Instant::now();
            black_box(f());
            t.elapsed().as_secs_f64() * 1000.0
        })
        .collect();
    v.sort_by(f64::total_cmp);
    v[v.len() / 2]
}

fn main() {
    for n in [100usize, 5000] {
        let bytes = page(n);
        let runs = if n > 1000 { 15 } else { 200 };
        let base: ItemsResponse = serde_json::from_slice(&bytes).unwrap();
        let strict: Strict = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(base.items, strict.items);
        assert_eq!(base.total_record_count, strict.total_record_count);
        let sonic: ItemsResponse = sonic_rs::from_slice(&bytes).unwrap();
        assert_eq!(base, sonic, "sonic-rs output differs");
        let mut buf = bytes.clone();
        let simd: ItemsResponse = simd_json::serde::from_slice(&mut buf).unwrap();
        assert_eq!(base, simd, "simd-json output differs");
        println!(
            "== {n} items, {} KB, arch {}",
            bytes.len() / 1024,
            std::env::consts::ARCH
        );
        println!(
            "  serde_json lenient (today)   {:>8.3} ms",
            time(runs, || serde_json::from_slice::<ItemsResponse>(&bytes)
                .unwrap())
        );
        println!(
            "  serde_json strict first pass {:>8.3} ms",
            time(runs, || serde_json::from_slice::<Strict>(&bytes).unwrap())
        );
        println!(
            "  serde_json Value only        {:>8.3} ms",
            time(runs, || serde_json::from_slice::<serde_json::Value>(&bytes)
                .unwrap())
        );
        println!(
            "  sonic-rs lenient             {:>8.3} ms",
            time(runs, || sonic_rs::from_slice::<ItemsResponse>(&bytes)
                .unwrap())
        );
        println!(
            "  sonic-rs strict              {:>8.3} ms",
            time(runs, || sonic_rs::from_slice::<Strict>(&bytes).unwrap())
        );
        println!(
            "  simd-json lenient (+copy)    {:>8.3} ms",
            time(runs, || {
                let mut b = bytes.clone();
                simd_json::serde::from_slice::<ItemsResponse>(&mut b).unwrap()
            })
        );
        println!(
            "  simd-json strict (+copy)     {:>8.3} ms",
            time(runs, || {
                let mut b = bytes.clone();
                simd_json::serde::from_slice::<Strict>(&mut b).unwrap()
            })
        );
    }
}
