//! Domain `log_redaction` (`LogRing.swift`: `LogRedaction.text`): credentials in free text. Hand-picked lines
//! (tokens, Authorization header values, `user:pass@` addresses, names inside longer words, odd whitespace) plus
//! random sequences of pieces. Read by `Domain_LogRedaction.swift` and `tests/oracle_log_redaction.rs`.
use crate::Rng;
use serde_json::{Value, json};

const PIECES: &[&str] = &[
    "api_key",
    "ApiKey",
    "APIKEY",
    "x-emby-token",
    "X-MediaBrowser-Token",
    "Token",
    "token",
    "accesstoken",
    "access_token",
    "secret",
    "pw",
    "Pw",
    "Password",
    "mytoken",
    "ätoken",
    "_pw",
    "pw_",
    "xtoken",
    "=",
    ":",
    " = ",
    ": ",
    "=\"",
    "\"",
    "\"abc def\"",
    "'",
    ",",
    ";",
    ")",
    "&",
    "&&",
    " ",
    "  ",
    "\t",
    "\n",
    "\u{00A0}",
    "\u{2003}",
    "\u{3000}",
    "abc",
    "0123456789abcdef",
    "geheim",
    "…",
    "é",
    "🙂",
    "http://",
    "https://",
    "ftp://",
    "ws://",
    "a.b://",
    "1x://",
    "nutzer:passwort@",
    "u:p@",
    ":@",
    "a@b",
    "@",
    "/",
    "/path",
    "server.example",
    "10.0.0.5:8096",
    "?static=true",
    "mediaSourceId=x",
    "Authorization: MediaBrowser Client=\"Swiftly\", Token=\"geheim123\"",
    "Bearer ",
    "\u{2028}",
];

const HAND: &[&str] = &[
    "",
    "plain text without secrets",
    "http://10.0.0.5:8096/Videos/abc/stream?static=true&ApiKey=0123456789abcdef&mediaSourceId=x",
    "Authorization: MediaBrowser Client=\"Swiftly\", Device=\"iPhone\", Token=\"geheim123\"",
    "X-Emby-Token: geheim456",
    "x-emby-token=abc&x-mediabrowser-token=def",
    "https://nutzer:passwort@server.example/",
    "https://nutzer:pass@wort@server.example/path",
    "http://:pw@host/ http://user:@host/",
    "mytoken=abc token=abc xtoken: abc _token=1",
    "PW = abc;rest",
    "password=a b",
    "Password = \"a b\" end",
    "secret=\"unclosed",
    "token=,x api_key=) pw=\"\"",
    "accesstoken=1 access_token=2 access-token=3",
    "libvlc: open 'http://h/v.mkv?api_key=KEY&x=1' failed",
    "{\"token\":\"abc\",\"pw\": \"def\"}",
    "Token=a\u{00A0}b pw=a\u{3000}b",
    "ätoken=1 éapi_key=2",
];

pub fn cases() -> Vec<Value> {
    let mut rng = Rng::new(0x4C4F_4752);
    let mut out: Vec<Value> = HAND.iter().map(|t| json!({"text": t})).collect();
    for _ in 0..3000 {
        let n = rng.range(1, 9);
        let text: String = (0..n).map(|_| *rng.pick(PIECES)).collect();
        out.push(json!({"text": text}));
    }
    out
}
