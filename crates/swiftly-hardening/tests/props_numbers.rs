//! Hostile numbers (NaN, infinity, -1, i64::MAX, 1e30, ...) against the public decode, format
//! and compute functions that take numbers from a server. Nothing may panic or overflow (the
//! tests run in the debug profile, where overflow panics). A failure prints the seed; replay
//! with `HARDENING_SEED=<n>`. Findings: F-cast-*.
#![allow(clippy::expect_used, clippy::unwrap_used)]

mod common;

use serde_json::{Value, json};
use swiftly_downloads::rules::{DownloadRules, ProgressEstimator};
use swiftly_downloads::size_text;
use swiftly_hardening::Rng;
use swiftly_model::{Item, parse_timestamp, seconds_from_ticks, ticks_from_seconds};
use swiftly_playback::trickplay::{Trickplay, TrickplayResponse};
use swiftly_plex::{PlexBif, merge};
use swiftly_sync::time::time_text;

const HOSTILE_INTS: [i64; 12] = [
    0,
    1,
    -1,
    2,
    255,
    65_535,
    2_147_483_647,
    4_294_967_295,
    i64::MAX,
    i64::MIN,
    i64::MAX - 1,
    i64::MIN + 1,
];
const HOSTILE_FLOATS: [f64; 14] = [
    0.0,
    -0.0,
    1.0,
    -1.0,
    0.5,
    1e15,
    1e19,
    1e30,
    -1e30,
    f64::MAX,
    f64::MIN,
    f64::NAN,
    f64::INFINITY,
    f64::NEG_INFINITY,
];

fn int(rng: &mut Rng) -> i64 {
    if rng.chance(70) {
        *rng.pick(&HOSTILE_INTS)
    } else {
        rng.next_u64() as i64
    }
}

fn float(rng: &mut Rng) -> f64 {
    if rng.chance(70) {
        *rng.pick(&HOSTILE_FLOATS)
    } else {
        f64::from_bits(rng.next_u64())
    }
}

/// A JSON number: integer, float (non-finite ones cannot be written, they become strings) or a string.
fn number(rng: &mut Rng) -> Value {
    match rng.below(4) {
        0 => json!(int(rng)),
        1 => json!(rng.next_u64()),
        2 => serde_json::Number::from_f64(float(rng)).map_or_else(|| json!("NaN"), Value::Number),
        _ => json!(format!("{}", int(rng))),
    }
}

#[test]
fn ticks_and_seconds() {
    common::for_seeds("props_numbers", 400, |seed| {
        let mut rng = Rng::new(seed);
        let s = float(&mut rng);
        let t = ticks_from_seconds(s);
        assert!(t >= 0, "ticks {t} for {s}");
        let _ = seconds_from_ticks(int(&mut rng));
        let _ = swiftly_jellyfin::ticks_from_seconds(s);
        let _ = swiftly_jellyfin::seconds_from_ticks(int(&mut rng));
        assert!(!time_text(s).is_empty());
        let _ = parse_timestamp(&format!("{}", float(&mut rng)));
    });
}

#[test]
fn item_decode_with_hostile_numbers() {
    let keys = [
        "RunTimeTicks",
        "ProductionYear",
        "IndexNumber",
        "ParentIndexNumber",
        "CommunityRating",
        "CriticRating",
        "ChildCount",
        "PlaybackPositionTicks",
        "PlayCount",
        "UnplayedItemCount",
        "Width",
        "Height",
        "Bitrate",
        "Size",
        "RecursiveItemCount",
        "AirsBeforeSeasonNumber",
        "LocalTrailerCount",
        "DvProfile",
        "DvBlCompatibilityId",
    ];
    common::for_seeds("props_numbers", 400, |seed| {
        let mut rng = Rng::new(seed);
        let mut item = json!({ "Id": "x", "Name": "n", "Type": "Movie" });
        let mut data = json!({});
        let mut stream = json!({ "Type": "Video", "Index": number(&mut rng) });
        for key in keys {
            if rng.chance(60) {
                item[key] = number(&mut rng);
                data[key] = number(&mut rng);
                stream[key] = number(&mut rng);
            }
        }
        item["UserData"] = data;
        item["MediaStreams"] = json!([stream]);
        item["MediaSources"] = json!([{ "Id": "s", "MediaStreams": [stream], "RunTimeTicks": number(&mut rng), "Bitrate": number(&mut rng), "Size": number(&mut rng) }]);
        if let Ok(decoded) = serde_json::from_value::<Item>(item) {
            if let Some(share) = decoded.watched_share() {
                assert!(
                    (0.0..=1.0).contains(&share) || share.is_nan(),
                    "share {share}"
                );
            }
            let _ = serde_json::to_string(&decoded);
        }
    });
}

