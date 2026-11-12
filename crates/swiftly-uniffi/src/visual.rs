//! Pure helpers for pictures and pages the host draws itself: the hues of a decoded picture,
//! the 5 x 5 tone grid and the fading mesh of the detail pages (`ImageTone`, `MoodReason`), and
//! the open-source licence list. The host hands over ready pixels (RGBA, at most 48 pixels on
//! a side) and gets plain numbers back.

use swiftly_images::{mood, tone};
use swiftly_support::licenses::LicenseData;

/// One control point of the tone grid; the colour is `None` without hues (use the app's
/// `reason` colour).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ToneGridPoint {
    /// 0...1 from the left.
    pub x: f32,
    /// 0...1 from the top.
    pub y: f32,
    /// Hue in degrees.
    pub hue: Option<f64>,
    /// Saturation 0...1.
    pub saturation: Option<f64>,
    /// Brightness 0...1.
    pub brightness: Option<f64>,
}

/// A control point of the fading mesh, colours as sRGB 0...1.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct MoodPoint {
    /// 0...1 across.
    pub x: f32,
    /// Down, as a fraction of the mesh height.
    pub y: f32,
    /// Red.
    pub red: f64,
    /// Green.
    pub green: f64,
    /// Blue.
    pub blue: f64,
}

/// The fading mesh, row by row.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct MoodMesh {
    /// Points per row.
    pub columns: u32,
    /// Rows.
    pub rows: u32,
    /// The points.
    pub points: Vec<MoodPoint>,
}

fn mesh_of(m: mood::Mesh) -> MoodMesh {
    MoodMesh {
        columns: u32::try_from(m.columns).unwrap_or(0),
        rows: u32::try_from(m.rows).unwrap_or(0),
        points: m
            .points
            .into_iter()
            .map(|p| MoodPoint {
                x: p.x,
                y: p.y,
                red: p.color.r,
                green: p.color.g,
                blue: p.color.b,
            })
            .collect(),
    }
}

/// Up to five hues in degrees from RGBA pixels; empty if none can be derived.
#[uniffi::export]
pub fn picture_tones(rgba: Vec<u8>) -> Vec<f64> {
    tone::tones_from_rgba(&rgba)
}

/// The 5 x 5 grid of control points for these hues.
#[uniffi::export]
pub fn tone_grid(tones: Vec<f64>) -> Vec<ToneGridPoint> {
    tone::grid(&tones)
        .into_iter()
        .map(|p| ToneGridPoint {
            x: p.x,
            y: p.y,
            hue: p.color.map(|c| c.audio),
            saturation: p.color.map(|c| c.saturation),
            brightness: p.color.map(|c| c.brightness),
        })
        .collect()
}

/// The colour at any point of the tone field (`ImageTone.color(_:at:)`): hue, saturation and
/// brightness at `x`, `y` (both 0...1); no colour without hues (use the app's `reason` colour).
#[uniffi::export]
pub fn tone_at(tones: Vec<f64>, x: f64, y: f64) -> ToneGridPoint {
    let color = (!tones.is_empty()).then(|| tone::av::hsb(&tones, x, y));
    ToneGridPoint {
        x: x as f32,
        y: y as f32,
        hue: color.map(|c| c.audio),
        saturation: color.map(|c| c.saturation),
        brightness: color.map(|c| c.brightness),
    }
}

/// How much of the page colour is left at `y` points down (1 ... 0): full down to `since`, then
/// along a smootherstep curve to nothing over `run_out` (`AvComputation.decay`).
#[uniffi::export]
pub fn mood_decay(y: f64, since: f64, run_out: f64) -> f64 {
    tone::av::decay(y, since, run_out)
}

/// One sample of the fading mesh (`ImageTone.color(_:x:y:decay:)`): the colour at `x`, `y` led
/// back to the page colour by `decay` (1 ... 0) in OKLab, sRGB 0...1. Without hues the page colour.
#[uniffi::export]
pub fn mood_color(tones: Vec<f64>, x: f64, y: f64, decay: f64) -> MoodPoint {
    let c = if tones.is_empty() {
        mood::REASON
    } else {
        tone::av::color(&tones, x, y, decay)
    };
    MoodPoint {
        x: x as f32,
        y: y as f32,
        red: c.r,
        green: c.g,
        blue: c.b,
    }
}

/// The mesh of a detail page (iPhone): the colour fades out into the page colour from `since`.
#[uniffi::export]
pub fn detail_mood_mesh(tones: Vec<f64>, since: f64) -> MoodMesh {
    mesh_of(mood::detail_mesh(&tones, since))
}

