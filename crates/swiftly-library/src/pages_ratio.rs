//! `PagesRatio` (Swift `PagesRatio.swift`): whether libVLC flipped an anamorphic picture and
//! what display ratio applies instead.

/// "16:9", "2.35:1" to width divided by height (:17-21). Empty parts are omitted like
/// `split(separator:)`.
fn value(text: Option<&str>) -> Option<f64> {
    let parts: Vec<&str> = text?.split(':').filter(|p| !p.is_empty()).collect();
    if parts.len() != 2 {
        return None;
    }
    let a: f64 = parts[0].parse().ok()?;
    let b: f64 = parts[1].parse().ok()?;
    (a > 0.0 && b > 0.0).then(|| a / b)
}

/// The display ratio VLC must be forced to, or `None` if nothing needs to be done (:30-39).
/// `sar` is the pixel ratio as VLC reports it; `width`/`height` the image size from the server;
/// `display` Jellyfin's `AspectRatio`.
pub fn correction(
    sar: (u32, u32),
    width: i64,
    height: i64,
    display: Option<&str>,
) -> Option<String> {
    if sar.0 == 0 || sar.1 == 0 || width <= 0 || height <= 0 {
        return None;
    }
    let dar = value(display)?;
    let expects = dar * height as f64 / width as f64;
    let vlc = f64::from(sar.0) / f64::from(sar.1);
    let near = |a: f64, b: f64| (a - b).abs() / b < 0.02;
    if near(expects, 1.0) || near(vlc, expects) || !near(vlc * expects, 1.0) {
        return None;
    }
    display.map(String::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn twisted_is_detected() {
        assert_eq!(
            correction((45, 64), 720, 576, Some("16:9")).as_deref(),
            Some("16:9")
        );
    }
    #[test]
    fn correct_picture_is_untouched() {
        assert_eq!(correction((64, 45), 720, 576, Some("16:9")), None);
        assert_eq!(correction((9216, 6480), 720, 576, Some("16:9")), None);
    }
    #[test]
    fn square_pixels_and_missing_values_do_nothing() {
        assert_eq!(correction((1, 1), 1920, 1080, Some("16:9")), None);
        assert_eq!(correction((45, 64), 720, 576, None), None);
        assert_eq!(correction((45, 64), 720, 576, Some("kaputt")), None);
        assert_eq!(correction((0, 64), 720, 576, Some("16:9")), None);
        assert_eq!(correction((45, 64), 0, 576, Some("16:9")), None);
    }
}
