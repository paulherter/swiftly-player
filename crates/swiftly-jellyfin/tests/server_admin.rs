//! The administrator's server page, calls and readers (mock transport): counts with and without the plugin, drives,
//! tasks, log tail, session cards, and the requests of stop, restart and scan.
#![allow(clippy::expect_used, clippy::unwrap_used)]

use futures_executor::block_on;
use serde_json::{Value, json};
use swiftly_jellyfin::{
    ClientConfig, DiskUse, JellyfinClient, ResolutionCounts, ResolutionFilter, ServerDisk,
    ServerLogFile, ServerStream, ServerTask, Session, TitleAddition,
};
use swiftly_model::DeliveryMethod;
use swiftly_net::{ErrorKind, Method, MockTransport};

fn client(mock: MockTransport) -> JellyfinClient<MockTransport> {
    let c = JellyfinClient::new(
        mock,
        "https://tv.example.de",
        ClientConfig::new("dev1", "Test", "1.0"),
    )
    .expect("client");
    c.set_session(Some(Session {
        access_token: "TOKEN".into(),
        user_id: "u1".into(),
        user_name: "n".into(),
        server_url: "https://tv.example.de".into(),
        kind: swiftly_jellyfin::ServerKind::Jellyfin,
    }));
    c
}

fn calls(c: &JellyfinClient<MockTransport>) -> Vec<String> {
    c.transport()
        .requests()
        .iter()
        .map(|r| {
            let m = match r.method {
                Method::Get => "GET",
                Method::Post => "POST",
                Method::Put => "PUT",
                Method::Delete => "DELETE",
            };
            format!("{m} {}", r.url.path())
        })
        .collect()
}

fn stream(json: &str) -> ServerStream {
    ServerStream::playing(format!("[{json}]").as_bytes())
        .expect("list")
        .into_iter()
        .next()
        .expect("a playing session")
}

// ---------------------------------------------------------------- counts

#[test]
fn plugin_resolutions_sum_films_and_episodes_and_leave_music_videos_out() {
    let answer = json!({
        "Movie": {"4K": 10, "1080p": 20, "720p": 5, "SD": 3, "HDR": 8, "DV": 2},
        "Episode": {"4K": 1, "1080p": 100, "720p": 50, "SD": 7, "HDR": 0, "DV": 0},
        "MusicVideo": {"4K": 99, "SD": 99},
    });
    assert_eq!(
        ResolutionCounts::plugin(&answer),
        ResolutionCounts {
            uhd: 11,
            hd: 175,
            sd: 10
        }
    );
}

#[test]
fn filter_resolutions_take_4k_off_the_hd_count() {
    assert_eq!(
        ResolutionCounts::filters(4, 30, 6),
        ResolutionCounts {
            uhd: 4,
            hd: 26,
            sd: 6
        }
    );
    assert_eq!(ResolutionCounts::filters(5, 3, 0).hd, 0);
}

