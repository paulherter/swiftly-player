//! `cargo xtask fixture-server [--port N] [--big] [--real-shapes] [--slow-downloads] [--mode ...]`: a small Jellyfin-shaped HTTP server for the real-app runs. Auth (password
//! and Quick Connect), views, items, resume and next up, detail with a media source, seasons and episodes, generated
//! pictures, a playable test clip (16-bit WAV tone served with ranges) and the playback reports. Everything is
//! deterministic and read-only; user `demo`, password `demo` (or empty). Not a Jellyfin replacement: only what the
//! Rust app asks for.
//!
//! # Real shapes (opt-in)
//!
//! `cargo xtask fixture-server --port 8096 --real-shapes` (or `SWIFTLY_FIXTURE_REAL=1` in the environment) serves the
//! shapes a real server has and the plain fixture does not. Without the switch every answer stays byte-identical.
//! The user is `demo` (id `u1`; `u-<SWIFTLY_FIXTURE_ID>` when that is set) and carries `PrimaryImageTag` `avatar1`.
//!
//! | What | Id(s) |
//! |---|---|
//! | Library "Filme" (movies): 5 films `ra0..ra4` + the virtual movie | `rl-movies-a` |
//! | Library "Filme 4K" (movies): the same 5 films as `rb0..rb4`, `ProviderIds.Tmdb` = `1000 + n` | `rl-movies-b` |
//! | Library "Heimvideos" (`homevideos`): 3 clips typed `Movie`, no Tmdb id | `rl-home`, clips `hv0..hv2` |
//! | Library "Serien" (`tvshows`) | `rl-shows` |
//! | Missing movie, `LocationType: "Virtual"`, listed in `rl-movies-a`, no media sources | `rv1` |
//! | Series "Küstenwache" | `rs1` |
//! | Season 2 of it (`SeriesId`, `SeriesName`, `IndexNumber`); children via `Shows/rs1/Episodes?SeasonId=rse1` or `Items?ParentId=rse1` | `rse1` |
//! | Episodes of that season, `DateCreated` rising with the number; `Items/Latest` and `Items?SortBy=DateCreated` list them newest first | `re1..re4` |
//! | People (`Type` Person, picture tag `p<id>`); `Items?PersonIds=<id>` lists films and the series | `rp1`, `rp2` |
//! | User picture (PNG; `maxHeight`/`maxWidth` set the size) | `/Users/u1/Images/Primary`, `/UserImage` |
//!
//! Also in this mode: `/Users`, `/Users/Me`, `/Users/Public` and the auth answers carry `PrimaryImageTag`; the movie
//! detail `People` lists actors `rp1`/`rp2` with `PrimaryImageTag`; `Items` without a parent lists the whole catalogue
//! (each shared film twice, so a client has to merge by Tmdb id); every image route serves a small generated PNG.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};

const NAMES: [&str; 6] = [
    "Nordlicht",
    "Sommerregen",
    "Die Brücke",
    "Stilles Wasser",
    "Papierschiffe",
    "Nachtzug",
];

pub(crate) fn movie(i: usize) -> String {
    let resume = if i.is_multiple_of(2) {
        r#""PlaybackPositionTicks":3000000000,"PlayedPercentage":25.0,"Played":false"#
    } else {
        r#""Played":false"#
    };
    format!(
        r#"{{"Id":"m{i}","Name":"{}","Type":"Movie","ProductionYear":{},"RunTimeTicks":120000000,"Overview":"Ein ruhiger Testfilm vom Fixture-Server.","Genres":["Drama"],"CommunityRating":7.5,"OfficialRating":"FSK 12","People":[{{"Id":"p1","Name":"Anna Test","Type":"Actor","Role":"Hauptrolle","PrimaryImageTag":"pp1"}},{{"Id":"p2","Name":"Ben Regie","Type":"Director"}}],"RemoteTrailers":[{{"Url":"https://www.youtube.com/watch?v=fixture{i}"}}],"ImageTags":{{"Primary":"p{i}"}},"BackdropImageTags":["b{i}"],"MediaSources":[{{"Id":"src{i}","Name":"Test","Container":"mp4","Size":{clip},"SupportsDirectPlay":true,"SupportsDirectStream":true,"RunTimeTicks":120000000,"MediaStreams":[{{"Type":"Video","Codec":"h264","Index":0,"Width":320,"Height":180}},{{"Type":"Audio","Codec":"aac","Channels":1,"Index":1,"DisplayTitle":"Ton","IsDefault":true}}]}},{{"Id":"src{i}b","Name":"Test klein","Container":"mkv","Size":900000,"SupportsDirectPlay":true,"SupportsDirectStream":true,"RunTimeTicks":120000000,"MediaStreams":[{{"Type":"Video","Codec":"hevc","Index":0,"Width":1280,"Height":720}},{{"Type":"Audio","Codec":"ac3","Channels":6,"Index":1,"Language":"deu","DisplayTitle":"Deutsch 5.1"}},{{"Type":"Subtitle","Codec":"srt","Index":2,"Language":"eng"}}]}}],"UserData":{{{resume}}}}}"#,
        NAMES[i % NAMES.len()],
        2015 + i,
        clip = CLIP.len()
    )
}

pub(crate) fn series() -> String {
    r#"{"Id":"s1","Name":"Hafenlichter","Type":"Series","ProductionYear":2020,"ChildCount":1,"ImageTags":{"Primary":"ps1"},"UserData":{"UnplayedItemCount":2,"Played":false}}"#.into()
}

fn episode(n: usize) -> String {
    format!(
        r#"{{"Id":"e{n}","Name":"Folge {n}","Type":"Episode","SeriesId":"s1","SeriesName":"Hafenlichter","SeasonId":"se1","ParentIndexNumber":1,"IndexNumber":{n},"RunTimeTicks":120000000,"ImageTags":{{"Primary":"pe{n}"}},"MediaSources":[{{"Id":"srce{n}","Name":"Test","Container":"wav","SupportsDirectPlay":true,"MediaStreams":[]}}],"UserData":{{"Played":false}}}}"#
    )
}

