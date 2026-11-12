//! Made-up content of the G1 demo: German titles and generated gradient posters and heroes.

/// Real German film and series titles (some localised foreign ones), umlauts and long ones included.
pub const TITLES: [&str; 48] = [
    "Das Boot",
    "Der Himmel über Berlin",
    "Lola rennt",
    "Good Bye, Lenin!",
    "Das Leben der Anderen",
    "Der Untergang",
    "Die Welle",
    "Systemsprenger",
    "Toni Erdmann",
    "Fack ju Göhte",
    "Der Schuh des Manitu",
    "Die unendliche Geschichte",
    "Das Parfum: Die Geschichte eines Mörders",
    "Nosferatu: Eine Symphonie des Grauens",
    "Metropolis",
    "Der Pate",
    "Die Verurteilten",
    "Das Schweigen der Lämmer",
    "Zurück in die Zukunft",
    "Der Club der toten Dichter",
    "Ziemlich beste Freunde",
    "Vom Winde verweht",
    "Die Schöne und das Biest",
    "Der Herr der Ringe: Die Gefährten",
    "Chihiros Reise ins Zauberland",
    "Prinzessin Mononoke",
    "Das wandelnde Schloss",
    "Die Reise des jungen Che",
    "Der weiße Hai",
    "Jäger des verlorenen Schatzes",
    "Die Känguru-Chroniken",
    "Dark",
    "Babylon Berlin",
    "Dogs of Berlin",
    "Haus des Geldes",
    "Der Tatortreiniger",
    "Tatort: Münster",
    "Die Brücke",
    "Ein Fall für zwei",
    "Löwenzahn",
    "Die Sendung mit der Maus",
    "Bibi & Tina",
    "Die Wilden Kerle",
    "Der kleine Eisbär",
    "Wickie und die starken Männer",
    "Heidi",
    "Pettersson und Findus",
    "Käpt'n Blaubär",
];

/// Titles of the three rails.
pub const RAIL_TITLES: [&str; 3] = ["Weiterschauen", "Neu hinzugefügt", "Für dich empfohlen"];

/// Title of item `index` in rail `rail`. Repeats get a part number so the 200 items differ.
pub fn title_for(rail: usize, index: usize) -> String {
    let n = (index * 7 + rail * 13) % TITLES.len();
    let round = (index * 7 + rail * 13) / TITLES.len();
    let base = TITLES[n];
    if round.is_multiple_of(3) {
        base.to_owned()
    } else {
        format!("{base} {}", round % 3 + 1)
    }
}

/// Number of different posters.
pub const POSTER_VARIANTS: usize = 48;
/// Number of different heroes.
pub const HERO_VARIANTS: usize = 6;
/// Poster size in pixels (the tile token at 1x).
pub const POSTER_SIZE: (usize, usize) = (116, 174);
/// Hero size in pixels.
pub const HERO_SIZE: (usize, usize) = (640, 200);

fn hsv(h: f32, s: f32, v: f32) -> [f32; 3] {
    let h = h.rem_euclid(1.0) * 6.0;
    let (i, f) = (h.floor(), h.fract());
    let (p, q, t) = (v * (1.0 - s), v * (1.0 - s * f), v * (1.0 - s * (1.0 - f)));
    match i as i32 {
        0 => [v, t, p],
        1 => [q, v, p],
        2 => [p, v, t],
        3 => [p, q, v],
        4 => [t, p, v],
        _ => [v, p, q],
    }
}

/// A gradient between two hues along an angle, a soft light, and a dark foot. Straight-alpha RGBA.
fn gradient(w: usize, h: usize, variant: usize, count: usize) -> Vec<u8> {
    let hue = variant as f32 / count as f32;
    let a = hsv(hue, 0.65, 0.85);
    let b = hsv(hue + 0.12 + 0.05 * (variant % 3) as f32, 0.75, 0.35);
    let angle = 0.5 + 0.9 * ((variant * 5 % 7) as f32 / 7.0);
    let (ca, sa) = (angle.cos(), angle.sin());
    let mut px = Vec::with_capacity(w * h * 4);
    for y in 0..h {
        for x in 0..w {
            let (u, v) = (x as f32 / w as f32, y as f32 / h as f32);
            let t = (((u - 0.5) * ca + (v - 0.5) * sa) + 0.5).clamp(0.0, 1.0);
            let (dx, dy) = (u - 0.3, v - 0.25);
            let glow = (-(dx * dx + dy * dy) * 9.0).exp() * 0.35;
            let foot = ((v - 0.62) / 0.38).clamp(0.0, 1.0);
            let mut out = [0.0_f32; 3];
            for c in 0..3 {
                let base = a[c] * (1.0 - t) + b[c] * t;
                out[c] = ((base + glow) * (1.0 - 0.55 * foot)).clamp(0.0, 1.0);
            }
            px.extend_from_slice(&[
                (out[0] * 255.0) as u8,
                (out[1] * 255.0) as u8,
                (out[2] * 255.0) as u8,
                255,
            ]);
        }
    }
    px
}

