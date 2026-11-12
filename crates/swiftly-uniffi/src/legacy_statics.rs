//! The static calls of the old Android facade (`Kern.titleMark*`, `Kern.imageTone*`, `Kern.logAppend/logExcerpt`,
//! `Kern.downloadLanguageName`, `Android/core/.../Core.swift`) from the core, with the same answers.

use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

use swiftly_images::tone;
use swiftly_l10n::Locale;
use swiftly_playback::{av_computation, track_label};
use swiftly_rules::title_marks;
use swiftly_support::log_ring::LogRing;
use swiftly_vm::LabelWords;

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// Crop without the transparent margin of a premultiplied RGBA logo: x, y, width, height, density, luminance; empty
/// if nothing covers.
#[uniffi::export]
pub fn title_mark_measure(rgba: Vec<u8>, width: i64, height: i64) -> Vec<f64> {
    match title_marks::measure(&rgba, width, height) {
        Some(m) => vec![
            m.x as f64,
            m.y as f64,
            m.width as f64,
            m.height as f64,
            m.density,
            m.luminance,
        ],
        None => Vec::new(),
    }
}

/// Width and height of the logo in the units of `row` and `max_width`.
#[uniffi::export]
pub fn title_mark_size(pages_ratio: f64, density: f64, row: f64, max_width: f64) -> Vec<f64> {
    let (w, h) = title_marks::size(pages_ratio, density, row, max_width, None);
    vec![w, h]
}

/// Mostly dark: shown as a white silhouette.
#[uniffi::export]
pub fn title_mark_dark(luminance: f64) -> bool {
    title_marks::is_dark(luminance)
}

/// Up to five tones from RGBA points of an image.
#[uniffi::export]
pub fn image_tones(rgba: Vec<u8>) -> Vec<f64> {
    tone::tones_from_rgba(&rgba)
}

/// The grid of a page as ARGB points, `columns` x `rows`.
#[uniffi::export]
pub fn image_tone_points(
    tones: Vec<f64>,
    columns: i64,
    rows: i64,
    height: f64,
    color_height: f64,
    since: f64,
    run_out: f64,
) -> Vec<i32> {
    if columns < 0 || rows < 0 {
        return Vec::new();
    }
    av_computation::points(
        &tones,
        columns as usize,
        rows as usize,
        height,
        color_height,
        since,
        run_out,
    )
}

/// The color at a point of the surface as ARGB.
#[uniffi::export]
pub fn image_tone_color(tones: Vec<f64>, x: f64, y: f64) -> i32 {
    let c = av_computation::color(&tones, x, y, 1.0);
    let k = |w: f64| -> u32 { (w * 255.0).round().clamp(0.0, 255.0) as u32 };
    (0xFF00_0000u32 | (k(c.r) << 16) | (k(c.g) << 8) | k(c.b)) as i32
}

fn ring() -> &'static LogRing {
    static RING: OnceLock<LogRing> = OnceLock::new();
    RING.get_or_init(LogRing::default)
}

/// One line into the memory the user shares their log from (redacted on entry).
#[uniffi::export]
pub fn log_append(text: String) {
    ring().append(&text, now());
}

/// The lines of the last `seconds`, oldest first, with time, separated by newlines. `utc_offset` is the local time
/// zone in seconds east of UTC.
#[uniffi::export]
pub fn log_excerpt(seconds: f64, utc_offset: i64) -> String {
    ring().excerpt(seconds, now(), utc_offset).join("\n")
}

/// "German" for a language key, for the load sheet's audio row; the key itself if unknown.
#[uniffi::export]
pub fn download_language_name(key: String, locale: String) -> String {
    let words = LabelWords::new(Locale::parse(&locale));
    track_label::language(Some(&key), &words).unwrap_or(key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn title_mark_crop_and_size() {
        let mut px = vec![0u8; 4 * 4 * 4];
        let i = (2 * 4 + 1) * 4;
        px[i..i + 4].copy_from_slice(&[255, 255, 255, 255]);
        let m = title_mark_measure(px, 4, 4);
        assert_eq!(m.len(), 6);
        assert_eq!((m[0], m[1], m[2], m[3]), (1.0, 2.0, 1.0, 1.0));
        assert!(title_mark_measure(vec![0; 64], 4, 4).is_empty());
        assert_eq!(title_mark_size(2.0, 0.5, 20.0, 300.0).len(), 2);
        assert!(!title_mark_dark(0.9) && title_mark_dark(0.0));
    }

    #[test]
    fn tones_points_color() {
        assert_eq!(image_tone_color(vec![], 0.5, 0.5), 0xFF10_1010u32 as i32);
        assert!(image_tone_points(vec![], 1, 3, 10.0, 10.0, 0.0, 0.0).is_empty());
        assert_eq!(
            image_tone_points(vec![], 3, 3, 10.0, 10.0, 20.0, 0.0).len(),
            9
        );
        assert!(image_tones(vec![0; 3]).is_empty());
    }

    #[test]
    fn log_redacts_and_lists() {
        log_append("hello api_key=abcdef12345".into());
        let text = log_excerpt(60.0, 0);
        assert!(text.contains("hello"));
    }

    #[test]
    fn language_names() {
        assert_eq!(download_language_name("ger".into(), "en".into()), "German");
        assert_eq!(download_language_name("de".into(), "de".into()), "Deutsch");
    }
}