fn boxset(n: usize) -> String {
    let name = if n == 1 {
        "Nordlicht-Reihe"
    } else {
        "Zwei Filme"
    };
    format!(r#"{{"Id":"c{n}","Name":"{name}","Type":"BoxSet","ImageTags":{{"Primary":"pc{n}"}}}}"#)
}

fn playlist() -> String {
    r#"{"Id":"pl1","Name":"Abendprogramm","Type":"Playlist","MediaType":"Video","ImageTags":{"Primary":"ppl1"}}"#.into()
}

// ---- Player extras: one extra movie `g1` carrying everything the stateful player reads. Nothing above changed;
// `g1` is in no list (reach it by id or `ids=g1`), so every answer that existed before stays byte-identical.

/// Id of the player-extras movie.
const EXTRAS_ID: &str = "g1";
/// Its two versions (media sources): "1080p" and "4K".
const EXTRAS_SOURCES: [&str; 2] = ["srcg1", "srcg1b"];
/// Trickplay layout: 6 tiles of 320x176, 3 across and 2 down, one every 2 s, so the whole 12 s fit on sheet 0.
const TRICK: (u32, u32, u32, u32) = (320, 176, 3, 2);

/// MediaStreams of one version: video, audio 1 (English) and audio 2 (German, Index 2), an external SRT (Index 3) and an external VTT (Index 4).
fn extras_streams(source: &str, codec: &str, width: u32, height: u32) -> String {
    format!(
        r#"[{{"Type":"Video","Codec":"{codec}","Index":0,"Width":{width},"Height":{height}}},{{"Type":"Audio","Codec":"aac","Channels":2,"Index":1,"Language":"eng","DisplayTitle":"English","IsDefault":true}},{{"Type":"Audio","Codec":"ac3","Channels":6,"Index":2,"Language":"deu","DisplayTitle":"Deutsch 5.1"}},{{"Type":"Subtitle","Codec":"srt","Index":3,"Language":"eng","DisplayTitle":"English (SRT)","IsExternal":true,"IsTextSubtitleStream":true,"SupportsExternalStream":true,"DeliveryMethod":"External","DeliveryUrl":"/Videos/{EXTRAS_ID}/{source}/Subtitles/3/0/Stream.srt"}},{{"Type":"Subtitle","Codec":"webvtt","Index":4,"Language":"deu","DisplayTitle":"Deutsch (VTT)","IsExternal":true,"IsTextSubtitleStream":true,"SupportsExternalStream":true,"DeliveryMethod":"External","DeliveryUrl":"/Videos/{EXTRAS_ID}/{source}/Subtitles/4/0/Stream.vtt"}}]"#
    )
}

fn extras_sources() -> String {
    let (a, b) = (EXTRAS_SOURCES[0], EXTRAS_SOURCES[1]);
    format!(
        r#"[{{"Id":"{a}","Name":"1080p","Container":"mp4","Size":{clip},"SupportsDirectPlay":true,"SupportsDirectStream":true,"RunTimeTicks":120000000,"MediaStreams":{}}},{{"Id":"{b}","Name":"4K","Container":"mkv","Size":9000000,"SupportsDirectPlay":true,"SupportsDirectStream":true,"RunTimeTicks":120000000,"MediaStreams":{}}}]"#,
        extras_streams(a, "h264", 1920, 1080),
        extras_streams(b, "hevc", 3840, 2160),
        clip = CLIP.len()
    )
}

/// The `Trickplay` item field: per media source id, per width (`TrickplayInfoDto`).
fn extras_trickplay() -> String {
    let (w, h, across, down) = TRICK;
    let detail = format!(
        r#"{{"{w}":{{"Width":{w},"Height":{h},"TileWidth":{across},"TileHeight":{down},"ThumbnailCount":{},"Interval":2000,"Bandwidth":100000}}}}"#,
        across * down
    );
    format!(
        r#"{{"{}":{detail},"{}":{detail}}}"#,
        EXTRAS_SOURCES[0], EXTRAS_SOURCES[1]
    )
}

/// Irregular on purpose: evenly spaced chapters count as a generated grid and are dropped by the client.
fn extras_movie() -> String {
    format!(
        r#"{{"Id":"{EXTRAS_ID}","Name":"Player-Extras","Type":"Movie","ProductionYear":2024,"RunTimeTicks":120000000,"Overview":"Kapitel, Vorschaubilder, Untertitel, zwei Tonspuren und zwei Versionen.","Genres":["Drama"],"ImageTags":{{"Primary":"pg1"}},"BackdropImageTags":["bg1"],"Chapters":[{{"Name":"Anfang","StartPositionTicks":0,"ImageTag":"cg1"}},{{"Name":"Mitte","StartPositionTicks":30000000}},{{"Name":"Ende","StartPositionTicks":80000000,"ImageTag":"cg3"}}],"Trickplay":{},"MediaSources":{},"UserData":{{"Played":false}}}}"#,
        extras_trickplay(),
        extras_sources()
    )
}

/// The `PlaybackInfo` answer of item `id`: the item's own versions (the ids its listing names, as a real server keeps
/// them), else the one version `src-<id>` that the other fixtures name.
fn playback_info(id: &str) -> String {
    let item = real_find(id).or_else(|| {
        let n = id.strip_prefix('m')?.parse::<usize>().ok()?;
        (n < NAMES.len()).then(|| movie(n))
    });
    let own = item.as_deref().and_then(|j| {
        let from = j.find(r#""MediaSources":["#)? + r#""MediaSources":"#.len();
        let mut depth = 0usize;
        for (i, c) in j[from..].char_indices() {
            match c {
                '[' => depth += 1,
                ']' => {
                    depth -= 1;
                    if depth == 0 {
                        return Some(j[from..=from + i].to_owned());
                    }
                }
                _ => {}
            }
        }
        None
    });
    let sources = own.unwrap_or_else(|| {
        format!(r#"[{{"Id":"src-{id}","Container":"mp4","SupportsDirectPlay":true,"SupportsDirectStream":true,"RunTimeTicks":120000000,"MediaStreams":[{{"Type":"Video","Codec":"h264","Index":0,"Width":320,"Height":180}},{{"Type":"Audio","Codec":"aac","Channels":1,"Index":1,"IsDefault":true}}]}}]"#)
    });
    format!(r#"{{"MediaSources":{sources},"PlaySessionId":"fx-session"}}"#)
}

fn extras_playback_info() -> String {
    format!(
        r#"{{"MediaSources":{},"PlaySessionId":"fx-session"}}"#,
        extras_sources()
    )
}

/// Intro 2 s to 5 s and Outro 10 s to the end.
fn extras_segments() -> String {
    r#"{"Items":[{"Type":"Intro","StartTicks":20000000,"EndTicks":50000000},{"Type":"Outro","StartTicks":100000000,"EndTicks":120000000}],"TotalRecordCount":2}"#.into()
}

fn extras_subtitle(path: &str) -> Reply {
    if path.ends_with(".vtt") {
        Reply(200, "text/vtt", b"WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nHallo vom Fixture\n\n00:00:04.000 --> 00:00:06.000\nZweite Zeile\n".to_vec())
    } else {
        Reply(200, "application/x-subrip", b"1\n00:00:01,000 --> 00:00:03,000\nHello from the fixture\n\n2\n00:00:04,000 --> 00:00:06,000\nSecond line\n".to_vec())
    }
}

/// `tiles.m3u8` of the 320 px trickplay: one image playlist over the single sheet.
fn extras_trickplay_playlist() -> Reply {
    let (w, h, across, down) = TRICK;
    let m = format!(
        "#EXTM3U\n#EXT-X-TARGETDURATION:12\n#EXT-X-VERSION:7\n#EXT-X-MEDIA-SEQUENCE:1\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-IMAGES-ONLY\n#EXTINF:12.000,\n#EXT-X-TILES:RESOLUTION={}x{},LAYOUT={across}x{down},DURATION=2.000\n0.jpg\n#EXT-X-ENDLIST\n",
        w * across,
        h * down
    );
    Reply(200, "application/vnd.apple.mpegurl", m.into_bytes())
}

/// MSB-first bit packer with JPEG byte stuffing (0xFF is followed by 0x00).
struct BitWriter {
    acc: u32,
    bits: u32,
    out: Vec<u8>,
}

impl BitWriter {
    fn put(&mut self, value: u32, len: u32) {
        self.acc = (self.acc << len) | (value & ((1 << len) - 1));
        self.bits += len;
        while self.bits >= 8 {
            let byte = (self.acc >> (self.bits - 8)) as u8;
            self.out.push(byte);
            if byte == 0xFF {
                self.out.push(0);
            }
            self.bits -= 8;
        }
    }
}

/// Baseline grayscale JPEG whose 8x8 blocks are flat (DC only): enough for a real, decodable sheet without a JPEG crate.
fn flat_jpeg(w: usize, h: usize, level: impl Fn(usize, usize) -> u8) -> Vec<u8> {
    const DC_BITS: [u8; 16] = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0];
    // Canonical codes of the standard luminance DC table (symbols 0..=11 in order).
    let mut codes = Vec::new();
    let mut code = 0_u32;
    for (i, n) in DC_BITS.iter().enumerate() {
        for _ in 0..*n {
            codes.push((code, i as u32 + 1));
            code += 1;
        }
        code <<= 1;
    }
    let mut out = vec![0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x43, 0x00];
    out.extend([16_u8; 64]);
    out.extend([
        0xFF,
        0xC0,
        0x00,
        0x0B,
        0x08,
        (h >> 8) as u8,
        h as u8,
        (w >> 8) as u8,
        w as u8,
        0x01,
        0x01,
        0x11,
        0x00,
    ]);
    out.extend([0xFF, 0xC4, 0x00, 0x1F, 0x00]);
    out.extend(DC_BITS);
    out.extend(0..12_u8);
    // The AC table holds one symbol, end-of-block, as the one-bit code "0".
    out.extend([
        0xFF, 0xC4, 0x00, 0x14, 0x10, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x00,
    ]);
    out.extend([0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00]);
    let mut bw = BitWriter {
        acc: 0,
        bits: 0,
        out,
    };
    let mut prev = 0_i32;
    for by in 0..h / 8 {
        for bx in 0..w / 8 {
            // Quantiser 16 and the DCT scale of 8 make one DC step worth two gray levels.
            let dc = (i32::from(level(bx * 8, by * 8)) - 128) / 2;
            let diff = dc - prev;
            prev = dc;
            let cat = 32 - diff.unsigned_abs().leading_zeros();
            let (c, len) = codes[cat as usize];
            bw.put(c, len);
            if cat > 0 {
                let extra = if diff < 0 {
                    diff + (1 << cat) - 1
                } else {
                    diff
                };
                bw.put(extra as u32, cat);
            }
            bw.put(0, 1);
        }
    }
    if bw.bits > 0 {
        let pad = 8 - bw.bits;
        bw.put((1 << pad) - 1, pad);
    }
    bw.out.extend([0xFF, 0xD9]);
    bw.out
}

/// Sheet 0 of the extras trickplay: six flat tiles, each a different gray.
fn extras_trickplay_sheet() -> Vec<u8> {
    let (w, h, across, down) = TRICK;
    flat_jpeg((w * across) as usize, (h * down) as usize, |x, y| {
        let slot = (y / h as usize) * across as usize + x / w as usize;
        (40 + 35 * slot) as u8
    })
}

pub(crate) fn list(items: &[String]) -> String {
    format!(
        r#"{{"Items":[{}],"TotalRecordCount":{}}}"#,
        items.join(","),
        items.len()
    )
}

fn all_items() -> Vec<String> {
    (0..6).map(movie).chain(std::iter::once(series())).collect()
}

/// What the plain fixture's `/Items` lists. Without a type or library the whole catalogue, as ever; with
/// `IncludeItemTypes` only those types (episodes too, when asked for); with a library as parent only what that library
/// holds (`lib-movies` the films, `lib-shows` the series), so the "Serien" tab no longer lists the films.
fn plain_items(types: Option<&str>, parent: Option<&str>) -> Vec<String> {
    let mut items = all_items();
    if types.is_some() {
        items.extend((1..=3).map(episode));
    }
    let items = of_types(items, types);
    match parent {
        Some("lib-movies") => of_types(items, Some("Movie")),
        Some("lib-shows") => of_types(items, Some("Series")),
        _ => items,
    }
}

pub(crate) fn find(id: &str) -> Option<String> {
    // The real-shape titles (`re1`, `ra0`, ...) are answered by their own routes; the sessions list reads them from there.
    if let Some(Reply(200, _, body)) = real_answer("GET", &format!("/Items/{id}"), "") {
        return String::from_utf8(body).ok();
    }
    let n: usize = id.get(1..)?.parse().ok()?;
    match id.as_bytes().first()? {
        b'm' if n < 6 => Some(movie(n)),
        // Two audio tracks in the first source (German and English), for the download audio choice; not in the lists.
        b'm' if n == 9 => Some(movie(9).replacen(
            r#"{"Type":"Audio","Codec":"aac","Channels":1,"Index":1,"DisplayTitle":"Ton","IsDefault":true}"#,
            r#"{"Type":"Audio","Codec":"ac3","Channels":6,"Index":1,"Language":"deu","DisplayTitle":"Deutsch 5.1","IsDefault":true},{"Type":"Audio","Codec":"aac","Channels":2,"Index":3,"Language":"eng","DisplayTitle":"English"}"#,
            1,
        )),
        b's' if n == 1 => Some(series()),
        b'g' if n == 1 => Some(extras_movie()),
        b'p' if n == 1 => Some(r#"{"Id":"p1","Name":"Anna Test","Type":"Person","Overview":"Schauspielerin aus dem Fixture.","PremiereDate":"1980-05-01T00:00:00.0000000Z","ProductionLocations":["Berlin"],"ProviderIds":{"Tmdb":"1234"},"ImageTags":{"Primary":"pp1"}}"#.into()),
        b'e' if (1..=3).contains(&n) => Some(episode(n)),
        _ => None,
    }
}

fn auth_result(name: &str) -> String {
    auth_result_with(name, real_enabled())
}

/// `real`: the user carries a `PrimaryImageTag` (a profile picture), as a real server's does.
fn auth_result_with(name: &str, real: bool) -> String {
    let sid = server_id();
    let tag = if real {
        format!(r#","PrimaryImageTag":"{REAL_AVATAR_TAG}""#)
    } else {
        String::new()
    };
    let uid = if crate::fixture_big::enabled() {
        format!("u-{name}")
    } else if sid == "fx" {
        "u1".to_string()
    } else {
        format!("u-{sid}")
    };
    format!(
        r#"{{"User":{{"Id":"{uid}","Name":"{name}","ServerId":"{sid}"{tag}}},"AccessToken":"fixture-token","ServerId":"{sid}"}}"#
    )
}

fn png(seed: u32, w: u32, h: u32) -> Vec<u8> {
    let mut data = Vec::with_capacity((w * h * 3) as usize);
    for y in 0..h {
        for x in 0..w {
            // Wrapping on purpose: the seed is a hash, and release builds always wrapped here.
            data.extend([
                (x * 255 / w).wrapping_add(seed.wrapping_mul(37)) as u8,
                (y * 255 / h) as u8,
                (seed.wrapping_mul(61) % 256) as u8,
            ]);
        }
    }
    encode_rgb(w, h, &data)
}

/// A picture with a slow colour ramp, rings and one-pixel texture, a different hue per `seed`: no flat areas, so
/// stretching, blur and a neighbour's colour on the edge all show in the pixels.
fn detailed_picture(seed: u32, w: u32, h: u32) -> Vec<u8> {
    let hue = f64::from(seed % 360) / 360.0 * std::f64::consts::TAU;
    let (base_r, base_g, base_b) = (
        hue.cos() * 0.5 + 0.5,
        (hue + 2.1).cos() * 0.5 + 0.5,
        (hue + 4.2).cos() * 0.5 + 0.5,
    );
    let mut data = Vec::with_capacity((w * h * 3) as usize);
    for y in 0..h {
        for x in 0..w {
            let (fx, fy) = (f64::from(x) / f64::from(w), f64::from(y) / f64::from(h));
            let rings = (((fx - 0.5).powi(2) + (fy - 0.4).powi(2)).sqrt() * 60.0).sin() * 0.12;
            let ramp = 0.25 + 0.5 * fy;
            let grid = if x % 16 == 0 || y % 16 == 0 {
                0.06
            } else {
                0.0
            };
            let mut n = x.wrapping_mul(374_761_393) ^ y.wrapping_mul(668_265_263) ^ seed;
            n = (n ^ (n >> 13)).wrapping_mul(1_274_126_177);
            let noise = f64::from((n ^ (n >> 16)) & 255) / 255.0 * 0.08 - 0.04;
            let v = (ramp + rings + grid + noise).clamp(0.0, 1.0);
            data.extend([
                ((base_r * 0.6 + 0.4) * v * 255.0) as u8,
                ((base_g * 0.6 + 0.4) * v * 255.0) as u8,
                ((base_b * 0.6 + 0.4) * v * 255.0) as u8,
            ]);
        }
    }
    encode_rgb(w, h, &data)
}

/// The original size of the picture `kind` ("Primary", "Backdrop", "Thumb", "Logo") of item `id`, as a real library holds
/// it: posters 2000 x 3000, backdrops 4K, an episode's still and a thumb Full HD, a logo 800 wide.
fn original_size(id: &str, kind: &str) -> (u32, u32) {
    let numbered = |prefix: &str| {
        id.strip_prefix(prefix)
            .is_some_and(|r| r.starts_with(|c: char| c.is_ascii_digit()))
    };
    match kind {
        "Backdrop" => (3840, 2160),
        "Thumb" => (1920, 1080),
        "Logo" => (800, 310),
        _ if numbered("re") || numbered("e") || numbered("bm-ep") => (1920, 1080),
        _ => (2000, 3000),
    }
}

/// The size Jellyfin answers with (`DrawingUtils.Resize`): `max*` fit the picture into the box and keep its aspect,
/// `fill*` cover the box and cut the rest; a picture is never enlarged beyond its original.
fn resized(
    original: (u32, u32),
    max: (Option<u32>, Option<u32>),
    fill: (Option<u32>, Option<u32>),
) -> (u32, u32) {
    let (ow, oh) = (f64::from(original.0), f64::from(original.1));
    if let (Some(fw), Some(fh)) = fill {
        let (fw, fh) = (f64::from(fw), f64::from(fh));
        // The largest box of the fill aspect the original holds.
        let k = (ow / fw).min(oh / fh).min(1.0);
        return (
            ((fw * k).round() as u32).max(1),
            ((fh * k).round() as u32).max(1),
        );
    }
    let k = [
        max.0.map(|w| f64::from(w) / ow),
        max.1.map(|h| f64::from(h) / oh),
        Some(1.0),
    ]
    .into_iter()
    .flatten()
    .fold(f64::MAX, f64::min);
    (
        ((ow * k).round() as u32).max(1),
        ((oh * k).round() as u32).max(1),
    )
}

/// A picture of `/Items/<id>/Images/<kind>[/<n>]` the way a real Jellyfin sends it: rendered at the size the query asks
/// for (`maxWidth` / `maxHeight` / `fillWidth` / `fillHeight`, names case-insensitive), at most the original.
fn jellyfin_picture(path: &str, query: &str) -> Reply {
    let segs: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    let at = segs.iter().position(|s| *s == "Images").unwrap_or(0);
    let id = at
        .checked_sub(1)
        .and_then(|i| segs.get(i))
        .copied()
        .unwrap_or("x");
    let kind = segs.get(at + 1).copied().unwrap_or("Primary");
    let seed = id
        .bytes()
        .fold(7_u32, |a, b| a.wrapping_mul(31).wrapping_add(u32::from(b)));
    let ask = |k: &str| {
        query.split('&').find_map(|p| {
            p.split_once('=')
                .filter(|(n, _)| n.eq_ignore_ascii_case(k))
                .and_then(|(_, v)| v.parse::<u32>().ok())
                .filter(|v| *v > 0)
        })
    };
    let (w, h) = resized(
        original_size(id, kind),
        (ask("maxWidth"), ask("maxHeight")),
        (ask("fillWidth"), ask("fillHeight")),
    );
    Reply(200, "image/png", detailed_picture(seed, w, h))
}

fn encode_rgb(w: u32, h: u32, data: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut enc = png::Encoder::new(&mut out, w, h);
    enc.set_color(png::ColorType::Rgb);
    enc.set_depth(png::BitDepth::Eight);
    if let Ok(mut wr) = enc.write_header() {
        let _ = wr.write_image_data(data);
    }
    out
}

/// Server id; `SWIFTLY_FIXTURE_ID` lets a second fixture on another port be a different server (account switching).
fn server_id() -> String {
    std::env::var("SWIFTLY_FIXTURE_ID").unwrap_or_else(|_| "fx".into())
}

pub(crate) struct Reply(pub(crate) u16, pub(crate) &'static str, pub(crate) Vec<u8>);

fn json(body: String) -> Reply {
    Reply(200, "application/json", body.into_bytes())
}

/// The 12 s test clip (320x180 h264 + aac, generated with ffmpeg; served with ranges).
/// What every film download and stream answers with; the catalogue declares exactly this many bytes.
pub(crate) const CLIP: &[u8] = include_bytes!("../assets/fixture-clip.mp4");
/// `POST /Sessions/Playing*` paths in arrival order, read back with `GET /fixture/reports`.
static REPORTS: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());
/// Every request target in arrival order, read back with `GET /fixture/seen` (what a client really asked).
static SEEN: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());
/// The synced settings: the body of `/DisplayPreferences/swiftly` (what the apps' settings sync reads and writes), kept in memory.
/// `None` until a client writes it; then the same body comes back, like on a real server.
static DISPLAY_PREFS: std::sync::Mutex<Option<Vec<u8>>> = std::sync::Mutex::new(None);

fn record(path: &str) {
    if let Ok(mut r) = REPORTS.lock() {
        r.push(path.to_owned());
    }
}

pub(crate) fn route(method: &str, target: &str, body: &str) -> Reply {
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    let path = path.trim_end_matches('/');
    let has = |k: &str| query.split('&').any(|p| p.split('=').next() == Some(k));
    let param = |k: &str| {
        query.split('&').find_map(|p| {
            p.split_once('=')
                .filter(|(n, _)| *n == k)
                .map(|(_, v)| v.to_owned())
        })
    };
    if let Ok(mut seen) = SEEN.lock() {
        seen.push(target.to_owned());
    }
    // The opt-in big catalogue (`--big`): answers first, only when switched on.
    if let Some(reply) = crate::fixture_big::answer(method, path, query) {
        return reply;
    }
    // The opt-in real shapes (`--real-shapes`): after the big catalogue, before everything plain.
    if let Some(reply) = real_answer(method, path, query) {
        return reply;
    }
    // The playback bench's server transcodes (HLS folders next to the media): before the plain media routes.
    if let Some(reply) = crate::fixture_hls::answer(method, path, body) {
        return reply;
    }
    // The playback bench titles (`bm-*`, only with SWIFTLY_FIXTURE_MEDIA_DIR): real media files.
    if let Some(reply) = crate::fixture_media::answer(path, query) {
        return reply;
    }
    // plex.tv itself (pins, Home users, resources) for the sign-in runs of the desktop app.
    if let Some(reply) = crate::fixture_plex::account(method, path) {
        return reply;
    }
    // The Plex fixture: paths no Jellyfin route uses.
    // Plex timeline reports: recorded as `/:/timeline/<state>` beside the Jellyfin ones.
    if path == "/:/timeline" {
        record(&format!(
            "/:/timeline/{}",
            param("state").unwrap_or_default()
        ));
        return Reply(200, "text/plain", Vec::new());
    }
    // The Plex shape of the bench titles (rating keys 9001..): real media, files only with a token.
    if let Some(reply) = crate::fixture_plex::bench(path, query) {
        return reply;
    }
    // The Plex part files play the same test clip.
    if path.starts_with("/library/parts/") {
        return Reply(200, "video/mp4", CLIP.to_vec());
    }
    if crate::fixture_seerr::handles(path) {
        return match crate::fixture_seerr::answer(method, path) {
            Some(b) => json(b),
            None => Reply(404, "text/plain", b"unknown in the seerr fixture".to_vec()),
        };
    }
    if crate::fixture_plex::handles(path) {
        return match crate::fixture_plex::answer(path) {
            Some(b) => json(b),
            None => Reply(404, "text/plain", b"unknown in the plex fixture".to_vec()),
        };
    }
    match (method, path) {
        (m, p) if p.starts_with("/DisplayPreferences/") => {
            if m == "POST" {
                if let Ok(mut stored) = DISPLAY_PREFS.lock() {
                    *stored = Some(body.as_bytes().to_vec());
                }
                Reply(204, "text/plain", Vec::new())
            } else {
                let stored = DISPLAY_PREFS.lock().ok().and_then(|s| s.clone());
                Reply(200, "application/json", stored.unwrap_or_else(|| br#"{"Id":"swiftly","CustomPrefs":{}}"#.to_vec()))
            }
        }
        (_, "/fixture/seen") => json(format!("[{}]", SEEN.lock().map(|r| r.iter().map(|l| format!("\"{l}\"")).collect::<Vec<_>>().join(",")).unwrap_or_default())),
        (_, "/System/Info/Public") => json(format!(r#"{{"ServerName":"Fixture","Version":"10.10.0","Id":"{}","ProductName":"{}"}}"#, server_id(), std::env::var("SWIFTLY_FIXTURE_PRODUCT").unwrap_or_else(|_| "Jellyfin Server".into()))),
        ("POST", "/Users/AuthenticateByName") => {
            let user = if crate::fixture_big::enabled() { crate::fixture_big::ACCOUNTS.iter().find(|n| body.contains(&format!(r#""Username":"{n}""#))) } else { body.contains(r#""Username":"demo""#).then_some(&"demo") };
            let ok = user.is_some() && (body.contains(r#""Pw":"demo""#) || body.contains(r#""Pw":"""#));
            if let (true, Some(name)) = (ok, user) { json(auth_result(name)) } else { Reply(401, "text/plain", b"bad".to_vec()) }
        }
        (_, "/QuickConnect/Enabled") => json("true".into()),
        ("POST", "/QuickConnect/Authorize") => json(if param("code").as_deref() == Some("000000") { "false".into() } else { "true".into() }),
        ("POST", "/Sessions/Logout") => Reply(204, "text/plain", Vec::new()),
        ("POST", "/QuickConnect/Initiate") => json(r#"{"Secret":"quick-secret","Code":"123456","Authenticated":false}"#.into()),
        (_, "/QuickConnect/Connect") => json(r#"{"Secret":"quick-secret","Code":"123456","Authenticated":true}"#.into()),
        ("POST", "/Users/AuthenticateWithQuickConnect") => json(auth_result("demo")),
        (_, "/Users/Public") => json(r#"[{"Id":"u1","Name":"demo"}]"#.into()),
        (_, p) if p.ends_with("/UserViews") || p.ends_with("/Views") => json(list(&[
            r#"{"Id":"lib-movies","Name":"Filme","Type":"CollectionFolder","CollectionType":"movies"}"#.into(),
            r#"{"Id":"lib-shows","Name":"Serien","Type":"CollectionFolder","CollectionType":"tvshows"}"#.into(),
        ])),
        (_, p) if p.ends_with("/UserItems/Resume") || p.ends_with("/Items/Resume") => json(list(&[movie(0), movie(2)])),
        (_, "/Shows/NextUp") => json(list(&[episode(2)])),
        (_, p) if p.ends_with("/Shows/s1/Seasons") || p == "/Shows/s1/Seasons" => json(list(&[r#"{"Id":"se1","Name":"Staffel 1","Type":"Season","IndexNumber":1,"SeriesId":"s1"}"#.into()])),
        (_, p) if p.ends_with("/Episodes") => json(list(&[episode(1), episode(2), episode(3)])),
        (_, p) if p.ends_with("/Items/Latest") => json(format!("[{}]", all_items().join(","))),
        // Real shapes: pictures resized like Jellyfin does (see `jellyfin_picture`), with fine detail, so a soft or
        // stretched cover shows.
        (_, p) if p.contains("/Images/") && real_enabled() && !p.starts_with("/Users/") => jellyfin_picture(p, query),
        (_, p) if p.contains("/Images/") => {
            let id = p.split('/').rev().nth(2).unwrap_or("x");
            let seed = id.bytes().fold(7_u32, |a, b| a.wrapping_mul(31).wrapping_add(u32::from(b)));
            let (w, h) = if p.contains("Backdrop") { (320, 180) } else { (200, 300) };
            Reply(200, "image/png", png(seed, w, h))
        }
        (_, p) if p.contains("/Videos/") && (p.ends_with("/stream") || p.contains("/stream.")) => Reply(200, "video/mp4", CLIP.to_vec()),
        // Player extras (`g1` only; every other id keeps its old answer below).
        (_, "/MediaSegments/g1") => json(extras_segments()),
        // The first bench episode (10 s) has an outro from 6 s to the end, so the next-episode card opens (desktop check).
        (_, "/MediaSegments/bm-ep1") => json(r#"{"Items":[{"Type":"Outro","StartTicks":60000000,"EndTicks":100000000}],"TotalRecordCount":1}"#.into()),
        (_, "/Videos/g1/Trickplay/320/tiles.m3u8") => extras_trickplay_playlist(),
        (_, "/Videos/g1/Trickplay/320/0.jpg") => Reply(200, "image/jpeg", extras_trickplay_sheet()),
        (_, p) if p.starts_with("/Videos/g1/Trickplay/") => Reply(404, "text/plain", b"no such sheet".to_vec()),
        (_, p) if p.starts_with("/Videos/g1/") && p.contains("/Subtitles/") && (p.ends_with("/Stream.srt") || p.ends_with("/Stream.vtt")) => extras_subtitle(p),
        (_, "/Items/g1/PlaybackInfo") => json(extras_playback_info()),
        (_, p) if p.ends_with("/Items") && param("ids").is_some_and(|ids| ids == EXTRAS_ID) => json(list(&[extras_movie()])),
        // Without that mode the devices that hold a socket are the user's sessions, and a play order reaches the target's socket.
        ("GET", "/Sessions") if !crate::fixture_modes::global().0.sessions => json(crate::fixture_sessions::list(query)),
        ("POST", p) if !crate::fixture_modes::global().0.sessions && p.starts_with("/Sessions/") && !p.starts_with("/Sessions/Playing") && !p.starts_with("/Sessions/Capabilities") && p.matches('/').count() >= 3 => {
            crate::fixture_sessions::command(p, query, body).unwrap_or(Reply(404, "text/plain", Vec::new()))
        }
        // Mode `sessions`: a second device of the same user (the TV) plays m1 at 25 s; hand-over posts are recorded.
        ("GET", "/Sessions") if crate::fixture_modes::global().0.sessions => json(r#"[{"Id":"fx-tv","UserId":"u1","DeviceId":"fx-tv-device","DeviceName":"Fixture TV","Client":"Swiftly TV","SupportsRemoteControl":true,"LastActivityDate":"2099-01-01T00:00:00.0000000Z","PlayableMediaTypes":["Video"],"NowPlayingItem":{"Id":"m1","Name":"Sommerregen","Type":"Movie","RunTimeTicks":120000000},"PlayState":{"IsPaused":false,"PositionTicks":250000000}}]"#.into()),
        ("POST", p) if crate::fixture_modes::global().0.sessions && p.starts_with("/Sessions/fx-tv/") => {
            record(p);
            Reply(204, "text/plain", Vec::new())
        }
        (_, "/MediaSegments") => Reply(404, "text/plain", Vec::new()),
        (_, p) if p.starts_with("/MediaSegments/") => json(r#"{"Items":[{"Type":"Intro","StartTicks":20000000,"EndTicks":50000000}],"TotalRecordCount":1}"#.into()),
        (_, "/fixture/reports") => json(format!("[{}]", REPORTS.lock().map(|r| r.iter().map(|l| format!("\"{l}\"")).collect::<Vec<_>>().join(",")).unwrap_or_default())),
        (_, p) if p.ends_with("/PlaybackInfo") => json(playback_info(p.split('/').rev().nth(1).unwrap_or("m0"))),
        ("POST", p) if p.starts_with("/Sessions/Playing") || p.contains("/PlayedItems") || p.contains("/FavoriteItems") => {
            if p.starts_with("/Sessions/Playing") {
                record(p);
            }
            Reply(204, "text/plain", Vec::new())
        }
        // Around a title: similar titles, extras, local trailers.
        // Jelly Twiggy: who has watched a title.
        (_, p) if p.starts_with("/JellyTwiggy/Items/") && p.ends_with("/Watchers") => json(r#"[{"UserId":"u1","UserName":"demo","ImageTag":"ut1","PlayCount":2,"LastWatched":"2026-01-02T03:04:05.0000000Z","ProgressPercent":55.0},{"UserId":"u2","UserName":"Zoe","PlayCount":0,"WatchedCount":3,"TotalCount":10}]"#.into()),
        (_, p) if p.ends_with("/Similar") => json(list(&[movie(1), movie(2), movie(3)])),
        (_, p) if p.ends_with("/SpecialFeatures") => json(format!("[{}]", r#"{"Id":"x1","Name":"Making of","Type":"Video","RunTimeTicks":6000000000,"ImageTags":{"Primary":"px1"},"BackdropImageTags":["bx1"]}"#)),
        (_, p) if p.ends_with("/LocalTrailers") => json(format!("[{}]", r#"{"Id":"t1","Name":"Trailer","Type":"Trailer","RunTimeTicks":1800000000,"BackdropImageTags":["bt1"]}"#)),
        // Collections (BoxSets) and a video playlist, for the library section calls.
        (_, p) if p.ends_with("/Items") && param("IncludeItemTypes").is_some_and(|t| t == "BoxSet") => json(list(&[boxset(1), boxset(2)])),
        (_, p) if p.ends_with("/Items") && param("IncludeItemTypes").is_some_and(|t| t == "Playlist") => json(list(&[playlist()])),
        (_, p) if p.ends_with("/Items") && param("ParentId").is_some_and(|id| id == "c1" || id == "c2") => {
            let members: Vec<String> = if param("ParentId").is_some_and(|id| id == "c1") { (0..3).map(movie).collect() } else { (3..5).map(movie).collect() };
            json(list(&members))
        }
        (_, p) if p.starts_with("/Playlists/pl1/") && p.ends_with("/Items") => json(list(&[movie(1), movie(2), episode(1)])),
        // `Items?ids=a,b`: exactly the known ones (the downloads catch-up asks this way).
        (_, p) if p.ends_with("/Items") && (has("Ids") || has("ids")) => {
            let ids = param("Ids").or_else(|| param("ids")).unwrap_or_default().replace("%2C", ",").replace("%2c", ",");
            json(list(&ids.split(',').filter_map(find).collect::<Vec<_>>()))
        }
        (_, p) if p.ends_with("/Items") && !has("Ids") && !has("ids") => json(list(&plain_items(param("IncludeItemTypes").as_deref(), param("ParentId").as_deref()))),
        (_, p) if p.rsplit('/').nth(1) == Some("Items") => match find(p.rsplit('/').next().unwrap_or("")) {
            Some(item) => json(item),
            None => Reply(404, "text/plain", b"no such item".to_vec()),
        },
        _ => json(list(&[])),
    }
}

// ---- Real shapes (`--real-shapes`): what a real Jellyfin server sends and the plain fixture never does. Opt-in; with
// the switch off none of this runs, so every answer above stays byte-identical.

static REAL_ON: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[cfg(test)]
thread_local! {
    /// Lets one test thread switch the mode on without touching the other tests (they run in parallel).
    static FORCE_REAL: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

fn enable_real() {
    REAL_ON.store(true, std::sync::atomic::Ordering::Relaxed);
}

fn real_enabled() -> bool {
    #[cfg(test)]
    if FORCE_REAL.with(std::cell::Cell::get) {
        return true;
    }
    REAL_ON.load(std::sync::atomic::Ordering::Relaxed)
        || std::env::var_os("SWIFTLY_FIXTURE_REAL").is_some()
}

const REAL_LIB_A: &str = "rl-movies-a";
const REAL_LIB_B: &str = "rl-movies-b";
const REAL_LIB_HOME: &str = "rl-home";
const REAL_LIB_SHOWS: &str = "rl-shows";
/// The real-shape collections: one with its own picture, one without (two titles, a mosaic of two), one without (four
/// titles, a 2 x 2 mosaic); and one video playlist.
const REAL_BOX_PICTURE: &str = "rc1";
const REAL_BOX_TWO: &str = "rc2";
const REAL_BOX_FOUR: &str = "rc3";
const REAL_PLAYLIST: &str = "rpl1";
const REAL_SERIES: &str = "rs1";
const REAL_SEASON: &str = "rse1";
const REAL_VIRTUAL: &str = "rv1";
const REAL_PERSONS: [(&str, &str, &str, &str); 2] = [
    ("rp1", "Anna Test", "1980-05-01T00:00:00.0000000Z", "1234"),
    (
        "rp2",
        "Carl Beispiel",
        "1975-09-12T00:00:00.0000000Z",
        "5678",
    ),
];
/// Tmdb id of the five films both movie libraries hold (film `i` has `1000 + i`).
const REAL_TMDB_BASE: usize = 1000;
const REAL_AVATAR_TAG: &str = "avatar1";

fn real_user_id() -> String {
    let sid = server_id();
    if sid == "fx" {
        "u1".into()
    } else {
        format!("u-{sid}")
    }
}

fn real_user() -> String {
    format!(
        r#"{{"Id":"{}","Name":"demo","ServerId":"{}","HasPassword":true,"PrimaryImageTag":"{REAL_AVATAR_TAG}"}}"#,
        real_user_id(),
        server_id()
    )
}

/// A movie built from the plain fixture movie `base`: another id and name, real provider ids and location type, and
/// people whose actors carry a picture tag.
fn real_movie(id: &str, base: usize, name: &str, tmdb: Option<usize>) -> String {
    let actors = r#"{"Id":"rp1","Name":"Anna Test","Type":"Actor","Role":"Hauptrolle","PrimaryImageTag":"prp1"},{"Id":"rp2","Name":"Carl Beispiel","Type":"Actor","Role":"Nebenrolle","PrimaryImageTag":"prp2"}"#;
    let provider = tmdb.map_or(String::new(), |t| {
        format!(r#""ProviderIds":{{"Tmdb":"{t}"}},"#)
    });
    movie(base)
        .replacen(&format!(r#""Id":"m{base}""#), &format!(r#""Id":"{id}""#), 1)
        .replacen(
            &format!(r#""Name":"{}""#, NAMES[base % NAMES.len()]),
            &format!(r#""Name":"{name}""#),
            1,
        )
        .replacen(
            r#"{"Id":"p1","Name":"Anna Test","Type":"Actor","Role":"Hauptrolle","PrimaryImageTag":"pp1"}"#,
            actors,
            1,
        )
        .replacen(
            r#""Type":"Movie","#,
            &format!(r#""Type":"Movie","LocationType":"FileSystem",{provider}"#),
            1,
        )
}

/// The five shared films of one movie library: `ra0..ra4` (library A) or `rb0..rb4` (library B), the same Tmdb ids.
fn real_library_movies(prefix: &str) -> Vec<String> {
    (0..5)
        .map(|i| {
            real_movie(
                &format!("{prefix}{i}"),
                i,
                NAMES[i],
                Some(REAL_TMDB_BASE + i),
            )
        })
        .collect()
}

/// The collections (`BoxSet`) of the real shapes.
fn real_boxsets() -> Vec<String> {
    vec![
        format!(
            r#"{{"Id":"{REAL_BOX_PICTURE}","Name":"Nordlicht-Reihe","Type":"BoxSet","ImageTags":{{"Primary":"prc1"}}}}"#
        ),
        format!(r#"{{"Id":"{REAL_BOX_TWO}","Name":"Zwei Filme","Type":"BoxSet"}}"#),
        format!(r#"{{"Id":"{REAL_BOX_FOUR}","Name":"Hafen-Abende","Type":"BoxSet"}}"#),
    ]
}

/// The video playlist of the real shapes (no picture of its own).
fn real_playlist() -> String {
    format!(
        r#"{{"Id":"{REAL_PLAYLIST}","Name":"Abendprogramm","Type":"Playlist","MediaType":"Video"}}"#
    )
}

/// What a real collection holds, in the order the server keeps it.
fn real_box_members(id: &str) -> Option<Vec<String>> {
    let movies = real_library_movies("ra");
    let more = real_library_movies("rb");
    Some(match id {
        REAL_BOX_PICTURE => movies.into_iter().take(3).collect(),
        REAL_BOX_TWO => more.into_iter().skip(3).collect(),
        REAL_BOX_FOUR => movies.into_iter().take(4).collect(),
        _ => return None,
    })
}

/// A missing (virtual) movie: listed by the library, but there is no file behind it.
fn real_virtual() -> String {
    format!(
        r#"{{"Id":"{REAL_VIRTUAL}","Name":"Fehlender Film","Type":"Movie","ProductionYear":2021,"LocationType":"Virtual","IsMissing":true,"ProviderIds":{{"Tmdb":"9999"}},"UserData":{{"Played":false}}}}"#
    )
}

/// Home videos: typed `Movie` like a real server does, without any provider id.
fn real_home() -> Vec<String> {
    ["Urlaub am Meer", "Geburtstag", "Wanderung"]
        .iter()
        .enumerate()
        .map(|(i, name)| real_movie(&format!("hv{i}"), i, name, None))
        .collect()
}

fn real_series() -> String {
    format!(
        r#"{{"Id":"{REAL_SERIES}","Name":"Küstenwache","Type":"Series","ProductionYear":2024,"ChildCount":1,"ProviderIds":{{"Tmdb":"7777"}},"ImageTags":{{"Primary":"prs1"}},"People":[{{"Id":"rp1","Name":"Anna Test","Type":"Actor","Role":"Kommissarin","PrimaryImageTag":"prp1"}}],"UserData":{{"UnplayedItemCount":4,"Played":false}}}}"#
    )
}

fn real_season() -> String {
    format!(
        r#"{{"Id":"{REAL_SEASON}","Name":"Staffel 2","Type":"Season","IndexNumber":2,"SeriesId":"{REAL_SERIES}","SeriesName":"Küstenwache","ParentId":"{REAL_SERIES}","ChildCount":4,"ImageTags":{{"Primary":"prse1"}},"UserData":{{"Played":false}}}}"#
    )
}

/// Episode `n` (1..=4) of the season; a higher number was added later (`DateCreated`).
fn real_episode(n: usize) -> String {
    // A real server's media source carries the run time; a client that plays the file reads its length from there.
    let mut base = episode(n).replace(
        r#""Container":"wav","SupportsDirectPlay":true,"MediaStreams":[]"#,
        r#""Container":"wav","SupportsDirectPlay":true,"RunTimeTicks":120000000,"MediaStreams":[]"#,
    );
    // `SWIFTLY_FIXTURE_EPISODE_VERSIONS=1`: every episode names a second version, to run the version choice on episodes.
    if std::env::var_os("SWIFTLY_FIXTURE_EPISODE_VERSIONS").is_some() {
        base = base.replacen(
            r#""MediaStreams":[]}]"#,
            &format!(
                r#""MediaStreams":[]}},{{"Id":"srce{n}b","Name":"Test klein","Container":"wav","SupportsDirectPlay":true,"MediaStreams":[]}}]"#
            ),
            1,
        );
    }
    base.replacen(&format!(r#""Id":"e{n}""#), &format!(r#""Id":"re{n}""#), 1)
        .replacen(
            r#""SeriesId":"s1","SeriesName":"Hafenlichter","SeasonId":"se1","ParentIndexNumber":1"#,
            &format!(
                r#""SeriesId":"{REAL_SERIES}","SeriesName":"Küstenwache","SeasonId":"{REAL_SEASON}","SeasonName":"Staffel 2","ParentIndexNumber":2"#
            ),
            1,
        )
        .replacen(
            r#""Type":"Episode","#,
            &format!(r#""Type":"Episode","DateCreated":"2026-11-0{n}T20:00:00.0000000Z","#),
            1,
        )
}

/// Newest first, as `Items/Latest` and `SortBy=DateCreated` (descending) answer.
fn real_episodes_newest_first() -> Vec<String> {
    (1..=4).rev().map(real_episode).collect()
}

fn real_person(id: &str) -> Option<String> {
    let (id, name, born, tmdb) = REAL_PERSONS.iter().find(|p| p.0 == id)?;
    Some(format!(
        r#"{{"Id":"{id}","Name":"{name}","Type":"Person","Overview":"Schauspielerin oder Schauspieler aus dem Fixture.","PremiereDate":"{born}","ProductionLocations":["Berlin"],"ProviderIds":{{"Tmdb":"{tmdb}"}},"ImageTags":{{"Primary":"p{id}"}}}}"#
    ))
}

fn real_views() -> Vec<String> {
    vec![
        format!(
            r#"{{"Id":"{REAL_LIB_A}","Name":"Filme","Type":"CollectionFolder","CollectionType":"movies"}}"#
        ),
        format!(
            r#"{{"Id":"{REAL_LIB_B}","Name":"Filme 4K","Type":"CollectionFolder","CollectionType":"movies"}}"#
        ),
        format!(
            r#"{{"Id":"{REAL_LIB_HOME}","Name":"Heimvideos","Type":"CollectionFolder","CollectionType":"homevideos"}}"#
        ),
        format!(
            r#"{{"Id":"{REAL_LIB_SHOWS}","Name":"Serien","Type":"CollectionFolder","CollectionType":"tvshows"}}"#
        ),
    ]
}

/// One real item by id (movies, home videos, the virtual movie, series, season, episodes, persons, the libraries).
fn real_find(id: &str) -> Option<String> {
    let numbered = |prefix: &str, max: usize| {
        id.strip_prefix(prefix)
            .and_then(|n| n.parse::<usize>().ok())
            .filter(|n| *n < max)
    };
    if let Some(i) = numbered("ra", 5) {
        return real_library_movies("ra").into_iter().nth(i);
    }
    if let Some(i) = numbered("rb", 5) {
        return real_library_movies("rb").into_iter().nth(i);
    }
    if let Some(i) = numbered("hv", 3) {
        return real_home().into_iter().nth(i);
    }
    if let Some(n) = numbered("re", 5).filter(|n| *n >= 1) {
        return Some(real_episode(n));
    }
    match id {
        REAL_PLAYLIST => Some(real_playlist()),
        REAL_BOX_PICTURE | REAL_BOX_TWO | REAL_BOX_FOUR => real_boxsets()
            .into_iter()
            .find(|b| b.contains(&format!(r#""Id":"{id}""#))),
        REAL_VIRTUAL => Some(real_virtual()),
        REAL_SERIES => Some(real_series()),
        REAL_SEASON => Some(real_season()),
        _ => real_person(id).or_else(|| {
            real_views()
                .into_iter()
                .find(|v| v.contains(&format!(r#""Id":"{id}""#)))
        }),
    }
}

/// Keeps the items whose `Type` is one of the comma separated `types`; `None` keeps everything.
fn of_types(items: Vec<String>, types: Option<&str>) -> Vec<String> {
    let Some(types) = types else { return items };
    let wanted: Vec<String> = types
        .replace("%2C", ",")
        .replace("%2c", ",")
        .split(',')
        .map(|t| format!(r#""Type":"{t}""#))
        .collect();
    items
        .into_iter()
        .filter(|i| wanted.iter().any(|t| i.contains(t.as_str())))
        .collect()
}

/// Everything a library of this id holds: `recursive` also goes down into seasons and episodes.
fn real_children(parent: &str, recursive: bool) -> Option<Vec<String>> {
    let mut items = match parent {
        REAL_LIB_A => {
            let mut a = real_library_movies("ra");
            a.push(real_virtual());
            a
        }
        REAL_LIB_B => real_library_movies("rb"),
        REAL_LIB_HOME => real_home(),
        REAL_LIB_SHOWS => vec![real_series()],
        REAL_BOX_PICTURE | REAL_BOX_TWO | REAL_BOX_FOUR => return real_box_members(parent),
        REAL_SERIES => vec![real_season()],
        REAL_SEASON => (1..=4).map(real_episode).collect(),
        _ => return None,
    };
    if recursive && parent == REAL_LIB_SHOWS {
        items.push(real_season());
        items.extend((1..=4).map(real_episode));
    } else if recursive && parent == REAL_SERIES {
        items.extend((1..=4).map(real_episode));
    }
    Some(items)
}

/// A square, clearly coloured avatar: a violet-blue gradient with a light head and shoulders.
fn real_avatar(size: u32) -> Vec<u8> {
    let s = i64::from(size);
    let mut data = Vec::with_capacity((size * size * 3) as usize);
    for y in 0..s {
        for x in 0..s {
            let inside = |cx: i64, cy: i64, r: i64| (x - cx).pow(2) + (y - cy).pow(2) <= r * r;
            let px = if inside(s / 2, s * 38 / 100, s / 5) {
                [250, 215, 180]
            } else if inside(s / 2, s * 98 / 100, s * 38 / 100) {
                [245, 245, 250]
            } else {
                [
                    (40 + 90 * x / s) as u8,
                    (90 + 40 * y / s) as u8,
                    (220 - 60 * y / s) as u8,
                ]
            };
            data.extend(px);
        }
    }
    encode_rgb(size, size, &data)
}

fn real_json_list(items: &[String]) -> Reply {
    json(list(items))
}

/// The real-shape answers, or `None` to let the plain fixture answer. Only when the mode is on.
fn real_answer(method: &str, path: &str, query: &str) -> Option<Reply> {
    if !real_enabled() {
        return None;
    }
    real_answer_on(method, path, query)
}

fn real_answer_on(method: &str, path: &str, query: &str) -> Option<Reply> {
    let param = |k: &str| {
        query.split('&').find_map(|p| {
            p.split_once('=')
                .filter(|(n, _)| n.eq_ignore_ascii_case(k))
                .map(|(_, v)| v.to_owned())
        })
    };
    let segs: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    let types = param("IncludeItemTypes");
    let recursive = param("Recursive").is_some_and(|v| v.eq_ignore_ascii_case("true"));
    match segs.as_slice() {
        ["Users", "Public"] if method == "GET" => Some(json(format!("[{}]", real_user()))),
        ["Users"] if method == "GET" => Some(json(format!("[{}]", real_user()))),
        ["Users", u] if method == "GET" && *u != "AuthenticateByName" => Some(json(real_user())),
        ["Users", _, "Images", "Primary"] | ["UserImage"] => {
            let size = [
                "maxHeight",
                "maxWidth",
                "fillHeight",
                "fillWidth",
                "height",
                "width",
            ]
            .iter()
            .find_map(|k| param(k).and_then(|v| v.parse::<u32>().ok()))
            .unwrap_or(192)
            .clamp(32, 512);
            Some(Reply(200, "image/png", real_avatar(size)))
        }
        [.., "UserViews"] | [.., "Views"] => Some(real_json_list(&real_views())),
        ["Shows", id, "Seasons"] if *id == REAL_SERIES => Some(real_json_list(&[real_season()])),
        ["Shows", id, "Episodes"] if *id == REAL_SERIES => {
            let all = match param("SeasonId") {
                Some(s) if s != REAL_SEASON => Vec::new(),
                _ => (1..=4).map(real_episode).collect(),
            };
            Some(real_json_list(&all))
        }
        ["Playlists", id, "Items"] if *id == REAL_PLAYLIST => Some(real_json_list(&[
            real_find("ra0").unwrap_or_default(),
            real_find("ra1").unwrap_or_default(),
            real_episode(1),
        ])),
        [.., "Items"] if types.as_deref() == Some("BoxSet") => {
            Some(real_json_list(&real_boxsets()))
        }
        [.., "Items"] if types.as_deref() == Some("Playlist") => {
            Some(real_json_list(&[real_playlist()]))
        }
        // "Next up" comes from the same catalogue as the Serien library: without this arm the simple fixture's series
        // "Hafenlichter" showed on Home although no library holds it.
        ["Shows", "NextUp"] => Some(real_json_list(&[real_episode(2)])),
        [.., "Items", "Latest"] => {
            let items = param("ParentId")
                .and_then(|p| real_children(&p, false))
                .unwrap_or_else(real_episodes_newest_first);
            Some(json(format!(
                "[{}]",
                of_types(items, types.as_deref()).join(",")
            )))
        }
        [.., "Items", id] if method == "GET" && real_find(id).is_some() => real_find(id).map(json),
        [.., "Items"] => {
            let ids = param("Ids").or_else(|| param("ids"));
            let plain = types
                .as_deref()
                .is_some_and(|t| t.contains("BoxSet") || t.contains("Playlist"));
            if let Some(ids) = ids {
                let ids = ids.replace("%2C", ",").replace("%2c", ",");
                let found: Vec<String> = ids.split(',').filter_map(real_find).collect();
                return (!found.is_empty()).then(|| real_json_list(&found));
            }
            if let Some(person) = param("PersonIds") {
                let items = match person.as_str() {
                    "rp1" => vec![real_find("ra0"), real_find("ra2"), real_find(REAL_SERIES)],
                    "rp2" => vec![real_find("ra1"), real_find(REAL_SERIES)],
                    _ => Vec::new(),
                };
                let items = items.into_iter().flatten().collect();
                return Some(real_json_list(&of_types(items, types.as_deref())));
            }
            if let Some(items) = param("ParentId").and_then(|p| real_children(&p, recursive)) {
                // Nothing in a collection is a favourite or half watched: those filters leave it empty.
                let narrowed = param("Filters")
                    .is_some_and(|f| f.contains("IsFavorite") || f.contains("IsResumable"));
                let boxed = param("ParentId").is_some_and(|p| real_box_members(&p).is_some());
                if narrowed && boxed {
                    return Some(real_json_list(&[]));
                }
                return Some(real_json_list(&of_types(items, types.as_deref())));
            }
            if plain || param("ParentId").is_some() {
                return None;
            }
            if param("SortBy").is_some_and(|s| s.starts_with("DateCreated")) {
                let mut items = real_episodes_newest_first();
                items.extend(real_library_movies("ra"));
                items.extend(real_library_movies("rb"));
                items.extend(real_home());
                return Some(real_json_list(&of_types(items, types.as_deref())));
            }
            // The whole catalogue: both libraries' films (so a film shows twice), the home videos, the
            // missing movie, the series; seasons and episodes only when asked for by type.
            let mut items = real_library_movies("ra");
            items.push(real_virtual());
            items.extend(real_library_movies("rb"));
            items.extend(real_home());
            items.push(real_series());
            if types.is_some() {
                items.push(real_season());
                items.extend((1..=4).map(real_episode));
            }
            Some(real_json_list(&of_types(items, types.as_deref())))
        }
        _ => None,
    }
}

fn serve(mut stream: TcpStream) {
    let mut reader = BufReader::new(match stream.try_clone() {
        Ok(s) => s,
        Err(_) => return,
    });
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).unwrap_or(0) == 0 {
            return;
        }
        let mut parts = line.split_whitespace();
        let (method, target) = (
            parts.next().unwrap_or("GET").to_owned(),
            parts.next().unwrap_or("/").to_owned(),
        );
        let mut length = 0_usize;
        let mut range = None;
        let mut range_end: Option<usize> = None;
        let mut close = false;
        let mut ws_key = None;
        let mut device = String::new();
        let mut authorization = String::new();
        loop {
            let mut h = String::new();
            if reader.read_line(&mut h).unwrap_or(0) == 0 || h.trim().is_empty() {
                break;
            }
            let lower = h.to_ascii_lowercase();
            if let Some(v) = lower.strip_prefix("content-length:") {
                length = v.trim().parse().unwrap_or(0);
            }
            if lower.starts_with("connection:") && lower.contains("close") {
                close = true;
            }
            if lower.starts_with("sec-websocket-key:") {
                ws_key = h.split_once(':').map(|(_, v)| v.trim().to_owned());
            }
            if (lower.starts_with("authorization:") || lower.starts_with("x-emby-authorization:"))
                && let Some((_, rest)) = h.split_once("DeviceId=\"")
            {
                device = rest.split('"').next().unwrap_or("").to_owned();
                authorization = h.clone();
            }
            if let Some(v) = lower.strip_prefix("range:") {
                range = v
                    .trim()
                    .strip_prefix("bytes=")
                    .and_then(|r| r.split('-').next()?.parse::<usize>().ok());
                range_end = v
                    .trim()
                    .strip_prefix("bytes=")
                    .and_then(|r| r.split('-').nth(1)?.parse::<usize>().ok());
            }
        }
        let mut body = vec![0; length];
        if reader.read_exact(&mut body).is_err() {
            return;
        }
        if let (Some(key), true) = (&ws_key, target.starts_with("/socket")) {
            let socket_device = target
                .split_once("deviceId=")
                .map(|(_, r)| r.split('&').next().unwrap_or("").to_owned())
                .unwrap_or_default();
            crate::fixture_syncplay::websocket(stream, key, &socket_device);
            return;
        }
        let body_text = String::from_utf8_lossy(&body);
        crate::fixture_sessions::seen(&authorization);
        crate::fixture_sessions::observe(
            &method,
            target.split('?').next().unwrap_or(""),
            &body_text,
            &device,
        );
        let (cfg, state) = crate::fixture_modes::global();
        let normal = || match crate::fixture_syncplay::answer(&method, &target, &body_text, &device)
        {
            Some(r) => r,
            None => route(&method, &target, &body_text),
        };
        let Reply(status, kind, data) =
            match crate::fixture_modes::handle(cfg, state, &method, &target, &normal) {
                crate::fixture_modes::Outcome::Reply(r) => r,
                crate::fixture_modes::Outcome::Drop => return,
            };
        // Milliseconds since the first request, so a live run can tell when a picture was asked for.
        static FIRST: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
        let at = FIRST
            .get_or_init(std::time::Instant::now)
            .elapsed()
            .as_millis();
        eprintln!("fixture-server: {method} {target} -> {status} +{at}ms");
        let (status, slice, extra) = match range {
            // `bytes=a-b` cuts to b (inclusive); `bytes=a-` runs to the end as before.
            Some(from) if status == 200 && from < data.len() => {
                let last = range_end
                    .map_or(data.len() - 1, |e| e.min(data.len() - 1))
                    .max(from);
                (
                    206,
                    data[from..=last].to_vec(),
                    format!("Content-Range: bytes {from}-{last}/{}\r\n", data.len()),
                )
            }
            _ if method == "POST" && target == "/api/v1/auth/jellyfin" => (
                status,
                data,
                "Set-Cookie: connect.sid=fixture; Path=/; HttpOnly\r\n".to_owned(),
            ),
            _ => (status, data, String::new()),
        };
        // `SWIFTLY_FIXTURE_ONE_REQUEST=1`: one request per connection, like a Plex origin on HTTP/1.1.
        let close = close || std::env::var_os("SWIFTLY_FIXTURE_ONE_REQUEST").is_some();
        let hang_up = if close { "Connection: close\r\n" } else { "" };
        let head = format!(
            "HTTP/1.1 {status} X\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nAccept-Ranges: bytes\r\n{hang_up}{extra}\r\n",
            slice.len()
        );
        if stream.write_all(head.as_bytes()).is_err() {
            return;
        }
        // `--slow-downloads`: media bodies trickle out (16 KiB every 100 ms), so a download stays "loading" long enough to
        // pause, resume and watch in the UI.
        let slow = SLOW_DOWNLOADS.load(std::sync::atomic::Ordering::Relaxed)
            && target.contains("/Videos/")
            && slice.len() > SLOW_CHUNK;
        let sent = if slow {
            slice.chunks(SLOW_CHUNK).all(|c| {
                std::thread::sleep(std::time::Duration::from_millis(100));
                stream.write_all(c).is_ok()
            })
        } else {
            stream.write_all(&slice).is_ok()
        };
        if !sent {
            return;
        }
        if close {
            return;
        }
    }
}

/// Set by `--slow-downloads`.
static SLOW_DOWNLOADS: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// Bytes per step of a slow download.
const SLOW_CHUNK: usize = 16 * 1024;

/// Runs the server until the process is stopped. Prints `listening on http://127.0.0.1:PORT` once ready.
/// Flags (env in brackets): `--big` [SWIFTLY_FIXTURE_BIG] (300 movies, 40 series, genres, four accounts), `--port N`, `--mode a,b` [SWIFTLY_FIXTURE_MODE], `--latency-ms N` [SWIFTLY_FIXTURE_LATENCY_MS],
/// `--flaky-every N` [SWIFTLY_FIXTURE_FLAKY_EVERY], `--expire-after N` [SWIFTLY_FIXTURE_EXPIRE_AFTER].
pub fn run(args: &[String]) -> Result<(), String> {
    const USAGE: &str = "usage: cargo xtask fixture-server [--port N] [--real-shapes] [--mode empty|long|huge|i18n|sessions|slow|offline-flaky|auth-expire[,..]] [--latency-ms N] [--flaky-every N] [--expire-after N]";
    let env_num = |k: &str| std::env::var(k).ok().and_then(|v| v.parse::<u64>().ok());
    let (mut port, mut modes) = (
        0_u16,
        std::env::var("SWIFTLY_FIXTURE_MODE").unwrap_or_default(),
    );
    let (mut latency, mut flaky, mut expire) = (
        env_num("SWIFTLY_FIXTURE_LATENCY_MS"),
        env_num("SWIFTLY_FIXTURE_FLAKY_EVERY"),
        env_num("SWIFTLY_FIXTURE_EXPIRE_AFTER"),
    );
    let mut it = args.iter();
    while let Some(flag) = it.next() {
        if flag == "--big" {
            crate::fixture_big::enable();
            continue;
        }
        if flag == "--real-shapes" {
            enable_real();
            continue;
        }
        if flag == "--slow-downloads" {
            SLOW_DOWNLOADS.store(true, std::sync::atomic::Ordering::Relaxed);
            continue;
        }
        let value = it.next().ok_or(USAGE)?;
        let num = || value.parse::<u64>().map_err(|e| e.to_string());
        match flag.as_str() {
            "--port" => port = value.parse::<u16>().map_err(|e| e.to_string())?,
            "--mode" => modes = value.clone(),
            "--latency-ms" => latency = Some(num()?),
            "--flaky-every" => flaky = Some(num()?),
            "--expire-after" => expire = Some(num()?),
            _ => return Err(USAGE.into()),
        }
    }
    crate::fixture_modes::set_global(crate::fixture_modes::Config::parse(
        &modes, latency, flaky, expire,
    )?);
    // `SWIFTLY_FIXTURE_BIND=0.0.0.0`: reachable from a real device on the LAN (default: this machine only).
    let bind = std::env::var("SWIFTLY_FIXTURE_BIND").unwrap_or_else(|_| "127.0.0.1".into());
    let listener = TcpListener::bind((bind.as_str(), port)).map_err(|e| e.to_string())?;
    let addr = listener.local_addr().map_err(|e| e.to_string())?;
    println!("listening on http://{addr}");
    for stream in listener.incoming().flatten() {
        std::thread::spawn(move || serve(stream));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn playback_info_names_the_versions_the_listing_names() {
        let ids = |json: &str| {
            json.split(r#""Id":""#)
                .skip(1)
                .filter_map(|r| r.split('"').next())
                .filter(|i| i.starts_with("src"))
                .map(str::to_owned)
                .collect::<Vec<_>>()
        };
        let all = ["ra0", "ra1", "ra4", "rb2", "hv1", "m0", "m3"];
        for id in all {
            let item =
                super::real_find(id).unwrap_or_else(|| super::movie(id[1..].parse().unwrap()));
            let (listed, offered) = (ids(&item), ids(&super::playback_info(id)));
            assert!(!listed.is_empty(), "{id} lists no version");
            assert_eq!(
                listed, offered,
                "{id}: PlaybackInfo must offer the listed versions"
            );
        }
        // Items without versions in their listing keep the one `src-<id>` version.
        assert!(super::playback_info("bg-m1").contains(r#""Id":"src-bg-m1""#));
    }

    use super::*;

    /// Every kind of request the server answered before the player extras existed.
    const OLD_REQUESTS: &[(&str, &str, &str)] = &[
        ("GET", "/System/Info/Public", ""),
        (
            "POST",
            "/Users/AuthenticateByName",
            r#"{"Username":"demo","Pw":"demo"}"#,
        ),
        (
            "POST",
            "/Users/AuthenticateByName",
            r#"{"Username":"x","Pw":"y"}"#,
        ),
        ("POST", "/QuickConnect/Initiate", ""),
        ("GET", "/QuickConnect/Connect?secret=quick-secret", ""),
        ("POST", "/Users/AuthenticateWithQuickConnect", ""),
        ("GET", "/Users/Public", ""),
        ("GET", "/Users/u1/Views", ""),
        ("GET", "/UserItems/Resume?userId=u1", ""),
        ("GET", "/Shows/NextUp?userId=u1", ""),
        ("GET", "/Shows/s1/Seasons?userId=u1", ""),
        ("GET", "/Shows/s1/Episodes?userId=u1", ""),
        ("GET", "/Users/u1/Items/Latest", ""),
        ("GET", "/Users/u1/Items?Recursive=true", ""),
        ("GET", "/Users/u1/Items/m0", ""),
        ("GET", "/Users/u1/Items/m1", ""),
        ("GET", "/Users/u1/Items/m2", ""),
        ("GET", "/Users/u1/Items/m3", ""),
        ("GET", "/Users/u1/Items/m4", ""),
        ("GET", "/Users/u1/Items/m5", ""),
        ("GET", "/Users/u1/Items/m6", ""),
        ("GET", "/Users/u1/Items/m10", ""),
        ("GET", "/Users/u1/Items/s1", ""),
        ("GET", "/Users/u1/Items/p1", ""),
        ("GET", "/Users/u1/Items/e1", ""),
        ("GET", "/Users/u1/Items/e2", ""),
        ("GET", "/Users/u1/Items/e3", ""),
        ("GET", "/Users/u1/Items/e4", ""),
        ("GET", "/Items/m0?userId=u1&Fields=Chapters", ""),
        ("GET", "/Items/m0?userId=u1&Fields=Trickplay", ""),
        ("GET", "/Items/m2/Images/Primary", ""),
        ("GET", "/Items/m2/Images/Backdrop/0", ""),
        ("GET", "/Videos/m0/stream?static=true", ""),
        ("GET", "/Videos/m0/stream.mp4", ""),
        ("GET", "/MediaSegments", ""),
        ("GET", "/MediaSegments/m0", ""),
        ("GET", "/MediaSegments/e1", ""),
        ("POST", "/Items/m0/PlaybackInfo", "{}"),
        ("POST", "/Items/e1/PlaybackInfo", "{}"),
        ("POST", "/Users/u1/PlayedItems/m0", ""),
        ("GET", "/Items/m0/Similar", ""),
        ("GET", "/Items/m0/SpecialFeatures", ""),
        ("GET", "/Items/m0/LocalTrailers", ""),
        ("GET", "/Users/u1/Items?IncludeItemTypes=BoxSet", ""),
        ("GET", "/Users/u1/Items?IncludeItemTypes=Playlist", ""),
        ("GET", "/Users/u1/Items?ParentId=c1", ""),
        ("GET", "/Users/u1/Items?ParentId=c2", ""),
        ("GET", "/Playlists/pl1/Items", ""),
        ("GET", "/Videos/m0/Trickplay/320/0.jpg", ""),
        ("GET", "/Videos/m0/src0/Subtitles/2/Stream.srt", ""),
        ("GET", "/nowhere", ""),
    ];

    fn fnv(hash: &mut u64, bytes: &[u8]) {
        for b in bytes {
            *hash = (*hash ^ u64::from(*b)).wrapping_mul(0x0000_0100_0000_01b3);
        }
    }

    /// What a PNG shows: its decoded pixels. The compressed bytes depend on the `png` crate's deflate backend, which
    /// the feature set of the whole build decides (a workspace-wide test run picks another one than `-p xtask`).
    fn png_pixels(data: &[u8]) -> Vec<u8> {
        let mut reader = png::Decoder::new(std::io::Cursor::new(data))
            .read_info()
            .expect("png header");
        let mut pixels = vec![0; reader.output_buffer_size().expect("png size")];
        let info = reader.next_frame(&mut pixels).expect("png data");
        pixels.truncate(info.buffer_size());
        pixels
    }

    fn old_answers_hash() -> u64 {
        let mut hash = 0xcbf2_9ce4_8422_2325_u64;
        for (method, target, body) in OLD_REQUESTS {
            let Reply(status, kind, data) = route(method, target, body);
            let data = if kind == "image/png" {
                png_pixels(&data)
            } else {
                data
            };
            fnv(
                &mut hash,
                format!("{method} {target} {status} {kind} {}\n", data.len()).as_bytes(),
            );
            fnv(&mut hash, &data);
        }
        hash
    }

    /// Hash of the answers above (PNG as decoded pixels), measured on the server before the player extras were added.
    /// `Items?ids=` is not in the list on purpose: it answered the unfiltered fallback before the downloads catch-up
    /// needed the real filter (see `ids_filter_answers_exactly_the_known_ones`); every other answer is unchanged
    /// (checked by re-running the old routing: the old hash 13_088_136_916_963_034_929 came back with that one request).
    const OLD_ANSWERS_HASH: u64 = 17_122_911_487_198_912_136;

    #[test]
    fn display_preferences_keep_what_a_client_wrote() {
        let Reply(status, _, first) = route(
            "GET",
            "/DisplayPreferences/swiftly?userId=u1&client=Swiftly",
            "",
        );
        assert_eq!(
            (status, first.as_slice()),
            (200, br#"{"Id":"swiftly","CustomPrefs":{}}"#.as_slice())
        );
        let body = r#"{"Id":"swiftly","CustomPrefs":{"swiftly.changed":"1"}}"#;
        let Reply(status, _, _) = route(
            "POST",
            "/DisplayPreferences/swiftly?userId=u1&client=Swiftly",
            body,
        );
        assert_eq!(status, 204);
        let Reply(_, _, back) = route(
            "GET",
            "/DisplayPreferences/swiftly?userId=u1&client=Swiftly",
            "",
        );
        assert_eq!(back, body.as_bytes());
    }

    #[test]
    fn old_answers_stay_byte_identical() {
        assert_eq!(
            old_answers_hash(),
            OLD_ANSWERS_HASH,
            "an answer that existed before the player extras changed"
        );
    }

    #[test]
    fn ids_filter_answers_exactly_the_known_ones() {
        let body = text(&get("/Users/u1/Items?ids=m1")).to_owned();
        assert!(
            body.starts_with(r#"{"Items":[{"Id":"m1""#)
                && body.matches(r#""Id":"m1""#).count() == 1,
            "{body}"
        );
        assert!(text(&get("/Users/u1/Items?ids=nope")).starts_with(r#"{"Items":[]"#));
    }

    fn get(target: &str) -> Reply {
        route("GET", target, "")
    }

    fn text(reply: &Reply) -> &str {
        std::str::from_utf8(&reply.2).expect("utf-8 body")
    }

    #[test]
    fn extras_movie_is_reachable_but_in_no_list() {
        let Reply(status, _, body) = get("/Users/u1/Items/g1");
        assert_eq!(status, 200);
        let item = String::from_utf8(body).expect("utf-8");
        for part in [
            r#""Id":"g1""#,
            r#""Chapters":["#,
            r#""Name":"Anfang","StartPositionTicks":0,"ImageTag":"cg1""#,
            r#""Name":"Mitte","StartPositionTicks":30000000}"#,
            r#""Trickplay":{"srcg1":{"320":{"Width":320,"Height":176,"TileWidth":3,"TileHeight":2,"ThumbnailCount":6,"Interval":2000"#,
        ] {
            assert!(item.contains(part), "missing {part}");
        }
        assert!(
            get("/Users/u1/Items?ids=g1")
                .2
                .starts_with(br#"{"Items":[{"Id":"g1""#)
        );
        for list in [
            "/Users/u1/Items",
            "/Users/u1/Items/Latest",
            "/UserItems/Resume",
            "/Items/m0/Similar",
        ] {
            assert!(
                !text(&get(list)).contains(r#""Id":"g1""#),
                "{list} lists g1"
            );
        }
    }

    #[test]
    fn extras_has_two_versions_two_audio_tracks_and_external_subtitles() {
        let item = text(&get("/Users/u1/Items/g1")).to_owned();
        assert!(
            item.contains(r#"{"Id":"srcg1","Name":"1080p""#)
                && item.contains(r#"{"Id":"srcg1b","Name":"4K""#)
        );
        for source in ["srcg1", "srcg1b"] {
            let streams = extras_streams(source, "h264", 1920, 1080);
            assert!(streams.contains(
                r#""Type":"Audio","Codec":"ac3","Channels":6,"Index":2,"Language":"deu""#
            ));
            assert!(streams.contains(
                r#""Index":3,"Language":"eng","DisplayTitle":"English (SRT)","IsExternal":true"#
            ));
            assert!(streams.contains(&format!(r#""DeliveryMethod":"External","DeliveryUrl":"/Videos/g1/{source}/Subtitles/3/0/Stream.srt""#)));
            assert!(item.contains(&format!("/Videos/g1/{source}/Subtitles/4/0/Stream.vtt")));
        }
        let info = route("POST", "/Items/g1/PlaybackInfo", "{}");
        assert!(
            text(&info).contains(r#""Name":"4K""#)
                && text(&info).contains(r#""PlaySessionId":"fx-session""#)
        );
    }

    #[test]
    fn extras_subtitle_files_are_tiny_valid_srt_and_vtt() {
        for path in [
            "/Videos/g1/srcg1/Subtitles/3/Stream.srt",
            "/Videos/g1/srcg1b/Subtitles/3/0/Stream.srt",
        ] {
            let r = get(path);
            assert_eq!((r.0, r.1), (200, "application/x-subrip"), "{path}");
            assert!(text(&r).starts_with("1\n00:00:01,000 --> 00:00:03,000\n"));
        }
        for path in [
            "/Videos/g1/srcg1/Subtitles/4/Stream.vtt",
            "/Videos/g1/srcg1/Subtitles/4/0/Stream.vtt",
        ] {
            let r = get(path);
            assert_eq!((r.0, r.1), (200, "text/vtt"), "{path}");
            assert!(text(&r).starts_with("WEBVTT\n\n00:00:01.000 --> 00:00:03.000\n"));
        }
    }

    #[test]
    fn extras_segments_have_intro_and_outro_only_for_g1() {
        let r = get("/MediaSegments/g1");
        assert_eq!(r.0, 200);
        assert!(text(&r).contains(r#"{"Type":"Intro","StartTicks":20000000,"EndTicks":50000000}"#));
        assert!(
            text(&r).contains(r#"{"Type":"Outro","StartTicks":100000000,"EndTicks":120000000}"#)
        );
        assert!(!text(&get("/MediaSegments/m0")).contains("Outro"));
    }

    #[test]
    fn extras_trickplay_serves_manifest_and_one_decodable_looking_sheet() {
        let m = get("/Videos/g1/Trickplay/320/tiles.m3u8");
        assert!(
            text(&m).contains("#EXT-X-TILES:RESOLUTION=960x352,LAYOUT=3x2,DURATION=2.000\n0.jpg")
        );
        let sheet = get("/Videos/g1/Trickplay/320/0.jpg");
        assert_eq!((sheet.0, sheet.1), (200, "image/jpeg"));
        let b = sheet.2;
        assert!(b.starts_with(&[0xFF, 0xD8]) && b.ends_with(&[0xFF, 0xD9]));
        let sof = b
            .windows(4)
            .position(|w| w == [0xFF, 0xC0, 0x00, 0x0B])
            .expect("SOF0");
        assert_eq!(u16::from_be_bytes([b[sof + 5], b[sof + 6]]), 352);
        assert_eq!(u16::from_be_bytes([b[sof + 7], b[sof + 8]]), 960);
        assert_eq!(get("/Videos/g1/Trickplay/320/1.jpg").0, 404);
    }

    // ---- Real shapes (`--real-shapes`)

    /// Runs `f` with the real shapes on for this test thread only.
    fn real<T>(f: impl FnOnce() -> T) -> T {
        FORCE_REAL.with(|c| c.set(true));
        let out = f();
        FORCE_REAL.with(|c| c.set(false));
        out
    }

    fn real_get(target: &str) -> String {
        let r = real(|| get(target));
        assert_eq!(r.0, 200, "{target}");
        text(&r).to_owned()
    }

    fn ids_of(body: &str) -> Vec<String> {
        body.split(r#""Id":""#)
            .skip(1)
            .filter_map(|p| p.split('"').next().map(str::to_owned))
            .filter(|id| (id.starts_with('r') && !id.starts_with("rp")) || id.starts_with("hv"))
            .collect()
    }

    #[test]
    fn real_shapes_carry_collections_and_a_playlist() {
        let boxes = real_get("/Users/u1/Items?IncludeItemTypes=BoxSet&Recursive=true");
        assert_eq!(boxes.matches(r#""Type":"BoxSet""#).count(), 3, "{boxes}");
        // One with its own picture, the others without (the Mac draws a mosaic for those).
        assert_eq!(boxes.matches("ImageTags").count(), 1, "{boxes}");
        assert_eq!(
            ids_of(&real_get(
                "/Users/u1/Items?ParentId=rc1&IncludeItemTypes=Movie"
            )),
            ["ra0", "ra1", "ra2"]
        );
        assert_eq!(
            ids_of(&real_get("/Users/u1/Items?ParentId=rc2")),
            ["rb3", "rb4"]
        );
        assert_eq!(ids_of(&real_get("/Users/u1/Items?ParentId=rc3")).len(), 4);
        let lists = real_get("/Users/u1/Items?IncludeItemTypes=Playlist");
        assert!(lists.contains(r#""Id":"rpl1""#), "{lists}");
        let entries = real_get("/Playlists/rpl1/Items?UserId=u1");
        assert!(
            entries.contains("ra0") && entries.contains(r#""Type":"Episode""#),
            "{entries}"
        );
        assert!(real_get("/Users/u1/Items/rc2").contains("Zwei Filme"));
        // A collection has no favourites: that filter leaves it empty, while the plain list stays full.
        assert!(ids_of(&real_get("/Users/u1/Items?ParentId=rc1&Filters=IsFavorite")).is_empty());
    }

    /// The Serien library lists series only and the Filme library films only (the i18n mode served both everywhere).
    #[test]
    fn the_plain_libraries_hold_their_own_kind_of_title() {
        let shows = text(&get(
            "/Users/u1/Items?ParentId=lib-shows&IncludeItemTypes=Series&Recursive=true",
        ))
        .to_owned();
        assert!(
            shows.contains(r#""Type":"Series""#) && !shows.contains(r#""Type":"Movie""#),
            "{shows}"
        );
        let shows = text(&get("/Users/u1/Items?ParentId=lib-shows&Recursive=true")).to_owned();
        assert!(!shows.contains(r#""Type":"Movie""#), "{shows}");
        let movies = text(&get(
            "/Users/u1/Items?ParentId=lib-movies&IncludeItemTypes=Movie",
        ))
        .to_owned();
        assert!(
            movies.contains(r#""Type":"Movie""#) && !movies.contains(r#""Type":"Series""#),
            "{movies}"
        );
        // Without a type or a parent the catalogue stays whole.
        let all = text(&get("/Users/u1/Items?Recursive=true")).to_owned();
        assert!(
            all.contains(r#""Type":"Movie""#) && all.contains(r#""Type":"Series""#),
            "{all}"
        );
    }

    #[test]
    fn plain_collections_stay_as_they_were() {
        let plain = text(&get("/Users/u1/Items?IncludeItemTypes=BoxSet")).to_owned();
        assert!(
            plain.contains(r#""Id":"c1""#) && !plain.contains("rc1"),
            "{plain}"
        );
    }

    #[test]
    fn the_declared_size_is_the_size_it_serves() {
        let size = format!("\"Size\":{},", CLIP.len());
        assert!(movie(1).contains(&size), "the film's first source");
        assert!(extras_sources().contains(&size), "the extras' first source");
        assert!(!movie(1).contains("1500000"));
    }

    #[test]
    fn real_shapes_are_off_by_default() {
        for target in [
            "/Users/u1/Views",
            "/Users/Me",
            "/Users/u1/Items?ParentId=rl-home",
            "/Users/u1/Items?PersonIds=rp1",
            "/Users/u1/Items/rv1",
            "/Users/u1/Items/rse1",
            "/Users/u1/Items/rp1",
            "/Users/u1/Images/Primary",
        ] {
            let r = get(target);
            if r.1 == "image/png" {
                // The plain gradient, not the avatar.
                assert_ne!(r.2, real(|| get(target)).2, "{target}");
            } else {
                let body = text(&r);
                assert!(
                    !body.contains("rl-movies-a") && !body.contains("Virtual"),
                    "{target}: {body}"
                );
                assert!(
                    !body.contains("rv1")
                        && !body.contains("rse1")
                        && !body.contains("PrimaryImageTag\":\"avatar1"),
                    "{target}: {body}"
                );
            }
        }
        assert!(!auth_result_with("demo", false).contains("PrimaryImageTag"));
        let default_auth = route(
            "POST",
            "/Users/AuthenticateByName",
            r#"{"Username":"demo","Pw":"demo"}"#,
        );
        assert!(!text(&default_auth).contains("PrimaryImageTag"));
        assert!(!text(&get("/Users/u1/Views")).contains("rl-"));
    }

    #[test]
    fn real_two_movie_libraries_share_tmdb_ids() {
        let views = real_get("/Users/u1/Views");
        assert_eq!(
            views.matches(r#""CollectionType":"movies""#).count(),
            2,
            "{views}"
        );
        assert!(views.contains(r#""Id":"rl-home","Name":"Heimvideos","Type":"CollectionFolder","CollectionType":"homevideos""#));
        let a = real_get("/Users/u1/Items?ParentId=rl-movies-a");
        let b = real_get("/Users/u1/Items?ParentId=rl-movies-b");
        for n in 0..5 {
            let tmdb = format!(r#""ProviderIds":{{"Tmdb":"{}"}}"#, 1000 + n);
            assert!(
                a.contains(&format!(r#""Id":"ra{n}""#)) && a.contains(&tmdb),
                "{a}"
            );
            assert!(
                b.contains(&format!(r#""Id":"rb{n}""#)) && b.contains(&tmdb),
                "{b}"
            );
        }
        assert!(!b.contains("ra0"));
        // Without a parent every film is in the catalogue twice.
        let all = real_get("/Users/u1/Items?Recursive=true&IncludeItemTypes=Movie");
        assert_eq!(all.matches(r#""Tmdb":"1000""#).count(), 2, "{all}");
    }

    #[test]
    fn real_home_videos_are_movies_without_tmdb_ids() {
        let home = real_get("/Users/u1/Items?ParentId=rl-home");
        assert_eq!(home.matches(r#""Type":"Movie""#).count(), 3, "{home}");
        assert!(
            !home.contains("ProviderIds") && home.contains(r#""Id":"hv2""#),
            "{home}"
        );
    }

    #[test]
    fn real_virtual_movie_is_listed_but_has_no_file() {
        let a = real_get("/Users/u1/Items?ParentId=rl-movies-a");
        assert!(a.contains(r#""Id":"rv1""#), "{a}");
        let item = real_get("/Users/u1/Items/rv1");
        assert!(
            item.contains(r#""LocationType":"Virtual""#) && !item.contains("MediaSources"),
            "{item}"
        );
        assert!(real_get("/Users/u1/Items/ra0").contains(r#""LocationType":"FileSystem""#));
    }

    #[test]
    fn real_next_up_names_a_series_of_the_series_library() {
        let next = real_get("/Shows/NextUp?userId=u1");
        assert!(next.contains(r#""SeriesName":"Küstenwache""#), "{next}");
        assert!(!next.contains("Hafenlichter"), "{next}");
        let library = real_get("/Users/u1/Items?ParentId=rl-shows");
        assert!(library.contains(r#""Name":"Küstenwache""#), "{library}");
    }

    #[test]
    fn real_season_returns_its_episodes_both_ways() {
        let season = real_get("/Users/u1/Items/rse1");
        for part in [
            r#""Type":"Season""#,
            r#""SeriesId":"rs1""#,
            r#""SeriesName":"Küstenwache""#,
            r#""IndexNumber":2"#,
        ] {
            assert!(season.contains(part), "{season}");
        }
        assert!(real_get("/Shows/rs1/Seasons?userId=u1").contains(r#""Id":"rse1""#));
        for target in [
            "/Shows/rs1/Episodes?userId=u1&SeasonId=rse1",
            "/Users/u1/Items?ParentId=rse1",
        ] {
            let eps = real_get(target);
            assert_eq!(
                eps.matches(r#""Type":"Episode""#).count(),
                4,
                "{target}: {eps}"
            );
        }
        assert_eq!(
            real_get("/Shows/rs1/Episodes?SeasonId=nope"),
            r#"{"Items":[],"TotalRecordCount":0}"#
        );
    }

    #[test]
    fn real_latest_and_date_created_list_episodes_of_one_series() {
        for target in [
            "/Users/u1/Items/Latest",
            "/Users/u1/Items?SortBy=DateCreated&SortOrder=Descending&IncludeItemTypes=Episode",
        ] {
            let body = real_get(target);
            assert_eq!(ids_of(&body), ["re4", "re3", "re2", "re1"], "{target}");
            assert_eq!(body.matches(r#""SeriesId":"rs1""#).count(), 4);
            assert_eq!(body.matches(r#""SeasonId":"rse1""#).count(), 4);
            assert_eq!(body.matches(r#""ParentIndexNumber":2"#).count(), 4);
            assert!(
                body.contains(r#""IndexNumber":4"#)
                    && body.contains(r#""DateCreated":"2026-11-04"#)
            );
        }
    }

    #[test]
    fn real_people_have_details_credits_and_pictures() {
        let person = real_get("/Users/u1/Items/rp1");
        for part in [
            r#""Type":"Person""#,
            r#""Overview":"#,
            r#""PremiereDate":"1980-05-01"#,
            r#""ProductionLocations":["Berlin"]"#,
            r#""ProviderIds":{"Tmdb":"1234"}"#,
            r#""ImageTags":{"Primary":"prp1"}"#,
        ] {
            assert!(person.contains(part), "{person}");
        }
        let credits = real_get("/Users/u1/Items?PersonIds=rp1&Recursive=true");
        assert_eq!(ids_of(&credits), ["ra0", "ra2", "rs1"], "{credits}");
        assert_eq!(
            real_get("/Users/u1/Items?PersonIds=zz"),
            r#"{"Items":[],"TotalRecordCount":0}"#
        );
        let movie = real_get("/Users/u1/Items/ra0");
        assert!(movie.contains(r#"{"Id":"rp1","Name":"Anna Test","Type":"Actor","Role":"Hauptrolle","PrimaryImageTag":"prp1"}"#), "{movie}");
        let picture = real(|| get("/Items/rp1/Images/Primary?tag=prp1"));
        assert_eq!((picture.0, picture.1), (200, "image/png"));
        assert!(png_pixels(&picture.2).len() > 100);
    }

    /// The size of the picture a real-shape request gets (read from the PNG header).
    fn picture_size(target: &str) -> (u32, u32) {
        let r = real(|| get(target));
        assert_eq!((r.0, r.1), (200, "image/png"), "{target}");
        let header = png::Decoder::new(std::io::Cursor::new(&r.2[..]))
            .read_info()
            .expect("png header");
        let info = header.info();
        (info.width, info.height)
    }

    #[test]
    fn real_pictures_are_resized_to_the_asked_size_like_jellyfin() {
        // A poster fits the height it asks for and keeps its 2:3 aspect.
        assert_eq!(
            picture_size("/Items/ra0/Images/Primary?tag=t&maxHeight=480&quality=90"),
            (320, 480)
        );
        assert_eq!(
            picture_size("/Items/ra0/Images/Primary?maxHeight=300"),
            (200, 300)
        );
        // Never above the original (2000 x 3000).
        assert_eq!(
            picture_size("/Items/ra0/Images/Primary?maxHeight=5000"),
            (2000, 3000)
        );
        // A backdrop fits the width (4K original, 16:9).
        assert_eq!(
            picture_size("/Items/ra0/Images/Backdrop/0?maxWidth=1280"),
            (1280, 720)
        );
        assert_eq!(
            picture_size("/Items/ra0/Images/Backdrop?maxWidth=9999"),
            (3840, 2160)
        );
        // An episode's still is landscape, not a poster: height 360 gives 640 x 360, width 640 the same.
        assert_eq!(
            picture_size("/Items/re1/Images/Primary?maxHeight=360"),
            (640, 360)
        );
        assert_eq!(
            picture_size("/Items/bm-ep2/Images/Primary?maxWidth=640"),
            (640, 360)
        );
        assert_eq!(
            picture_size("/Items/ra0/Images/Thumb?maxWidth=960"),
            (960, 540)
        );
        // A fill box is met exactly (cover and cut), names in any case.
        assert_eq!(
            picture_size("/Items/ra0/Images/Primary?fillWidth=300&fillHeight=300"),
            (300, 300)
        );
        assert_eq!(
            picture_size("/Items/ra0/Images/Primary?FillWidth=320&FillHeight=180"),
            (320, 180)
        );
        // Without any size: the original.
        assert_eq!(picture_size("/Items/ra0/Images/Primary"), (2000, 3000));
    }

    #[test]
    fn real_user_has_a_picture_and_a_tag() {
        for target in ["/Users/Me", "/Users/u1", "/Users", "/Users/Public"] {
            assert!(
                real_get(target).contains(r#""PrimaryImageTag":"avatar1""#),
                "{target}"
            );
        }
        let auth = auth_result_with("demo", true);
        assert!(
            auth.contains(r#""Name":"demo","ServerId":"fx","PrimaryImageTag":"avatar1""#),
            "{auth}"
        );
        let routed = real(|| {
            route(
                "POST",
                "/Users/AuthenticateByName",
                r#"{"Username":"demo","Pw":"demo"}"#,
            )
        });
        assert!(text(&routed).contains("PrimaryImageTag"));
        let small = real(|| get("/Users/u1/Images/Primary?maxHeight=64&tag=avatar1"));
        let big = real(|| get("/Users/u1/Images/Primary"));
        assert_eq!((small.0, small.1), (200, "image/png"));
        let (px, big_px) = (png_pixels(&small.2), png_pixels(&big.2));
        assert_eq!((px.len(), big_px.len()), (64 * 64 * 3, 192 * 192 * 3));
        // Coloured and not flat: many distinct colours, none of them gray.
        let distinct: std::collections::HashSet<_> = big_px.chunks(3).collect();
        assert!(distinct.len() > 50, "{}", distinct.len());
        let corner = &big_px[0..3];
        assert!(corner[2] > corner[0] + 60, "{corner:?}");
        assert_eq!(real(|| get("/UserImage?userId=u1")).0, 200);
    }
}
