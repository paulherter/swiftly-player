#![allow(clippy::unwrap_used, clippy::expect_used)]
//! Correctness under bad input and concurrency: damaged and hostile files, wrong statuses, tile identity after
//! eviction and cancel, one fetch for many askers, EXIF, CMYK, 16-bit, huge canvases.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use swiftly_images::decode::{
    DecodeError, Decoded, MAX_PIXELS, PixelDecoder, RustDecoder, decode, downscale, downscale_fast,
    mip_chain, premultiplied,
};
use swiftly_images::fixture::{self, FixtureImages};
use swiftly_images::{Device, ImageLoader, LoadError, MemoryPlate, Priority, Slot};
use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, HttpTransport};
use url::Url;

fn url(id: &str) -> Url {
    Url::parse(&format!(
        "http://fixture.test/Items/{id}/Images/Primary?tag=t&ApiKey=secret"
    ))
    .unwrap()
}

fn photo_rgb(w: u32, h: u32) -> Vec<u8> {
    let mut v = Vec::new();
    for y in 0..h {
        for x in 0..w {
            v.extend_from_slice(&[
                (x * 255 / w) as u8,
                (y * 255 / h) as u8,
                ((x + y) % 256) as u8,
            ]);
        }
    }
    v
}

fn jpeg(w: u32, h: u32) -> Vec<u8> {
    let mut out = Vec::new();
    jpeg_encoder::Encoder::new(&mut out, 90)
        .encode(
            &photo_rgb(w, h),
            w as u16,
            h as u16,
            jpeg_encoder::ColorType::Rgb,
        )
        .unwrap();
    out
}

/// Inserts an EXIF APP1 segment with the given orientation right after the SOI marker.
fn with_orientation(jpg: &[u8], o: u16) -> Vec<u8> {
    let mut tiff = b"MM\0\x2A\0\0\0\x08".to_vec();
    tiff.extend_from_slice(&[0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1]);
    tiff.extend_from_slice(&o.to_be_bytes());
    tiff.extend_from_slice(&[0, 0, 0, 0, 0, 0]);
    let mut seg = b"Exif\0\0".to_vec();
    seg.extend_from_slice(&tiff);
    let mut out = vec![0xFF, 0xD8, 0xFF, 0xE1];
    out.extend_from_slice(&((seg.len() + 2) as u16).to_be_bytes());
    out.extend_from_slice(&seg);
    out.extend_from_slice(&jpg[2..]);
    out
}

#[test]
fn truncated_and_flipped_files_fail_cleanly_for_every_format() {
    let png = fixture::png("x", 64, 48);
    let jpg = jpeg(64, 48);
    for (name, full) in [("png", png), ("jpeg", jpg)] {
        for cut in [0, 1, 3, 8, 20, full.len() / 2, full.len() - 1] {
            // Must not panic; a short prefix is an error, a lucky long one may still decode.
            let _ = decode(&full[..cut], 100);
        }
        let mut bad = full.clone();
        for i in (0..bad.len()).step_by(7) {
            bad[i] ^= 0x5A;
        }
        let _ = decode(&bad, 100);
        assert!(
            decode(&full[..full.len() / 3], 100).is_err(),
            "{name} truncated to a third must be an error"
        );
    }
    assert_eq!(decode(b"", 100), Err(DecodeError::Unsupported));
    assert!(decode(b"RIFF....WEBPxxxx", 100).is_err());
}

#[test]
fn a_small_file_declaring_a_huge_canvas_is_refused_before_allocating() {
    // PNG header only: 60000 x 60000 RGBA would be 14 GB.
    let mut png = vec![
        0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, b'I', b'H', b'D', b'R',
    ];
    png.extend_from_slice(&60_000u32.to_be_bytes());
    png.extend_from_slice(&60_000u32.to_be_bytes());
    png.extend_from_slice(&[8, 6, 0, 0, 0]);
    png.extend_from_slice(&[0, 0, 0, 0]);
    let started = std::time::Instant::now();
    let r = decode(&png, 100);
    assert!(r.is_err());
    assert!(started.elapsed().as_millis() < 500);
    const { assert!(MAX_PIXELS <= 100_000_000) };
}

#[test]
fn exif_orientation_turns_the_picture_and_swaps_the_sides() {
    let base = jpeg(48, 32);
    let plain = decode(&base, 1000).unwrap();
    assert_eq!((plain.width, plain.height), (48, 32));
    for o in 1u16..=8 {
        let d = decode(&with_orientation(&base, o), 1000).unwrap();
        let swapped = o >= 5;
        assert_eq!(
            (d.width, d.height),
            if swapped { (32, 48) } else { (48, 32) },
            "orientation {o}"
        );
    }
    // 6 = turn 90 clockwise: the plain picture's top-left pixel ends up top-right.
    let d = decode(&with_orientation(&base, 6), 1000).unwrap();
    let tl = &plain.rgba[0..4];
    let tr = &d.rgba[(d.width as usize - 1) * 4..d.width as usize * 4];
    assert_eq!(tl, tr);
}

