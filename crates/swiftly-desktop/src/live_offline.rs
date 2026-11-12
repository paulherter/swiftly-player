//! Offline playback: a downloaded file goes through the same player screen as a streamed title, with `downloaded: true`,
//! a file URL as the address and no plan from the server (reports that cannot be sent wait in `pending.reports`).

use crate::live::Core;
use crate::live_downloads::{downloads_dir, finished};
use crate::live_play::Prepared;
use crate::login_screen::Pending;
use std::path::Path;
use swiftly_downloads::DownloadItem;
use swiftly_jellyfin::{PlayMethod, ReportPlan};
use swiftly_playback::player_state::EngineRequest;
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_vm::{AccountRef, PlayerSpec};

/// The subtitle files that were downloaded with the title (`<file>.untertitel/<index>.<ext>`), as the external tracks of
/// the engine request: the stream entries the track list is built from and the files themselves (local paths).
fn downloaded_subtitles(
    item: &DownloadItem,
    file: &Path,
) -> (
    Vec<swiftly_model::MediaStream>,
    Vec<swiftly_playback::track_mapping::SubtitleFile>,
) {
    let folder = file.with_file_name(item.subtitle_folder_name());
    let mut found: Vec<(i64, String, std::path::PathBuf)> = std::fs::read_dir(&folder)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            let (index, ext) = name.split_once('.')?;
            Some((
                index.parse::<i64>().ok()?,
                ext.to_ascii_lowercase(),
                e.path(),
            ))
        })
        .collect();
    found.sort_by_key(|f| f.0);
    let streams = swiftly_vm::subtitle_sidecar::streams(&folder);
    let files = found
        .into_iter()
        .map(
            |(index, ext, path)| swiftly_playback::track_mapping::SubtitleFile {
                index,
                address: path.to_string_lossy().into_owned(),
                attribute: Some(ext),
            },
        )
        .collect();
    (streams, files)
}

/// The spec for a downloaded file; pure, so it can be tested without a server.
pub fn offline_spec(item: &DownloadItem, file: &Path, since: f64) -> Result<PlayerSpec, String> {
    let url = swiftly_images::Url::from_file_path(file)
        .map_err(|()| "Der Pfad der Datei ist nicht gültig.".to_owned())?;
    let runtime = item.runtime_ticks.map_or(0.0, |t| t as f64 / 1e7);
    let (streams, subtitle_files) = downloaded_subtitles(item, file);
    Ok(PlayerSpec {
        item_id: item.id.clone(),
        title: item.title.clone(),
        plan: ReportPlan {
            play_session_id: None,
            media_source_id: item.source.clone(),
            method: PlayMethod::DirectPlay,
        },
        request: EngineRequest {
            item_id: item.id.clone(),
            streams,
            runtime,
            subtitle_files,
            url: url.to_string(),
            headers: Vec::new(),
            software_decode: false,
            buffer_level: BufferLevel::Normal,
            frame_rate_match: false,
            external_track_id_base: 1000,
        },
        start_at: since,
        audio_index: None,
        subtitle_index: -1,
        next: None,
        series_id: item.series_identifier.clone(),
        track_title: None,
        downloaded: true,
    })
}

/// Everything the player needs for the finished download `id`, from `liste.json` and the file; no network.
///
/// # Errors
/// Text when the title is not (or no longer) on the device.
pub fn prepare_offline(core: &Core, account: &AccountRef, id: &str) -> Result<Prepared, String> {
    let (item, file) = finished(&downloads_dir(), &account.key(), id)
        .ok_or("Dieser Titel liegt nicht mehr auf dem Gerät.")?;
    let spec = offline_spec(&item, &file, item.resume_from())?;
    let second = match (item.season, item.episode) {
        (Some(s), Some(e)) => format!("S{s} · F{e}"),
        _ => String::new(),
    };
    // Whatever the account's kind: the reports of the stop go to that server (Jellyfin `ClientReporter`, Plex timeline).
    let server = core.server_for(account).map_err(|e| format!("{e:?}"))?;
    Ok(Prepared::offline(
        core,
        spec,
        (item.title.clone(), second),
        server,
        account.key(),
    ))
}

/// The same as [`prepare_offline`], as the pending value the suite polls.
pub fn pending_offline(
    core: &Core,
    account: &AccountRef,
    id: &str,
) -> Pending<Result<Prepared, String>> {
    let (tx, rx) = Pending::channel();
    let _ = tx.send(prepare_offline(core, account, id));
    rx
}

#[cfg(test)]
mod tests {
    use super::*;
    use swiftly_downloads::Art;

    #[test]
    fn spec_points_at_the_file_without_a_plan() {
        let mut item = DownloadItem::new("e1", "acc", Art::Film, "Der lange Weg", 10, 1.0);
        item.runtime_ticks = Some(36_000_000_000);
        let dir = std::env::temp_dir();
        let spec = offline_spec(&item, &dir.join("acc-e1.mkv"), 12.5).unwrap();
        assert!(spec.downloaded);
        assert!(
            spec.request.url.starts_with("file://") && spec.request.url.ends_with("acc-e1.mkv")
        );
        assert_eq!(spec.plan.play_session_id, None);
        assert_eq!(spec.request.runtime, 3600.0);
        assert_eq!(spec.start_at, 12.5);
    }
}

#[cfg(test)]
mod subtitle_tests {
    use super::*;
    use swiftly_downloads::Art;

    #[test]
    fn subtitles_downloaded_with_the_title_are_in_the_offline_spec() {
        let dir = std::env::temp_dir().join(format!("swiftly-offline-subs-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut item = DownloadItem::new("m1", "acc", Art::Film, "Film", 10, 1.0);
        item.container = Some("mkv".into());
        let file = dir.join(item.file_name());
        let folder = dir.join(item.subtitle_folder_name());
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(&file, b"x").unwrap();
        std::fs::write(
            folder.join("3.srt"),
            b"1\n00:00:01,000 --> 00:00:02,000\nHi\n",
        )
        .unwrap();
        std::fs::write(folder.join("5.ass"), b"[Script Info]\n").unwrap();
        std::fs::write(folder.join("info.json"), r#"[{"index":3,"language":"eng","codec":"subrip"},{"index":5,"language":"ger","title":"Signs","codec":"ass","forced":true}]"#).unwrap();
        let spec = offline_spec(&item, &file, 0.0).unwrap();
        let files: Vec<_> = spec
            .request
            .subtitle_files
            .iter()
            .map(|f| {
                (
                    f.index,
                    f.address.rsplit('/').next().unwrap_or_default().to_owned(),
                )
            })
            .collect();
        assert_eq!(
            files,
            vec![(3, "3.srt".to_owned()), (5, "5.ass".to_owned())]
        );
        let tracks: Vec<_> = spec
            .request
            .streams
            .iter()
            .map(|s| (s.index, s.codec.clone().unwrap_or_default(), s.is_external))
            .collect();
        assert_eq!(
            tracks,
            vec![
                (Some(3), "subrip".to_owned(), Some(true)),
                (Some(5), "ass".to_owned(), Some(true))
            ]
        );
        let named: Vec<_> = spec
            .request
            .streams
            .iter()
            .map(|s| {
                (
                    s.language.clone().unwrap_or_default(),
                    s.title.clone(),
                    s.is_forced,
                )
            })
            .collect();
        assert_eq!(
            named,
            vec![
                ("eng".to_owned(), None, Some(false)),
                ("ger".to_owned(), Some("Signs".to_owned()), Some(true))
            ]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
