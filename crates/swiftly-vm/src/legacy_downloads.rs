#![allow(missing_docs)]
//! The pure download calls of the old Android facade (`Kern.downloadQualities`, `downloadSpace`, `downloadGroups`, ...)
//! as the JSON strings the Compose code parses. The list is the persisted `liste.json` array. The calls that need a
//! server (`downloadItem`, `downloadAudioOptions`, `downloadSections`, ...) are not here: the core's `DownloadsVm`
//! and `DownloadHost` own that flow.

use std::collections::HashMap;
use std::sync::{Mutex, PoisonError};

use serde::Serialize;
use serde_json::json;
use swiftly_downloads::rules::{DownloadRules, FootSpace, ProgressEstimator};
use swiftly_downloads::{DownloadGroup, DownloadItem, decode_list, encode_list};
use swiftly_l10n::{Locale, Translator};
use swiftly_net::ErrorKind;
use swiftly_rules::download_quality::DownloadQuality;
use swiftly_rules::download_right::DownloadPermission;

use crate::downloads_vm::{decimal_separator, size_text};
use crate::title_text::TitleText;

fn items(list: &str) -> Vec<DownloadItem> {
    decode_list(list.as_bytes()).unwrap_or_default()
}

fn quality(raw: &str) -> DownloadQuality {
    DownloadQuality::from_raw_value(raw).unwrap_or(DownloadQuality::Original)
}

fn sep(locale: &Locale) -> &'static str {
    decimal_separator(locale.language())
}

fn name_of(q: DownloadQuality, t: &Translator) -> String {
    q.name().map_or_else(|| t.t("Original"), str::to_owned)
}

fn addition_of(q: DownloadQuality, t: &Translator, s: &str) -> String {
    q.addition(s).unwrap_or_else(|| t.t("Direct Play"))
}

/// `Kern.downloadQualities`: `[{"id","zeile","plakette"}]` for the picker; `files` is `[[bytes, runtimeTicks]]`.
pub fn download_qualities(selectable: bool, files: &str, locale: Locale) -> String {
    let pairs: Vec<Vec<i64>> = serde_json::from_str(files).unwrap_or_default();
    let pairs: Vec<(i64, Option<i64>)> = pairs
        .iter()
        .filter(|p| p.len() == 2)
        .map(|p| (p[0], (p[1] > 0).then_some(p[1])))
        .collect();
    let source = DownloadQuality::source_bitrate_of(&pairs);
    let t = Translator::new(locale.clone());
    let s = sep(&locale);
    let rows: Vec<_> = DownloadQuality::offered(selectable, source)
        .into_iter()
        .map(|q| json!({"id": q.raw_value(), "zeile": format!("{} · {}", name_of(q, &t), addition_of(q, &t, s)), "plakette": badge_of(q, &t, s)}))
        .collect();
    serde_json::Value::Array(rows).to_string()
}

fn badge_of(q: DownloadQuality, t: &Translator, s: &str) -> String {
    if q == DownloadQuality::Original {
        t.t("Direct Play · Originalqualität")
    } else {
        format!("{} · {}", name_of(q, t), addition_of(q, t, s))
    }
}

pub fn download_estimated(q: &str, bytes: i64, ticks: i64) -> i64 {
    quality(q).estimated_bytes(bytes, (ticks > 0).then_some(ticks))
}

pub fn download_badge(q: &str, locale: Locale) -> String {
    let t = Translator::new(locale.clone());
    badge_of(quality(q), &t, sep(&locale))
}

pub fn download_quality_name(q: &str, locale: Locale) -> String {
    let q = quality(q);
    if q == DownloadQuality::Original {
        return String::new();
    }
    name_of(q, &Translator::new(locale))
}

pub fn download_in_quality(list: &str, q: &str) -> String {
    let q = quality(q);
    let out: Vec<DownloadItem> = items(list).iter().map(|i| i.in_quality(q)).collect();
    String::from_utf8(encode_list(&out).unwrap_or_default()).unwrap_or_else(|_| "[]".into())
}

pub fn download_shared(list: &str, locale: Locale) -> String {
    let levels: Vec<DownloadQuality> = items(list)
        .iter()
        .map(|i| i.quality.unwrap_or(DownloadQuality::Original))
        .collect();
    DownloadQuality::common(&levels)
        .map_or_else(String::new, |q| name_of(q, &Translator::new(locale)))
}

pub fn download_next(list: &str, wlan: bool, only_over_wlan: bool) -> String {
    DownloadRules::next_one(&items(list), wlan, only_over_wlan)
        .map(|i| i.id.clone())
        .unwrap_or_default()
}

