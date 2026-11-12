//! Decoding and downscaling: JPEG, PNG and WebP to straight-alpha RGBA, scaled so the longest
//! edge is at most `border` pixels (`CGImageSourceCreateThumbnailAtIndex` with
//! `kCGImageSourceThumbnailMaxPixelSize` in `ImageCache.load`).

use crate::memory::Device;

/// A decoded picture, 8-bit straight-alpha RGBA, rows top to bottom.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Decoded {
    /// Width in pixels.
    pub width: u32,
    /// Height in pixels.
    pub height: u32,
    /// `width * height * 4` bytes.
    pub rgba: Vec<u8>,
}

impl Decoded {
    /// What the memory cache counts: width times height times four (`Record.byte`).
    pub fn cost(&self) -> usize {
        (self.width as usize)
            .saturating_mul(self.height as usize)
            .saturating_mul(4)
    }

    /// `rgba` holds exactly `width * height * 4` bytes (the fields are public, so a caller can break
    /// this; the pixel loops below index by it).
    pub fn is_consistent(&self) -> bool {
        (self.width as usize)
            .checked_mul(self.height as usize)
            .and_then(|pixels| pixels.checked_mul(4))
            == Some(self.rgba.len())
    }
}

/// Why a picture could not be decoded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecodeError {
    /// Not a format we read (or empty).
    Unsupported,
    /// The data is damaged or ends early.
    Corrupt(String),
    /// More than 100 megapixels; refused before allocating.
    TooLarge,
}

impl std::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unsupported => f.write_str("unsupported image format"),
            Self::Corrupt(why) => write!(f, "damaged image: {why}"),
            Self::TooLarge => f.write_str("image too large"),
        }
    }
}

impl std::error::Error for DecodeError {}

/// Pictures with more pixels than this are refused before anything is allocated.
pub const MAX_PIXELS: u64 = 100_000_000;

/// The longest edge to decode to: the tile's edge in points times 3.2 (`displayEdge * 3.2`), never above
/// the device limit (`edgesLength`); without a tile edge the device limit alone.
pub fn border_for(display_edge_points: Option<f32>, device: Device) -> u32 {
    let cap = device.decode_edge();
    match display_edge_points {
        // `max(1).min(cap)`, not `clamp(1, cap)`: clamp panics when the device limit is 0.
        Some(e) if e.is_finite() && e > 0.0 => ((e * 3.2) as u32).max(1).min(cap),
        _ => cap,
    }
}

/// Decodes `bytes` and scales down so the longest edge is at most `border` (never up).
pub fn decode(bytes: &[u8], border: u32) -> Result<Decoded, DecodeError> {
    let mut full = decode_full(bytes)?;
    if bytes.starts_with(&[0xFF, 0xD8]) {
        // `kCGImageSourceCreateThumbnailWithTransform`: a JPEG's EXIF orientation is applied.
        full = orient(full, jpeg_orientation(bytes));
    }
    Ok(downscale(full, border))
}

/// The EXIF orientation (1 to 8) of a JPEG; 1 when there is none.
pub fn jpeg_orientation(b: &[u8]) -> u8 {
    let mut i = 2;
    while i + 4 <= b.len() && b[i] == 0xFF {
        let marker = b[i + 1];
        if marker == 0xDA || marker == 0xD9 {
            break;
        }
        let len = usize::from(u16::from_be_bytes([b[i + 2], b[i + 3]]));
        let seg = b.get(i + 4..(i + 2 + len).min(b.len())).unwrap_or(&[]);
        if marker == 0xE1 && seg.starts_with(b"Exif\0\0") {
            return exif_orientation(&seg[6..]).unwrap_or(1);
        }
        i += 2 + len;
    }
    1
}