#[test]
fn without_the_plugin_the_filters_count_and_the_load_is_not_asked_again() {
    let mock = MockTransport::new()
        .route(
            "/System/Info",
            200,
            r#"{"ServerName":"lysnet","Version":"10.11.2"}"#,
        )
        .route(
            "/Items/Counts",
            200,
            r#"{"MovieCount":3,"SeriesCount":2,"EpisodeCount":40}"#,
        )
        .route("/JellyTwiggy/LibraryResolutions", 404, "")
        .route("/JellyTwiggy/SystemMetrics", 404, "")
        .route("/Items", 200, r#"{"Items":[],"TotalRecordCount":5}"#);
    let c = client(mock);
    let system = block_on(c.server_system()).expect("system");
    assert_eq!(
        (system.name.as_str(), system.version.as_str()),
        ("lysnet", "10.11.2")
    );
    assert_eq!(block_on(c.item_counts()).expect("counts").episodes, 40);
    assert_eq!(block_on(c.plugin_resolutions()), None);
    let counted: Vec<Option<i64>> = [
        ResolutionFilter::Uhd,
        ResolutionFilter::HdOrBetter,
        ResolutionFilter::Sd,
    ]
    .into_iter()
    .map(|f| block_on(c.resolution_filter_count(f)))
    .collect();
    assert_eq!(counted, vec![Some(5), Some(5), Some(5)]);
    // Every filter answers 5 here: 4K 5, HD-or-better 5 -> HD 0, SD 5.
    assert_eq!(
        ResolutionCounts::filters(5, 5, 5),
        ResolutionCounts {
            uhd: 5,
            hd: 0,
            sd: 5
        }
    );
    let query: Vec<String> = c
        .transport()
        .requests()
        .iter()
        .filter(|r| r.url.path() == "/Items")
        .filter_map(|r| r.url.query().map(str::to_owned))
        .collect();
    assert!(
        query[0].contains("Is4K=true") && query[0].contains("Limit=0"),
        "{query:?}"
    );
    assert!(query[1].contains("IsHd=true") && query[2].contains("IsHd=false"));
    // The first 404 of the load says "no plugin"; after that the page stops asking.
    assert_eq!(block_on(c.system_load()), None);
    c.transport().clear_requests();
    assert_eq!(block_on(c.system_load()), None);
    assert_eq!(block_on(c.plugin_resolutions()), None);
    assert!(calls(&c).is_empty(), "{:?}", calls(&c));
}

#[test]
fn with_the_plugin_the_load_and_the_resolutions_come_from_there() {
    let mock = MockTransport::new()
        .route(
            "/JellyTwiggy/LibraryResolutions",
            200,
            r#"{"Movie":{"4K":2,"1080p":1,"SD":0,"HDR":1,"DV":1}}"#,
        )
        .route(
            "/JellyTwiggy/SystemMetrics",
            200,
            r#"{"CpuPercent":12.5,"MemoryPercent":40,"MemoryUsedBytes":4000000000,"MemoryTotalBytes":10000000000}"#,
        );
    let c = client(mock);
    assert_eq!(
        block_on(c.plugin_resolutions()),
        Some(ResolutionCounts {
            uhd: 2,
            hd: 1,
            sd: 0
        })
    );
    let load = block_on(c.system_load()).expect("load");
    assert_eq!(
        (load.cpu_percent, load.memory_percent),
        (Some(12.5), Some(40.0))
    );
    assert!(!calls(&c).iter().any(|p| p == "GET /Items"));
}

#[test]
fn an_empty_plugin_answer_is_no_load() {
    let c = client(MockTransport::new().route("/JellyTwiggy/SystemMetrics", 200, "{}"));
    assert_eq!(block_on(c.system_load()), None);
}

// ---------------------------------------------------------------- drives, tasks, logs

#[test]
fn folders_on_one_drive_are_one_drive_and_unreadable_ones_are_missing() {
    let storage = json!({
        "ProgramDataFolder": {"Path": "/config", "FreeSpace": 50, "UsedSpace": 50, "DeviceId": "/"},
        "CacheFolder": {"Path": "/cache", "FreeSpace": 50, "UsedSpace": 50, "DeviceId": "/"},
        "TranscodingTempFolder": {"Path": "/tmp/t", "FreeSpace": -1, "UsedSpace": -1},
        "Libraries": [
            {"Id": "1", "Name": "Filme", "Folders": [
                {"Path": "/media/movies", "FreeSpace": 50, "UsedSpace": 950, "DeviceId": "/media"}]},
            {"Id": "2", "Name": "Serien", "Folders": [
                {"Path": "/media/tv", "FreeSpace": 50, "UsedSpace": 950, "DeviceId": "/media"},
                {"Path": "/usb/tv", "FreeSpace": 10, "UsedSpace": 10}]}
        ]
    });
    let list = ServerDisk::from_storage(&storage);
    assert_eq!(
        list.iter().map(|d| d.id.as_str()).collect::<Vec<_>>(),
        ["/media", "/usb/tv", "/"]
    );
    assert_eq!(
        list[0].uses,
        [
            DiskUse::Library("Filme".into()),
            DiskUse::Library("Serien".into())
        ]
    );
    assert_eq!((list[0].total(), list[0].free_share()), (1000, 0.05));
    assert!(list[0].nearly_full() && !list[2].nearly_full());
    assert_eq!(list[2].uses, [DiskUse::Jellyfin]);
}

#[test]
fn only_running_tasks_the_furthest_along_first() {
    let list = json!([
        {"Id": "a", "Name": "Scan", "State": "Running", "CurrentProgressPercentage": 12.4},
        {"Id": "b", "Name": "Idle", "State": "Idle"},
        {"Name": "no id", "State": "Running"},
        {"Id": "c", "Name": "Trickplay", "State": "Running", "CurrentProgressPercentage": 80}
    ]);
    let all: Vec<ServerTask> = list
        .as_array()
        .unwrap()
        .iter()
        .filter_map(ServerTask::read)
        .collect();
    let running = ServerTask::running(all);
    assert_eq!(
        running.iter().map(|t| t.id.as_str()).collect::<Vec<_>>(),
        ["c", "a"]
    );
}

#[test]
fn a_log_shows_its_end_from_a_line_start() {
    let text = "erste\nzweite\ndritte\n";
    assert_eq!(ServerLogFile::tail(text.as_bytes(), 100), text);
    assert_eq!(ServerLogFile::tail(text.as_bytes(), 10), "dritte\n");
}

#[test]
fn log_files_come_newest_first_and_a_file_is_cut_to_its_end() {
    let mock = MockTransport::new()
        .route(
            "/System/Logs",
            200,
            r#"[{"Name":"old.log","Size":10,"DateModified":"2026-11-01T10:00:00.0000000Z"},
                {"Name":"new.log","Size":2048,"DateModified":"2026-11-17T10:00:00.0000000Z"}]"#,
        )
        .route("/System/Logs/Log", 200, "erste\nzweite\ndritte\n");
    let c = client(mock);
    let files = block_on(c.log_files()).expect("files");
    assert_eq!(
        files.iter().map(|f| f.name.as_str()).collect::<Vec<_>>(),
        ["new.log", "old.log"]
    );
    assert_eq!(
        block_on(c.log_text("new.log", 10)).expect("log"),
        "dritte\n"
    );
    let last = c.transport().last_request().expect("request");
    assert_eq!(last.url.query(), Some("name=new.log"));
}

