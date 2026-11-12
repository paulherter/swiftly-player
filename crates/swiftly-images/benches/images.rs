#![allow(clippy::unwrap_used, clippy::expect_used, missing_docs)]
//! Image path benchmarks (`cargo bench -p swiftly-images`): decode per format and size, scaling, keys, caches and
//! the 200-tile scroll scenario over a local fixture transport. Pictures are synthetic but photo-like
//! (smooth light, texture, noise) so JPEG sizes and decode work are close to real posters.

use std::sync::{Arc, OnceLock};
use swiftly_images::decode::{Decoded, decode, downscale};
use swiftly_images::fixture::FixtureImages;
use swiftly_images::{Device, ImageLoader, Limits, MemoryImageCache, Priority, RustDecoder, Slot};
use swiftly_net::{ErrorKind, HttpRequest, HttpResponse, HttpTransport};
use url::Url;

fn main() {
    divan::main();
}

/// Photo-like RGB pixels.
fn photo(w: u32, h: u32, seed: u32) -> Vec<u8> {
    let mut s = seed.wrapping_mul(2_654_435_761).max(1);
    let mut out = Vec::with_capacity((w * h * 3) as usize);
    for y in 0..h {
        for x in 0..w {
            s ^= s << 13;
            s ^= s >> 17;
            s ^= s << 5;
            let noise = (s & 15) as f32 - 8.0;
            let fx = x as f32 / w as f32;
            let fy = y as f32 / h as f32;
            let l = 110.0
                + 70.0 * (fx * 6.0 + seed as f32).sin() * (fy * 4.0).cos()
                + 40.0 * (fy - 0.5);
            let tex = 12.0 * ((x as f32 * 0.35).sin() * (y as f32 * 0.29).sin());
            out.push((l + tex + noise + 20.0 * fx).clamp(0.0, 255.0) as u8);
            out.push((l * 0.9 + tex + noise + 30.0 * fy).clamp(0.0, 255.0) as u8);
            out.push((l * 0.7 + tex + noise + 40.0 * (1.0 - fx)).clamp(0.0, 255.0) as u8);
        }
    }
    out
}

fn jpeg(w: u32, h: u32, q: u8) -> Vec<u8> {
    let mut out = Vec::new();
    let enc = jpeg_encoder::Encoder::new(&mut out, q);
    enc.encode(
        &photo(w, h, 7),
        w as u16,
        h as u16,
        jpeg_encoder::ColorType::Rgb,
    )
    .unwrap();
    out
}

fn png_bytes(w: u32, h: u32) -> Vec<u8> {
    let rgb = photo(w, h, 3);
    let mut out = Vec::new();
    let mut e = png::Encoder::new(&mut out, w, h);
    e.set_color(png::ColorType::Rgb);
    e.set_depth(png::BitDepth::Eight);
    e.set_compression(png::Compression::Fast);
    e.write_header().unwrap().write_image_data(&rgb).unwrap();
    out
}

fn webp_bytes(w: u32, h: u32) -> Vec<u8> {
    let rgb = photo(w, h, 5);
    let mut out = Vec::new();
    image_webp::WebPEncoder::new(&mut out)
        .encode(&rgb, w, h, image_webp::ColorType::Rgb8)
        .unwrap();
    out
}