fn exif_orientation(t: &[u8]) -> Option<u8> {
    let big = match t.get(..2)? {
        b"MM" => true,
        b"II" => false,
        _ => return None,
    };
    let u16_at = |o: usize| -> Option<u16> {
        let v = [*t.get(o)?, *t.get(o + 1)?];
        Some(if big {
            u16::from_be_bytes(v)
        } else {
            u16::from_le_bytes(v)
        })
    };
    let u32_at = |o: usize| -> Option<u32> {
        let v = [*t.get(o)?, *t.get(o + 1)?, *t.get(o + 2)?, *t.get(o + 3)?];
        Some(if big {
            u32::from_be_bytes(v)
        } else {
            u32::from_le_bytes(v)
        })
    };
    let ifd = usize::try_from(u32_at(4)?).ok()?;
    for n in 0..usize::from(u16_at(ifd)?) {
        // Saturating: a hostile offset must give "no entry" (`get` is `None`), not an overflow on 32-bit hosts.
        let e = ifd.saturating_add(2).saturating_add(n * 12);
        if u16_at(e)? == 0x0112 {
            let v = u16_at(e + 8)?;
            return (1..=8).contains(&v).then_some(v as u8);
        }
    }
    None
}

/// Applies an EXIF orientation: 2 mirror, 3 turn 180, 4 flip, 5 transpose, 6 turn 90 clockwise, 7 transverse,
/// 8 turn 90 counter-clockwise.
pub fn orient(src: Decoded, o: u8) -> Decoded {
    if !(2..=8).contains(&o) || !src.is_consistent() {
        return src;
    }
    let (w, h) = (src.width as usize, src.height as usize);
    let swap = o >= 5;
    let (dw, dh) = if swap { (h, w) } else { (w, h) };
    let mut out = vec![0u8; src.rgba.len()];
    for y in 0..h {
        for x in 0..w {
            let (dx, dy) = match o {
                2 => (w - 1 - x, y),
                3 => (w - 1 - x, h - 1 - y),
                4 => (x, h - 1 - y),
                5 => (y, x),
                6 => (h - 1 - y, x),
                7 => (h - 1 - y, w - 1 - x),
                _ => (y, w - 1 - x),
            };
            let (s, d) = ((y * w + x) * 4, (dy * dw + dx) * 4);
            out[d..d + 4].copy_from_slice(&src.rgba[s..s + 4]);
        }
    }
    Decoded {
        width: dw as u32,
        height: dh as u32,
        rgba: out,
    }
}

fn decode_full(bytes: &[u8]) -> Result<Decoded, DecodeError> {
    if bytes.len() >= 3 && bytes[..3] == [0xFF, 0xD8, 0xFF] {
        decode_jpeg(bytes)
    } else if bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
        decode_png(bytes)
    } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        decode_webp(bytes)
    } else {
        Err(DecodeError::Unsupported)
    }
}

fn check_size(w: u64, h: u64) -> Result<(), DecodeError> {
    if w == 0 || h == 0 {
        return Err(DecodeError::Corrupt("empty".into()));
    }
    if w * h > MAX_PIXELS {
        return Err(DecodeError::TooLarge);
    }
    Ok(())
}

fn decode_jpeg(bytes: &[u8]) -> Result<Decoded, DecodeError> {
    use zune_core::bytestream::ZCursor;
    use zune_core::colorspace::ColorSpace;
    use zune_core::options::DecoderOptions;
    let options = DecoderOptions::default().jpeg_set_out_colorspace(ColorSpace::RGBA);
    let mut d = zune_jpeg::JpegDecoder::new_with_options(ZCursor::new(bytes), options);
    d.decode_headers()
        .map_err(|e| DecodeError::Corrupt(format!("{e:?}")))?;
    let (w, h) = d
        .dimensions()
        .ok_or_else(|| DecodeError::Corrupt("no size".into()))?;
    check_size(w as u64, h as u64)?;
    let rgba = d
        .decode()
        .map_err(|e| DecodeError::Corrupt(format!("{e:?}")))?;
    if rgba.len() != w * h * 4 {
        return Err(DecodeError::Corrupt("wrong length".into()));
    }
    Ok(Decoded {
        width: w as u32,
        height: h as u32,
        rgba,
    })
}

