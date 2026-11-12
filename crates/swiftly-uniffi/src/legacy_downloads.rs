//! The pure download rules of the old Android facade (`Kern.download*`), answered with the same JSON. The list
//! arguments are the persisted `liste.json` array. Texts follow `locale`.

use swiftly_l10n::Locale;

fn loc(locale: &str) -> Locale {
    Locale::parse(locale)
}

/// `Kern.downloadQualities`: the picker rows `[{"id","zeile","plakette"}]`; `files` is `[[bytes, runtimeTicks]]`.
#[uniffi::export]
pub fn legacy_download_qualities(selectable: bool, files: String, locale: String) -> String {
    swiftly_vm::download_qualities(selectable, &files, loc(&locale))
}
/// `Kern.downloadEstimated`.
#[uniffi::export]
pub fn legacy_download_estimated(quality: String, bytes: i64, ticks: i64) -> i64 {
    swiftly_vm::download_estimated(&quality, bytes, ticks)
}
/// `Kern.downloadBadge`.
#[uniffi::export]
pub fn legacy_download_badge(quality: String, locale: String) -> String {
    swiftly_vm::download_badge(&quality, loc(&locale))
}
/// `Kern.downloadQualityName`.
#[uniffi::export]
pub fn legacy_download_quality_name(quality: String, locale: String) -> String {
    swiftly_vm::download_quality_name(&quality, loc(&locale))
}
/// `Kern.downloadInQuality`.
#[uniffi::export]
pub fn legacy_download_in_quality(list: String, quality: String) -> String {
    swiftly_vm::download_in_quality(&list, &quality)
}
/// `Kern.downloadShared`.
#[uniffi::export]
pub fn legacy_download_shared(list: String, locale: String) -> String {
    swiftly_vm::download_shared(&list, loc(&locale))
}
/// `Kern.downloadNext`.
#[uniffi::export]
pub fn legacy_download_next(list: String, wlan: bool, only_over_wlan: bool) -> String {
    swiftly_vm::download_next(&list, wlan, only_over_wlan)
}
/// `Kern.downloadMayLoad`.
#[uniffi::export]
pub fn legacy_download_may_load(wlan: bool, only_over_wlan: bool) -> bool {
    swiftly_vm::download_may_load(wlan, only_over_wlan)
}
/// `Kern.downloadErrorText`.
#[uniffi::export]
pub fn legacy_download_error_text(status: i64, locale: String) -> String {
    swiftly_vm::download_error_text(status, loc(&locale))
}
/// `Kern.downloadSpace`.
#[uniffi::export]
pub fn legacy_download_space(bytes: i64, free: i64, list: String) -> String {
    swiftly_vm::download_space(bytes, free, &list)
}
/// `Kern.downloadGroups`.
#[uniffi::export]
pub fn legacy_download_groups(list: String) -> String {
    swiftly_vm::download_groups(&list)
}
/// `Kern.downloadSize`.
#[uniffi::export]
pub fn legacy_download_size(bytes: i64, locale: String) -> String {
    swiftly_vm::download_size(bytes, loc(&locale))
}
/// `Kern.downloadFooterSpace`.
#[uniffi::export]
pub fn legacy_download_footer_space(bytes: i64, free: i64) -> String {
    swiftly_vm::download_footer_space(bytes, free)
}
/// `Kern.downloadProgress`.
#[uniffi::export]
pub fn legacy_download_progress(loaded: i64, total: i64, locale: String) -> String {
    swiftly_vm::download_progress(loaded, total, loc(&locale))
}
/// `Kern.downloadProgressShow`.
#[uniffi::export]
pub fn legacy_download_progress_show(loaded: i64, total: i64, before: i64, elapsed: f64) -> bool {
    swiftly_vm::download_progress_show(loaded, total, before, elapsed)
}
/// `Kern.downloadResumeFrom`.
#[uniffi::export]
pub fn legacy_download_resume_from(entry: String) -> f64 {
    swiftly_vm::download_resume_from(&entry)
}
/// `Kern.downloadNextEpisode`.
#[uniffi::export]
pub fn legacy_download_next_episode(list: String, locale: String) -> String {
    swiftly_vm::download_next_episode(&list, loc(&locale))
}
/// `Kern.downloadButtonShow`.
#[uniffi::export]
pub fn legacy_download_button_show(rights: String, function_on: bool) -> bool {
    swiftly_vm::download_button_show(&rights, function_on)
}
/// `Kern.downloadEstimatorReport`.
#[uniffi::export]
pub fn legacy_download_estimator_report(id: String, loaded: i64, total: i64) {
    swiftly_vm::download_estimator_report(&id, loaded, total);
}
/// `Kern.downloadEstimatorHalt`.
#[uniffi::export]
pub fn legacy_download_estimator_halt(id: String) {
    swiftly_vm::download_estimator_halt(&id);
}
/// `Kern.downloadEstimatorValue`.
#[uniffi::export]
pub fn legacy_download_estimator_value(id: String, loaded: i64) -> i64 {
    swiftly_vm::download_estimator_value(&id, loaded)
}
/// `Kern.downloadEstimatorForget`.
#[uniffi::export]
pub fn legacy_download_estimator_forget(id: String) {
    swiftly_vm::download_estimator_forget(&id);
}

// ---- the settings lists ----------------------------------------------------------------------------------------------

/// `Kern.bitrateLevels`.
#[uniffi::export]
pub fn legacy_bitrate_levels(locale: String) -> String {
    swiftly_vm::bitrate_levels(loc(&locale))
}
/// `Kern.span`.
#[uniffi::export]
pub fn legacy_span() -> String {
    swiftly_vm::span()
}
/// `Kern.languages`.
#[uniffi::export]
pub fn legacy_languages(from: String, locale: String) -> String {
    swiftly_vm::languages(&from, loc(&locale))
}
/// `Kern.bufferLevels`.
#[uniffi::export]
pub fn legacy_buffer_levels(locale: String) -> String {
    swiftly_vm::buffer_levels(loc(&locale))
}
