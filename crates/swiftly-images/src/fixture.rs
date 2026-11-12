//! A fixture image server for the demo and the tests: an [`HttpTransport`] that answers
//! `/Items/<id>/Images/<kind>` with a deterministic PNG, built with integer arithmetic only so the bytes and the
//! decoded pixels are identical on every host. Ids starting with `missing` answer 404, ids starting with
//! `corrupt` answer 200 with bytes that are no picture, ids starting with `broken` fail like a lost connection.

use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, HttpTransport};

/// Size of a poster fixture (2x of the 116 x 174 point tile).
pub const POSTER: (u32, u32) = (232, 348);
/// Size of a landscape or backdrop fixture.
pub const LANDSCAPE: (u32, u32) = (640, 360);

/// The fixture server.
#[derive(Debug, Clone, Copy, Default)]
pub struct FixtureImages;

fn hash(text: &str) -> u32 {
    text.bytes().fold(0x811c_9dc5_u32, |h, b| {
        (h ^ u32::from(b)).wrapping_mul(0x0100_0193)
    })
}

fn colour(h: u32, shift: u32) -> [u32; 3] {
    let v = h.rotate_left(shift);
    [
        40 + (v & 0xFF) * 170 / 255,
        40 + ((v >> 8) & 0xFF) * 170 / 255,
        40 + ((v >> 16) & 0xFF) * 170 / 255,
    ]
}

/// The RGBA pixels of the fixture for `id` at `w x h`: a diagonal blend of two colours from the id, a lighter
/// band, and a dark foot, all integers.
pub fn pixels(id: &str, w: u32, h: u32) -> Vec<u8> {
    let hs = hash(id);
    let (a, b) = (colour(hs, 0), colour(hs, 11));
    let mut out = Vec::with_capacity((w * h * 4) as usize);
    for y in 0..h {
        for x in 0..w {
            let t = (x * 256 / w + y * 256 / h) / 2; // 0..255
            let band = if (x + y) % 64 < 6 { 24 } else { 0 };
            let foot = if y * 100 / h > 62 {
                (y * 100 / h - 62) * 55 / 38
            } else {
                0
            };
            for c in 0..3 {
                let base = (a[c] * (255 - t) + b[c] * t) / 255 + band;
                out.push((base * (100 - foot) / 100).min(255) as u8);
            }
            out.push(255);
        }
    }
    out
}

/// The PNG for `id` at `w x h`.
pub fn png(id: &str, w: u32, h: u32) -> Vec<u8> {
    let mut out = Vec::new();
    let mut enc = png::Encoder::new(&mut out, w, h);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    if let Ok(mut writer) = enc.write_header() {
        let _ = writer.write_image_data(&pixels(id, w, h));
    }
    out
}

impl HttpTransport for FixtureImages {
    async fn send(&self, request: HttpRequest) -> Result<HttpResponse, ErrorKind> {
        let path = request.url.path().to_owned();
        let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
        let (id, kind) = match parts.as_slice() {
            [.., "Items", id, "Images", kind] | [.., "Users", id, "Images", kind] => (*id, *kind),
            [.., "Items", id, "Images", kind, _] => (*id, *kind),
            _ => return Ok(HttpResponse::new(404, "")),
        };
        if id.starts_with("broken") {
            return Err(ErrorKind::Network { code: -1009 });
        }
        if id.starts_with("missing") {
            return Ok(HttpResponse::new(404, ""));
        }
        if id.starts_with("corrupt") {
            return Ok(HttpResponse::new(
                200,
                b"<html>not a picture</html>".to_vec(),
            ));
        }
        let (w, h) = if kind.eq_ignore_ascii_case("Primary") {
            POSTER
        } else {
            LANDSCAPE
        };
        Ok(HttpResponse::new(200, png(id, w, h)).with_header("Content-Type", "image/png"))
    }
}
