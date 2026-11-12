//! Remote control: message mapping and reconnect rules (RemoteControl.swift, PlayOn.swift).
#![allow(clippy::unwrap_used, clippy::expect_used)]

use swiftly_sync::remote::{KEEP_ALIVE, LinkError, RemoteControl, RemoteLink, RemoteOutput};
use swiftly_sync::{PlayOrder, RemoteCommand, SyncPlayPostDirection};

#[test]
fn playstate_translation() {
    let t = RemoteControl::translate;
    assert_eq!(t("Pause", None), Some(RemoteCommand::Pause));
    assert_eq!(t("Unpause", None), Some(RemoteCommand::Proceed));
    assert_eq!(t("PlayPause", None), Some(RemoteCommand::Toggle));
    assert_eq!(t("Stop", None), Some(RemoteCommand::Stop));
    assert_eq!(
        t("Seek", Some(600_000_000)),
        Some(RemoteCommand::JumpOn(60.0))
    );
    assert_eq!(t("Seek", None), None);
    assert_eq!(t("FastForward", None), Some(RemoteCommand::Forward));
    assert_eq!(t("Rewind", None), Some(RemoteCommand::Back));
    assert_eq!(t("NextTrack", None), Some(RemoteCommand::Next));
    assert_eq!(t("PreviousTrack", None), Some(RemoteCommand::Previous));
    assert_eq!(t("Nope", None), None);
}

