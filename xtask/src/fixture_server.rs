//! `cargo xtask fixture-server [--port N] [--big] [--mode ...]`: a small Jellyfin-shaped HTTP server for the real-app runs. Auth (password
//! and Quick Connect), views, items, resume and next up, detail with a media source, seasons and episodes, generated
//! pictures, a playable test clip (16-bit WAV tone served with ranges) and the playback reports. Everything is
//! deterministic and read-only; user `demo`, password `demo` (or empty). Not a Jellyfin replacement: only what the
//! Rust app asks for.

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
        r#"{{"Id":"m{i}","Name":"{}","Type":"Movie","ProductionYear":{},"RunTimeTicks":120000000,"Overview":"Ein ruhiger Testfilm vom Fixture-Server.","Genres":["Drama"],"CommunityRating":7.5,"OfficialRating":"FSK 12","People":[{{"Id":"p1","Name":"Anna Test","Type":"Actor","Role":"Hauptrolle","PrimaryImageTag":"pp1"}},{{"Id":"p2","Name":"Ben Regie","Type":"Director"}}],"RemoteTrailers":[{{"Url":"https://www.youtube.com/watch?v=fixture{i}"}}],"ImageTags":{{"Primary":"p{i}"}},"BackdropImageTags":["b{i}"],"MediaSources":[{{"Id":"src{i}","Name":"Test","Container":"mp4","Size":1500000,"SupportsDirectPlay":true,"SupportsDirectStream":true,"RunTimeTicks":120000000,"MediaStreams":[{{"Type":"Video","Codec":"h264","Index":0,"Width":320,"Height":180}},{{"Type":"Audio","Codec":"aac","Channels":1,"Index":1,"DisplayTitle":"Ton","IsDefault":true}}]}},{{"Id":"src{i}b","Name":"Test klein","Container":"mkv","Size":900000,"SupportsDirectPlay":true,"SupportsDirectStream":true,"RunTimeTicks":120000000,"MediaStreams":[{{"Type":"Video","Codec":"hevc","Index":0,"Width":1280,"Height":720}},{{"Type":"Audio","Codec":"ac3","Channels":6,"Index":1,"Language":"deu","DisplayTitle":"Deutsch 5.1"}},{{"Type":"Subtitle","Codec":"srt","Index":2,"Language":"eng"}}]}}],"UserData":{{{resume}}}}}"#,
        NAMES[i % NAMES.len()],
        2015 + i
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
        r#"[{{"Id":"{a}","Name":"1080p","Container":"mp4","Size":1500000,"SupportsDirectPlay":true,"SupportsDirectStream":true,"RunTimeTicks":120000000,"MediaStreams":{}}},{{"Id":"{b}","Name":"4K","Container":"mkv","Size":9000000,"SupportsDirectPlay":true,"SupportsDirectStream":true,"RunTimeTicks":120000000,"MediaStreams":{}}}]"#,
        extras_streams(a, "h264", 1920, 1080),
        extras_streams(b, "hevc", 3840, 2160)
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

pub(crate) fn find(id: &str) -> Option<String> {
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
    let sid = server_id();
    let uid = if crate::fixture_big::enabled() {
        format!("u-{name}")
    } else if sid == "fx" {
        "u1".to_string()
    } else {
        format!("u-{sid}")
    };
    format!(
        r#"{{"User":{{"Id":"{uid}","Name":"{name}","ServerId":"{sid}"}},"AccessToken":"fixture-token","ServerId":"{sid}"}}"#
    )
}

