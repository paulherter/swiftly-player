//! Domain `title_marks` (TitleMarksMetric.swift): crop/density/luminance of generated premultiplied RGBA
//! logos (alpha around the threshold, colour above alpha, short buffers, zero or negative sizes), the
//! density factor, the dark limit and the size rule. Read by `Domain_Description.swift` and
//! `tests/oracle_title_marks.rs`.
use crate::Rng;
use serde_json::{Value, json};

fn pixel(rng: &mut Rng) -> [i64; 4] {
    let a = match rng.below(8) {
        0 => 0,
        1 => 7,
        2 => 8,
        3 => 9,
        4 => 255,
        _ => rng.range(0, 255),
    };
    let channel = |rng: &mut Rng| match rng.below(6) {
        0 => 0,
        1 => a,
        2 => 255, // above alpha: not premultiplied, `linear` clamps
        _ => rng.range(0, a),
    };
    [channel(rng), channel(rng), channel(rng), a]
}

fn number(rng: &mut Rng) -> f64 {
    match rng.below(9) {
        0 => 0.0,
        1 => -(rng.range(1, 400) as f64) / 8.0,
        2 => 1e9,
        3 => *rng.pick(&[0.05, 0.25, 0.5, 1.0, 2.2, 0.049, 0.051, 0.3, 0.7]),
        4 => rng.range(1, 4000) as f64 / 64.0,
        _ => rng.range(1, 800) as f64 / 8.0,
    }
}

pub fn cases() -> Vec<Value> {
    let mut rng = Rng::new(0x5449_544D);
    let mut out = Vec::new();
    for _ in 0..1500 {
        let (w, h) = (rng.range(1, 12), rng.range(1, 10));
        // Mostly one blob on a transparent field, sometimes noise.
        let noise = rng.chance(35);
        let (bx0, bx1) = (rng.range(0, w - 1), rng.range(0, w - 1));
        let (by0, by1) = (rng.range(0, h - 1), rng.range(0, h - 1));
        let mut rgba: Vec<i64> = Vec::new();
        for y in 0..h {
            for x in 0..w {
                let inside = x >= bx0.min(bx1)
                    && x <= bx0.max(bx1)
                    && y >= by0.min(by1)
                    && y <= by0.max(by1);
                let p = if noise || (inside && rng.chance(85)) {
                    pixel(&mut rng)
                } else if rng.chance(3) {
                    [0, 0, 0, rng.range(0, 8)]
                } else {
                    [0, 0, 0, 0]
                };
                rgba.extend(p);
            }
        }
        // A buffer that is too short or too long.
        match rng.below(12) {
            0 => rgba.truncate(rgba.len().saturating_sub(rng.range(1, 6) as usize)),
            1 => rgba.extend([1, 2, 3, 4, 5]),
            _ => {}
        }
        out.push(json!({"op": "measure", "w": w, "h": h, "rgba": rgba}));
    }
    for (w, h, n) in [
        (0, 5, 20),
        (5, 0, 20),
        (-1, 5, 20),
        (5, -1, 20),
        (3_000_000_000_i64, 1, 4),
        (1, 3_000_000_000_i64, 4),
        (2, 2, 0),
    ] {
        out.push(json!({"op": "measure", "w": w, "h": h, "rgba": vec![255; n]}));
    }
    for d in [0.0, 0.05, 0.049, 0.25, 0.5, 0.75, 1.0, -1.0, 2.0, 0.2, 0.3] {
        out.push(json!({"op": "factor", "density": d}));
    }
    for _ in 0..200 {
        out.push(json!({"op": "factor", "density": rng.unit() * 1.2 - 0.1}));
    }
    for l in [0.0, 0.1, 0.249999, 0.25, 0.250001, 1.0, -1.0] {
        out.push(json!({"op": "dark", "l": l}));
    }
    for _ in 0..2500 {
        let max_h = if rng.chance(50) {
            Value::Null
        } else {
            json!(number(&mut rng))
        };
        out.push(json!({"op": "size", "ratio": number(&mut rng), "density": rng.unit() * 1.1, "row": number(&mut rng),
            "maxWidth": number(&mut rng) * 4.0, "maxHeight": max_h}));
    }
    out
}
