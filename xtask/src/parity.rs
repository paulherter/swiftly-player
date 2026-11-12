//! `swiftui-parity`: the real SwiftUI screens (rendered offscreen by `Tests/SwiftUIParity`) against the Rust goldens.
//! One line per screen: mean abs diff, share within 8 levels, structural distance (1 - mean block SSIM on luma, in
//! percent); side-by-side PNGs (SwiftUI | Rust | heat map) go to `build/swiftui-parity/diff`. Worst first.

use crate::smoke::decode;
use std::path::{Path, PathBuf};
use std::process::Command;

pub struct Row {
    pub name: String,
    pub mean_abs: f64,
    pub within8: f64,
    /// 0 = identical structure, 100 = unrelated.
    pub structural: f64,
    /// Layout boxes: share of 16x16 blocks that hold content (luma spread) on both sides out of those that hold
    /// content on either side, in percent. 100 = the same blocks are busy.
    pub boxes: f64,
    /// Text positions: how well the horizontal ink profiles (strong edges per row) agree, in percent.
    pub rows: f64,
}

/// Blocks (16x16) with visible content: luma spread above a small threshold.
fn busy_blocks(l: &[f32], w: usize, h: usize) -> Vec<bool> {
    const BLOCK: usize = 16;
    let mut out = vec![];
    for by in (0..h.saturating_sub(BLOCK - 1)).step_by(BLOCK) {
        for bx in (0..w.saturating_sub(BLOCK - 1)).step_by(BLOCK) {
            let (mut lo, mut hi) = (255f32, 0f32);
            for y in by..by + BLOCK {
                for x in bx..bx + BLOCK {
                    lo = lo.min(l[y * w + x]);
                    hi = hi.max(l[y * w + x]);
                }
            }
            out.push(hi - lo > 24.0);
        }
    }
    out
}

/// Strong vertical-direction edges per pixel row, binned to 4 rows: where lines of text and tile edges lie.
fn row_profile(l: &[f32], w: usize, h: usize) -> Vec<f64> {
    let mut prof = vec![0f64; h.div_ceil(4)];
    for y in 0..h {
        let mut n = 0u32;
        for x in 1..w {
            n += u32::from((l[y * w + x] - l[y * w + x - 1]).abs() > 40.0);
        }
        prof[y / 4] += f64::from(n);
    }
    prof
}

fn luma(rgb: &[u8]) -> Vec<f32> {
    rgb.as_chunks::<3>()
        .0
        .iter()
        .map(|p| 0.299 * f32::from(p[0]) + 0.587 * f32::from(p[1]) + 0.114 * f32::from(p[2]))
        .collect()
}

/// Mean SSIM over non-overlapping 16x16 luma blocks.
fn ssim(a: &[f32], b: &[f32], w: usize, h: usize) -> f64 {
    const BLOCK: usize = 16;
    let (c1, c2) = ((0.01f64 * 255.0).powi(2), (0.03f64 * 255.0).powi(2));
    let (mut total, mut n) = (0.0, 0u32);
    for by in (0..h.saturating_sub(BLOCK - 1)).step_by(BLOCK) {
        for bx in (0..w.saturating_sub(BLOCK - 1)).step_by(BLOCK) {
            let (mut sa, mut sb, mut saa, mut sbb, mut sab) = (0f64, 0f64, 0f64, 0f64, 0f64);
            for y in by..by + BLOCK {
                for x in bx..bx + BLOCK {
                    let (p, q) = (f64::from(a[y * w + x]), f64::from(b[y * w + x]));
                    sa += p;
                    sb += q;
                    saa += p * p;
                    sbb += q * q;
                    sab += p * q;
                }
            }
            let k = (BLOCK * BLOCK) as f64;
            let (ma, mb) = (sa / k, sb / k);
            let (va, vb, cov) = (saa / k - ma * ma, sbb / k - mb * mb, sab / k - ma * mb);
            total += ((2.0 * ma * mb + c1) * (2.0 * cov + c2))
                / ((ma * ma + mb * mb + c1) * (va + vb + c2));
            n += 1;
        }
    }
    if n == 0 { 1.0 } else { total / f64::from(n) }
}

fn write_side_by_side(path: &Path, w: u32, h: u32, a: &[u8], b: &[u8]) -> Result<(), String> {
    let (w, h) = (w as usize, h as usize);
    let mut out = vec![0u8; w * 3 * h * 3];
    for y in 0..h {
        for x in 0..w {
            let i = (y * w + x) * 3;
            let d = (0..3)
                .map(|c| u32::from(a[i + c].abs_diff(b[i + c])))
                .max()
                .unwrap_or(0);
            let heat = [
                (d * 4).min(255) as u8,
                (d * 2).min(255) as u8,
                255 - (d * 4).min(255) as u8,
            ];
            for (panel, px) in [&a[i..i + 3], &b[i..i + 3], &heat[..]]
                .into_iter()
                .enumerate()
            {
                let o = (y * w * 3 + panel * w + x) * 3;
                out[o..o + 3].copy_from_slice(px);
            }
        }
    }
    let file = std::fs::File::create(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), (w * 3) as u32, h as u32);
    enc.set_color(png::ColorType::Rgb);
    enc.set_depth(png::BitDepth::Eight);
    enc.write_header()
        .and_then(|mut wr| wr.write_image_data(&out))
        .map_err(|e| e.to_string())
}