fn decode_png(bytes: &[u8]) -> Result<Decoded, DecodeError> {
    let corrupt = |e: png::DecodingError| DecodeError::Corrupt(e.to_string());
    let mut decoder = png::Decoder::new(std::io::Cursor::new(bytes));
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = decoder.read_info().map_err(corrupt)?;
    let (w, h) = reader.info().size();
    check_size(u64::from(w), u64::from(h))?;
    let size = reader.output_buffer_size().ok_or(DecodeError::TooLarge)?;
    let mut buf = vec![0; size];
    let info = reader.next_frame(&mut buf).map_err(corrupt)?;
    buf.truncate(info.buffer_size());
    let rgba = match info.color_type {
        png::ColorType::Rgba => buf,
        png::ColorType::Rgb => rgb_to_rgba(&buf),
        png::ColorType::Grayscale => buf.iter().flat_map(|&g| [g, g, g, 255]).collect(),
        png::ColorType::GrayscaleAlpha => buf
            .as_chunks::<2>()
            .0
            .iter()
            .flat_map(|p| [p[0], p[0], p[0], p[1]])
            .collect(),
        png::ColorType::Indexed => return Err(DecodeError::Unsupported),
    };
    if rgba.len() != w as usize * h as usize * 4 {
        return Err(DecodeError::Corrupt("wrong length".into()));
    }
    Ok(Decoded {
        width: w,
        height: h,
        rgba,
    })
}

fn decode_webp(bytes: &[u8]) -> Result<Decoded, DecodeError> {
    let corrupt = |e: image_webp::DecodingError| DecodeError::Corrupt(e.to_string());
    let mut d = image_webp::WebPDecoder::new(std::io::Cursor::new(bytes)).map_err(corrupt)?;
    let (w, h) = d.dimensions();
    check_size(u64::from(w), u64::from(h))?;
    let size = d.output_buffer_size().ok_or(DecodeError::TooLarge)?;
    let mut buf = vec![0; size];
    d.read_image(&mut buf).map_err(corrupt)?;
    let rgba = if d.has_alpha() {
        buf
    } else {
        rgb_to_rgba(&buf)
    };
    if rgba.len() != w as usize * h as usize * 4 {
        return Err(DecodeError::Corrupt("wrong length".into()));
    }
    Ok(Decoded {
        width: w,
        height: h,
        rgba,
    })
}

