//! The answer format of the Kotlin `Bridge.http` call: `S<status>\n`, header lines `name: value\n`, an empty line, the body;
//! or `E<kind>\n<text>` (`net:<NSURLError code>`, `cert`, `cancelled`). Pure, so the host tests cover it.

use swiftly_net::{CertificateReason, ErrorKind, HttpResponse};

/// Parses the answer bytes of `Bridge.http`.
pub fn parse_answer(bytes: &[u8]) -> Result<HttpResponse, ErrorKind> {
    let line_end = bytes
        .iter()
        .position(|&b| b == b'\n')
        .unwrap_or(bytes.len());
    let first = String::from_utf8_lossy(&bytes[..line_end]).into_owned();
    if let Some(kind) = first.strip_prefix('E') {
        return Err(match kind {
            "cert" => ErrorKind::Certificate(CertificateReason::Otherwise),
            "cancelled" => ErrorKind::Cancelled,
            k => ErrorKind::Network {
                code: k
                    .strip_prefix("net:")
                    .and_then(|c| c.parse().ok())
                    .unwrap_or(-1005),
            },
        });
    }
    let status: u16 = first
        .strip_prefix('S')
        .and_then(|s| s.parse().ok())
        .ok_or(ErrorKind::Network { code: -1005 })?;
    let mut headers = Vec::new();
    let mut at = line_end + 1;
    let mut url = None;
    while at < bytes.len() {
        let end = bytes[at..]
            .iter()
            .position(|&b| b == b'\n')
            .map_or(bytes.len(), |p| at + p);
        let line = String::from_utf8_lossy(&bytes[at..end]).into_owned();
        at = (end + 1).min(bytes.len());
        if line.is_empty() {
            break;
        }
        if let Some((n, v)) = line.split_once(": ") {
            if n == "x-final-url" {
                url = url::Url::parse(v).ok();
            } else {
                headers.push((n.to_owned(), v.to_owned()));
            }
        }
    }
    Ok(HttpResponse {
        status,
        headers,
        body: bytes[at.min(bytes.len())..].to_vec(),
        url,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_status_headers_body() {
        let r = parse_answer(
            b"S200\nContent-Type: application/json\nx-final-url: http://h/a\n\n{\"a\":1}",
        )
        .unwrap_or_else(|_| HttpResponse::new(0, ""));
        assert_eq!(r.status, 200);
        assert_eq!(r.header("content-type"), Some("application/json"));
        assert_eq!(r.body, b"{\"a\":1}");
        assert_eq!(r.url.map(|u| u.to_string()), Some("http://h/a".to_owned()));
    }

    #[test]
    fn body_may_hold_blank_lines() {
        let r = parse_answer(b"S404\n\na\n\nb").unwrap_or_else(|_| HttpResponse::new(0, ""));
        assert_eq!((r.status, r.body), (404, b"a\n\nb".to_vec()));
    }

    #[test]
    fn failures_map_to_kinds() {
        assert_eq!(
            parse_answer(b"Enet:-1001\ntimeout").err(),
            Some(ErrorKind::Network { code: -1001 })
        );
        assert_eq!(
            parse_answer(b"Ecert\nx").err(),
            Some(ErrorKind::Certificate(CertificateReason::Otherwise))
        );
        assert_eq!(
            parse_answer(b"garbage").err(),
            Some(ErrorKind::Network { code: -1005 })
        );
    }
}
