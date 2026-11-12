import Foundation
import JellyfinKit

// Domain log_redaction (LogRing.swift: LogRedaction.text).
// Generator: crates/swiftly-hardening/src/inputs/log_redaction.rs.
// Rust: swiftly_support::log_ring::redact (swiftly_uniffi::log_redact).

let domainLogRedaction = Domain("log_redaction") { raw in
    let c = try srDict(raw)
    return ["s": LogRedaction.text(srStr(c["text"]) ?? "")]
}