/// Compares every `<name>.png` in `swift_dir` that has a golden of the same name; worst structural distance first.
pub fn compare_all(root: &Path, swift_dir: &Path, write_diffs: bool) -> Result<Vec<Row>, String> {
    let golden_dir = root.join("crates/swiftly-ui/tests/golden");
    let mut rows = vec![];
    let Ok(read) = std::fs::read_dir(swift_dir) else {
        return Ok(rows);
    };
    for entry in read.flatten() {
        let path = entry.path();
        if path.extension().is_none_or(|e| e != "png") {
            continue;
        }
        let name = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or_default()
            .to_owned();
        let golden = golden_dir.join(format!("{name}.png"));
        if !golden.exists() {
            continue;
        }
        let (wa, ha, a) = decode(&path)?;
        let (wb, hb, b) = decode(&golden)?;
        if (wa, ha) != (wb, hb) {
            return Err(format!("{name}: size {wa}x{ha} vs {wb}x{hb}"));
        }
        let (mut sum, mut close) = (0u64, 0u64);
        for (x, y) in a.as_chunks::<3>().0.iter().zip(b.as_chunks::<3>().0) {
            let d = [0, 1, 2].map(|i| u64::from(x[i].abs_diff(y[i])));
            sum += d.iter().sum::<u64>();
            close += u64::from(d.iter().all(|v| *v <= 8));
        }
        let px = (u64::from(wa) * u64::from(ha)).max(1);
        let structural = (1.0 - ssim(&luma(&a), &luma(&b), wa as usize, ha as usize)) * 100.0;
        if write_diffs {
            let dir = swift_dir.join("diff");
            std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
            write_side_by_side(&dir.join(format!("{name}.png")), wa, ha, &a, &b)?;
        }
        let (la, lb) = (luma(&a), luma(&b));
        let (ba, bb) = (
            busy_blocks(&la, wa as usize, ha as usize),
            busy_blocks(&lb, wa as usize, ha as usize),
        );
        let both = ba.iter().zip(&bb).filter(|(x, y)| **x && **y).count();
        let either = ba.iter().zip(&bb).filter(|(x, y)| **x || **y).count();
        let (pa, pb) = (
            row_profile(&la, wa as usize, ha as usize),
            row_profile(&lb, wa as usize, ha as usize),
        );
        let total: f64 = pa.iter().chain(&pb).sum();
        let gap: f64 = pa.iter().zip(&pb).map(|(x, y)| (x - y).abs()).sum();
        rows.push(Row {
            name,
            mean_abs: sum as f64 / (px * 3) as f64,
            within8: close as f64 / px as f64,
            structural,
            boxes: if either == 0 {
                100.0
            } else {
                both as f64 * 100.0 / either as f64
            },
            rows: if total == 0.0 {
                100.0
            } else {
                (1.0 - gap / total) * 100.0
            },
        });
    }
    rows.sort_by(|x, y| y.structural.total_cmp(&x.structural));
    Ok(rows)
}

/// The SwiftUI renders: `build/swiftui-parity`, or the folder in `SWIFTUI_PARITY_DIR` (renders made on the Mac and
/// compared on another machine).
fn swift_dir(root: &Path) -> PathBuf {
    std::env::var_os("SWIFTUI_PARITY_DIR")
        .map_or_else(|| root.join("build/swiftui-parity"), PathBuf::from)
}

/// Informational line for `check-all`.
pub fn summary(root: &Path) -> String {
    match compare_all(root, &swift_dir(root), false) {
        Ok(rows) if !rows.is_empty() => format!(
            "swiftui-parity: {} screens, worst {} {:.1}",
            rows.len(),
            rows[0].name,
            rows[0].structural
        ),
        Ok(_) => "swiftui-parity: not run (no renders; run cargo xtask swiftui-parity)".to_owned(),
        Err(e) => format!("swiftui-parity: not run ({e})"),
    }
}