/// Area-average scale down so the longest edge is at most `border`. Integer arithmetic only, so the
/// result is identical on every host and bit-identical to the first version of this function (kept as the
/// reference in the tests). A picture that already fits is returned as it is.
///
/// Rows are walked in memory order and the sums of one output row are kept in a small buffer; pictures
/// without any transparency (almost every poster) skip the alpha weights, which gives the same bytes.
pub fn downscale(src: Decoded, border: u32) -> Decoded {
    let longest = src.width.max(src.height);
    if border == 0 || longest <= border || !src.is_consistent() {
        return src;
    }
    let (dw, dh) = target_size(src.width, src.height, border);
    let (dw, dh) = (dw as usize, dh as usize);
    let (sw, sh) = (src.width as usize, src.height as usize);
    let xs: Vec<(usize, usize)> = (0..dw)
        .map(|dx| {
            let x0 = dx * sw / dw;
            (x0, (((dx + 1) * sw).div_ceil(dw)).clamp(x0 + 1, sw))
        })
        .collect();
    let mut out = Vec::with_capacity(dw * dh * 4);
    if src
        .rgba
        .as_chunks::<4>()
        .0
        .iter()
        .fold(255u8, |all, p| all & p[3])
        == 255
    {
        // Opaque: no alpha weights. Each output row adds its source rows window by window; 32-bit sums per
        // window, 64-bit across rows. (Adding whole rows first and the windows after was measured slower.)
        let mut acc = vec![[0u64; 3]; dw];
        for dy in 0..dh {
            let y0 = dy * sh / dh;
            let y1 = (((dy + 1) * sh).div_ceil(dh)).clamp(y0 + 1, sh);
            acc.fill([0; 3]);
            for y in y0..y1 {
                let row = &src.rgba[y * sw * 4..(y + 1) * sw * 4];
                for (a, &(x0, x1)) in acc.iter_mut().zip(&xs) {
                    let (mut r, mut g, mut b) = (0u32, 0u32, 0u32);
                    for p in row[x0 * 4..x1 * 4].as_chunks::<4>().0 {
                        r += u32::from(p[0]);
                        g += u32::from(p[1]);
                        b += u32::from(p[2]);
                    }
                    a[0] += u64::from(r);
                    a[1] += u64::from(g);
                    a[2] += u64::from(b);
                }
            }
            for (a, &(x0, x1)) in acc.iter().zip(&xs) {
                let n = ((y1 - y0) * (x1 - x0)) as u64;
                out.extend_from_slice(&[
                    ((a[0] + n / 2) / n) as u8,
                    ((a[1] + n / 2) / n) as u8,
                    ((a[2] + n / 2) / n) as u8,
                    255,
                ]);
            }
        }
        return Decoded {
            width: dw as u32,
            height: dh as u32,
            rgba: out,
        };
    }
    let mut acc = vec![[0u64; 4]; dw];
    for dy in 0..dh {
        let y0 = dy * sh / dh;
        let y1 = (((dy + 1) * sh).div_ceil(dh)).clamp(y0 + 1, sh);
        acc.iter_mut().for_each(|a| *a = [0; 4]);
        for y in y0..y1 {
            let row = &src.rgba[y * sw * 4..(y + 1) * sw * 4];
            for (a, &(x0, x1)) in acc.iter_mut().zip(&xs) {
                for p in row[x0 * 4..x1 * 4].as_chunks::<4>().0.iter() {
                    let pa = u64::from(p[3]);
                    a[0] += u64::from(p[0]) * pa;
                    a[1] += u64::from(p[1]) * pa;
                    a[2] += u64::from(p[2]) * pa;
                    a[3] += pa;
                }
            }
        }
        for (a, &(x0, x1)) in acc.iter().zip(&xs) {
            let n = ((y1 - y0) * (x1 - x0)) as u64;
            // Alpha-weighted so transparent pixels do not bleed colour.
            let w = a[3];
            out.extend_from_slice(&[
                (a[0] + w / 2).checked_div(w).unwrap_or(0) as u8,
                (a[1] + w / 2).checked_div(w).unwrap_or(0) as u8,
                (a[2] + w / 2).checked_div(w).unwrap_or(0) as u8,
                ((w + n / 2) / n) as u8,
            ]);
        }
    }
    Decoded {
        width: dw as u32,
        height: dh as u32,
        rgba: out,
    }
}

/// 3 bytes per pixel to 4 with full alpha, in one allocation.
fn rgb_to_rgba(rgb: &[u8]) -> Vec<u8> {
    let mut out = vec![255u8; rgb.len() / 3 * 4];
    for (d, s) in out
        .as_chunks_mut::<4>()
        .0
        .iter_mut()
        .zip(rgb.as_chunks::<3>().0)
    {
        d[..3].copy_from_slice(s);
    }
    out
}

/// Target size of [`downscale`] for a source of `w` x `h` and a `border`.
fn target_size(w: u32, h: u32, border: u32) -> (u32, u32) {
    let longest = w.max(h);
    let scale = f64::from(border) / f64::from(longest);
    (
        ((f64::from(w) * scale).round() as u32).max(1),
        ((f64::from(h) * scale).round() as u32).max(1),
    )
}

/// Same sizes as [`downscale`], computed with `fast_image_resize` (NEON on arm64, AVX2/SSE4.1 on x64): a box
/// filter with alpha weighting. Pixels may differ from the integer reference by a few levels, and may differ
/// a little between CPU families, so it is not used where the result is pinned by goldens.
pub fn downscale_fast(src: Decoded, border: u32) -> Decoded {
    use fast_image_resize as fir;
    let longest = src.width.max(src.height);
    if border == 0 || longest <= border || !src.is_consistent() {
        return src;
    }
    let (dw, dh) = target_size(src.width, src.height, border);
    let Ok(from) =
        fir::images::ImageRef::new(src.width, src.height, &src.rgba, fir::PixelType::U8x4)
    else {
        return downscale(src, border);
    };
    let mut to = fir::images::Image::new(dw, dh, fir::PixelType::U8x4);
    let opts =
        fir::ResizeOptions::new().resize_alg(fir::ResizeAlg::Convolution(fir::FilterType::Box));
    if fir::Resizer::new().resize(&from, &mut to, &opts).is_err() {
        return downscale(src, border);
    }
    Decoded {
        width: dw,
        height: dh,
        rgba: to.into_vec(),
    }
}