#[test]
fn messages_are_mapped() {
    let rc = RemoteControl::new();
    assert_eq!(
        rc.process(r#"{"MessageType":"ForceKeepAlive","Data":60}"#),
        [RemoteOutput::Send(KEEP_ALIVE.into())]
    );
    assert_eq!(
        rc.process(
            r#"{"MessageType":"Playstate","Data":{"Command":"Seek","SeekPositionTicks":300000000}}"#
        ),
        [RemoteOutput::Command(RemoteCommand::JumpOn(30.0))]
    );
    let hint = r#"{"MessageType":"GeneralCommand","Data":{"Name":"DisplayMessage","Arguments":{"Header":"Swiftly-Uebernahme","Text":"Wohnzimmer"}}}"#;
    assert_eq!(
        rc.process(hint),
        [RemoteOutput::Handoff("Wohnzimmer".into())]
    );
    assert!(
        rc.process(&hint.replace("Swiftly-Uebernahme", "Anders"))
            .is_empty()
    );
    assert!(rc.process(&hint.replace("Wohnzimmer", "")).is_empty());
    let out = rc
        .process(r#"{"MessageType":"SyncPlayGroupUpdate","Data":{"Type":"GroupLeft","Data":"g"}}"#);
    assert_eq!(out, [RemoteOutput::SyncPlay(SyncPlayPostDirection::Leave)]);
    assert!(matches!(
        rc.process(r#"{"MessageType":"SyncPlayCommand","Data":{}}"#)[0],
        RemoteOutput::Unreadable(_)
    ));
    for junk in [
        "",
        "nope",
        "[]",
        r#"{"MessageType":5}"#,
        r#"{"MessageType":"Playstate"}"#,
        r#"{"MessageType":"Playstate","Data":{"Command":3}}"#,
    ] {
        assert!(rc.process(junk).is_empty(), "{junk}");
    }
}

#[test]
fn play_order() {
    let text = r#"{"MessageType":"Play","Data":{"ItemIds":["a","","b"],"StartIndex":1,"StartPositionTicks":1200000000,"PlayCommand":"PlayNow","MediaSourceId":"ms","AudioStreamIndex":2,"SubtitleStreamIndex":-1}}"#;
    let o = PlayOrder::read(text).unwrap();
    assert_eq!(o.item_ids, ["a", "b"]);
    assert_eq!(
        (o.item_id(), o.start, o.audio_index, o.subtitle_index),
        (Some("b"), 120.0, Some(2), Some(-1))
    );
    assert_eq!(o.media_source_id.as_deref(), Some("ms"));
    assert!(PlayOrder::read(&text.replace("PlayNow", "PlayNext")).is_none());
    assert!(PlayOrder::read(&text.replace("\"StartIndex\":1", "\"StartIndex\":9")).is_none());
    assert!(PlayOrder::read(r#"{"MessageType":"Play","Data":{"ItemIds":[]}}"#).is_none());
    let minimal = PlayOrder::read(
        r#"{"MessageType":"Play","Data":{"ItemIds":["x"],"StartPositionTicks":-5}}"#,
    )
    .unwrap();
    assert_eq!((minimal.start, minimal.start_index), (0.0, 0));
    assert!(
        PlayOrder::read(r#"{"MessageType":"Play","Data":{"ItemIds":["x"],"StartIndex":-1}}"#)
            .is_none()
    );
}

#[test]
fn socket_url_and_backoff() {
    assert_eq!(
        RemoteControl::socket_url("https://tv.example.de/", "tok en", "dev-1").unwrap(),
        "wss://tv.example.de/socket?ApiKey=tok%20en&deviceId=dev-1"
    );
    assert!(
        RemoteControl::socket_url("http://192.168.1.2:8096", "t", "d")
            .unwrap()
            .starts_with("ws://192.168.1.2:8096/socket")
    );
    assert!(RemoteControl::socket_url("ftp://x", "t", "d").is_none());
    let mut rc = RemoteControl::new();
    let waits: Vec<f64> = (0..7).map(|_| rc.next_reconnect_wait()).collect();
    assert_eq!(waits, [2.0, 4.0, 8.0, 16.0, 30.0, 30.0, 30.0]);
    rc.on_received();
    assert_eq!(
        rc.next_reconnect_wait(),
        2.0,
        "the count starts again after a message"
    );
}

#[test]
fn syncplay_learns_of_drop_and_return() {
    let mut rc = RemoteControl::new();
    assert_eq!(rc.on_received(), None, "first start: no 'again'");
    assert_eq!(
        rc.on_lost(),
        RemoteOutput::SyncPlay(SyncPlayPostDirection::ConnectionLost)
    );
    assert_eq!(
        rc.on_received(),
        Some(RemoteOutput::SyncPlay(
            SyncPlayPostDirection::ConnectionAgain
        ))
    );
    assert_eq!(rc.on_received(), None);
}

#[test]
fn line_setup_fallback_after_three_blamed_failures() {
    let mut rc = RemoteControl::new();
    assert!(!rc.line_setup_gives_up(500));
    assert!(!rc.line_setup_gives_up(426));
    assert!(!rc.line_setup_gives_up(426));
    assert!(rc.line_setup_gives_up(426));
}

struct Script(
    std::collections::VecDeque<Result<Option<String>, LinkError>>,
    Vec<String>,
);
impl RemoteLink for Script {
    async fn receive(&mut self) -> Result<Option<String>, LinkError> {
        self.0
            .pop_front()
            .unwrap_or(Err(LinkError::Other("end".into())))
    }
    async fn send(&mut self, text: &str) -> Result<(), LinkError> {
        self.1.push(text.into());
        Ok(())
    }
    fn close(&mut self) {}
}

#[test]
fn pump_sends_keepalive_answers_and_ends_with_the_error() {
    let mut link = Script(
        [
            Ok(Some(r#"{"MessageType":"ForceKeepAlive"}"#.into())),
            Ok(Some(
                r#"{"MessageType":"Playstate","Data":{"Command":"Pause"}}"#.into(),
            )),
            Ok(None),
            Err(LinkError::SetupFailed { code: 426 }),
        ]
        .into(),
        vec![],
    );
    let mut rc = RemoteControl::new();
    let mut got = Vec::new();
    let end = futures_executor::block_on(rc.pump(&mut link, |o| got.push(o)));
    assert_eq!(end, LinkError::SetupFailed { code: 426 });
    assert_eq!(got, [RemoteOutput::Command(RemoteCommand::Pause)]);
    assert_eq!(link.1, [KEEP_ALIVE]);
}

#[test]
fn capabilities_use_the_servers_spelling() {
    let b = RemoteControl::capabilities_body();
    let cmds: Vec<&str> = b["SupportedCommands"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    assert!(cmds.contains(&"PlayState") && !cmds.contains(&"Playstate"));
    assert_eq!(cmds.len(), 11);
    assert_eq!(b["SupportsMediaControl"], true);
}
