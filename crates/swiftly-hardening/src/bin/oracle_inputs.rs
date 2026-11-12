//! Writes `oracle/<domain>.in.json` for every domain (deterministic).
#![allow(clippy::print_stdout)]

fn main() {
    // The inputs module is dev-facing; the generator needs the same crate, so it lives in the lib.
    let mut failed = false;
    for (domain, cases) in swiftly_hardening::inputs::all() {
        let n = cases.len();
        match swiftly_hardening::oracle::write_inputs(domain, cases) {
            Ok(()) => println!("oracle-inputs: {domain}: {n} cases"),
            Err(e) => {
                eprintln!("oracle-inputs: {domain}: {e}");
                failed = true;
            }
        }
    }
    if failed {
        std::process::exit(1);
    }
}
