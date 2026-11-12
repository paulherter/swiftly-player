//! `ImageKey` (AddressSecret.swift) and `ImageStoreKey.swift`: under which name an image is
//! cached. **The formats must stay byte-identical** so disk caches written by the Swift app
//! stay valid; `tests/golden.rs` pins them against output of the compiled Swift functions.

use url::Url;

/// Under which name an image is cached in memory: the address without the access token
/// (`ApiKey`, `api_key`, `X-Plex-Token`), so an account switch does not make the same poster a
/// new image. The host stays (it lives for the process only); `tag` stays too.
///
/// This is `swiftly_jellyfin::image_key`, plus one case it does not cover: when the token was
/// the only query item, Swift's `URLComponents` leaves an empty query behind (`…/i?`).
pub fn image_key(url: &Url) -> String {
    let key = swiftly_jellyfin::image_key(url);
    if url.query().is_some()
        && let Ok(mut parsed) = Url::parse(&key)
        && parsed.query().is_none()
    {
        parsed.set_query(Some(""));
        return parsed.to_string();
    }
    key
}

/// The key under which an image lies on disk: no scheme, host, port or credentials, only path,
/// query and fragment. `None` without a non-empty `tag` item (case-insensitive name): without
/// Jellyfin's fingerprint a stale image would never be noticed, so it does not go to disk.
pub fn store_key(url: &Url) -> Option<String> {
    let key = Url::parse(&image_key(url)).ok()?;
    let has_tag = key.query()?.split('&').any(|item| {
        let (name, value) = item.split_once('=').unwrap_or((item, ""));
        decode(name).to_lowercase() == "tag" && !value.is_empty()
    });
    if !has_tag {
        return None;
    }
    let mut out = key.path().to_string();
    if let Some(query) = key.query() {
        out.push('?');
        out.push_str(query);
    }
    if let Some(fragment) = key.fragment() {
        out.push('#');
        out.push_str(fragment);
    }
    Some(out)
}

/// Percent-decoding of a query name (`URLQueryItem.name`).
fn decode(raw: &str) -> String {
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && let Some(hex) = raw.get(i + 1..i + 3)
            && let Ok(byte) = u8::from_str_radix(hex, 16)
        {
            out.push(byte);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}