#[test]
fn sizes_and_progress() {
    common::for_seeds("props_numbers", 400, |seed| {
        let mut rng = Rng::new(seed);
        let _ = size_text::size(int(&mut rng), ",");
        let _ = size_text::fixed(float(&mut rng), (rng.below(4)) as usize, ".");
        let _ = DownloadRules::reached_end(int(&mut rng), Some(int(&mut rng)));
        let _ = DownloadRules::reached_end(int(&mut rng), None);
        let mut estimator = ProgressEstimator::new();
        let mut now = float(&mut rng);
        for _ in 0..8 {
            estimator.report(int(&mut rng), int(&mut rng), now);
            now = if rng.chance(50) {
                float(&mut rng)
            } else {
                now + 1.0
            };
            let _ = estimator.value(now);
            if rng.chance(20) {
                estimator.halt();
            }
        }
    });
}

#[test]
fn trickplay_from_hostile_details() {
    common::for_seeds("props_numbers", 400, |seed| {
        let mut rng = Rng::new(seed);
        let t = Trickplay {
            width: int(&mut rng),
            height: int(&mut rng),
            tiles_wide: int(&mut rng),
            tiles_up: int(&mut rng),
            count: int(&mut rng),
            interval: int(&mut rng),
        };
        let _ = t.tile(float(&mut rng));
        let _ = Trickplay::choose(&[t, t], int(&mut rng));
        let detail = json!({ "Width": number(&mut rng), "Height": number(&mut rng), "TileWidth": number(&mut rng), "TileHeight": number(&mut rng), "ThumbnailCount": number(&mut rng), "Interval": number(&mut rng) });
        let text = json!({ "Id": "e", "Name": "n", "Trickplay": { "src": { "320": detail } } })
            .to_string();
        if let Ok(response) = serde_json::from_str::<TrickplayResponse>(&text)
            && let Some(chosen) = response.of(None).or_else(|| response.of(Some("src")))
        {
            let _ = chosen.tile(float(&mut rng));
        }
    });
}

fn le(v: u32) -> [u8; 4] {
    v.to_le_bytes()
}

#[test]
fn bif_with_hostile_header_words() {
    common::for_seeds("props_numbers", 400, |seed| {
        let mut rng = Rng::new(seed);
        let count = if rng.chance(70) {
            rng.below(6) as u32
        } else {
            rng.next_u64() as u32
        };
        let mut data = vec![0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A];
        data.extend(le(0));
        data.extend(le(count));
        data.extend(le(if rng.chance(50) {
            u32::MAX
        } else {
            rng.next_u64() as u32
        }));
        data.extend([0u8; 44]);
        for _ in 0..(count.min(5) + 1) * 2 {
            data.extend(le(if rng.chance(50) {
                u32::MAX
            } else {
                rng.next_u64() as u32
            }));
        }
        data.extend((0..rng.below(64)).map(|_| rng.next_u64() as u8));
        if let Some(bif) = PlexBif::parse(&data) {
            let _ = bif.image_at_seconds(float(&mut rng));
            let _ = bif.image(int(&mut rng));
            let _ = bif.interval();
            let _ = bif.picture_size();
        }
        // A page of nothing, asked for hostile positions.
        let _ = merge::page(&[], int(&mut rng), None, int(&mut rng), int(&mut rng));
        let _ = merge::window(&[int(&mut rng).max(0), 3], int(&mut rng), int(&mut rng));
    });
}