fn cached<T>(cell: &'static OnceLock<T>, f: impl FnOnce() -> T) -> &'static T {
    cell.get_or_init(f)
}

static J_ORIG: OnceLock<Vec<u8>> = OnceLock::new(); // 2000x3000 original poster
static J_SERVER: OnceLock<Vec<u8>> = OnceLock::new(); // 600x900 server-resized poster
static J_TILE: OnceLock<Vec<u8>> = OnceLock::new(); // 232x348
static J_BACK: OnceLock<Vec<u8>> = OnceLock::new(); // 1920x1080 backdrop
static P_SERVER: OnceLock<Vec<u8>> = OnceLock::new();
static W_SERVER: OnceLock<Vec<u8>> = OnceLock::new();

#[divan::bench(args = ["orig_2000x3000", "server_600x900", "tile_232x348", "backdrop_1920x1080"])]
fn decode_jpeg(b: divan::Bencher, which: &str) {
    let (data, border) = match which {
        "orig_2000x3000" => (cached(&J_ORIG, || jpeg(2000, 3000, 85)), 928),
        "server_600x900" => (cached(&J_SERVER, || jpeg(600, 900, 90)), 928),
        "tile_232x348" => (cached(&J_TILE, || jpeg(232, 348, 90)), 928),
        _ => (cached(&J_BACK, || jpeg(1920, 1080, 85)), 1600),
    };
    b.bench_local(|| decode(divan::black_box(data), border).unwrap());
}

#[divan::bench]
fn decode_png_600x900(b: divan::Bencher) {
    let d = cached(&P_SERVER, || png_bytes(600, 900));
    b.bench_local(|| decode(divan::black_box(d), 928).unwrap());
}

#[divan::bench]
fn decode_webp_600x900(b: divan::Bencher) {
    let d = cached(&W_SERVER, || webp_bytes(600, 900));
    b.bench_local(|| decode(divan::black_box(d), 928).unwrap());
}

fn rgba(w: u32, h: u32) -> Decoded {
    let rgb = photo(w, h, 9);
    let mut v = Vec::with_capacity((w * h * 4) as usize);
    for p in rgb.as_chunks::<3>().0 {
        v.extend_from_slice(&[p[0], p[1], p[2], 255]);
    }
    Decoded {
        width: w,
        height: h,
        rgba: v,
    }
}

#[divan::bench(args = [(2000, 3000, 928), (600, 900, 348), (1920, 1080, 640)])]
fn resize(b: divan::Bencher, a: (u32, u32, u32)) {
    let src = rgba(a.0, a.1);
    b.with_inputs(|| src.clone())
        .bench_local_values(|s| downscale(s, a.2));
}

#[divan::bench(args = [(2000, 3000, 928), (600, 900, 348), (1920, 1080, 640)])]
fn resize_fast_simd(b: divan::Bencher, a: (u32, u32, u32)) {
    let src = rgba(a.0, a.1);
    b.with_inputs(|| src.clone())
        .bench_local_values(|s| swiftly_images::decode::downscale_fast(s, a.2));
}

#[divan::bench]
fn mip_chain_928x1392(b: divan::Bencher) {
    let src = rgba(928, 1392);
    b.bench_local(|| swiftly_images::decode::mip_chain(divan::black_box(&src), 12));
}

fn urls(n: usize) -> Vec<Url> {
    (0..n)
        .map(|i| {
            Url::parse(&format!(
                "https://jf.example.org:8920/Items/{i:032x}/Images/Primary?fillHeight=696&fillWidth=464&quality=90&tag=abcdef0123456789&ApiKey=secretsecretsecret"
            ))
            .unwrap()
        })
        .collect()
}

#[divan::bench]
fn key_hash_name(b: divan::Bencher) {
    let u = urls(1);
    b.bench_local(|| swiftly_images::name(divan::black_box(&u[0])));
}

#[divan::bench]
fn image_key_cold(b: divan::Bencher) {
    let u = urls(1);
    b.bench_local(|| swiftly_images::image_key(divan::black_box(&u[0])));
}

#[divan::bench(args = [200, 2000])]
fn memory_hit(b: divan::Bencher, n: usize) {
    let u = urls(n);
    let mut c: MemoryImageCache<u32> = MemoryImageCache::new(usize::MAX);
    let keys: Vec<String> = u.iter().map(|x| c.key_for(x)).collect();
    for k in &keys {
        c.insert(k, 1, 100);
    }
    let mut i = 0;
    b.bench_local(|| {
        i = (i + 7) % n;
        c.get(&keys[i]).copied()
    });
}

#[divan::bench(args = [200, 2000])]
fn memory_insert_evicting(b: divan::Bencher, n: usize) {
    let u = urls(n * 2);
    let mut c: MemoryImageCache<u32> = MemoryImageCache::new(n * 100);
    let keys: Vec<String> = u.iter().map(|x| c.key_for(x)).collect();
    let mut i = 0;
    b.bench_local(|| {
        i = (i + 1) % keys.len();
        c.insert(&keys[i], 1, 100);
    });
}

#[divan::bench]
fn memory_key_for_hit(b: divan::Bencher) {
    let u = urls(1);
    let mut c: MemoryImageCache<u32> = MemoryImageCache::new(1);
    c.key_for(&u[0]);
    b.bench_local(|| c.key_for(divan::black_box(&u[0])));
}

/// Serves a prebuilt body for every request (no encoding in the timed part).
struct Canned(Vec<u8>);
impl HttpTransport for Canned {
    async fn send(&self, _request: HttpRequest) -> Result<HttpResponse, ErrorKind> {
        Ok(HttpResponse::new(200, self.0.clone()))
    }
}

/// 200 tiles asked at once as a grid scrolls in, loaded to the end and polled.
fn scroll<T: HttpTransport + 'static>(t: Arc<T>, border: u32) -> usize {
    scroll_with(t, border, Limits::for_device(Device::Phone))
}

fn scroll_with<T: HttpTransport + 'static>(t: Arc<T>, border: u32, limits: Limits) -> usize {
    let l = ImageLoader::build(t, None, 512 * 1024 * 1024, limits, Arc::new(RustDecoder));
    let u = urls(200);
    for x in &u {
        l.request(x, border, Priority::Visible);
    }
    l.settle();
    l.poll();
    u.iter()
        .filter(|x| matches!(l.request(x, border, Priority::Visible), Slot::Ready(_)))
        .count()
}

#[divan::bench(sample_count = 5)]
fn scroll_200_png_fixture(b: divan::Bencher) {
    b.bench_local(|| assert_eq!(scroll(Arc::new(FixtureImages), 400), 200));
}

#[divan::bench(sample_count = 5)]
fn scroll_200_jpeg_600x900(b: divan::Bencher) {
    let t = Arc::new(Canned(cached(&J_SERVER, || jpeg(600, 900, 90)).clone()));
    b.bench_local(|| assert_eq!(scroll(Arc::clone(&t), 696), 200));
}

#[divan::bench(sample_count = 5)]
fn scroll_200_jpeg_2000x3000(b: divan::Bencher) {
    let t = Arc::new(Canned(cached(&J_ORIG, || jpeg(2000, 3000, 85)).clone()));
    b.bench_local(|| assert_eq!(scroll(Arc::clone(&t), 696), 200));
}

/// Which decode parallelism is fastest for a 200-tile scroll (cores on this machine: see the log header).
#[divan::bench(args = [1, 2, 3, 4, 6], sample_count = 5)]
fn scroll_200_jpeg_600x900_decode_slots(b: divan::Bencher, decode: usize) {
    let t = Arc::new(Canned(cached(&J_SERVER, || jpeg(600, 900, 90)).clone()));
    b.bench_local(|| {
        assert_eq!(
            scroll_with(Arc::clone(&t), 696, Limits { fetch: 4, decode }),
            200
        )
    });
}
