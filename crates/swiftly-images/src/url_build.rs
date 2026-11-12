//! `base.appendingPathComponent(path)` plus `URLComponents.queryItems`, as one address.
//!
//! `swiftly-jellyfin` has the same builder but keeps it crate-private; this is the same rule
//! on top of its public `encode_query_value`.

use swiftly_jellyfin::encode_query_value;
use url::Url;

pub(crate) fn build(base: &Url, path: &str, query: &[(&str, String)]) -> Option<Url> {
    let mut text = base.as_str().trim_end_matches('/').to_string();
    if let Some(i) = text.find('?') {
        text.truncate(i);
    }
    text.push('/');
    for (i, segment) in path.split('/').enumerate() {
        if i > 0 {
            text.push('/');
        }
        for b in segment.bytes() {
            if b.is_ascii_alphanumeric() || b"-._~!$&'()*+,;=:@".contains(&b) {
                text.push(char::from(b));
            } else {
                text.push_str(&format!("%{b:02X}"));
            }
        }
    }
    if !query.is_empty() {
        text.push('?');
        let items: Vec<String> = query
            .iter()
            .map(|(n, v)| format!("{}={}", encode_query_value(n), encode_query_value(v)))
            .collect();
        text.push_str(&items.join("&"));
    }
    Url::parse(&text).ok()
}
