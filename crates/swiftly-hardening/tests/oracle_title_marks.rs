//! Differential oracle, `TitleMarksMetric` (Tools/Oracle, Domain_Description.swift): crop, density,
//! luminance, density factor and size rule through the real Swift code and `swiftly_rules::title_marks`.
#![allow(clippy::expect_used, clippy::unwrap_used)]

use serde_json::{Value, json};
use swiftly_hardening::oracle::assert_equal;
use swiftly_rules::title_marks as tm;

#[test]
fn title_marks() {
    assert_equal("title_marks", |c| {
        let d = |k: &str| c[k].as_f64().unwrap_or(0.0);
        match c["op"].as_str().unwrap() {
            "measure" => {
                let px: Vec<u8> = c["rgba"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|x| x.as_i64().unwrap_or(0).clamp(0, 255) as u8)
                    .collect();
                match tm::measure(
                    &px,
                    c["w"].as_i64().unwrap_or(0),
                    c["h"].as_i64().unwrap_or(0),
                ) {
                    Some(m) => json!([
                        m.x,
                        m.y,
                        m.width,
                        m.height,
                        m.density,
                        m.luminance,
                        m.pages_ratio()
                    ]),
                    None => Value::Null,
                }
            }
            "factor" => json!(tm::density_factor(d("density"))),
            "dark" => json!(tm::is_dark(d("l"))),
            _ => {
                let (w, h) = tm::size(
                    d("ratio"),
                    d("density"),
                    d("row"),
                    d("maxWidth"),
                    c["maxHeight"].as_f64(),
                );
                json!([w, h])
            }
        }
    });
}
