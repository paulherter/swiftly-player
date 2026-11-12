// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! An 8-bit RGBA image and its PNG form.

use crate::geometry::Color;
use std::io::Write;
use std::path::Path;

/// An 8-bit RGBA image, rows top to bottom (alpha is 255 for rendered frames).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RgbaImage {
    /// Width in pixels.
    pub width: usize,
    /// Height in pixels.
    pub height: usize,
    /// `width * height * 4` bytes.
    pub pixels: Vec<u8>,
}

impl RgbaImage {
    /// An image of one colour.
    pub fn filled(width: usize, height: usize, c: Color) -> RgbaImage {
        let px = c
            .to_array()
            .map(|v| (v.clamp(0.0, 1.0) * 255.0 + 0.5) as u8);
        let pixels = (0..width * height).flat_map(|_| px).collect();
        RgbaImage {
            width,
            height,
            pixels,
        }
    }

    /// The four bytes of pixel `(x, y)`; zeros outside the image.
    pub fn pixel(&self, x: usize, y: usize) -> [u8; 4] {
        if x >= self.width || y >= self.height {
            return [0; 4];
        }
        let i = (y * self.width + x) * 4;
        [
            self.pixels[i],
            self.pixels[i + 1],
            self.pixels[i + 2],
            self.pixels[i + 3],
        ]
    }

    /// Encodes as PNG (8-bit RGBA).
    pub fn to_png(&self) -> Result<Vec<u8>, String> {
        let mut out = Vec::new();
        {
            let mut enc = png::Encoder::new(&mut out, self.width as u32, self.height as u32);
            enc.set_color(png::ColorType::Rgba);
            enc.set_depth(png::BitDepth::Eight);
            let mut w = enc.write_header().map_err(|e| e.to_string())?;
            w.write_image_data(&self.pixels)
                .map_err(|e| e.to_string())?;
        }
        Ok(out)
    }

    /// Writes the PNG to `path`.
    pub fn write_png(&self, path: &Path) -> Result<(), String> {
        let bytes = self.to_png()?;
        let mut f = std::fs::File::create(path).map_err(|e| e.to_string())?;
        f.write_all(&bytes).map_err(|e| e.to_string())
    }

    /// Decodes an 8-bit RGB or RGBA PNG.
    pub fn from_png(bytes: &[u8]) -> Result<RgbaImage, String> {
        let mut reader = png::Decoder::new(std::io::Cursor::new(bytes))
            .read_info()
            .map_err(|e| e.to_string())?;
        let mut buf = vec![0; reader.output_buffer_size().ok_or("image too large")?];
        let info = reader.next_frame(&mut buf).map_err(|e| e.to_string())?;
        buf.truncate(info.buffer_size());
        let (width, height) = (info.width as usize, info.height as usize);
        let pixels = match (info.color_type, info.bit_depth) {
            (png::ColorType::Rgba, png::BitDepth::Eight) => buf,
            (png::ColorType::Rgb, png::BitDepth::Eight) => buf
                .as_chunks::<3>()
                .0
                .iter()
                .flat_map(|p| [p[0], p[1], p[2], 255])
                .collect(),
            other => return Err(format!("unsupported PNG format {other:?}")),
        };
        Ok(RgbaImage {
            width,
            height,
            pixels,
        })
    }

    /// Reads a PNG file.
    pub fn read_png(path: &Path) -> Result<RgbaImage, String> {
        let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
        RgbaImage::from_png(&bytes)
    }

    /// Compares with `other` (same size). Returns `(max channel difference, share of pixels that differ in any channel)`.
    pub fn diff(&self, other: &RgbaImage) -> (u8, f64) {
        if (self.width, self.height) != (other.width, other.height) {
            return (255, 1.0);
        }
        let mut max = 0u8;
        let mut differing = 0usize;
        for (a, b) in self
            .pixels
            .as_chunks::<4>()
            .0
            .iter()
            .zip(other.pixels.as_chunks::<4>().0)
        {
            let d = a
                .iter()
                .zip(b)
                .map(|(x, y)| x.abs_diff(*y))
                .max()
                .unwrap_or(0);
            max = max.max(d);
            if d > 0 {
                differing += 1;
            }
        }
        (
            max,
            differing as f64 / (self.width * self.height).max(1) as f64,
        )
    }
}
