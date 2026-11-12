//! Parse, clone and size benchmark for [`Item`] lists (plain `Instant`, no extra crates):
//! `cargo bench -p swiftly-model --bench parse`.

use std::hint::black_box;
use std::time::Instant;

use swiftly_model::{Item, ItemsResponse};

/// One realistic list entry as Jellyfin sends it with the list fields.
fn entry(i: usize) -> String {
    let kind = ["Movie", "Series", "Episode"][i % 3];
    format!(
        r#"{{"Name":"Title number {i} of the library: a long name","ServerId":"0123456789abcdef0123456789abcdef","Id":"{i:032x}","HasSubtitles":true,"Container":"mkv","PremiereDate":"2019-0{m}-1{d}T00:00:00.0000000Z","CriticRating":{c},"OfficialRating":"PG-13","ChannelId":null,"CommunityRating":7.{d},"RunTimeTicks":{rt},"ProductionYear":{y},"IsFolder":false,"Type":"{kind}","UserData":{{"PlaybackPositionTicks":0,"PlayCount":{pc},"IsFavorite":false,"Played":false,"Key":"tmdb{i}","ItemId":"00000000000000000000000000000000","PlayedPercentage":{pp}.5,"LastPlayedDate":"2024-01-0{d}T10:00:00.0000000Z"}},"PrimaryImageAspectRatio":0.6666666666666666,"Overview":"{ov}","SortName":"title number {i:08}","DateCreated":"2023-0{m}-0{d}T12:00:00.0000000Z","ProviderIds":{{"Tmdb":"{i}","Imdb":"tt{i:07}","Tvdb":"{i}"}},"Genres":["Action","Drama","Science Fiction"],"ParentIndexNumber":{d},"IndexNumber":{m},"SeriesName":"A series","SeriesId":"{i:032x}","ImageTags":{{"Primary":"{tag}","Thumb":"{tag}","Logo":"{tag}"}},"BackdropImageTags":["{tag}"],"MediaType":"Video","LocationType":"FileSystem"}}"#,
        m = 1 + i % 9,
        d = 1 + i % 8,
        c = 50 + i % 40,
        rt = 5_400_000_000i64 + i as i64,
        y = 1980 + i % 44,
        pc = i % 3,
        pp = i % 100,
        ov = "A long overview text that stands for the synopsis of the film. ".repeat(4),
        tag = format!("{:032x}", i * 7919),
    )
}

fn page(n: usize) -> Vec<u8> {
    let items: Vec<String> = (0..n).map(entry).collect();
    format!(
        r#"{{"Items":[{}],"TotalRecordCount":{n},"StartIndex":0}}"#,
        items.join(",")
    )
    .into_bytes()
}

fn time<R>(label: &str, runs: usize, mut f: impl FnMut() -> R) {
    let mut samples: Vec<f64> = (0..runs)
        .map(|_| {
            let t = Instant::now();
            black_box(f());
            t.elapsed().as_secs_f64() * 1000.0
        })
        .collect();
    samples.sort_by(f64::total_cmp);
    println!(
        "{label:<44} median {:>9.3} ms   min {:>9.3} ms",
        samples[samples.len() / 2],
        samples[0]
    );
}

fn main() {
    let body = page(10_000);
    println!("Item size_of = {} bytes", std::mem::size_of::<Item>());
    println!("10k page body = {} KiB", body.len() / 1024);
    time("jellyfin: parse 10k ItemsResponse", 15, || {
        serde_json::from_slice::<ItemsResponse>(&body).map(|r| r.items.len())
    });
    let items = serde_json::from_slice::<ItemsResponse>(&body)
        .map(|r| r.items)
        .unwrap_or_default();
    time("jellyfin: clone 10k Items", 15, || items.clone());
    let heap: usize = items
        .iter()
        .map(|i| {
            i.id.capacity()
                + i.name.capacity()
                + i.overview.as_ref().map_or(0, String::capacity)
                + i.genres.as_ref().map_or(0, |g| {
                    g.iter().map(String::capacity).sum::<usize>() + g.capacity() * 24
                })
        })
        .sum();
    println!(
        "approx heap of ids/names/overview/genres = {} KiB",
        heap / 1024
    );
    let small = page(200);
    time("jellyfin: parse 200 ItemsResponse", 100, || {
        serde_json::from_slice::<ItemsResponse>(&small).map(|r| r.items.len())
    });
}