#[test]
fn image_entry_points_with_hostile_sizes() {
    use swiftly_images::blurhash;
    use swiftly_images::decode::{self, Decoded, RustDecoder};
    use swiftly_images::{Device, MemoryImageCache, PixelDecoder, border_for, mood, tone};
    common::for_seeds("props_numbers", 400, |seed| {
        let mut rng = Rng::new(seed);
        // Pictures whose fields do not fit their pixels (the fields are public).
        let dim = |rng: &mut Rng| {
            *rng.pick(&[
                0u32,
                1,
                2,
                3,
                255,
                65_535,
                u32::MAX,
                u32::MAX - 1,
                2_147_483_648,
            ])
        };
        let pixels: Vec<u8> = (0..rng.below(64)).map(|_| rng.next_u64() as u8).collect();
        let picture = Decoded {
            width: dim(&mut rng),
            height: dim(&mut rng),
            rgba: pixels,
        };
        let _ = picture.cost();
        let _ = decode::orient(picture.clone(), rng.below(12) as u8);
        let _ = decode::downscale(picture.clone(), dim(&mut rng));
        let _ = decode::downscale_fast(picture.clone(), dim(&mut rng));
        let _ = decode::premultiplied(&picture);
        let _ = decode::mip_chain(&picture, rng.below(40) as usize);
        let _ = border_for(Some(float(&mut rng) as f32), Device::Phone);
        // Files with an image signature and a damaged body, a hostile EXIF block included.
        let mut bytes = match rng.below(3) {
            0 => vec![
                0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x20, b'E', b'x', b'i', b'f', 0, 0,
            ],
            1 => vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A],
            _ => b"RIFF\0\0\0\0WEBP".to_vec(),
        };
        bytes.extend(if rng.chance(50) {
            b"MM\0*".to_vec()
        } else {
            b"II*\0".to_vec()
        });
        bytes.extend((0..rng.below(48)).map(|_| {
            if rng.chance(40) {
                0xFF
            } else {
                rng.next_u64() as u8
            }
        }));
        let _ = decode::jpeg_orientation(&bytes);
        let _ = RustDecoder.decode(&bytes, dim(&mut rng));
        let hash: String = (0..rng.below(40))
            .map(|_| *rng.pick(&['0', '1', 'L', 'E', 'H', '~', '$', 'é']))
            .collect();
        let _ = blurhash::decode(&hash, dim(&mut rng), dim(&mut rng));
        let mut cache: MemoryImageCache<u8> = MemoryImageCache::new(rng.next_u64() as usize);
        for i in 0..6 {
            cache.insert(
                &format!("k{}", i % 3),
                0,
                if rng.chance(50) {
                    usize::MAX
                } else {
                    rng.next_u64() as usize
                },
            );
        }
        let _ = tone::tones_from_rgba(&picture.rgba);
        let _ = mood::mesh(
            &[float(&mut rng), float(&mut rng)],
            float(&mut rng),
            float(&mut rng),
            float(&mut rng),
            float(&mut rng),
        );
    });
}

#[test]
fn model_entry_points_with_hostile_numbers() {
    use swiftly_model::PlaybackInfoResponse;
    common::for_seeds("props_numbers", 400, |seed| {
        let mut rng = Rng::new(seed);
        let stream = json!({
            "Type": *rng.pick(&["Audio", "Video", "Subtitle"]), "Index": number(&mut rng), "Channels": number(&mut rng),
            "RealFrameRate": number(&mut rng), "AverageFrameRate": number(&mut rng), "BitRate": number(&mut rng),
            "Width": number(&mut rng), "Height": number(&mut rng), "DvProfile": number(&mut rng), "Language": "deu",
        });
        let source = json!({ "Id": "s", "RunTimeTicks": number(&mut rng), "Size": number(&mut rng), "Bitrate": number(&mut rng), "MediaStreams": [stream] });
        let text = json!({ "MediaSources": [source.clone(), source] }).to_string();
        if let Ok(info) = serde_json::from_str::<PlaybackInfoResponse>(&text) {
            for source in &info.media_sources {
                if let Some(seconds) = source.runtime_seconds() {
                    assert!(seconds > 0.0, "runtime {seconds}");
                }
                for stream in source.media_streams.iter().flatten() {
                    let _ = stream.frame_rate();
                    let _ = stream.short();
                }
            }
        }
        let item = json!({
            "Id": "e", "Name": "n", "Type": *rng.pick(&["Episode", "Season", "Series", "Movie"]),
            "ParentIndexNumber": number(&mut rng), "IndexNumber": number(&mut rng), "ChildCount": number(&mut rng),
            "UnplayedItemCount": number(&mut rng), "RunTimeTicks": number(&mut rng), "ProductionYear": number(&mut rng),
            "UserData": { "PlaybackPositionTicks": number(&mut rng), "PlayCount": number(&mut rng), "LastPlayedDate": "2026-09-03T14:10:09Z" },
        });
        if let Ok(item) = serde_json::from_value::<Item>(item) {
            let _ = item.episode_code();
            let _ = item.new_arrivals_row();
            let _ = item.context_line();
            let _ = item.runtime_seconds();
            let _ = item.kind();
            let _ = item.is_watched();
            let _ = item.watched_share();
        }
        // The list wrapper reads a hostile total.
        let _ = serde_json::from_value::<swiftly_model::ItemsResponse>(
            json!({ "Items": [], "TotalRecordCount": number(&mut rng) }),
        );
    });
}