/// The fading mesh with every measure given (TV and Mac pages).
#[uniffi::export]
pub fn mood_mesh(
    tones: Vec<f64>,
    height: f64,
    color_height: f64,
    since: f64,
    run_out: f64,
) -> MoodMesh {
    mesh_of(mood::mesh(&tones, height, color_height, since, run_out))
}

/// The noise tile laid over the mesh (96 x 96 pixels, RGBA).
#[uniffi::export]
pub fn mood_noise_tile() -> Vec<u8> {
    mood::noise_tile()
}

/// One component of the licence list.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LicenseEntry {
    /// Stable id.
    pub id: String,
    /// Name.
    pub name: String,
    /// Version.
    pub version: String,
    /// SPDX expression.
    pub spdx: String,
    /// Author.
    pub author: String,
    /// Where it comes from.
    pub source: String,
    /// Group heading.
    pub group: String,
    /// Names of the licence texts.
    pub texts: Vec<String>,
}

/// The components that ship on `platform` (`ios`, `ipados`, `macos`, `tvos`, `android`,
/// `linux`, `windows`), from the bytes of `LICENSES/components.json`; empty if unreadable.
#[uniffi::export]
pub fn licenses_for_platform(json: Vec<u8>, platform: String) -> Vec<LicenseEntry> {
    let Some(data) = LicenseData::parse(&json) else {
        return Vec::new();
    };
    data.for_platform(&platform)
        .map(|c| LicenseEntry {
            id: c.id.clone(),
            name: c.name.clone(),
            version: c.version.clone(),
            spdx: c.spdx.clone(),
            author: c.author.clone(),
            source: c.source.clone(),
            group: c.group.clone(),
            texts: c.texts.clone(),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_red_picture_has_a_red_hue_and_the_grid_and_mesh_are_filled() {
        let rgba: Vec<u8> = (0..16 * 16).flat_map(|_| [200u8, 20, 20, 255]).collect();
        let tones = picture_tones(rgba);
        assert!(!tones.is_empty());
        assert!(tones[0] < 20.0 || tones[0] > 340.0, "{tones:?}");
        let grid = tone_grid(tones.clone());
        assert_eq!(grid.len(), 25);
        assert!(grid.iter().all(|p| p.hue.is_some()));
        assert_eq!(
            tone_grid(Vec::new())
                .iter()
                .filter(|p| p.hue.is_some())
                .count(),
            0
        );
        let m = detail_mood_mesh(tones, 400.0);
        assert_eq!(m.points.len() as u32, m.columns * m.rows);
        assert_eq!(mood_noise_tile().len(), 96 * 96 * 4);
    }

    #[test]
    fn the_licence_list_follows_the_platform() {
        let json = br#"{"schema":1,"angebot":{"titel":"t","kurz":"x","kontakt":"k","abschnitte":[]},"bausteine":[
          {"id":"a","name":"A","version":"1","spdx":"MIT","urheber":"u","quelle":"q","plattformen":["ios"],"texte":["MIT"],"gruppe":"g"},
          {"id":"b","name":"B","version":"2","spdx":"MIT","urheber":"u","quelle":"q","plattformen":["android"],"texte":[],"gruppe":"g"}]}"#;
        let ios = licenses_for_platform(json.to_vec(), "ios".into());
        assert_eq!(ios.len(), 1);
        assert_eq!(ios[0].name, "A");
        assert!(licenses_for_platform(b"nope".to_vec(), "ios".into()).is_empty());
    }

    #[test]
    fn single_samples_equal_the_grid_and_the_mesh() {
        let tones = vec![210.0, 30.0];
        let grid = tone_grid(tones.clone());
        for p in &grid {
            let one = tone_at(tones.clone(), f64::from(p.x), f64::from(p.y));
            assert_eq!(one.hue, p.hue);
            assert_eq!(one.saturation, p.saturation);
            assert_eq!(one.brightness, p.brightness);
        }
        let mesh = mood_mesh(tones.clone(), 2200.0, 1250.0, 350.0, 1300.0);
        let first = &mesh.points[0];
        let f = mood_decay(0.0, 350.0, 1300.0);
        let one = mood_color(tones, f64::from(first.x), 0.0, f);
        assert_eq!(
            (one.red, one.green, one.blue),
            (first.red, first.green, first.blue)
        );
    }

    #[test]
    fn without_hues_the_page_colour_stays() {
        let c = mood_color(Vec::new(), 0.5, 0.5, 0.7);
        assert!((c.red - 16.0 / 255.0).abs() < 1e-12);
        assert_eq!(tone_at(Vec::new(), 0.2, 0.55).hue, None);
    }
}