pub fn download_may_load(wlan: bool, only_over_wlan: bool) -> bool {
    DownloadRules::may_load(wlan, only_over_wlan)
}

pub fn download_error_text(status: i64, locale: Locale) -> String {
    swiftly_l10n::error_text::readable_error(
        &Translator::new(locale),
        &ErrorKind::Http {
            status: u16::try_from(status).unwrap_or(0),
            body: None,
        },
    )
}

pub fn download_space(bytes: i64, free: i64, list: &str) -> String {
    let p = DownloadRules::slot(bytes, free, &items(list));
    json!({
        "reicht": p.suffices,
        "freiDanach": p.free_after,
        "entbehrlich": p.dispensable.iter().map(|i| i.id.clone()).collect::<Vec<_>>(),
        "entbehrlichBytes": p.dispensable_bytes,
        "reichtNachAufraeumen": p.suffices_to_clean_up(),
    })
    .to_string()
}

pub fn download_groups(list: &str) -> String {
    let rows: Vec<_> = DownloadRules::grouped(&items(list))
        .iter()
        .map(|g| match g {
            DownloadGroup::Single(p) => json!({"id": g.id(), "titel": g.title(), "bytes": g.bytes(), "folgen": [p.id]}),
            DownloadGroup::Series { id, episodes, .. } => {
                json!({"id": g.id(), "titel": g.title(), "bytes": g.bytes(), "serienId": id, "folgen": episodes.iter().map(|e| e.id.clone()).collect::<Vec<_>>()})
            }
        })
        .collect();
    serde_json::Value::Array(rows).to_string()
}

pub fn download_size(bytes: i64, locale: Locale) -> String {
    size_text(bytes, sep(&locale))
}

pub fn download_footer_space(bytes: i64, free: i64) -> String {
    match DownloadRules::foot_space(bytes, free) {
        FootSpace::Free(rest) => json!({"reicht": true, "bytes": rest}),
        FootSpace::Few(missing) => json!({"reicht": false, "bytes": missing}),
    }
    .to_string()
}

pub fn download_progress(loaded: i64, total: i64, locale: Locale) -> String {
    let (a, b) = DownloadRules::progress(loaded, total, sep(&locale));
    json!([a, b]).to_string()
}

pub fn download_progress_show(loaded: i64, total: i64, before: i64, elapsed: f64) -> bool {
    DownloadRules::progress_show(
        loaded,
        total,
        (before >= 0).then_some(before),
        (elapsed >= 0.0).then_some(elapsed),
    )
}

pub fn download_resume_from(entry: &str) -> f64 {
    serde_json::from_str::<DownloadItem>(entry)
        .map(|i| i.resume_from())
        .unwrap_or(0.0)
}

pub fn download_next_episode(list: &str, locale: Locale) -> String {
    let all = items(list);
    let Some(p) = DownloadRules::next_episode(&all) else {
        return "{}".into();
    };
    json!({"id": p.id, "knopftext": TitleText::new(locale).series_button(Some(&p.as_item()), false)}).to_string()
}

pub fn download_button_show(rights: &str, function_on: bool) -> bool {
    DownloadPermission::offer(
        DownloadPermission::from_server((!rights.is_empty()).then_some(rights == "1")),
        function_on,
    )
}

// ---- the estimator: one state per running download -----------------------------------------------------------------

static ESTIMATOR: Mutex<Option<HashMap<String, ProgressEstimator>>> = Mutex::new(None);

fn with_estimator<R>(f: impl FnOnce(&mut HashMap<String, ProgressEstimator>) -> R) -> R {
    let mut guard = ESTIMATOR.lock().unwrap_or_else(PoisonError::into_inner);
    f(guard.get_or_insert_with(HashMap::new))
}

fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

pub fn download_estimator_report(id: &str, loaded: i64, total: i64) {
    with_estimator(|m| {
        m.entry(id.to_owned())
            .or_insert_with(ProgressEstimator::new)
            .report(loaded, total, now())
    });
}

pub fn download_estimator_halt(id: &str) {
    with_estimator(|m| {
        if let Some(e) = m.get_mut(id) {
            e.halt();
        }
    });
}

pub fn download_estimator_value(id: &str, loaded: i64) -> i64 {
    with_estimator(|m| m.get_mut(id).map_or(loaded, |e| e.value(now())))
}

pub fn download_estimator_forget(id: &str) {
    with_estimator(|m| {
        m.remove(id);
    });
}

#[derive(Serialize)]
struct _Unused;