fn png(seed: u32, w: u32, h: u32) -> Vec<u8> {
    let mut out = Vec::new();
    let mut enc = png::Encoder::new(&mut out, w, h);
    enc.set_color(png::ColorType::Rgb);
    enc.set_depth(png::BitDepth::Eight);
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
    if let Ok(mut wr) = enc.write_header() {
        let _ = wr.write_image_data(&data);
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
const CLIP: &[u8] = include_bytes!("../assets/fixture-clip.mp4");
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
    // The playback bench's server transcodes (HLS folders next to the media): before the plain media routes.
    if let Some(reply) = crate::fixture_hls::answer(method, path, body) {
        return reply;
    }
    // The playback bench titles (`bm-*`, only with SWIFTLY_FIXTURE_MEDIA_DIR): real media files.
    if let Some(reply) = crate::fixture_media::answer(path, query) {
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
        (_, "/System/Info/Public") => json(format!(r#"{{"ServerName":"Fixture","Version":"10.10.0","Id":"{}","ProductName":"Jellyfin Server"}}"#, server_id())),
        ("POST", "/Users/AuthenticateByName") => {
            let user = if crate::fixture_big::enabled() { crate::fixture_big::ACCOUNTS.iter().find(|n| body.contains(&format!(r#""Username":"{n}""#))) } else { body.contains(r#""Username":"demo""#).then_some(&"demo") };
            let ok = user.is_some() && (body.contains(r#""Pw":"demo""#) || body.contains(r#""Pw":"""#));
            if let (true, Some(name)) = (ok, user) { json(auth_result(name)) } else { Reply(401, "text/plain", b"bad".to_vec()) }
        }
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
        // Mode `sessions`: a second device of the same user (the TV) plays m1 at 25 s; hand-over posts are recorded.
        ("GET", "/Sessions") if crate::fixture_modes::global().0.sessions => json(r#"[{"Id":"fx-tv","UserId":"u1","DeviceId":"fx-tv-device","DeviceName":"Fixture TV","Client":"Swiftly TV","SupportsRemoteControl":true,"LastActivityDate":"2099-01-01T00:00:00.0000000Z","PlayableMediaTypes":["Video"],"NowPlayingItem":{"Id":"m1","Name":"Sommerregen","Type":"Movie","RunTimeTicks":120000000},"PlayState":{"IsPaused":false,"PositionTicks":250000000}}]"#.into()),
        ("POST", p) if crate::fixture_modes::global().0.sessions && p.starts_with("/Sessions/fx-tv/") => {
            record(p);
            Reply(204, "text/plain", Vec::new())
        }
        (_, "/MediaSegments") => Reply(404, "text/plain", Vec::new()),
        (_, p) if p.starts_with("/MediaSegments/") => json(r#"{"Items":[{"Type":"Intro","StartTicks":20000000,"EndTicks":50000000}],"TotalRecordCount":1}"#.into()),
        (_, "/fixture/reports") => json(format!("[{}]", REPORTS.lock().map(|r| r.iter().map(|l| format!("\"{l}\"")).collect::<Vec<_>>().join(",")).unwrap_or_default())),
        (_, p) if p.ends_with("/PlaybackInfo") => {
            let id = p.split('/').rev().nth(1).unwrap_or("m0");
            json(format!(r#"{{"MediaSources":[{{"Id":"src-{id}","Container":"mp4","SupportsDirectPlay":true,"SupportsDirectStream":true,"RunTimeTicks":120000000,"MediaStreams":[{{"Type":"Video","Codec":"h264","Index":0,"Width":320,"Height":180}},{{"Type":"Audio","Codec":"aac","Channels":1,"Index":1,"IsDefault":true}}]}}],"PlaySessionId":"fx-session"}}"#))
        }
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
        (_, p) if p.ends_with("/Items") && !has("Ids") && !has("ids") => json(list(&all_items())),
        (_, p) if p.rsplit('/').nth(1) == Some("Items") => match find(p.rsplit('/').next().unwrap_or("")) {
            Some(item) => json(item),
            None => Reply(404, "text/plain", b"no such item".to_vec()),
        },
        _ => json(list(&[])),
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
        eprintln!("fixture-server: {method} {target} -> {status}");
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
        if stream.write_all(head.as_bytes()).is_err() || stream.write_all(&slice).is_err() {
            return;
        }
        if close {
            return;
        }
    }
}

/// Runs the server until the process is stopped. Prints `listening on http://127.0.0.1:PORT` once ready.
/// Flags (env in brackets): `--big` [SWIFTLY_FIXTURE_BIG] (300 movies, 40 series, genres, four accounts), `--port N`, `--mode a,b` [SWIFTLY_FIXTURE_MODE], `--latency-ms N` [SWIFTLY_FIXTURE_LATENCY_MS],
/// `--flaky-every N` [SWIFTLY_FIXTURE_FLAKY_EVERY], `--expire-after N` [SWIFTLY_FIXTURE_EXPIRE_AFTER].
pub fn run(args: &[String]) -> Result<(), String> {
    const USAGE: &str = "usage: cargo xtask fixture-server [--port N] [--mode empty|long|huge|i18n|sessions|slow|offline-flaky|auth-expire[,..]] [--latency-ms N] [--flaky-every N] [--expire-after N]";
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
    const OLD_ANSWERS_HASH: u64 = 12_171_024_901_924_467_041;

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
}