/// Straight alpha to premultiplied alpha, rounded (what GPUs blend with). Opaque pixels stay as they are.
pub fn premultiplied(src: &Decoded) -> Decoded {
    let mut rgba = src.rgba.clone();
    for p in rgba.as_chunks_mut::<4>().0.iter_mut() {
        let a = u32::from(p[3]);
        if a != 255 {
            for c in &mut p[..3] {
                *c = ((u32::from(*c) * a + 127) / 255) as u8;
            }
        }
    }
    Decoded {
        width: src.width,
        height: src.height,
        rgba,
    }
}

/// A mip chain for the GPU: level 0 is `src` premultiplied, every next level halves each side (rounded up)
/// with a 2 x 2 box average of premultiplied values, down to 1 x 1 or `max_levels` levels.
pub fn mip_chain(src: &Decoded, max_levels: usize) -> Vec<Decoded> {
    let mut chain = Vec::new();
    if max_levels == 0 || src.width == 0 || src.height == 0 || !src.is_consistent() {
        return chain;
    }
    chain.push(premultiplied(src));
    while chain.len() < max_levels {
        let Some(prev) = chain.last() else { break };
        if prev.width == 1 && prev.height == 1 {
            break;
        }
        let (pw, ph) = (prev.width as usize, prev.height as usize);
        let (w, h) = (pw.div_ceil(2), ph.div_ceil(2));
        let mut rgba = Vec::with_capacity(w * h * 4);
        for y in 0..h {
            for x in 0..w {
                let (mut sum, mut n) = ([0u32; 4], 0u32);
                for (sx, sy) in [
                    (2 * x, 2 * y),
                    (2 * x + 1, 2 * y),
                    (2 * x, 2 * y + 1),
                    (2 * x + 1, 2 * y + 1),
                ] {
                    if sx < pw && sy < ph {
                        let i = (sy * pw + sx) * 4;
                        for (c, s) in sum.iter_mut().zip(&prev.rgba[i..i + 4]) {
                            *c += u32::from(*s);
                        }
                        n += 1;
                    }
                }
                rgba.extend(sum.iter().map(|c| ((c + n / 2) / n) as u8));
            }
        }
        chain.push(Decoded {
            width: w as u32,
            height: h as u32,
            rgba,
        });
    }
    chain
}

/// Turns file bytes into pixels no larger than `border`. The Rust decoders are one implementation; a platform
/// shell can supply another (ImageIO on Apple, BitmapFactory on Android) behind the same trait when a
/// measurement shows it is faster. Output is always straight-alpha RGBA with the EXIF turn applied.
pub trait PixelDecoder: Send + Sync {
    /// Decodes `bytes` and scales so the longest edge is at most `border`.
    fn decode(&self, bytes: &[u8], border: u32) -> Result<Decoded, DecodeError>;
}

/// The built-in decoders of this crate (zune-jpeg, png, image-webp).
#[derive(Debug, Clone, Copy, Default)]
pub struct RustDecoder;