// ---------------------------------------------------------------- streams

const FILM: &str = r#"
{"Id":"s1","UserId":"u","UserName":"Andrey","Client":"Jellyfin Web","DeviceName":"Safari",
 "RemoteEndPoint":"172.30.212.2",
 "NowPlayingItem":{"Id":"m","Name":"Tenzing","Type":"Movie","ProductionYear":2026,"RunTimeTicks":75330000000,
   "ImageTags":{"Primary":"t"},
   "MediaStreams":[{"Type":"Video","Codec":"hevc","Width":3840,"Height":1600,"VideoRangeType":"DOVIWithHDR10","BitRate":25000000,"Index":0},
                   {"Type":"Audio","Codec":"ac3","Channels":6,"BitRate":640000,"Index":1},
                   {"Type":"Audio","Codec":"aac","Channels":2,"Index":2}]},
 "PlayState":{"PositionTicks":0,"IsPaused":true,"PlayMethod":"Transcode","AudioStreamIndex":1},
 "TranscodingInfo":{"IsVideoDirect":true,"IsAudioDirect":true,"Bitrate":26400000,"Framerate":241}}
"#;

#[test]
fn a_film_card_reads_title_poster_tracks_and_rate() {
    let s = stream(FILM);
    assert_eq!(s.title(), "Tenzing");
    assert_eq!(s.addition(), Some(TitleAddition::Year(2026)));
    assert_eq!(s.subtitle(), None);
    assert_eq!(s.poster(), ("m".to_owned(), Some("t".to_owned())));
    assert_eq!(s.id(), "s1/m");
    assert!(s.paused);
    let video = s.video_track().expect("video");
    assert_eq!(
        ServerStream::resolution(video.width, video.height),
        Some("4K")
    );
    assert_eq!(ServerStream::range(video.range_type.as_deref()), Some("DV"));
    // The chosen audio track (index 1), not the file's other one.
    assert_eq!(
        s.audio_track().and_then(|a| a.codec.as_deref()),
        Some("ac3")
    );
    assert_eq!(
        ServerStream::short_rate(s.bitrate()).as_deref(),
        Some("26 Mb/s")
    );
}

