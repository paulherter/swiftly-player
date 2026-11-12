//! A subtitle file read into cues, so the app can draw the text itself
//! (`JK/SubtitleCues.swift`). Reads SRT and WebVTT; markup (`<i>`, `{\an8}`, ASS overrides) is
//! dropped, the saved look decides. Pure: text in, cues out; the time is passed to the lookup.

/// One line of text shown from `start` to `end` (seconds).
#[derive(Debug, Clone, PartialEq)]
pub struct SubtitleCue {
    /// Start in seconds.
    pub start: f64,
    /// End in seconds.
    pub end: f64,
    /// Text, lines joined by `\n`.
    pub text: String,
}

impl SubtitleCue {
    /// Builds a cue.
    pub fn new(start: f64, end: f64, text: &str) -> Self {
        Self {
            start,
            end,
            text: text.to_owned(),
        }
    }
}

/// The cues of one file, sorted by start.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct SubtitleCues {
    cues: Vec<SubtitleCue>,
    /// `latest_end[i]` is the largest end among `cues[0..=i]`; lets a lookup stop walking back
    /// as soon as no earlier cue can still be showing.
    latest_end: Vec<f64>,
}

/// The longest subtitle file read (a real SRT is well under 1 MiB): a hostile server cannot make the parser copy and
/// split hundreds of megabytes. Longer text is cut at a character boundary.
const MAX_TEXT_BYTES: usize = 8 * 1024 * 1024;

fn capped(raw: &str) -> &str {
    if raw.len() <= MAX_TEXT_BYTES {
        return raw;
    }
    let mut end = MAX_TEXT_BYTES;
    while !raw.is_char_boundary(end) {
        end -= 1;
    }
    raw.get(..end).unwrap_or("")
}

impl SubtitleCues {
    /// Sorted by start; the file's order is kept for equal starts.
    pub fn new(mut cues: Vec<SubtitleCue>) -> Self {
        cues.sort_by(|a, b| a.start.total_cmp(&b.start));
        let mut running = f64::NEG_INFINITY;
        let latest_end = cues
            .iter()
            .map(|c| {
                running = running.max(c.end);
                running
            })
            .collect();
        Self { cues, latest_end }
    }

    /// The cues in order.
    pub fn cues(&self) -> &[SubtitleCue] {
        &self.cues
    }

    /// No cue at all.
    pub fn is_empty(&self) -> bool {
        self.cues.is_empty()
    }

    /// The text to show at `seconds`: every cue that covers it, one under the other.
    pub fn text_at(&self, seconds: f64) -> Option<String> {
        // Index after the last cue that starts at or before `seconds`.
        let low = self.cues.partition_point(|c| c.start <= seconds);
        let mut found: Vec<&str> = Vec::new();
        let mut position = low;
        while position > 0 && self.latest_end[position - 1] > seconds {
            position -= 1;
            if self.cues[position].end > seconds {
                found.push(&self.cues[position].text);
            }
        }
        if found.is_empty() {
            None
        } else {
            found.reverse();
            Some(found.join("\n"))
        }
    }

    /// Reads an SRT or WebVTT file; blocks that do not parse are skipped.
    pub fn parse(raw: &str) -> Self {
        let raw = capped(raw);
        let text = raw.strip_prefix('\u{FEFF}').unwrap_or(raw);
        let text = text.replace("\r\n", "\n").replace('\r', "\n");
        // A "blank" line holding spaces still ends a block; otherwise the next cue is lost.
        let pieces: Vec<&str> = text.split('\n').collect();
        let last = pieces.len() - 1;
        let text = pieces
            .iter()
            .enumerate()
            .map(|(i, line)| {
                let blank = !line.is_empty() && line.chars().all(|c| c == ' ' || c == '\t');
                if blank && i > 0 && i < last { "" } else { line }
            })
            .collect::<Vec<_>>()
            .join("\n");
        let mut cues = Vec::new();
        for block in text.split("\n\n") {
            let lines: Vec<&str> = block.split('\n').collect();
            let Some(arrow) = lines.iter().position(|l| l.contains("-->")) else {
                continue;
            };
            let parts: Vec<&str> = lines[arrow].split("-->").collect();
            if parts.len() != 2 {
                continue;
            }
            let Some(start) = seconds(parts[0]) else {
                continue;
            };
            // WebVTT puts cue settings after the end time ("... line:90%").
            let end_word = parts[1].split_whitespace().next().unwrap_or("");
            let Some(end) = seconds(end_word) else {
                continue;
            };
            let body = lines[arrow + 1..]
                .iter()
                .map(|l| clean(l))
                .filter(|l| !l.is_empty())
                .collect::<Vec<_>>()
                .join("\n");
            if body.is_empty() || end <= start {
                continue;
            }
            cues.push(SubtitleCue {
                start,
                end,
                text: body,
            });
        }
        Self::new(cues)
    }
}

/// `00:01:02,500`, `00:01:02.500`, `01:02.500`.
fn seconds(raw: &str) -> Option<f64> {
    let text = raw.trim().replace(',', ".");
    let parts: Vec<&str> = text.split(':').filter(|p| !p.is_empty()).collect();
    if !(2..=3).contains(&parts.len()) {
        return None;
    }
    let mut total = 0.0;
    for part in parts {
        let value: f64 = part.parse().ok()?;
        total = total * 60.0 + value;
    }
    Some(total)
}