impl PixelDecoder for RustDecoder {
    fn decode(&self, bytes: &[u8], border: u32) -> Result<Decoded, DecodeError> {
        decode(bytes, border)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // F-cast-06: a picture whose fields do not fit its pixels, hostile EXIF offsets and edges.
    #[test]
    fn hostile_sizes_never_panic() {
        for (w, h) in [
            (u32::MAX, u32::MAX),
            (u32::MAX, 1),
            (1, u32::MAX),
            (65_535, 65_535),
            (3, 3),
        ] {
            let src = Decoded {
                width: w,
                height: h,
                rgba: vec![7; 16],
            };
            assert_eq!(
                src.cost(),
                (w as usize).saturating_mul(h as usize).saturating_mul(4)
            );
            if (w, h) != (3, 3) {
                assert!(!src.is_consistent());
            }
            for o in 0..=9 {
                assert_eq!(orient(src.clone(), o), src);
            }
            assert_eq!(downscale(src.clone(), 2), src);
            assert!(mip_chain(&src, 40).is_empty());
            let _ = downscale_fast(src.clone(), 2);
            let _ = premultiplied(&src);
        }
        for e in [
            f32::NAN,
            f32::INFINITY,
            f32::NEG_INFINITY,
            -1.0,
            0.0,
            1e30,
            f32::MAX,
        ] {
            assert!(border_for(Some(e), Device::Phone) >= 1);
        }
        // IFD offset at u32::MAX, entry count 65535: no entry, no overflow.
        let mut exif = b"Exif\0\0MM\0*".to_vec();
        exif.extend([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
        let mut jpeg = vec![0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF];
        jpeg.extend(exif);
        assert_eq!(jpeg_orientation(&jpeg), 1);
    }

    /// The first version of `downscale`, per pixel, kept to prove the faster one gives the same bytes.
    fn reference(src: &Decoded, border: u32) -> Decoded {
        let longest = src.width.max(src.height);
        if border == 0 || longest <= border {
            return src.clone();
        }
        let (dw, dh) = target_size(src.width, src.height, border);
        let (sw, sh) = (src.width as usize, src.height as usize);
        let mut out = Vec::new();
        for dy in 0..dh as usize {
            let y0 = dy * sh / dh as usize;
            let y1 = (((dy + 1) * sh).div_ceil(dh as usize)).clamp(y0 + 1, sh);
            for dx in 0..dw as usize {
                let x0 = dx * sw / dw as usize;
                let x1 = (((dx + 1) * sw).div_ceil(dw as usize)).clamp(x0 + 1, sw);
                let (mut r, mut g, mut b, mut a, mut n) = (0u64, 0u64, 0u64, 0u64, 0u64);
                for y in y0..y1 {
                    for x in x0..x1 {
                        let i = (y * sw + x) * 4;
                        let pa = u64::from(src.rgba[i + 3]);
                        r += u64::from(src.rgba[i]) * pa;
                        g += u64::from(src.rgba[i + 1]) * pa;
                        b += u64::from(src.rgba[i + 2]) * pa;
                        a += pa;
                        n += 1;
                    }
                }
                out.extend_from_slice(&[
                    (r + a / 2).checked_div(a).unwrap_or(0) as u8,
                    (g + a / 2).checked_div(a).unwrap_or(0) as u8,
                    (b + a / 2).checked_div(a).unwrap_or(0) as u8,
                    (a + n / 2).checked_div(n).unwrap_or(0) as u8,
                ]);
            }
        }
        Decoded {
            width: dw,
            height: dh,
            rgba: out,
        }
    }

    fn noise(w: u32, h: u32, seed: u32, alpha: bool) -> Decoded {
        let mut s = seed.max(1);
        let rgba = (0..w * h * 4)
            .map(|i| {
                s ^= s << 13;
                s ^= s >> 17;
                s ^= s << 5;
                if i % 4 == 3 && !alpha {
                    255
                } else {
                    (s >> 7) as u8
                }
            })
            .collect();
        Decoded {
            width: w,
            height: h,
            rgba,
        }
    }

    #[test]
    fn faster_downscale_gives_the_same_bytes_as_the_first_version() {
        for (w, h, b, alpha) in [
            (97, 61, 40, false),
            (97, 61, 40, true),
            (300, 450, 128, false),
            (300, 450, 128, true),
            (64, 64, 7, true),
            (1000, 3, 10, false),
            (5, 900, 33, true),
            (2, 2, 1, false),
            (31, 17, 30, true),
            (30, 600, 2, false),
        ] {
            let src = noise(w, h, w * 31 + h, alpha);
            assert_eq!(
                downscale(src.clone(), b),
                reference(&src, b),
                "{w}x{h} -> {b} alpha {alpha}"
            );
        }
    }
}