#[test]
fn only_a_new_container_is_direct_stream_a_real_conversion_is_transcode() {
    assert_eq!(stream(FILM).delivery(), DeliveryMethod::DirectStream);
    let json = FILM.replace(r#""IsVideoDirect":true"#, r#""IsVideoDirect":false"#);
    assert_eq!(stream(&json).delivery(), DeliveryMethod::Transcode);
}

#[test]
fn direct_play_shows_the_rate_of_the_tracks() {
    let json = FILM
        .replace(
            r#""PlayMethod":"Transcode""#,
            r#""PlayMethod":"DirectPlay""#,
        )
        .replace(r#""Bitrate":26400000,"#, "");
    let s = stream(&json);
    assert_eq!(s.delivery(), DeliveryMethod::DirectPlay);
    assert_eq!(
        ServerStream::short_rate(s.bitrate()).as_deref(),
        Some("26 Mb/s")
    );
}

#[test]
fn the_short_rate_has_whole_mb_from_ten_one_digit_below_and_kb_under_one() {
    assert_eq!(
        ServerStream::short_rate(Some(26_400_000.0)).as_deref(),
        Some("26 Mb/s")
    );
    assert_eq!(
        ServerStream::short_rate(Some(4_540_000.0)).as_deref(),
        Some("4.5 Mb/s")
    );
    assert_eq!(
        ServerStream::short_rate(Some(320_000.0)).as_deref(),
        Some("320 kb/s")
    );
    assert_eq!(
        (
            ServerStream::short_rate(None),
            ServerStream::short_rate(Some(0.0))
        ),
        (None, None)
    );
}

#[test]
fn an_episode_shows_the_series_season_episode_and_the_series_poster() {
    let s = stream(
        r#"{"Id":"s2","UserName":"Anna","NowPlayingItem":{"Id":"e","Name":"Pilot","Type":"Episode","SeriesName":"Lost",
          "SeriesId":"ser","SeriesPrimaryImageTag":"st","ParentIndexNumber":1,"IndexNumber":3,"RunTimeTicks":26000000000},
         "PlayState":{"PositionTicks":12000000000,"PlayMethod":"DirectPlay"}}"#,
    );
    assert_eq!(
        (s.title().as_str(), s.subtitle().as_deref()),
        ("Lost", Some("Pilot"))
    );
    assert_eq!(
        s.addition(),
        Some(TitleAddition::Episode {
            season: 1,
            episode: 3
        })
    );
    assert_eq!(s.poster(), ("ser".to_owned(), Some("st".to_owned())));
    assert!(!s.paused);
    assert!((s.share() - 12.0 / 26.0).abs() < 1e-4);
    assert_eq!(s.id(), "s2/e");
}

#[test]
fn sessions_without_playback_drop_out_and_a_broken_one_does_not_take_the_others() {
    let body = r#"[{"Id":"idle","UserName":"X"},{"Id":"bad","NowPlayingItem":{"Name":"no id"}},
        {"Id":"ok","NowPlayingItem":{"Id":"i","Name":"Song","Type":"Audio","AlbumArtist":"Band","AlbumId":"al","AlbumPrimaryImageTag":"at"}}]"#;
    let list = ServerStream::playing(body.as_bytes()).expect("list");
    assert_eq!(
        list.iter()
            .map(|s| s.session_id.as_str())
            .collect::<Vec<_>>(),
        ["ok"]
    );
    assert_eq!(
        list[0].addition(),
        Some(TitleAddition::Artist("Band".into()))
    );
    assert!(list[0].square_poster() && list[0].is_audio());
    assert_eq!(list[0].poster().0, "al");
    assert!(matches!(
        ServerStream::playing(b"{}"),
        Err(ErrorKind::Decoding(_))
    ));
}

