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

/// **A gap shorter than this chains** (milliseconds): the text swaps at once, with no blank in between. A gap of
/// this length or longer keeps the fade of a pause. Decided once, here; every renderer follows it.
pub const CHAIN_GAP_MS: u32 = 500;

/// How a renderer changes from one cue to the next.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CueChange {
    /// Overlap or a short gap: the new text replaces the old at once, the box stays and takes the new size at once.
    Chain,
    /// A real pause: the text fades out and the next one fades in as before.
    Fade,
}

/// The change between a cue ending at `previous_end` and the next one starting at `next_start` (seconds).
pub fn cue_change(previous_end: f64, next_start: f64) -> CueChange {
    let gap_ms = ((next_start - previous_end) * 1000.0).round();
    if gap_ms < f64::from(CHAIN_GAP_MS) {
        CueChange::Chain
    } else {
        CueChange::Fade
    }
}

/// **The end each cue is shown until**, one per input span `(start, end)` in the input order. A cue that is followed
/// by nothing for less than [`CHAIN_GAP_MS`] is held until the next cue starts, so no frame between them is blank;
/// every other end is unchanged. Overlapping and simultaneous cues stay as they are (they stack). Spans that are not
/// finite or not positive are left alone.
pub fn chain_ends(spans: &[(f64, f64)]) -> Vec<f64> {
    let mut shown: Vec<f64> = spans.iter().map(|s| s.1).collect();
    let mut order: Vec<usize> = (0..spans.len())
        .filter(|&i| spans[i].0.is_finite() && spans[i].1.is_finite() && spans[i].1 > spans[i].0)
        .collect();
    order.sort_by(|&a, &b| spans[a].0.total_cmp(&spans[b].0));
    // `cover` is where everything shown so far ends; `holders` are the cues that end exactly there.
    let mut cover = f64::NEG_INFINITY;
    let mut holders: Vec<usize> = Vec::new();
    for i in order {
        let (start, end) = spans[i];
        if cover.is_finite() && start > cover && cue_change(cover, start) == CueChange::Chain {
            for &h in &holders {
                shown[h] = start;
            }
            cover = start;
            holders.clear();
        }
        if end > cover {
            cover = end;
            holders.clear();
            holders.push(i);
        } else if end == cover {
            holders.push(i);
        }
    }
    shown
}

