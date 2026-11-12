//! Differential oracle: compare the Rust output with what the Swift code produced for the same inputs.
//!
//! Files (all JSON) live in `crates/swiftly-hardening/oracle/`:
//! * `<domain>.in.json`    `{"domain": "...", "cases": [ ... ]}` written by `oracle-inputs`
//! * `<domain>.swift.json` `{"domain": "...", "results": [ ... ]}` written by `Tools/Oracle` (real Swift)
//! * `known.json`          `{"<domain>": {"<case index>": "finding id"}}` differences that are
//!   recorded as findings and accepted until decided (Swift bug).

use serde_json::Value;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

pub fn dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("oracle")
}

pub fn read(file: &str) -> Result<Value, String> {
    let path = dir().join(file);
    let text = fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))
}

pub fn write(file: &str, value: &Value) -> Result<(), String> {
    let path = dir().join(file);
    let text = serde_json::to_string(value).map_err(|e| e.to_string())?;
    fs::write(&path, text + "\n").map_err(|e| format!("{}: {e}", path.display()))
}

/// Write `<domain>.in.json` (used by the generator binary).
pub fn write_inputs(domain: &str, cases: Vec<Value>) -> Result<(), String> {
    let doc = serde_json::json!({ "domain": domain, "cases": cases });
    write(&format!("{domain}.in.json"), &doc)
}

/// JSON equality with a relative tolerance for numbers (Swift prints doubles with 17 digits,
/// Rust parses them back exactly, so the tolerance only absorbs `1e-9` library noise).
pub fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => match (x.as_f64(), y.as_f64()) {
            (Some(x), Some(y)) => (x - y).abs() <= 1e-9 * x.abs().max(y.abs()).max(1.0),
            _ => x == y,
        },
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(p, q)| same(p, q))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w)))
        }
        _ => a == b,
    }
}

/// One mismatch, ready for the findings list.
#[derive(Debug)]
pub struct Difference {
    pub index: usize,
    pub input: Value,
    pub swift: Value,
    pub rust: Value,
}

pub struct Report {
    pub domain: String,
    pub total: usize,
    pub accepted: Vec<(usize, String)>,
    pub open: Vec<Difference>,
}

fn known(domain: &str) -> BTreeMap<usize, String> {
    let mut map = BTreeMap::new();
    if let Ok(doc) = read("known.json")
        && let Some(entries) = doc.get(domain).and_then(Value::as_object)
    {
        for (k, v) in entries {
            if let (Ok(i), Some(id)) = (k.parse(), v.as_str()) {
                map.insert(i, id.to_owned());
            }
        }
    }
    map
}

/// Run `rust` over every recorded input and compare with the Swift result.
pub fn run(domain: &str, rust: impl Fn(&Value) -> Value) -> Result<Report, String> {
    let inputs = read(&format!("{domain}.in.json"))?;
    let expected = read(&format!("{domain}.swift.json"))?;
    let cases = inputs["cases"].as_array().ok_or("cases is not an array")?;
    let results = expected["results"]
        .as_array()
        .ok_or("results is not an array")?;
    if cases.len() != results.len() {
        return Err(format!(
            "{domain}: {} inputs but {} Swift results (regenerate with `cargo xtask hardening --regen-oracle`)",
            cases.len(),
            results.len()
        ));
    }
    let known = known(domain);
    let mut report = Report {
        domain: domain.to_owned(),
        total: cases.len(),
        accepted: vec![],
        open: vec![],
    };
    let dump = std::env::var_os("HARDENING_DUMP_ALL").is_some();
    let mut every: Vec<Value> = Vec::new();
    for (index, (case, swift)) in cases.iter().zip(results).enumerate() {
        let got = rust(case);
        if dump {
            every.push(got.clone());
            if index + 1 == cases.len() {
                let out = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target/hardening");
                let _ = fs::create_dir_all(&out);
                let _ = fs::write(
                    out.join(format!("dump-{domain}.json")),
                    serde_json::to_string(&every).unwrap_or_default(),
                );
            }
        }
        if same(&got, swift) {
            continue;
        }
        if let Some(id) = known.get(&index) {
            report.accepted.push((index, id.clone()));
        } else {
            report.open.push(Difference {
                index,
                input: case.clone(),
                swift: swift.clone(),
                rust: got,
            });
        }
    }
    Ok(report)
}

/// `run` plus the test verdict: panics with the first differences, and always writes the
/// full list to `target/hardening/oracle-<domain>.json` for the findings document.
pub fn assert_equal(domain: &str, rust: impl Fn(&Value) -> Value) {
    let report = match run(domain, rust) {
        Ok(r) => r,
        Err(e) => panic!("{e}"),
    };
    let out = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target/hardening");
    let _ = fs::create_dir_all(&out);
    let summary = serde_json::json!({
        "domain": report.domain,
        "total": report.total,
        "accepted": report.accepted.len(),
        "open": report.open.iter().map(|d| serde_json::json!({
            "index": d.index, "input": d.input, "swift": d.swift, "rust": d.rust
        })).collect::<Vec<_>>(),
    });
    let _ = fs::write(
        out.join(format!("oracle-{domain}.json")),
        serde_json::to_string_pretty(&summary).unwrap_or_default(),
    );
    if let Some(first) = report.open.first() {
        panic!(
            "{domain}: {} of {} cases differ (accepted: {}). First #{}:\n input: {}\n swift: {}\n rust:  {}",
            report.open.len(),
            report.total,
            report.accepted.len(),
            first.index,
            first.input,
            first.swift,
            first.rust
        );
    }
    println!(
        "oracle {domain}: {} cases equal ({} accepted differences)",
        report.total,
        report.accepted.len()
    );
}