/// The demo posters on the image page, added once per `Cx` and shared by every screen.
pub fn posters(cx: &swiftly_ui::Cx) -> Vec<swiftly_ui::ImageId> {
    if let Some(v) = cx.memo.borrow().get("posters") {
        return v.clone();
    }
    let v: Vec<_> = (0..POSTER_VARIANTS)
        .filter_map(|v| {
            cx.add_image(
                POSTER_SIZE.0 as u32,
                POSTER_SIZE.1 as u32,
                &poster_pixels(v),
            )
        })
        .collect();
    cx.memo.borrow_mut().insert("posters", v.clone());
    v
}

/// The demo heroes on the image page, added once per `Cx` and shared by every screen.
pub fn heroes(cx: &swiftly_ui::Cx) -> Vec<swiftly_ui::ImageId> {
    if let Some(v) = cx.memo.borrow().get("heroes") {
        return v.clone();
    }
    let v: Vec<_> = (0..HERO_VARIANTS)
        .filter_map(|v| cx.add_image(HERO_SIZE.0 as u32, HERO_SIZE.1 as u32, &hero_pixels(v)))
        .collect();
    cx.memo.borrow_mut().insert("heroes", v.clone());
    v
}

/// Pixels of poster `variant`.
pub fn poster_pixels(variant: usize) -> Vec<u8> {
    gradient(POSTER_SIZE.0, POSTER_SIZE.1, variant, POSTER_VARIANTS)
}

/// Pixels of hero `variant`.
pub fn hero_pixels(variant: usize) -> Vec<u8> {
    gradient(HERO_SIZE.0, HERO_SIZE.1, variant, HERO_VARIANTS)
}

/// The detail text for an item: year, length, age rating and a paragraph.
pub fn blurb(rail: usize, index: usize) -> (String, Vec<&'static str>) {
    const PARAS: [&str; 4] = [
        "Ein ruhiger Abend, ein altes Haus und ein Geheimnis, das niemand mehr aussprechen will. Als die Tochter zurückkehrt, kommt alles ans Licht.",
        "Zwischen Hafen und Hinterhof erzählt der Film von Freundschaft, Schulden und der Frage, was ein Zuhause ausmacht.",
        "Mit viel Humor und wenig Geduld schlägt sich die Familie durch einen Sommer, der alles auf den Kopf stellt.",
        "Eine Reise durch die Nacht, drei Fremde im selben Zug und ein Koffer, den keiner geöffnet haben will.",
    ];
    let year = 1980 + (index * 7 + rail * 3) % 45;
    let minutes = 80 + (index * 13) % 70;
    let fsk = [0, 6, 12, 16][(index + rail) % 4];
    let meta = format!(
        "{year}  ·  {} Std. {:02} Min.  ·  FSK {fsk}",
        minutes / 60,
        minutes % 60
    );
    let mut lines = vec![PARAS[(index + rail) % 4]];
    lines.push("Deutsch, Englisch  ·  Untertitel: Deutsch, Englisch, Französisch");
    (meta, lines)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn titles_are_varied_and_pixels_have_the_right_size() {
        let all: std::collections::HashSet<String> = (0..200).map(|i| title_for(0, i)).collect();
        assert!(all.len() > 100, "{}", all.len());
        assert_eq!(poster_pixels(3).len(), 116 * 174 * 4);
        assert_eq!(hero_pixels(1).len(), 640 * 200 * 4);
        assert_ne!(poster_pixels(0), poster_pixels(1));
    }
}