#[test]
fn cmyk_jpeg_either_decodes_or_fails_without_panicking() {
    let mut out = Vec::new();
    let w = 32u32;
    let h = 24u32;
    let mut cmyk = Vec::new();
    for y in 0..h {
        for x in 0..w {
            cmyk.extend_from_slice(&[(x * 8) as u8, (y * 10) as u8, 40, 0]);
        }
    }
    jpeg_encoder::Encoder::new(&mut out, 90)
        .encode(&cmyk, w as u16, h as u16, jpeg_encoder::ColorType::Cmyk)
        .unwrap();
    match decode(&out, 100) {
        Ok(d) => assert_eq!((d.width, d.height, d.rgba.len()), (32, 24, 32 * 24 * 4)),
        Err(e) => assert!(matches!(
            e,
            DecodeError::Corrupt(_) | DecodeError::Unsupported
        )),
    }
}

#[test]
fn sixteen_bit_png_and_gray_alpha_become_8_bit_rgba() {
    let (w, h) = (16u32, 8u32);
    let mut out = Vec::new();
    let mut e = png::Encoder::new(&mut out, w, h);
    e.set_color(png::ColorType::Rgba);
    e.set_depth(png::BitDepth::Sixteen);
    let mut data = Vec::new();
    for _ in 0..w * h {
        data.extend_from_slice(&[0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00, 0xFF, 0xFF]);
    }
    e.write_header().unwrap().write_image_data(&data).unwrap();
    let d = decode(&out, 100).unwrap();
    assert_eq!(&d.rgba[..4], &[255, 128, 0, 255]);

    let mut out = Vec::new();
    let mut e = png::Encoder::new(&mut out, 4, 4);
    e.set_color(png::ColorType::GrayscaleAlpha);
    e.set_depth(png::BitDepth::Eight);
    e.write_header()
        .unwrap()
        .write_image_data(&[200, 128].repeat(16))
        .unwrap();
    let d = decode(&out, 100).unwrap();
    assert_eq!(&d.rgba[..4], &[200, 200, 200, 128]);
}

#[test]
fn simd_scaler_stays_close_to_the_integer_reference() {
    let d = decode(&fixture::png("ref", 640, 360), 1000).unwrap();
    for border in [320, 200, 100, 64] {
        let fast = downscale_fast(d.clone(), border);
        let slow = downscale(d.clone(), border);
        assert_eq!((fast.width, fast.height), (slow.width, slow.height));
        let worst = fast
            .rgba
            .iter()
            .zip(&slow.rgba)
            .map(|(a, b)| a.abs_diff(*b))
            .max()
            .unwrap();
        let mean = fast
            .rgba
            .iter()
            .zip(&slow.rgba)
            .map(|(a, b)| u64::from(a.abs_diff(*b)))
            .sum::<u64>() as f64
            / fast.rgba.len() as f64;
        assert!(
            worst <= 12 && mean < 1.0,
            "border {border}: worst {worst}, mean {mean}"
        );
    }
}

#[test]
fn transparent_pixels_do_not_bleed_colour_when_scaled() {
    let (w, h) = (64u32, 64u32);
    let mut rgba = Vec::new();
    for x in 0..w * h {
        // Left half opaque red, right half fully transparent with a green colour that must not leak.
        if x % w < w / 2 {
            rgba.extend_from_slice(&[255, 0, 0, 255])
        } else {
            rgba.extend_from_slice(&[0, 255, 0, 0])
        }
    }
    let small = downscale_fast(
        Decoded {
            width: w,
            height: h,
            rgba,
        },
        8,
    );
    let px = &small.rgba[(3 * 8) * 4..(3 * 8) * 4 + 4];
    assert!(px[0] > 250 && px[1] < 5, "{px:?}");
}

#[test]
fn mip_chain_halves_down_to_one_pixel_and_is_premultiplied() {
    let src = Decoded {
        width: 5,
        height: 3,
        rgba: [200, 100, 50, 128].repeat(15),
    };
    let chain = mip_chain(&src, 8);
    let dims: Vec<_> = chain.iter().map(|m| (m.width, m.height)).collect();
    assert_eq!(dims, vec![(5, 3), (3, 2), (2, 1), (1, 1)]);
    assert_eq!(&premultiplied(&src).rgba[..4], &[100, 50, 25, 128]);
    for m in &chain[1..] {
        let p = &m.rgba[..4];
        assert!(p[0].abs_diff(100) <= 1 && p[3].abs_diff(128) <= 1, "{p:?}");
    }
}

