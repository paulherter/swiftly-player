//! Supporter keys `SS2-...` (and the older `SS1-...`), checked offline. Behind the Cargo feature
//! `supporter-key`: the Play build must not carry the check at all (the key is the direct build's
//! way to support the app; Play uses purchases). Same rules as `SupporterKeyCheck.kt` and
//! `SupportKeyKit` (`SupporterKey.read` / `verify`).
//!
//! `SS2` before Base32 (RFC 4648, no padding): version (2), flags (bit 0 test), app (1 Swiftly,
//! 2 Sequence Studio), plan (1 monthly, 2 lifetime), purchase day (2 bytes, days since 1970, big
//! endian), expiry day (2 bytes, 0 = never; monthly keys only), licence ID (16 bytes), name (UTF-8,
//! 0 to 48 bytes), then 64 bytes Ed25519 signature over "SS2" + everything before it.
//! `SS1`: version (1), flags, app, issue day (2), order id (8), name, signature over "SS1" + payload.

use ed25519_dalek::{Signature, Verifier, VerifyingKey};

/// `SupporterKey.publicKeyBase64` (production). The Kotlin and Swift tests pin the same value.
pub const PUBLIC_KEY_BASE64: &str = "90hxOk72gFaCS0s3n2OxKoTYBUGvrzw3liCshhfRU2o=";
/// `SupporterKey.testPublicKeyBase64`: only for tests.
pub const TEST_PUBLIC_KEY_BASE64: &str = "iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w=";
/// App number of Swiftly inside a key.
pub const APP_SWIFTLY: u8 = 1;

const SIGNATURE: usize = 64;
const MAX_NAME: usize = 48;
const MAX_TEXT: usize = 400;
const DAY_MS: i64 = 86_400_000;

/// Why a key was refused. `as_str` is the word the Kotlin and Swift code use.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Failure {
    BadPublicKey,
    Empty,
    TooLong,
    WrongPrefix,
    BadEncoding,
    TooShort,
    BadSignature,
    UnsupportedVersion,
    UnknownApp,
    WrongApp,
    TestKey,
    BadName,
    UnknownPlan,
    Expired,
}

impl Failure {
    /// The shared failure word.
    pub fn as_str(self) -> &'static str {
        match self {
            Failure::BadPublicKey => "badPublicKey",
            Failure::Empty => "empty",
            Failure::TooLong => "tooLong",
            Failure::WrongPrefix => "wrongPrefix",
            Failure::BadEncoding => "badEncoding",
            Failure::TooShort => "tooShort",
            Failure::BadSignature => "badSignature",
            Failure::UnsupportedVersion => "unsupportedVersion",
            Failure::UnknownApp => "unknownApp",
            Failure::WrongApp => "wrongApp",
            Failure::TestKey => "testKey",
            Failure::BadName => "badName",
            Failure::UnknownPlan => "unknownPlan",
            Failure::Expired => "expired",
        }
    }
}

/// What a key says once its signature is checked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct License {
    pub app: u8,
    /// `"monthly"` or `"lifetime"`.
    pub plan: &'static str,
    pub issued_at_ms: i64,
    pub expires_at_ms: Option<i64>,
    /// Hex licence ID (SS1: the 8-byte order id).
    pub id: String,
    pub name: Option<String>,
    pub is_test: bool,
    pub is_legacy: bool,
}

impl License {
    /// Whether the key still counts at `now_ms`.
    pub fn is_active(&self, now_ms: i64) -> bool {
        self.expires_at_ms.is_none_or(|e| now_ms < e)
    }
}

/// Decodes a base64 public key; `None` unless it is exactly 32 bytes.
pub fn decode_public_key(base64: &str) -> Option<[u8; 32]> {
    let mut out = Vec::new();
    let (mut buffer, mut bits) = (0u32, 0u32);
    let body = base64.trim_end_matches('=');
    for c in body.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        } as u32;
        buffer = (buffer << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buffer >> bits) as u8);
            buffer &= (1 << bits) - 1;
        }
    }
    out.try_into().ok()
}

/// The production public key.
pub fn public_key() -> [u8; 32] {
    decode_public_key(PUBLIC_KEY_BASE64).unwrap_or([0; 32])
}

/// Checks a pasted key against the production key, including the expiry of monthly keys.
pub fn verify_now(text: &str, now_ms: i64) -> Result<License, Failure> {
    verify(text, &public_key(), APP_SWIFTLY, false, now_ms)
}

/// Checks a pasted key, including the expiry of monthly keys.
pub fn verify(
    text: &str,
    public_key: &[u8],
    app: u8,
    allow_test: bool,
    now_ms: i64,
) -> Result<License, Failure> {
    let license = read(text, public_key, app, allow_test)?;
    if license.is_active(now_ms) {
        Ok(license)
    } else {
        Err(Failure::Expired)
    }
}