/// Drops `<...>` and `{...}`, turns a literal `\N` into a line break, decodes four entities.
fn clean(line: &str) -> String {
    let no_tags = strip_between(line, '<', '>');
    let no_braces = strip_between(&no_tags, '{', '}');
    let mut result = String::with_capacity(no_braces.len());
    let mut chars = no_braces.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\' && matches!(chars.peek(), Some('N' | 'n')) {
            chars.next();
            result.push('\n');
        } else {
            result.push(c);
        }
    }
    let result = result
        .replace("&nbsp;", " ")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&");
    result.trim_matches([' ', '\t']).to_owned()
}

/// Removes `open ... close` spans (an unclosed `open` stays, as a regex would leave it).
fn strip_between(text: &str, open: char, close: char) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(i) = rest.find(open) {
        match rest[i + open.len_utf8()..].find(close) {
            Some(j) => {
                out.push_str(&rest[..i]);
                rest = &rest[i + open.len_utf8() + j + close.len_utf8()..];
            }
            None => break,
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn oversized_input_is_cut_at_a_character_boundary_and_still_parses() {
        // Two-byte characters make the byte cap fall inside a character.
        let cue = "1\n00:00:01,000 --> 00:00:02,000\nhello\n\n";
        let filler = "\u{00e9}".repeat(MAX_TEXT_BYTES / 2 + 10);
        let cues = SubtitleCues::parse(&format!("{cue}{filler}"));
        assert_eq!(cues.text_at(1.5).as_deref(), Some("hello"));
        assert!(capped(&filler).len() <= MAX_TEXT_BYTES);
    }

    #[test]
    fn a_blank_line_with_spaces_still_ends_a_block() {
        let cues = SubtitleCues::parse(
            "1\n00:00:01,000 --> 00:00:02,000\nOne\n \t\n2\n00:00:03,000 --> 00:00:04,000\nTwo\n",
        );
        let texts: Vec<&str> = cues.cues().iter().map(|c| c.text.as_str()).collect();
        assert_eq!(texts, ["One", "Two"]);
    }

    #[test]
    fn reads_srt() {
        let file = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:03,500\r\nHello <i>there</i>\r\n\r\n2\r\n00:01:00,000 --> 00:01:02,000\r\n{\\an8}Top\r\nline two\r\n";
        let cues = SubtitleCues::parse(file);
        assert_eq!(cues.cues().len(), 2);
        assert_eq!(cues.cues()[0].text, "Hello there");
        assert!(cues.cues()[0].start == 1.0 && cues.cues()[0].end == 3.5);
        assert_eq!(cues.cues()[1].text, "Top\nline two");
        assert_eq!(cues.cues()[1].start, 60.0);
    }

    #[test]
    fn reads_webvtt_with_settings_and_short_times() {
        let file = "WEBVTT\n\nNOTE a comment\n\nintro\n00:05.000 --> 00:07.250 line:90% align:center\nFish &amp; chips";
        let cues = SubtitleCues::parse(file);
        assert_eq!(cues.cues().len(), 1);
        assert!(cues.cues()[0].start == 5.0 && cues.cues()[0].end == 7.25);
        assert_eq!(cues.cues()[0].text, "Fish & chips");
    }

    #[test]
    fn finds_a_long_cue_behind_many_short_ones() {
        let mut list = vec![SubtitleCue::new(0.0, 1000.0, "long")];
        for i in 1..=30 {
            list.push(SubtitleCue::new(
                f64::from(i),
                f64::from(i) + 0.5,
                &format!("s{i}"),
            ));
        }
        let cues = SubtitleCues::new(list);
        assert_eq!(cues.text_at(20.2).as_deref(), Some("long\ns20"));
        assert_eq!(cues.text_at(25.7).as_deref(), Some("long"));
        assert_eq!(cues.text_at(1001.0), None);
    }

    #[test]
    fn finds_the_cue_at_a_time() {
        let cues = SubtitleCues::new(vec![
            SubtitleCue::new(1.0, 3.0, "a"),
            SubtitleCue::new(2.0, 5.0, "b"),
            SubtitleCue::new(10.0, 12.0, "c"),
        ]);
        assert_eq!(cues.text_at(0.5), None);
        assert_eq!(cues.text_at(1.5).as_deref(), Some("a"));
        assert_eq!(cues.text_at(2.5).as_deref(), Some("a\nb"));
        assert_eq!(cues.text_at(4.0).as_deref(), Some("b"));
        assert_eq!(cues.text_at(7.0), None);
        assert_eq!(cues.text_at(11.0).as_deref(), Some("c"));
        assert_eq!(cues.text_at(12.0), None);
    }

    #[test]
    fn skips_broken_blocks() {
        let cues = SubtitleCues::parse(
            "1\nnot a time\ntext\n\n2\n00:00:05,000 --> 00:00:04,000\nbackwards\n\n3\n00:00:01,000 --> 00:00:02,000\n\n",
        );
        assert!(cues.is_empty());
    }

    #[test]
    fn equal_starts_keep_the_file_order_and_ass_breaks_become_lines() {
        let cues = SubtitleCues::parse(
            "1\n00:00:01,000 --> 00:00:02,000\nfirst\\Nsecond\n\n2\n00:00:01,000 --> 00:00:02,000\nlater\n",
        );
        assert_eq!(cues.text_at(1.5).as_deref(), Some("first\nsecond\nlater"));
    }
}