#[test]
fn rust_decoder_is_a_pixel_decoder() {
    let d: &dyn PixelDecoder = &RustDecoder;
    let img = d.decode(&fixture::png("t", 100, 50), 40).unwrap();
    assert_eq!((img.width, img.height), (40, 20));
}

/// Answers a fixed status for every request.
struct Status(u16);
impl HttpTransport for Status {
    async fn send(&self, _r: HttpRequest) -> Result<HttpResponse, ErrorKind> {
        Ok(HttpResponse::new(self.0, ""))
    }
}

#[test]
fn not_found_and_redirect_statuses_fail_the_tile_without_decoding() {
    for code in [404u16, 301, 302, 500] {
        let l = ImageLoader::new(Arc::new(Status(code)), None, Device::Phone);
        let u = url("s");
        l.request(&u, 100, Priority::Visible);
        l.settle();
        l.poll();
        assert!(
            matches!(l.request(&u, 100, Priority::Visible), Slot::Failed(LoadError::Status(c)) if c == code)
        );
        assert_eq!(l.stats().decodes, 0);
    }
}

/// Counts requests and holds each answer a moment so askers overlap.
struct Counting(Arc<AtomicUsize>);
impl HttpTransport for Counting {
    async fn send(&self, r: HttpRequest) -> Result<HttpResponse, ErrorKind> {
        self.0.fetch_add(1, Ordering::SeqCst);
        std::thread::sleep(std::time::Duration::from_millis(30));
        FixtureImages.send(r).await
    }
}

#[test]
fn many_threads_asking_for_one_address_cause_one_fetch_and_one_decode() {
    let hits = Arc::new(AtomicUsize::new(0));
    let l = ImageLoader::new(Arc::new(Counting(Arc::clone(&hits))), None, Device::Mac);
    let u = url("same");
    let threads: Vec<_> = (0..32)
        .map(|_| {
            let (l, u) = (l.clone(), u.clone());
            std::thread::spawn(move || {
                for _ in 0..20 {
                    l.request(&u, 200, Priority::Visible);
                }
            })
        })
        .collect();
    for t in threads {
        t.join().unwrap();
    }
    l.settle();
    l.poll();
    assert_eq!(hits.load(Ordering::SeqCst), 1);
    assert_eq!(l.stats().decodes, 1);
    assert!(matches!(
        l.request(&u, 200, Priority::Visible),
        Slot::Ready(_)
    ));
}

#[test]
fn after_eviction_and_cancel_every_tile_still_shows_only_its_own_picture() {
    // Budget for about 6 pictures at 100 x 150 while 120 different ones stream through, a third of them cancelled.
    let l = ImageLoader::with_budget(Arc::new(FixtureImages), None, 6 * 100 * 150 * 4);
    let ids: Vec<String> = (0..120).map(|i| format!("tile{i}")).collect();
    for (n, id) in ids.iter().enumerate() {
        let u = url(id);
        l.request(&u, 150, Priority::Visible);
        if n % 3 == 0 {
            l.cancel(&u);
        }
        if n % 10 == 9 {
            l.settle();
            l.poll();
        }
    }
    l.settle();
    l.poll();
    let mut ready = 0;
    for id in &ids {
        if let Some(img) = l.cached(&url(id)) {
            let want =
                decode(&fixture::png(id, fixture::POSTER.0, fixture::POSTER.1), 150).unwrap();
            assert_eq!(*img, want, "{id} shows foreign pixels");
            ready += 1;
        }
    }
    assert!((1..=7).contains(&ready), "ready {ready}");
    let (count, bytes) = l.memory_use();
    assert!(bytes <= 6 * 100 * 150 * 4 + 1 && count <= 7);
}

#[test]
fn a_cancelled_then_revived_request_still_ends_with_its_own_picture() {
    let l = ImageLoader::new(
        Arc::new(Counting(Arc::new(AtomicUsize::new(0)))),
        Some(Arc::new(MemoryPlate::new(1 << 24))),
        Device::Mac,
    );
    let a = url("alpha");
    let b = url("beta");
    l.request(&a, 200, Priority::Visible);
    l.cancel(&a);
    l.request(&b, 200, Priority::Visible);
    l.request(&a, 200, Priority::Visible);
    l.settle();
    l.poll();
    let ia = l.cached(&a).unwrap();
    let ib = l.cached(&b).unwrap();
    assert_eq!(*ia, decode(&fixture::png("alpha", 232, 348), 200).unwrap());
    assert_eq!(*ib, decode(&fixture::png("beta", 232, 348), 200).unwrap());
}