/// Signature and layout, but not the expiry: an expired monthly key is still read, so it can be renewed.
pub fn read(text: &str, public_key: &[u8], app: u8, allow_test: bool) -> Result<License, Failure> {
    let key: [u8; 32] = public_key.try_into().map_err(|_| Failure::BadPublicKey)?;
    // Exactly what PHP's trim() removes.
    let trimmed = text.trim_matches(|c| matches!(c, ' ' | '\t' | '\n' | '\r' | '\0' | '\u{b}'));
    if trimmed.is_empty() {
        return Err(Failure::Empty);
    }
    let bytes = trimmed.as_bytes();
    if bytes.len() > MAX_TEXT {
        return Err(Failure::TooLong);
    }
    let prefix: Vec<u8> = bytes.iter().take(4).map(u8::to_ascii_uppercase).collect();
    let version = match prefix.as_slice() {
        b"SS1-" => 1u8,
        b"SS2-" => 2,
        _ => return Err(Failure::WrongPrefix),
    };
    let head = if version == 1 { 13 } else { 24 };
    let raw = base32_decode(&bytes[4..]).ok_or(Failure::BadEncoding)?;
    if raw.len() < head + SIGNATURE {
        return Err(Failure::TooShort);
    }
    let (payload, signature) = raw.split_at(raw.len() - SIGNATURE);
    let mut message = if version == 1 {
        b"SS1".to_vec()
    } else {
        b"SS2".to_vec()
    };
    message.extend_from_slice(payload);
    if !signature_ok(signature, &message, &key) {
        return Err(Failure::BadSignature);
    }
    if payload[0] != version {
        return Err(Failure::UnsupportedVersion);
    }
    let key_app = payload[2];
    if key_app != 1 && key_app != 2 {
        return Err(Failure::UnknownApp);
    }
    if key_app != app {
        return Err(Failure::WrongApp);
    }
    let is_test = payload[1] & 1 != 0;
    if is_test && !allow_test {
        return Err(Failure::TestKey);
    }
    let name_bytes = &payload[head..];
    let name = std::str::from_utf8(name_bytes).map_err(|_| Failure::BadName)?;
    if name_bytes.len() > MAX_NAME {
        return Err(Failure::BadName);
    }
    let day = |at: usize| (i64::from(payload[at]) << 8) | i64::from(payload[at + 1]);
    let hex = |from: usize, to: usize| {
        payload[from..to]
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>()
    };
    let name = (!name.is_empty()).then(|| name.to_owned());
    if version == 1 {
        return Ok(License {
            app: key_app,
            plan: "lifetime",
            issued_at_ms: day(3) * DAY_MS,
            expires_at_ms: None,
            id: hex(5, 13),
            name,
            is_test,
            is_legacy: true,
        });
    }
    let plan = match payload[3] {
        1 => "monthly",
        2 => "lifetime",
        _ => return Err(Failure::UnknownPlan),
    };
    let expiry_day = day(6);
    // Monthly keys always expire, lifetime keys never; anything else is not a shop key.
    if (plan == "monthly") != (expiry_day > 0) {
        return Err(Failure::UnknownPlan);
    }
    Ok(License {
        app: key_app,
        plan,
        issued_at_ms: day(4) * DAY_MS,
        expires_at_ms: (expiry_day > 0).then(|| expiry_day * DAY_MS),
        id: hex(8, 24),
        name,
        is_test,
        is_legacy: false,
    })
}

/// Ed25519 (RFC 8032, non-strict): canonical `S`, `A` on the curve, `[S]B - [k]A` encodes to `R`.
fn signature_ok(signature: &[u8], message: &[u8], key: &[u8; 32]) -> bool {
    let (Ok(sig), Ok(vk)) = (
        Signature::from_slice(signature),
        VerifyingKey::from_bytes(key),
    ) else {
        return false;
    };
    vk.verify(message, &sig).is_ok()
}

/// RFC 4648 Base32 without padding; skips dashes and whitespace, refuses non-zero trailing bits.
pub fn base32_decode(text: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let (mut buffer, mut bits) = (0u32, 0u32);
    for &b in text {
        if matches!(b, b'-' | b' ' | b'\n' | b'\r' | b'\t') {
            continue;
        }
        let value = match b.to_ascii_uppercase() {
            u @ b'A'..=b'Z' => u - b'A',
            u @ b'2'..=b'7' => u - b'2' + 26,
            _ => return None,
        } as u32;
        buffer = (buffer << 5) | value;
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            out.push((buffer >> bits) as u8);
        }
        buffer &= (1 << bits) - 1;
    }
    if bits >= 5 || buffer != 0 {
        return None;
    }
    Some(out)
}