/// The cues of one file, sorted by start.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct SubtitleCues {
    cues: Vec<SubtitleCue>,
    /// The end each cue is shown until (see [`chain_ends`]), same order as `cues`.
    shown_end: Vec<f64>,
    /// `latest_end[i]` is the largest shown end among `cues[0..=i]`; lets a lookup stop walking back
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
        let spans: Vec<(f64, f64)> = cues.iter().map(|c| (c.start, c.end)).collect();
        let shown_end = chain_ends(&spans);
        let mut running = f64::NEG_INFINITY;
        let latest_end = shown_end
            .iter()
            .map(|&end| {
                running = running.max(end);
                running
            })
            .collect();
        Self {
            cues,
            shown_end,
            latest_end,
        }
    }

    /// The end each cue is shown until, in the order of [`cues`](Self::cues): its own end, or the next cue's start
    /// when the gap is under [`CHAIN_GAP_MS`].
    pub fn shown_ends(&self) -> &[f64] {
        &self.shown_end
    }

    /// The cues in order.
    pub fn cues(&self) -> &[SubtitleCue] {
        &self.cues
    }

    /// No cue at all.
    pub fn is_empty(&self) -> bool {
        self.cues.is_empty()
    }

    /// The text to show at `seconds`: every cue that covers it, one under the other. A gap under
    /// [`CHAIN_GAP_MS`] is bridged: the previous text stays until the next cue starts.
    pub fn text_at(&self, seconds: f64) -> Option<String> {
        // Index after the last cue that starts at or before `seconds`.
        let low = self.cues.partition_point(|c| c.start <= seconds);
        let mut found: Vec<&str> = Vec::new();
        let mut position = low;
        while position > 0 && self.latest_end[position - 1] > seconds {
            position -= 1;
            if self.shown_end[position] > seconds {
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
        let text = normalized(raw);
        let mut cues = Vec::new();
        for block in text.split("\n\n") {
            let lines: Vec<&str> = block.split('\n').collect();
            let Some((arrow, start, end, _)) = timing(&lines) else {
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

/// The file text with one newline kind, no byte order mark, and a line of only spaces made a real blank line.
fn normalized(raw: &str) -> String {
    let raw = capped(raw);
    let text = raw.strip_prefix('\u{FEFF}').unwrap_or(raw);
    let text = text.replace("\r\n", "\n").replace('\r', "\n");
    // A "blank" line holding spaces still ends a block; otherwise the next cue is lost.
    let pieces: Vec<&str> = text.split('\n').collect();
    let last = pieces.len() - 1;
    pieces
        .iter()
        .enumerate()
        .map(|(i, line)| {
            let blank = !line.is_empty() && line.chars().all(|c| c == ' ' || c == '\t');
            if blank && i > 0 && i < last { "" } else { line }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// The timing line of one block: its index, start, end and the end word as written.
fn timing<'a>(lines: &[&'a str]) -> Option<(usize, f64, f64, &'a str)> {
    let arrow = lines.iter().position(|l| l.contains("-->"))?;
    let parts: Vec<&str> = lines[arrow].split("-->").collect();
    if parts.len() != 2 {
        return None;
    }
    let start = seconds(parts[0])?;
    // WebVTT puts cue settings after the end time ("... line:90%").
    let end_word = parts[1].split_whitespace().next().unwrap_or("");
    let end = seconds(end_word)?;
    Some((arrow, start, end, end_word))
}

fn clock(seconds: f64, comma: bool) -> String {
    let ms = (seconds.max(0.0) * 1000.0).round() as u64;
    let sep = if comma { ',' } else { '.' };
    format!(
        "{:02}:{:02}:{:02}{sep}{:03}",
        ms / 3_600_000,
        ms / 60_000 % 60,
        ms / 1000 % 60,
        ms % 1000
    )
}

/// **The same SRT or WebVTT text with every cue held until the next one starts when the gap is under
/// [`CHAIN_GAP_MS`]** (see [`chain_ends`]): only the end times change, markup, styling and cue settings stay. For a
/// player that draws the file itself and so cannot be told the chained ends (libass in mpv). Text that holds no
/// cue, or no change, comes back as it was read.
pub fn chain_text(raw: &str) -> String {
    let text = normalized(raw);
    let mut blocks: Vec<Vec<String>> = text
        .split("\n\n")
        .map(|b| b.split('\n').map(str::to_owned).collect())
        .collect();
    // (block, timing line, end word, start part, spans index)
    let mut found: Vec<(usize, usize, String)> = Vec::new();
    let mut spans: Vec<(f64, f64)> = Vec::new();
    for (bi, block) in blocks.iter().enumerate() {
        let lines: Vec<&str> = block.iter().map(String::as_str).collect();
        let Some((arrow, start, end, word)) = timing(&lines) else {
            continue;
        };
        let has_body = lines[arrow + 1..].iter().any(|l| !clean(l).is_empty());
        if !has_body || end <= start {
            continue;
        }
        found.push((bi, arrow, word.to_owned()));
        spans.push((start, end));
    }
    let shown = chain_ends(&spans);
    let mut changed = false;
    for (n, (bi, arrow, word)) in found.iter().enumerate() {
        if (shown[n] - spans[n].1).abs() < 0.0005 {
            continue;
        }
        let line = blocks[*bi][*arrow].clone();
        let Some((head, tail)) = line.split_once("-->") else {
            continue;
        };
        let rest = tail.trim_start().strip_prefix(word.as_str()).unwrap_or("");
        blocks[*bi][*arrow] = format!("{head}--> {}{rest}", clock(shown[n], word.contains(',')));
        changed = true;
    }
    if !changed {
        return raw.to_owned();
    }
    blocks
        .iter()
        .map(|b| b.join("\n"))
        .collect::<Vec<_>>()
        .join("\n\n")
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
    /// Two cues one second long, the second starting `gap_ms` after the first ends (negative: overlap).
    fn pair(gap_ms: i64) -> SubtitleCues {
        let second = 2.0 + gap_ms as f64 / 1000.0;
        SubtitleCues::new(vec![
            SubtitleCue::new(1.0, 2.0, "one"),
            SubtitleCue::new(second, second + 1.0, "two"),
        ])
    }

    /// The text at every millisecond of the join: never blank when chained.
    fn blank_ms(cues: &SubtitleCues, from_ms: i64, to_ms: i64) -> usize {
        (from_ms..to_ms)
            .filter(|ms| cues.text_at(*ms as f64 / 1000.0).is_none())
            .count()
    }

    #[test]
    fn overlap_never_blanks_and_keeps_both_lines_stacked() {
        let cues = pair(-300);
        assert_eq!(cue_change(2.0, 1.7), CueChange::Chain);
        assert_eq!(blank_ms(&cues, 1000, 2700), 0);
        assert_eq!(cues.text_at(1.8).as_deref(), Some("one\ntwo"));
        assert_eq!(cues.shown_ends()[0], 2.0);
    }

    #[test]
    fn zero_gap_swaps_at_once() {
        let cues = pair(0);
        assert_eq!(cue_change(2.0, 2.0), CueChange::Chain);
        assert_eq!(blank_ms(&cues, 1000, 3000), 0);
        assert_eq!(cues.text_at(1.999).as_deref(), Some("one"));
        assert_eq!(cues.text_at(2.0).as_deref(), Some("two"));
    }

    #[test]
    fn gap_of_200_ms_is_bridged() {
        let cues = pair(200);
        assert_eq!(cue_change(2.0, 2.2), CueChange::Chain);
        assert_eq!(cues.shown_ends()[0], 2.2);
        assert_eq!(blank_ms(&cues, 1000, 3200), 0);
        assert_eq!(cues.text_at(2.1).as_deref(), Some("one"));
        assert_eq!(cues.text_at(2.2).as_deref(), Some("two"));
    }

    #[test]
    fn gap_of_499_ms_is_still_bridged() {
        let cues = pair(499);
        assert_eq!(cue_change(2.0, 2.499), CueChange::Chain);
        assert_eq!(blank_ms(&cues, 1000, 3499), 0);
    }

    #[test]
    fn gap_of_500_ms_keeps_the_pause() {
        let cues = pair(500);
        assert_eq!(cue_change(2.0, 2.5), CueChange::Fade);
        assert_eq!(cues.shown_ends()[0], 2.0);
        assert_eq!(blank_ms(&cues, 1000, 3500), 500);
        assert_eq!(cues.text_at(2.2), None);
    }

    #[test]
    fn gap_of_two_seconds_keeps_the_pause() {
        let cues = pair(2000);
        assert_eq!(cue_change(2.0, 4.0), CueChange::Fade);
        assert_eq!(blank_ms(&cues, 1000, 5000), 2000);
    }

    #[test]
    fn chain_ends_bridges_from_the_latest_end_and_keeps_input_order() {
        // Input is not sorted; the long first cue (ends 5.0) is the one that is held, not the short one inside it.
        let spans = [(6.0, 7.0), (1.0, 5.0), (2.0, 3.0), (20.0, 21.0)];
        let shown = chain_ends(&spans);
        assert_eq!(shown, vec![7.0, 5.0, 3.0, 21.0]);
        let spans = [(1.0, 5.0), (2.0, 3.0), (5.3, 6.0)];
        assert_eq!(chain_ends(&spans), vec![5.3, 3.0, 6.0]);
        // Broken spans are left alone.
        assert_eq!(chain_ends(&[(f64::NAN, 1.0), (2.0, 1.0)]).len(), 2);
    }

    #[test]
    fn chain_text_changes_only_the_end_of_a_short_gap() {
        let raw = "1\n00:00:01,000 --> 00:00:02,000\n<i>A</i>\n\n2\n00:00:02,400 --> 00:00:03,000\nB\n\n3\n00:00:04,000 --> 00:00:05,000\nC\n";
        let out = chain_text(raw);
        assert!(
            out.contains("00:00:01,000 --> 00:00:02,400\n<i>A</i>"),
            "{out}"
        );
        assert!(out.contains("00:00:02,400 --> 00:00:03,000\nB"), "{out}");
        assert!(out.contains("00:00:04,000 --> 00:00:05,000\nC"), "{out}");
        let cues = SubtitleCues::parse(&out);
        assert_eq!(cues.cues().len(), 3);
        assert_eq!(cues.cues()[0].end, 2.4);
    }

    #[test]
    fn chain_text_keeps_vtt_settings_and_returns_unchanged_text() {
        let vtt = "WEBVTT\n\n00:01.000 --> 00:02.000 line:90%\nA\n\n00:02.100 --> 00:03.000\nB\n";
        let out = chain_text(vtt);
        assert!(out.contains("00:01.000 --> 00:00:02.100 line:90%"), "{out}");
        let far = "1\n00:00:01,000 --> 00:00:02,000\nA\n\n2\n00:00:03,000 --> 00:00:04,000\nB\n";
        assert_eq!(chain_text(far), far);
        assert_eq!(chain_text("no cues"), "no cues");
    }
}
