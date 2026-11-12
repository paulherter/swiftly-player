//! Port of Chapter.swift (the pure rules; JSON decoding of `ChapterInfo` / `ChapterResponse`
//! belongs to `swiftly-model`, only the tick-to-seconds conversion and the name trimming are
//! here as [`Chapter::from_ticks`]).
//!
//! A chapter has a start and a name; there is no end, a chapter runs to the next one.
//! [`ChapterBar`] decides which chapters divide the scrubber and where the cuts go.

use crate::notches_snap::SNAP_RANGE;

/// A chapter of a movie or episode, as stored in the file.
#[derive(Debug, Clone, PartialEq)]
pub struct Chapter {
    /// As the server names it; empty only if nothing came.
    pub name: String,
    /// Start in seconds (not ticks).
    pub from: f64,
}

impl Chapter {
    /// A chapter from seconds.
    pub fn new(name: &str, from: f64) -> Self {
        Self {
            name: name.to_owned(),
            from,
        }
    }

    /// From the server's `Name` and `StartPositionTicks` (10 000 000 ticks per second).
    /// The name is trimmed of whitespace and newlines, a missing name becomes empty.
    /// (`Chapter.swift:30-35`; a chapter without a start does not exist, so the ticks are
    /// not optional here.)
    pub fn from_ticks(name: Option<&str>, start_position_ticks: i64) -> Self {
        let trimmed = name.unwrap_or("").trim_matches(|c: char| c.is_whitespace());
        Self {
            name: trimmed.to_owned(),
            from: start_position_ticks as f64 / 10_000_000.0,
        }
    }
}

/// A piece of the bar, as a fraction of the runtime (0...1).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Piece {
    /// Start fraction.
    pub from: f64,
    /// End fraction.
    pub until: f64,
}

impl Piece {
    /// Where the piece lies on the bar, in points: `(x, width)`. The gap is taken half from
    /// each neighbor, nothing at the two ends. (`Chapter.swift:93-99`)
    pub fn frame_rect(&self, width: f64, gap: f64) -> (f64, f64) {
        let left = if self.from > 0.0 { gap / 2.0 } else { 0.0 };
        let right = if self.until < 1.0 { gap / 2.0 } else { 0.0 };
        let x = self.from * width + left;
        (x, (self.until * width - right - x).max(0.0))
    }
}

/// The scrubber, split at chapter boundaries.
pub struct ChapterBar;

impl ChapterBar {
    /// How far apart the spacings of a grid may be. (`Chapter.swift:132`)
    const GRID_TOLERANCE: f64 = 0.5;
    /// How many catch widths a piece must be wide for its edges to snap. (`Chapter.swift:190`)
    const SNAP_SPACING: f64 = 4.0;
    /// One millisecond of slack for [`ChapterBar::chapter_at`]. (`Chapter.swift:210`)
    const PLAY: f64 = 0.001;