#[test]
fn the_clock_has_hours_only_when_the_whole_is_that_long() {
    assert_eq!(ServerStream::clock(0.0, true), "0:00:00");
    assert_eq!(ServerStream::clock(7533.0, true), "2:05:33");
    assert_eq!(ServerStream::clock(65.0, false), "1:05");
}

#[test]
fn resolution_goes_by_width_first_and_range_only_when_not_sdr() {
    assert_eq!(ServerStream::resolution(Some(3840), Some(1600)), Some("4K"));
    assert_eq!(
        ServerStream::resolution(Some(1920), Some(800)),
        Some("1080p")
    );
    assert_eq!(ServerStream::resolution(Some(720), Some(576)), Some("SD"));
    assert_eq!(ServerStream::resolution(None, None), None);
    assert_eq!(ServerStream::range(Some("HDR10Plus")), Some("HDR10+"));
    assert_eq!(
        (
            ServerStream::range(Some("SDR")),
            ServerStream::range(Some("DOVIInvalid"))
        ),
        (None, None)
    );
}

// ---------------------------------------------------------------- requests

#[test]
fn stopping_a_task_is_a_delete_on_the_running_task() {
    let c = client(MockTransport::new().route("/ScheduledTasks/Running/scan", 204, ""));
    block_on(c.stop_task("scan")).expect("stopped");
    assert_eq!(calls(&c), ["DELETE /ScheduledTasks/Running/scan"]);
}

#[test]
fn restart_and_scan_are_posts() {
    let c = client(MockTransport::new());
    block_on(c.restart_server()).expect("restart");
    block_on(c.scan_libraries()).expect("scan");
    assert_eq!(calls(&c), ["POST /System/Restart", "POST /Library/Refresh"]);
}

#[test]
fn stopping_a_stream_stops_first_then_sends_the_message_without_a_time_limit() {
    let c = client(MockTransport::new());
    block_on(c.stop_playback("s1", "Nachricht", "  Server wird gewartet.  ")).expect("stopped");
    assert_eq!(
        calls(&c),
        [
            "POST /Sessions/s1/Playing/Stop",
            "POST /Sessions/s1/Message"
        ]
    );
    let body: Value = serde_json::from_slice(
        c.transport()
            .last_request()
            .expect("request")
            .body
            .as_deref()
            .expect("body"),
    )
    .expect("json");
    assert_eq!(body["Text"], "Server wird gewartet.");
    assert_eq!(body["Header"], "Nachricht");
    assert!(body.get("TimeoutMs").is_none());
}

#[test]
fn no_text_no_message_and_a_failed_message_keeps_the_stop() {
    let c = client(MockTransport::new());
    block_on(c.stop_playback("s1", "H", " ")).expect("stopped");
    assert_eq!(calls(&c), ["POST /Sessions/s1/Playing/Stop"]);
    let c = client(MockTransport::new().route("/Sessions/s1/Message", 404, ""));
    block_on(c.stop_playback("s1", "H", "Hallo")).expect("the stop went through");
    assert_eq!(calls(&c).len(), 2);
}

#[test]
fn a_failed_stop_sends_no_message() {
    let c = client(MockTransport::new().route("/Sessions/s1/Playing/Stop", 500, ""));
    assert!(matches!(
        block_on(c.stop_playback("s1", "H", "Hallo")),
        Err(ErrorKind::Http { status: 500, .. })
    ));
    assert_eq!(calls(&c).len(), 1);
}

#[test]
fn a_non_administrator_gets_403_on_every_call() {
    let c = client(MockTransport::new().route("/System/Info", 403, "forbidden"));
    assert!(matches!(
        block_on(c.server_system()),
        Err(ErrorKind::Http { status: 403, .. })
    ));
}
