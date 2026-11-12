//! `cargo run --release -p swiftly-hardening --bin soak` (long runs: `HARDENING_SOAK_SECS=600`).
fn main() {
    let cfg = swiftly_hardening::soak::Config::from_env(60);
    let report = swiftly_hardening::soak::workload::run(&cfg);
    if report.verdict.problems.is_empty() {
        println!("soak: PASS");
    } else {
        for p in &report.verdict.problems {
            println!("soak: FAIL {p}");
        }
        std::process::exit(1);
    }
}
