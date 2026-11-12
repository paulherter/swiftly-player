//! Generates `src/catalog_data.rs` from the Apple localisation sources.
//!
//! ```text
//! cargo run -p swiftly-l10n --bin gen_catalog            # write the file
//! cargo run -p swiftly-l10n --bin gen_catalog -- --check # fail if it differs
//! cargo run -p swiftly-l10n --bin gen_catalog -- --report# list problems in the translations
//! ```
//! `--root <dir>` points at the repository root (default: two levels above this crate).

use std::path::PathBuf;
use std::process::ExitCode;
use swiftly_l10n::{Catalog, check, codegen, source};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let flag = |name: &str| args.iter().any(|a| a == name);
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let root = args
        .iter()
        .position(|a| a == "--root")
        .and_then(|i| args.get(i + 1))
        .map_or_else(|| manifest.join("../.."), PathBuf::from);
    let target = manifest.join("src/catalog_data.rs");

    let parsed = match source::load(&root) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("gen_catalog: {e}");
            return ExitCode::from(2);
        }
    };

    if flag("--report") {
        println!("source conflicts ({}):", parsed.conflicts.len());
        for c in &parsed.conflicts {
            println!("  {c}");
        }
        let findings = check::findings(Catalog::builtin());
        println!("translation findings ({}):", findings.len());
        for f in &findings {
            println!("  {f}");
        }
        return ExitCode::SUCCESS;
    }

    let code = codegen::generate(&parsed);
    if flag("--check") {
        return match std::fs::read_to_string(&target) {
            Ok(old) if old == code => {
                println!(
                    "catalog_data.rs is up to date ({} keys)",
                    parsed.merged.len()
                );
                ExitCode::SUCCESS
            }
            _ => {
                eprintln!(
                    "catalog_data.rs differs from the sources; run `cargo run -p swiftly-l10n --bin gen_catalog`"
                );
                ExitCode::FAILURE
            }
        };
    }
    if let Err(e) = std::fs::write(&target, code) {
        eprintln!("gen_catalog: {}: {e}", target.display());
        return ExitCode::from(2);
    }
    println!("wrote {} ({} keys)", target.display(), parsed.merged.len());
    ExitCode::SUCCESS
}