/// `swiftui-parity [--no-render]`: renders with xcodebuild (Mac only, hosted test, no device), then compares.
pub fn run(root: &Path, args: &[String]) -> Result<(), String> {
    let out = swift_dir(root);
    if !args.iter().any(|a| a == "--no-render") {
        let _ = std::fs::remove_dir_all(&out);
        // The Mac sources are compiled into an unhosted test bundle (no app is started), built with xcodebuild and run
        // with the plain `xctest` runner.
        let dev = "/Applications/Xcode.app/Contents/Developer";
        let spec = Command::new("python3")
            .current_dir(root)
            .arg("Werkzeuge/parity-project.py")
            .output()
            .map_err(|e| format!("python3: {e}"))?;
        if !spec.status.success() {
            return Err(format!(
                "parity-project.py failed:\n{}",
                String::from_utf8_lossy(&spec.stderr)
            ));
        }
        let gen_ = Command::new("xcodegen")
            .current_dir(root)
            .args([
                "generate",
                "--spec",
                "build/parity/spec.yml",
                "--project",
                "build/parity",
                "--project-root",
                ".",
            ])
            .output()
            .map_err(|e| format!("xcodegen: {e}"))?;
        if !gen_.status.success() {
            return Err(format!(
                "xcodegen failed:\n{}",
                String::from_utf8_lossy(&gen_.stderr)
            ));
        }
        let st = Command::new("xcodebuild")
            .current_dir(root)
            .args([
                "-quiet",
                "build-for-testing",
                "-project",
                "build/parity/SwiftlyParity.xcodeproj",
                "-scheme",
                "SwiftlyParityTests",
                "-destination",
                "platform=macOS",
                "-jobs",
                "3",
                "-derivedDataPath",
                "build/DD-parity",
                "CODE_SIGNING_ALLOWED=NO",
            ])
            .env("DEVELOPER_DIR", dev)
            .output()
            .map_err(|e| format!("xcodebuild: {e}"))?;
        if !st.status.success() {
            let text = String::from_utf8_lossy(&st.stdout);
            let tail: Vec<&str> = text
                .lines()
                .filter(|l| l.contains("error:") || l.contains("failed"))
                .take(15)
                .collect();
            return Err(format!("render build failed:\n{}", tail.join("\n")));
        }
        let run = Command::new("xcrun")
            .current_dir(root)
            .args([
                "xctest",
                "build/DD-parity/Build/Products/Debug/SwiftlyParityTests.xctest",
            ])
            .env("DEVELOPER_DIR", dev)
            .env("SWIFTUI_PARITY_OUT", &out)
            .output()
            .map_err(|e| format!("xctest: {e}"))?;
        if !run.status.success() {
            let text = String::from_utf8_lossy(&run.stdout);
            let tail: Vec<&str> = text
                .lines()
                .filter(|l| l.contains("error:") || l.contains("failed"))
                .take(15)
                .collect();
            return Err(format!("render failed:\n{}", tail.join("\n")));
        }
    }
    let rows = compare_all(root, &out, true)?;
    if let Some(i) = args.iter().position(|a| a == "--shots") {
        let dir = PathBuf::from(args.get(i + 1).ok_or("--shots needs a directory")?);
        write_shots(
            root,
            &out,
            &dir,
            &[
                "home_desktop_initial",
                "library_desktop_initial",
                "detail_desktop_initial",
            ],
        )?;
    }
    if rows.is_empty() {
        return Err(format!("no renders with a golden in {}", out.display()));
    }
    for r in &rows {
        println!(
            "{:<28} mean abs {:>6.2} | within 8 {:>5.1} % | structure {:>5.1} | boxes {:>5.1} % | text rows {:>5.1} %",
            r.name,
            r.mean_abs,
            r.within8 * 100.0,
            r.structural,
            r.boxes,
            r.rows
        );
    }
    println!(
        "swiftui-parity: {} screens, worst {} {:.1} (diffs: {})",
        rows.len(),
        rows[0].name,
        rows[0].structural,
        out.join("diff").display()
    );
    Ok(())
}

/// SwiftUI on the left, Rust on the right, each halved (box filter), for people to look at.
fn write_shots(root: &Path, swift_dir: &Path, dir: &Path, names: &[&str]) -> Result<(), String> {
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    for name in names {
        let (w, h, a) = decode(&swift_dir.join(format!("{name}.png")))?;
        let (_, _, b) = decode(&root.join(format!("crates/swiftly-ui/tests/golden/{name}.png")))?;
        let (ow, oh) = ((w / 2) as usize, (h / 2) as usize);
        let mut out = vec![0u8; ow * 2 * oh * 3];
        for (panel, img) in [&a, &b].into_iter().enumerate() {
            for y in 0..oh {
                for x in 0..ow {
                    for c in 0..3 {
                        let at = |dx: usize, dy: usize| {
                            u32::from(img[((2 * y + dy) * w as usize + 2 * x + dx) * 3 + c])
                        };
                        out[(y * ow * 2 + panel * ow + x) * 3 + c] =
                            ((at(0, 0) + at(1, 0) + at(0, 1) + at(1, 1)) / 4) as u8;
                    }
                }
            }
        }
        let path = dir.join(format!("{}.png", name.trim_end_matches("_desktop_initial")));
        let file = std::fs::File::create(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        let mut enc = png::Encoder::new(std::io::BufWriter::new(file), (ow * 2) as u32, oh as u32);
        enc.set_color(png::ColorType::Rgb);
        enc.set_depth(png::BitDepth::Eight);
        enc.write_header()
            .and_then(|mut wr| wr.write_image_data(&out))
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}
