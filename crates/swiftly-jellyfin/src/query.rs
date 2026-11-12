use url::Url;

/// Percent-encodes one query name or value the way `URLComponents.queryItems` does.
///
/// Left as they are: letters, digits and `- . _ ~ ! $ ' ( ) * + , / : ; ? @` (the characters of
/// `urlQueryAllowed` except `&` and `=`, which would end the item). Everything else, including
/// space, `|`, `&`, `=`, `#`, `%` and every non-ASCII byte, becomes `%XX` in upper case.
/// The `|` matters: the genres filter joins with it (JellyfinClient.swift:507).
pub fn encode_query_value(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for b in raw.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~!$'()*+,/:;?@".contains(&b) {
            out.push(char::from(b));
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// `baseURL.appendingPathComponent(path)` plus `queryItems` (JellyfinClient.swift:213-218),
/// as one address. The query keeps the order it was given in.
pub(crate) fn build_url(base: &Url, path: &str, query: &[(String, String)]) -> Option<Url> {
    let mut text = base.as_str().trim_end_matches('/').to_string();
    // The base may carry a query of its own in theory; the Swift code ignores that too.
    if let Some(i) = text.find('?') {
        text.truncate(i);
    }
    text.push('/');
    for (i, seg) in path.split('/').enumerate() {
        if i > 0 {
            text.push('/');
        }
        for b in seg.bytes() {
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

const SECRET: [&str; 10] = [
    "api_key",
    "ApiKey",
    "X-Emby-Token",
    "X-Plex-Token",
    "token",
    "secret",
    "Secret",
    "pw",
    "Pw",
    "password",
];

/// Percent-decoding of a query item name, as `URLQueryItem.name` reports it (`%61pi_key` is `api_key`;
/// `+` stays a plus). Bytes that are not UTF-8 become U+FFFD.
fn decoded_name(raw: &str) -> String {
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

/// The address for the log: the values of secret query items become `…`
/// (`URL.withoutSecret`, AddressSecret.swift:1-18). The rest stays readable. A secret name written
/// with escapes (`%61pi_key`) counts too: a server decodes it, so the token behind it is just as live
/// (F-oracle-R01).
pub fn without_secret(url: &Url) -> String {
    let Some(query) = url.query() else {
        return url.to_string();
    };
    let items: Vec<String> = query
        .split('&')
        .map(|item| {
            let name = item.split_once('=').map_or(item, |(n, _)| n);
            let decoded = decoded_name(name);
            // Foundation writes the replacement percent-encoded: `…` becomes `%E2%80%A6` (F-oracle-E03).
            // An item without `=` and a secret name is redacted too (`URLQueryItem` with a nil value, F-oracle-E03).
            if SECRET.contains(&decoded.as_str()) {
                format!("{decoded}=%E2%80%A6")
            } else {
                item.to_string()
            }
        })
        .collect();
    let mut out = url.clone();
    out.set_query(None);
    let mut text = out.to_string();
    text.push('?');
    text.push_str(&items.join("&"));
    text
}

/// The cache key of an image address: the address without the token item
/// (`ImageKey.of`, AddressSecret.swift:30-45), so a changed token does not make the
/// same picture a new one.
pub fn image_key(url: &Url) -> String {
    let Some(query) = url.query() else {
        return url.to_string();
    };
    let is_token = |item: &&str| {
        let name = decoded_name(item.split('=').next().unwrap_or_default());
        matches!(name.as_str(), "ApiKey" | "api_key" | "X-Plex-Token")
    };
    let all: Vec<&str> = query.split('&').collect();
    if !all.iter().any(is_token) {
        return url.to_string();
    }
    let kept: Vec<&str> = all.into_iter().filter(|i| !is_token(i)).collect();
    let mut out = url.clone();
    let joined = kept.join("&");
    out.set_query(if kept.is_empty() {
        None
    } else {
        Some(joined.as_str())
    });
    out.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    // AuthRequestTests.swift:253 AddressSecretTests
    #[test]
    fn blacks_out_api_key() {
        let url = Url::parse(
            "https://tv.example.de/Videos/abc/stream?static=true&api_key=GEHEIM123&mediaSourceId=xy",
        )
        .expect("url");
        let text = without_secret(&url);
        assert!(!text.contains("GEHEIM123"));
        assert!(text.contains("static=true"));
        assert!(text.contains("mediaSourceId=xy"));
        assert!(text.contains("/Videos/abc/stream"));
    }

    // F-oracle-R01: a secret name spelled with escapes is still a secret.
    #[test]
    fn blacks_out_escaped_secret_names() {
        let url = Url::parse("https://h.de/x?a=1&%61pi_key=GEHEIM&X%2DEmby%2DToken=GEHEIM2&%70w")
            .expect("url");
        let text = without_secret(&url);
        assert!(!text.contains("GEHEIM"), "{text}");
        assert_eq!(
            text,
            "https://h.de/x?a=1&api_key=%E2%80%A6&X-Emby-Token=%E2%80%A6&pw=%E2%80%A6"
        );
        // The cache key drops an escaped token name too; ordinary keys stay as they were.
        let key = image_key(&Url::parse("https://h.de/i?tag=t&%41piKey=GEHEIM").expect("url"));
        assert_eq!(key, "https://h.de/i?tag=t");
        let plain = Url::parse("https://h.de/i?tag=t%41&ApiKey=x").expect("url");
        assert_eq!(image_key(&plain), "https://h.de/i?tag=t%41");
    }

    #[test]
    fn blacks_out_quick_connect_secret() {
        let url = Url::parse("https://tv.example.de/QuickConnect/Connect?secret=ABC").expect("url");
        assert!(!without_secret(&url).contains("ABC"));
    }

    #[test]
    fn harmless_address_is_unchanged() {
        let url = Url::parse("https://tv.example.de/System/Info/Public").expect("url");
        assert_eq!(
            without_secret(&url),
            "https://tv.example.de/System/Info/Public"
        );
    }

    #[test]
    fn image_key_ignores_the_token() {
        let a = Url::parse("https://x.de/Items/1/Images/Primary?tag=a&ApiKey=T1&maxHeight=480")
            .expect("url");
        let b = Url::parse("https://x.de/Items/1/Images/Primary?tag=a&ApiKey=T2&maxHeight=480")
            .expect("url");
        assert_eq!(image_key(&a), image_key(&b));
        assert_eq!(
            image_key(&a),
            "https://x.de/Items/1/Images/Primary?tag=a&maxHeight=480"
        );
    }

    #[test]
    fn query_encoding() {
        assert_eq!(encode_query_value("Action|Adventure"), "Action%7CAdventure");
        assert_eq!(encode_query_value("a b&c=d"), "a%20b%26c%3Dd");
        assert_eq!(encode_query_value("Movie,Series"), "Movie,Series");
        assert_eq!(encode_query_value("Überraschung"), "%C3%9Cberraschung");
        assert_eq!(encode_query_value("a+b"), "a+b");
    }

    #[test]
    fn base_path_and_trailing_slash() {
        let q = vec![("a".to_string(), "1".to_string())];
        let with = Url::parse("https://x.de/jf/").expect("url");
        let without = Url::parse("https://x.de/jf").expect("url");
        let plain = Url::parse("https://x.de").expect("url");
        assert_eq!(
            build_url(&with, "Items", &q).expect("u").as_str(),
            "https://x.de/jf/Items?a=1"
        );
        assert_eq!(
            build_url(&without, "Items", &q).expect("u").as_str(),
            "https://x.de/jf/Items?a=1"
        );
        assert_eq!(
            build_url(&plain, "Items/1/Similar", &[])
                .expect("u")
                .as_str(),
            "https://x.de/Items/1/Similar"
        );
    }
}
