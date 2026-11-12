//! BlurHash placeholders: a 20 to 30 character string from the server (`ImageBlurHashes`) becomes a small blurred
//! picture that stands in until the real one arrives. Decoding is a few thousand multiplications for a 32 x 32
//! result, so it can run on the UI thread; the UI scales the small picture up when it draws it.
//!
//! Algorithm: <https://github.com/woltapp/blurhash/blob/master/Algorithm.md>.

use crate::decode::Decoded;

const ALPHABET: &[u8; 83] =
    b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~";

fn value(c: u8) -> Option<usize> {
    ALPHABET.iter().position(|&a| a == c)
}

fn base83(s: &[u8]) -> Option<usize> {
    s.iter()
        .try_fold(0usize, |acc, &c| Some(acc * 83 + value(c)?))
}

fn srgb_to_linear(v: u8) -> f32 {
    let x = f32::from(v) / 255.0;
    if x <= 0.04045 {
        x / 12.92
    } else {
        ((x + 0.055) / 1.055).powf(2.4)
    }
}

fn linear_to_srgb(v: f32) -> u8 {
    let x = v.clamp(0.0, 1.0);
    let s = if x <= 0.003_130_8 {
        x * 12.92
    } else {
        1.055 * x.powf(1.0 / 2.4) - 0.055
    };
    (s * 255.0 + 0.5) as u8
}

fn sign_pow(v: f32, e: f32) -> f32 {
    v.abs().powf(e).copysign(v)
}

/// Decodes `hash` to an opaque RGBA picture of `width` x `height` (use a small size, 32 is plenty). `None` for a
/// hash that is not valid BlurHash or whose length does not match its component count.
pub fn decode(hash: &str, width: u32, height: u32) -> Option<Decoded> {
    let h = hash.as_bytes();
    if h.len() < 6 || width == 0 || height == 0 || width > 256 || height > 256 {
        return None;
    }
    let size = base83(&h[..1])?;
    let (nx, ny) = (size % 9 + 1, size / 9 + 1);
    if h.len() != 4 + 2 * nx * ny {
        return None;
    }
    let max = (base83(&h[1..2])? + 1) as f32 / 166.0;
    let mut colors: Vec<[f32; 3]> = Vec::with_capacity(nx * ny);
    let dc = base83(&h[2..6])?;
    colors.push([
        srgb_to_linear((dc >> 16) as u8),
        srgb_to_linear((dc >> 8 & 255) as u8),
        srgb_to_linear((dc & 255) as u8),
    ]);
    for i in 1..nx * ny {
        let v = base83(&h[4 + i * 2..6 + i * 2])?;
        let q = |n: usize| sign_pow((n as f32 - 9.0) / 9.0, 2.0) * max;
        colors.push([q(v / (19 * 19)), q(v / 19 % 19), q(v % 19)]);
    }
    let (w, hgt) = (width as usize, height as usize);
    let mut rgba = Vec::with_capacity(w * hgt * 4);
    // cos tables once per axis.
    let cx: Vec<f32> = (0..w * nx)
        .map(|k| (std::f32::consts::PI * (k % w) as f32 * (k / w) as f32 / w as f32).cos())
        .collect();
    let cy: Vec<f32> = (0..hgt * ny)
        .map(|k| (std::f32::consts::PI * (k % hgt) as f32 * (k / hgt) as f32 / hgt as f32).cos())
        .collect();
    for y in 0..hgt {
        for x in 0..w {
            let mut px = [0.0f32; 3];
            for j in 0..ny {
                for i in 0..nx {
                    let basis = cx[i * w + x] * cy[j * hgt + y];
                    let c = colors[j * nx + i];
                    px[0] += c[0] * basis;
                    px[1] += c[1] * basis;
                    px[2] += c[2] * basis;
                }
            }
            rgba.extend_from_slice(&[
                linear_to_srgb(px[0]),
                linear_to_srgb(px[1]),
                linear_to_srgb(px[2]),
                255,
            ]);
        }
    }
    Some(Decoded {
        width,
        height,
        rgba,
    })
}