    /// The chapters allowed to divide the bar: finite and non-negative starts only, sorted,
    /// duplicate starts dropped (the first wins), and none at all for fewer than two chapters
    /// or for the server's uniform placeholder grid. (`Chapter.swift:116-124`)
    pub fn usable(chapter: &[Chapter]) -> Vec<Chapter> {
        let mut sorted: Vec<Chapter> = chapter
            .iter()
            .filter(|c| c.from.is_finite() && c.from >= 0.0)
            .cloned()
            .collect();
        // Stable sort (Swift's sort is stable in practice), so of two equal starts the
        // earlier one in the input stays first and wins below.
        sorted.sort_by(|a, b| {
            a.from
                .partial_cmp(&b.from)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        let mut kept: Vec<Chapter> = Vec::new();
        for c in sorted {
            if !kept.iter().any(|k| k.from == c.from) {
                kept.push(c);
            }
        }
        if kept.len() < 2 || Self::is_grid(&kept) {
            Vec::new()
        } else {
            kept
        }
    }

    /// Starts at 0 (within tolerance), and every spacing equals the first.
    fn is_grid(sorted: &[Chapter]) -> bool {
        let Some(first_one) = sorted.first() else {
            return false;
        };
        if sorted.len() < 3 || first_one.from > Self::GRID_TOLERANCE {
            return false;
        }
        let step = sorted[1].from - first_one.from;
        if step <= 0.0 {
            return false;
        }
        sorted
            .windows(2)
            .all(|w| ((w[1].from - w[0].from) - step).abs() <= Self::GRID_TOLERANCE)
    }

    /// Where to cut, in seconds: every chapter start strictly inside the runtime (0 and
    /// anything at or past the end dropped). (`Chapter.swift:140-143`)
    pub fn limits(chapter: &[Chapter], duration: f64) -> Vec<f64> {
        if duration <= 0.0 {
            return Vec::new();
        }
        chapter
            .iter()
            .map(|c| c.from)
            .filter(|f| *f > 0.0 && *f < duration)
            .collect()
    }

    /// The pieces of the bar. A cut that would leave a piece narrower than `min_width`
    /// points (on either side) is dropped and the piece before it extends to the next cut.
    /// (`Chapter.swift:159-175`)
    pub fn pieces(limits: &[f64], duration: f64, width: f64, min_width: f64) -> Vec<Piece> {
        let whole = vec![Piece {
            from: 0.0,
            until: 1.0,
        }];
        if !(duration > 0.0 && width > 0.0) {
            return whole;
        }
        let mut cuts: Vec<f64> = limits
            .iter()
            .map(|l| l / duration)
            .filter(|c| *c > 0.0 && *c < 1.0)
            .collect();
        cuts.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let mut pieces = Vec::new();
        let mut beginning = 0.0;
        for cut in cuts {
            if (cut - beginning) * width >= min_width && (1.0 - cut) * width >= min_width {
                pieces.push(Piece {
                    from: beginning,
                    until: cut,
                });
                beginning = cut;
            }
        }
        pieces.push(Piece {
            from: beginning,
            until: 1.0,
        });
        pieces
    }

    /// What the slider snaps to: the cuts between pieces, in seconds, but only those where
    /// both neighbour pieces are at least `SNAP_SPACING` catch widths wide.
    /// (`Chapter.swift:184-190`)
    pub fn snap_cuts(pieces: &[Piece], duration: f64, width: f64) -> Vec<f64> {
        if !(duration > 0.0 && width > 0.0 && pieces.len() > 1) {
            return Vec::new();
        }
        let needed = Self::SNAP_SPACING * SNAP_RANGE / width;
        pieces
            .windows(2)
            .filter(|w| w[0].until - w[0].from >= needed && w[1].until - w[1].from >= needed)
            .map(|w| w[1].from * duration)
            .collect()
    }

    /// The piece containing a fraction. A boundary belongs to the piece starting there.
    pub fn piece_at(share: f64, pieces: &[Piece]) -> Option<usize> {
        if pieces.is_empty() || !share.is_finite() {
            return None;
        }
        Some(pieces.iter().rposition(|p| p.from <= share).unwrap_or(0))
    }

    /// The chapter at a position, or `None` before the first one. Needs sorted chapters (as
    /// from [`ChapterBar::usable`]). One millisecond of slack so a slider snapped to a cut
    /// names the chapter that starts there. (`Chapter.swift:206-209`)
    pub fn chapter_at(spot: f64, chapter: &[Chapter]) -> Option<&Chapter> {
        if !spot.is_finite() {
            return None;
        }
        chapter.iter().rev().find(|c| c.from <= spot + Self::PLAY)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn k(from: f64) -> Chapter {
        Chapter::new("", from)
    }

    fn kn(from: f64, name: &str) -> Chapter {
        Chapter::new(name, from)
    }

    // Swift: ChapterInReadTests.inRead - JSON decoding is not ported; the tick conversion
    // and name trimming are checked with the same values.
    #[test]
    fn in_read() {
        assert_eq!(
            Chapter::from_ticks(Some("Prolog"), 0),
            Chapter::new("Prolog", 0.0)
        );
        assert_eq!(
            Chapter::from_ticks(Some("  Der Überfall "), 4_235_000_000),
            Chapter::new("Der Überfall", 423.5)
        );
        // Without a name, an empty one, not an error.
        assert_eq!(
            Chapter::from_ticks(None, 31_500_000_000),
            Chapter::new("", 3150.0)
        );
    }

    // Swift: ChapterUsableTests.sorted
    #[test]
    fn sorted() {
        let raw = [
            kn(900.0, "C"),
            kn(0.0, "A"),
            kn(300.0, "B"),
            kn(300.0, "B2"),
        ];
        let names: Vec<String> = ChapterBar::usable(&raw)
            .into_iter()
            .map(|c| c.name)
            .collect();
        assert_eq!(names, ["A", "B", "C"]);
    }

    #[test]
    fn single() {
        assert!(ChapterBar::usable(&[kn(0.0, "Film")]).is_empty());
        assert!(ChapterBar::usable(&[]).is_empty());
    }

    #[test]
    fn unsinn() {
        assert!(ChapterBar::usable(&[k(-5.0), k(f64::NAN), k(f64::INFINITY), k(60.0)]).is_empty());
        let froms: Vec<f64> = ChapterBar::usable(&[k(-5.0), k(0.0), k(60.0)])
            .iter()
            .map(|c| c.from)
            .collect();
        assert_eq!(froms, [0.0, 60.0]);
    }

    #[test]
    fn grid() {
        // DummyChapterDuration = 300: one every five minutes, starting at 0.
        let placeholder: Vec<Chapter> = (0..9)
            .map(|i| kn(f64::from(i) * 300.0, &format!("Kapitel {}", i + 1)))
            .collect();
        assert!(ChapterBar::usable(&placeholder).is_empty());
    }

    #[test]
    fn real_chapter() {
        let disc = [k(0.0), k(312.4), k(655.1), k(1020.8), k(1301.0)];
        assert_eq!(ChapterBar::usable(&disc).len(), 5);
    }

    #[test]
    fn grid_not_off_null() {
        assert_eq!(ChapterBar::usable(&[k(90.0), k(390.0), k(690.0)]).len(), 3);
    }

    #[test]
    fn grid_with_play() {
        assert!(ChapterBar::usable(&[k(0.0), k(300.2), k(600.0), k(900.3)]).is_empty());
    }

    #[test]
    fn two_chapter() {
        assert_eq!(ChapterBar::usable(&[k(0.0), k(300.0)]).len(), 2);
    }

    // Swift: ChapterBarTests.limits
    #[test]
    fn limits() {
        let chapter = [
            kn(0.0, "A"),
            kn(600.0, "B"),
            kn(1800.0, "C"),
            kn(3000.0, "D"),
        ];
        assert_eq!(ChapterBar::limits(&chapter, 2400.0), [600.0, 1800.0]);
        // Nothing is cut while VLC does not know the duration.
        assert!(ChapterBar::limits(&chapter, 0.0).is_empty());
    }

    #[test]
    fn without_limits() {
        let whole = vec![Piece {
            from: 0.0,
            until: 1.0,
        }];
        assert_eq!(ChapterBar::pieces(&[], 2400.0, 300.0, 8.0), whole);
        assert_eq!(ChapterBar::pieces(&[600.0], 0.0, 300.0, 8.0), whole);
        assert_eq!(ChapterBar::pieces(&[600.0], 2400.0, 0.0, 8.0), whole);
    }

    #[test]
    fn cuts() {
        let s = ChapterBar::pieces(&[1800.0, 600.0], 2400.0, 300.0, 8.0);
        assert_eq!(
            s,
            [
                Piece {
                    from: 0.0,
                    until: 0.25
                },
                Piece {
                    from: 0.25,
                    until: 0.75
                },
                Piece {
                    from: 0.75,
                    until: 1.0
                }
            ]
        );
    }

    #[test]
    fn too_narrow() {
        // 300 points for 3000 s: one point is ten seconds, eight points 80 s.
        let s = ChapterBar::pieces(&[600.0, 650.0, 700.0, 2960.0], 3000.0, 300.0, 8.0);
        // 650 would sit 5 points past 600 and is dropped; 700 would sit 10 past, and stays.
        // 2960 would leave only 4 points at the end.
        let froms: Vec<f64> = s.iter().map(|p| p.from).collect();
        assert_eq!(froms, [0.0, 0.2, 700.0 / 3000.0]);
        assert_eq!(s.last().map(|p| p.until), Some(1.0));
    }

    #[test]
    fn frame_rect() {
        let s = ChapterBar::pieces(&[100.0], 400.0, 200.0, 8.0);
        let left = s[0].frame_rect(200.0, 2.0);
        let right = s[1].frame_rect(200.0, 2.0);
        assert!(left.0 == 0.0 && left.1 == 49.0);
        assert!(right.0 == 51.0 && right.1 == 149.0);
        let whole = Piece {
            from: 0.0,
            until: 1.0,
        }
        .frame_rect(200.0, 2.0);
        assert!(whole.0 == 0.0 && whole.1 == 200.0);
        // In the middle, something is taken off from both sides.
        let center = Piece {
            from: 0.25,
            until: 0.75,
        }
        .frame_rect(200.0, 2.0);
        assert!(center.0 == 51.0 && center.1 == 98.0);
    }

    #[test]
    fn snap_cuts() {
        // 300 points for 3000 s; each neighbouring piece needs 4 x 8 = 32 points.
        let s = ChapterBar::pieces(&[600.0, 900.0, 1100.0, 2000.0], 3000.0, 300.0, 8.0);
        assert_eq!(s.len(), 5);
        // All cuts are drawn; only the one at 2000 may snap.
        assert_eq!(ChapterBar::snap_cuts(&s, 3000.0, 300.0), [2000.0]);
        assert!(
            ChapterBar::snap_cuts(
                &[Piece {
                    from: 0.0,
                    until: 1.0
                }],
                3000.0,
                300.0
            )
            .is_empty()
        );
    }

    #[test]
    fn density_chapter() {
        let limits: Vec<f64> = (1..30).map(|i| f64::from(i) * 240.0).collect(); // 2 h, every 4 min
        let s = ChapterBar::pieces(&limits, 7200.0, 280.0, 8.0);
        assert_eq!(s.len(), 30);
        assert!(ChapterBar::snap_cuts(&s, 7200.0, 280.0).is_empty());
    }

    #[test]
    fn piece_at() {
        let s = [
            Piece {
                from: 0.0,
                until: 0.25,
            },
            Piece {
                from: 0.25,
                until: 1.0,
            },
        ];
        assert_eq!(ChapterBar::piece_at(0.0, &s), Some(0));
        assert_eq!(ChapterBar::piece_at(0.2499, &s), Some(0));
        assert_eq!(ChapterBar::piece_at(0.25, &s), Some(1));
        assert_eq!(ChapterBar::piece_at(1.0, &s), Some(1));
        assert_eq!(ChapterBar::piece_at(f64::NAN, &s), None);
        assert_eq!(ChapterBar::piece_at(0.5, &[]), None);
    }

    #[test]
    fn chapter_at() {
        let chapter = [kn(30.0, "Anfang"), kn(600.0, "Mitte")];
        assert!(ChapterBar::chapter_at(10.0, &chapter).is_none());
        assert_eq!(
            ChapterBar::chapter_at(30.0, &chapter).map(|c| c.name.as_str()),
            Some("Anfang")
        );
        assert_eq!(
            ChapterBar::chapter_at(599.9, &chapter).map(|c| c.name.as_str()),
            Some("Anfang")
        );
        assert_eq!(
            ChapterBar::chapter_at(4000.0, &chapter).map(|c| c.name.as_str()),
            Some("Mitte")
        );
    }

    #[test]
    fn snapped_names_correct_direction() {
        // Converted back via the fraction, the position often lands just before.
        let chapter = [kn(0.0, "A"), kn(1234.567, "B")];
        let name = |spot: f64| ChapterBar::chapter_at(spot, &chapter).map(|c| c.name.clone());
        for duration in [2468.9, 3000.1, 5423.77, 7199.3] {
            let s = ChapterBar::pieces(
                &ChapterBar::limits(&chapter, duration),
                duration,
                600.0,
                8.0,
            );
            let cut = ChapterBar::snap_cuts(&s, duration, 600.0)[0];
            assert_eq!(name(cut).as_deref(), Some("B"));
            assert_eq!(name(duration * (cut / duration)).as_deref(), Some("B"));
        }
        assert_eq!(name(1234.567 - 1e-9).as_deref(), Some("B"));
        assert_eq!(name(1234.5).as_deref(), Some("A"));
    }

    #[test]
    fn name_despite_too_narrow() {
        let chapter = [kn(0.0, "A"), kn(600.0, "B"), kn(650.0, "C")];
        let s = ChapterBar::pieces(&ChapterBar::limits(&chapter, 3000.0), 3000.0, 300.0, 8.0);
        assert_eq!(s.len(), 2);
        assert_eq!(
            ChapterBar::chapter_at(660.0, &chapter).map(|c| c.name.as_str()),
            Some("C")
        );
    }
}
