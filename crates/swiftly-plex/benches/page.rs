//! Parse and map benchmark for a Plex library page: `cargo bench -p swiftly-plex --bench page`.

#![allow(clippy::expect_used)]

use std::hint::black_box;
use std::time::Instant;

use swiftly_plex::PlexMapper;
use swiftly_plex::wire::PlexListing;

fn entry(i: usize) -> String {
    format!(
        r#"{{"ratingKey":"{k}","key":"/library/metadata/{k}","guid":"plex://movie/5d776{i:06x}","type":"movie","title":"Title number {i} of the library","titleSort":"title number {i:08}","contentRating":"PG-13","summary":"{ov}","rating":7.{d},"audienceRating":8.{d},"year":{y},"tagline":"A tagline","thumb":"/library/metadata/{k}/thumb/1700000000","art":"/library/metadata/{k}/art/1700000000","duration":{dur},"originallyAvailableAt":"2019-0{m}-1{d}","addedAt":1700000{i:03},"updatedAt":1700001{i:03},"viewCount":{vc},"Image":[{{"alt":"Poster","type":"coverPoster","url":"/library/metadata/{k}/thumb/1"}},{{"alt":"Background","type":"background","url":"/library/metadata/{k}/art/1"}},{{"alt":"Logo","type":"clearLogo","url":"/library/metadata/{k}/clearLogo/1"}}],"UltraBlurColors":{{"topLeft":"3f2a1e","topRight":"1e2f3f","bottomRight":"2a1e3f","bottomLeft":"3f1e2a"}},"Media":[{{"id":{k},"duration":{dur},"bitrate":8000,"width":1920,"height":1080,"aspectRatio":1.78,"audioChannels":6,"audioCodec":"eac3","videoCodec":"h264","videoResolution":"1080","container":"mkv","videoFrameRate":"24p","videoProfile":"high","Part":[{{"id":{k},"key":"/library/parts/{k}/1/file.mkv","duration":{dur},"file":"/data/movies/Title {i}/Title {i}.mkv","size":4000000000,"container":"mkv","videoProfile":"high"}}]}}],"Genre":[{{"tag":"Action"}},{{"tag":"Drama"}},{{"tag":"Science Fiction"}}],"Country":[{{"tag":"USA"}}],"Director":[{{"tag":"A Director"}}],"Writer":[{{"tag":"A Writer"}}],"Role":[{{"tag":"Actor One"}},{{"tag":"Actor Two"}}],"Guid":[{{"id":"imdb://tt{i:07}"}},{{"id":"tmdb://{i}"}},{{"id":"tvdb://{i}"}}]}}"#,
        k = 10_000 + i,
        d = 1 + i % 8,
        m = 1 + i % 9,
        y = 1980 + i % 44,
        dur = 5_400_000 + i,
        vc = i % 3,
        ov = "A long overview text that stands for the synopsis of the film. ".repeat(4),
    )
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
    let items: Vec<String> = (0..5_000).map(entry).collect();
    let body = format!(
        r#"{{"MediaContainer":{{"size":5000,"totalSize":5000,"offset":0,"Metadata":[{}]}}}}"#,
        items.join(",")
    )
    .into_bytes();
    println!("5k plex page body = {} KiB", body.len() / 1024);
    time("plex: parse 5k MediaContainer (wire)", 15, || {
        PlexListing::from_body(&body).map(|l| l.metadata.len())
    });
    let listing = PlexListing::from_body(&body).expect("fixture parses");
    let mapper = PlexMapper::new();
    time("plex: map 5k PlexMetadata to Item", 15, || {
        listing.metadata.iter().fold(0usize, |n, m| {
            black_box(mapper.item(m));
            n + 1
        })
    });
}
