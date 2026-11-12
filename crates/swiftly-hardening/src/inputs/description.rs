//! Domain `description` (Description.swift): `Description.readable` on generated and hostile markup,
//! plus `Item.description`, `Item.daysDate`, `Item.tmdbId` through a decoded `Item`.
//! Read by `Domain_Description.swift` and `tests/oracle_description.rs`.
use crate::Rng;
use serde_json::{Value, json};

const FRAGMENTS: &[&str] = &[
    "<br>",
    "<BR/>",
    "<br />",
    "<bR\t/>",
    "<br\u{000B}>",
    "<br\u{0085}>",
    "<br\u{00A0}/>",
    "<br\n>",
    "<br/ >",
    "<br //>",
    "<brx>",
    "<b r>",
    "<br",
    "</p>",
    "</P >",
    "</div>",
    "</DIV\n>",
    "</h1>",
    "</H6>",
    "</h7>",
    "</h>",
    "</p",
    "</pre>",
    "<p>",
    "<div class=\"a\">",
    "<li>",
    "<LI class='x'>",
    "<li",
    "<lib>",
    "<li<b>",
    "</li>",
    "<ul>",
    "</ul>",
    "<i>",
    "</i>",
    "<b>x</b>",
    "<a href=\"x>y\">",
    "<a",
    "<3",
    "5 < 6",
    "7 > 3",
    "<>",
    "</>",
    "< b>",
    "<é>",
    "<\u{FF22}r>",
    "<1a>",
    "<a<b>",
    "<a>>",
    "<!-- c -->",
    "<script>x</script>",
    "&amp;",
    "&lt;",
    "&gt;",
    "&quot;",
    "&apos;",
    "&#39;",
    "&nbsp;",
    "&#8211;",
    "&#x2013;",
    "&#X41;",
    "&#xd800;",
    "&#xDFFF;",
    "&#1114112;",
    "&#x10FFFF;",
    "&#x110000;",
    "&#0;",
    "&#1a;",
    "&#xGG;",
    "&#1234567;",
    "&#x;",
    "&#;",
    "&#x1F600;",
    "&#65",
    "&amp;lt;",
    "&amp;#39;",
    "&#38;amp;",
    "&AMP;",
    "&Lt;",
    "&amp;amp;",
    "&&amp;",
    "&#xA0;",
    "&#160;",
    "&#8239;",
    "&#8199;",
    "&#13;&#10;",
    " ",
    "  ",
    "\t",
    " \t ",
    "\n",
    "\r\n",
    "\r",
    "\n\n\n",
    "\n\n\n\n\n",
    " \n",
    "\t\n",
    "\u{00A0}",
    "\u{202F}",
    "\u{2007}",
    "\u{3000}",
    "\u{200B}",
    "\u{FEFF}",
    "\u{180E}",
    "\u{000B}",
    "\u{000C}",
    "\u{0085}",
    "\u{2028}",
    "\u{2029}",
    "\u{1680}",
    "\u{2003}",
    "\u{205F}",
    "a",
    "Hello",
    "world",
    "é",
    "e\u{301}",
    "日本",
    "🙂",
    "👨‍👩‍👧",
    "\u{301}",
    "\u{FE0F}",
    "\u{1F3FD}",
    "\u{200D}",
    "\u{200C}",
    "\u{0308}",
    "\u{0903}",
    "\u{20DD}",
    "\u{0300}\u{0301}",
    "\u{1160}",
    "\u{FE00}",
    "\u{0}",
    "•",
    "\r\n\u{301}",
    "&lt;\u{301}",
    "<br>\u{301}",
    "\"",
    "'",
    ";",
    "#",
    "&",
];

/// The JSON reader on the Swift side drops a byte order mark at the start of a string (measured:
/// `JSONSerialization` turns "\u{FEFF}x" into "x"); keep it out of the first position so the
/// recorded input is what Swift really saw.
fn unbom(s: &str) -> String {
    s.trim_start_matches('\u{FEFF}').to_owned()
}

pub fn readable() -> Vec<Value> {
    let mut rng = Rng::new(0x4445_5343);
    let mut out = vec![json!({"op": "readable", "text": ""})];
    for f in FRAGMENTS {
        out.push(json!({"op": "readable", "text": unbom(f)}));
    }
    for _ in 0..4200 {
        let n = rng.range(1, 12);
        let mut s = String::new();
        for _ in 0..n {
            s.push_str(rng.pick(FRAGMENTS));
        }
        // Cut somewhere (half a tag, half an entity).
        if rng.chance(15) {
            let chars: Vec<char> = s.chars().collect();
            let keep = rng.range(0, chars.len() as i64) as usize;
            s = chars[..keep].iter().collect();
        }
        out.push(json!({"op": "readable", "text": unbom(&s)}));
    }
    out
}

pub fn item() -> Vec<Value> {
    let mut rng = Rng::new(0x4445_5349);
    let dates = [
        "2020-05-17T00:00:00.0000000Z",
        "2020-5-7",
        "1999-12-31",
        "2020-05-1",
        "",
        "abcdefghij",
        "2020-ab-17",
        "-2020-05-1",
        "+2020-+5-+7",
        "2020--05-17",
        "2020-05-17-",
        "١٩٩٩-١٢-٣١",
        "20201231",
        "0000-00-00",
        "99999999-1-1",
        "2020-05-1\u{301}",
        "2020-05-17\u{301}",
        "2020-05-\u{301}17",
        "2020-05-17\r\n",
        "2020-5-17-9",
        "1-2-3-4-5-6",
        "----------",
        "1-1-1-1-1-",
        "12-34-5678",
        "2020-13-45",
        "-1-2-3-4-5",
        "2020-05-17 00:00",
        "٢٠٢٠-05-17",
        "2020-0-0",
        "+-2020-1-1",
        "  2020-5-1",
        "2020-05-1\u{200B}",
        "🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂",
        "2020/05/17",
    ];
    let tmdb = [
        "603",
        "+603",
        "-1",
        "0603",
        "6 03",
        "",
        "abc",
        "99999999999999999999",
        "9223372036854775807",
        "9223372036854775808",
        "٣",
        "1e3",
        " 5",
        "5 ",
        "+",
        "-",
        "--5",
        "0",
        "-0",
        "12\u{301}",
        "１２",
    ];
    let mut out = Vec::new();
    for date in dates {
        for t in [None, Some(tmdb[0])] {
            let mut c = json!({"op": "item", "premiere": date});
            if let Some(t) = t {
                c["tmdb"] = json!(t);
            }
            out.push(c);
        }
    }
    for t in tmdb {
        out.push(json!({"op": "item", "tmdb": t}));
    }
    for _ in 0..600 {
        let mut c = json!({"op": "item"});
        if rng.chance(70) {
            let mut s = String::new();
            for _ in 0..rng.range(0, 6) {
                s.push_str(rng.pick(FRAGMENTS));
            }
            c["overview"] = json!(unbom(&s));
        }
        if rng.chance(50) {
            c["premiere"] = json!(rng.pick(&dates));
        }
        if rng.chance(50) {
            c["tmdb"] = json!(rng.pick(&tmdb));
        }
        out.push(c);
    }
    out
}

pub fn cases() -> Vec<Value> {
    let mut v = readable();
    v.extend(item());
    v
}
