//! The subtitle provider calls: exact addresses and what is read from the answers.
#![allow(clippy::expect_used)]

use futures_executor::block_on;
use swiftly_jellyfin::{ClientConfig, JellyfinClient, ServerKind, Session};
use swiftly_net::{Method, MockTransport};

const BASE: &str = "https://tv.example.de";

fn client(mock: MockTransport, kind: ServerKind) -> JellyfinClient<MockTransport> {
    let c = JellyfinClient::new(
        mock,
        BASE,
        ClientConfig::new("dev", "Test", "1.0").kind(kind),
    )
    .expect("client");
    c.set_session(Some(Session {
        access_token: "TOKEN".into(),
        user_id: "u1".into(),
        user_name: "tester".into(),
        server_url: BASE.into(),
        kind,
    }));
    c
}

#[test]
fn search_asks_the_item_in_a_language_and_reads_every_field() {
    let body = r#"[{"Id":"abc_1","Name":"A.srt","ProviderName":"Open Subtitles","Format":"srt",
        "ThreeLetterISOLanguageName":"ger","CommunityRating":8.5,"DownloadCount":12,"IsHashMatch":true,
        "HearingImpaired":true,"Forced":false,"AiTranslated":false,"MachineTranslated":true,"Author":"x"},
        {"Id":42}, {"Id":"b_2"}]"#;
    let c = client(
        MockTransport::new().route("/RemoteSearch/Subtitles/deu", 200, body),
        ServerKind::Jellyfin,
    );
    let hits = block_on(c.subtitle_search("m1", "deu")).expect("hits");
    let r = c.transport().last_request().expect("request");
    assert_eq!(r.method, Method::Get);
    assert_eq!(
        r.url.as_str(),
        "https://tv.example.de/Items/m1/RemoteSearch/Subtitles/deu?isPerfectMatch=false"
    );
    // The entry with a wrong type is dropped, the others come through.
    assert_eq!(hits.len(), 2);
    assert_eq!(hits[0].id, "abc_1");
    assert_eq!(hits[0].provider_name, "Open Subtitles");
    assert_eq!(hits[0].language, "ger");
    assert_eq!(hits[0].community_rating, Some(8.5));
    assert_eq!(hits[0].download_count, Some(12));
    assert!(hits[0].is_hash_match && hits[0].hearing_impaired && hits[0].machine_translated);
    assert_eq!(hits[1].id, "b_2");
    assert_eq!(hits[1].name, "");
    assert!(!hits[1].hearing_impaired);
}

#[test]
fn download_posts_the_hit_id_without_a_body() {
    let c = client(
        MockTransport::new().route("/RemoteSearch/Subtitles/abc_1", 204, ""),
        ServerKind::Jellyfin,
    );
    block_on(c.subtitle_download("m1", "abc_1")).expect("done");
    let r = c.transport().last_request().expect("request");
    assert_eq!(r.method, Method::Post);
    assert_eq!(
        r.url.as_str(),
        "https://tv.example.de/Items/m1/RemoteSearch/Subtitles/abc_1"
    );
    assert_eq!(r.body, None);
    let refused = client(
        MockTransport::new().route("/RemoteSearch/Subtitles/abc_1", 500, "no"),
        ServerKind::Jellyfin,
    );
    assert!(block_on(refused.subtitle_download("m1", "abc_1")).is_err());
}

#[test]
fn a_provider_plugin_is_recognised_by_name_and_status() {
    let some = client(
        MockTransport::new().route(
            "/Plugins",
            200,
            r#"[{"Name":"Open Subtitles","Status":"Active"}]"#,
        ),
        ServerKind::Jellyfin,
    );
    assert_eq!(block_on(some.subtitle_provider_known()), Some(true));
    let off = client(
        MockTransport::new().route(
            "/Plugins",
            200,
            r#"[{"Name":"Open Subtitles","Status":"Disabled"}]"#,
        ),
        ServerKind::Jellyfin,
    );
    assert_eq!(block_on(off.subtitle_provider_known()), Some(false));
    let refused = client(
        MockTransport::new().route("/Plugins", 403, "{}"),
        ServerKind::Jellyfin,
    );
    assert_eq!(block_on(refused.subtitle_provider_known()), None);
    let emby = client(
        MockTransport::new().route("/Plugins", 200, "[]"),
        ServerKind::Emby,
    );
    assert_eq!(block_on(emby.subtitle_provider_known()), None);
}

#[test]
fn search_reads_the_body_jellyfin_writes_and_refuses_a_list_answer_that_is_an_object() {
    // As Jellyfin 10.10 serialises `RemoteSubtitleInfo`: every field present, nulls, an integer rating, a date.
    let real = r#"[{"ThreeLetterISOLanguageName":"deu","Id":"b3BlbnN1Yg==","ProviderName":"Open Subtitles","Name":"Movie.2024.WEB.German.srt",
        "Format":"srt","Author":null,"Comment":null,"DateCreated":"2024-05-01T10:00:00.0000000Z","CommunityRating":8,"RatingCount":null,
        "DownloadCount":1204,"IsHashMatch":false,"AiTranslated":false,"MachineTranslated":false,"Forced":false,"HearingImpaired":false}]"#;
    let c = client(
        MockTransport::new().route("/RemoteSearch/Subtitles/deu", 200, real),
        ServerKind::Jellyfin,
    );
    let hits = block_on(c.subtitle_search("m1", "deu")).expect("hits");
    assert_eq!(hits.len(), 1);
    assert_eq!(
        (hits[0].id.as_str(), hits[0].language.as_str()),
        ("b3BlbnN1Yg==", "deu")
    );
    assert_eq!(
        (
            hits[0].community_rating,
            hits[0].download_count,
            hits[0].author.clone()
        ),
        (Some(8.0), Some(1204), None)
    );
    // A server that does not know the route and answers its item list instead (an old fixture server did) is a decode error,
    // never an empty "no provider" answer.
    let object = client(
        MockTransport::new().route(
            "/RemoteSearch/Subtitles/deu",
            200,
            r#"{"Items":[],"TotalRecordCount":0,"StartIndex":0}"#,
        ),
        ServerKind::Jellyfin,
    );
    assert!(matches!(
        block_on(object.subtitle_search("m1", "deu")),
        Err(swiftly_net::ErrorKind::Decoding(_))
    ));
}
