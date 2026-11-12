//! Port of `Packages/JellyfinKit/Sources/JellyfinKit/Sections.swift`: the marked sections of an
//! episode (`/MediaSegments/{itemId}`), which skip button applies (`SectionLogic`), and the
//! automatic skip / card rules. Pure; positions and durations are `f64` seconds.

use serde::de::Error as _;
use serde::ser::SerializeStruct;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;
use swiftly_model::Lenient;
use swiftly_rules::episodes_end;

use crate::offering_layer::COUNTDOWN;

/// Hundred-nanosecond ticks per second (Sections.swift:69-70).
const TICKS_PER_SECOND: f64 = 10_000_000.0;

/// The kind of a section (Sections.swift:20-50). Wire names are the raw values the server
/// sends in `MediaSegmentDto.Type`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Art {
    /// `Unknown` (Sections.swift:21).
    #[serde(rename = "Unknown")]
    Unknown,
    /// Swift `ads`, `Commercial` (Sections.swift:22).
    #[serde(rename = "Commercial")]
    Ads,
    /// `Preview` (Sections.swift:23).
    #[serde(rename = "Preview")]
    Preview,
    /// Swift `lookBack`, `Recap` (Sections.swift:24).
    #[serde(rename = "Recap")]
    LookBack,
    /// Swift `credits`, `Outro` (Sections.swift:25).
    #[serde(rename = "Outro")]
    Credits,
    /// Swift `introSegment`, `Intro` (Sections.swift:26).
    #[serde(rename = "Intro")]
    IntroSegment,
}

impl Art {
    /// Parses the server's raw value; `None` for a type this version does not know.
    pub fn from_raw(raw: &str) -> Option<Self> {
        match raw {
            "Unknown" => Some(Self::Unknown),
            "Commercial" => Some(Self::Ads),
            "Preview" => Some(Self::Preview),
            "Recap" => Some(Self::LookBack),
            "Outro" => Some(Self::Credits),
            "Intro" => Some(Self::IntroSegment),
            _ => None,
        }
    }

    /// Whether this section is skipped in principle (Sections.swift:33-38). The outro applies
    /// only if something comes after it; [`SectionLogic`] decides that.
    pub fn skippable(self) -> bool {
        !matches!(self, Self::Unknown)
    }

    /// Button text (Sections.swift:40-49). The German source string is the catalog key
    /// (`translated(...)` in Swift).
    pub fn label(self) -> &'static str {
        match self {
            Self::IntroSegment => "Intro überspringen",
            Self::LookBack => "Rückblick überspringen",
            Self::Preview => "Vorschau überspringen",
            Self::Ads => "Werbung überspringen",
            Self::Credits => "Abspann überspringen",
            Self::Unknown => "Überspringen",
        }
    }
}

/// A marked section of an episode: intro, recap, outro (Sections.swift:18-96).
///
/// Decodes from `MediaSegmentDto` (`Type`, `StartTicks`, `EndTicks`); ticks become seconds.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Segment {
    /// The kind; an unknown type decodes as [`Art::Unknown`].
    pub art: Art,
    /// Start in seconds.
    pub from: f64,
    /// End in seconds.
    pub until: f64,
}

impl Segment {
    /// `init(art:from:until:)` (Sections.swift:57).
    pub fn new(art: Art, from: f64, until: f64) -> Self {
        Self { art, from, until }
    }

    /// `contains` (Sections.swift:93): start included, end excluded.
    pub fn contains(&self, spot: f64) -> bool {
        spot >= self.from && spot < self.until
    }
}

/// Ticks field: absent or `null` is 0; an integer (or a whole float) is taken; anything else
/// makes the segment undecodable, like `decodeIfPresent(Int64.self)` (Sections.swift:79-80).
fn ticks_seconds(v: Option<&Value>) -> Result<f64, String> {
    let Some(v) = v else { return Ok(0.0) };
    match v {
        Value::Null => Ok(0.0),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Ok(i as f64 / TICKS_PER_SECOND)
            } else if let Some(f) = n.as_f64().filter(|f| f.fract() == 0.0 && f.abs() < 9.2e18) {
                Ok(f / TICKS_PER_SECOND)
            } else {
                Err(format!("tick value {n} is not an Int64"))
            }
        }
        other => Err(format!("tick value {other} is not a number")),
    }
}

impl<'de> Deserialize<'de> for Segment {
    /// Sections.swift:71-81. The type is read as text and mapped leniently: a type this
    /// version does not know (or a non-text value) becomes [`Art::Unknown`] instead of
    /// failing the whole response.
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        struct Raw {
            #[serde(rename = "Type", default)]
            art: Option<Value>,
            #[serde(rename = "StartTicks", default)]
            from_ticks: Option<Value>,
            #[serde(rename = "EndTicks", default)]
            until_ticks: Option<Value>,
        }
        let raw = Raw::deserialize(deserializer)?;
        let art = match raw.art {
            Some(Value::String(s)) => Art::from_raw(&s).unwrap_or(Art::Unknown),
            _ => Art::Unknown,
        };
        Ok(Self {
            art,
            from: ticks_seconds(raw.from_ticks.as_ref()).map_err(D::Error::custom)?,
            until: ticks_seconds(raw.until_ticks.as_ref()).map_err(D::Error::custom)?,
        })
    }
}

impl Serialize for Segment {
    /// The same form the server sends (Sections.swift:86-91): seconds back to ticks, rounded.
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut s = serializer.serialize_struct("Segment", 3)?;
        s.serialize_field("Type", &self.art)?;
        s.serialize_field(
            "StartTicks",
            &((self.from * TICKS_PER_SECOND).round() as i64),
        )?;
        s.serialize_field(
            "EndTicks",
            &((self.until * TICKS_PER_SECOND).round() as i64),
        )?;
        s.end()
    }
}

/// The response shape of `/MediaSegments/{itemId}` (Sections.swift:99-108). Broken entries
/// are dropped ([`Lenient`]); a missing or `null` `Items` is an empty list.
#[derive(Debug, Clone, PartialEq)]
pub struct SectionResponse {
    /// The readable sections, in server order.
    pub items: Vec<Segment>,
}

impl<'de> Deserialize<'de> for SectionResponse {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        struct Raw {
            #[serde(rename = "Items", default)]
            items: Option<Lenient<Segment>>,
        }
        let raw = Raw::deserialize(deserializer)?;
        Ok(Self {
            items: raw.items.map(|l| l.0).unwrap_or_default(),
        })
    }
}

// MARK: - Which button applies

/// What the button at the bottom right of the player offers (Sections.swift:117-146).
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ButtonOffering {
    /// No button.
    Nobody,
    /// Jump to this second, with this label.
    Skip {
        /// Target second.
        to: f64,
        /// Kind of the section skipped.
        art: Art,
    },
    /// "Next episode".
    NextEpisode,
}

impl ButtonOffering {
    /// What is written on the button (Sections.swift:124-130): the German source string is the
    /// catalog key; empty for [`ButtonOffering::Nobody`].
    pub fn label(&self) -> &'static str {
        match self {
            Self::Nobody => "",
            Self::Skip { art, .. } => art.label(),
            Self::NextEpisode => "Nächste Folge",
        }
    }

    /// Which SF symbol precedes it (Sections.swift:137-143): skipping continues within the
    /// episode, advancing leaves it, so the two differ on purpose.
    pub fn symbol_text(&self) -> &'static str {
        match self {
            Self::Nobody => "",
            Self::Skip { .. } => "forward.fill",
            Self::NextEpisode => "forward.end.fill",
        }
    }

    /// Whether there is a button at all (Sections.swift:145).
    pub fn visible(&self) -> bool {
        *self != Self::Nobody
    }
}

/// Result of [`SectionLogic::automatic`]: the section acted on and the button's offering.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Automatic {
    /// The section the automatic skip acts on; the caller acts once per section.
    pub segment: Segment,
    /// The manual button's offering at this position.
    pub offering: ButtonOffering,
}

/// Decides from position, duration and sections which button applies (Sections.swift:156-290).
/// Without sections nothing changes: [`episodes_end::button_show`] alone decides.
pub struct SectionLogic;

impl SectionLogic {
    /// Shortly before the end of a section it is no longer offered (Sections.swift:162).
    pub const MIN_REMAINING: f64 = 1.5;
    /// Shorter sections get no button (Sections.swift:168).
    pub const MIN_LENGTH: f64 = 3.0;
    /// How close an outro must reach to the end of the file to count as "until the end"
    /// (Sections.swift:172).
    pub const CREDITS_TOLERANCE: f64 = 2.0;

    /// Sections that qualify for a button (Sections.swift:175-177).
    fn valid(sections: &[Segment]) -> Vec<Segment> {
        sections
            .iter()
            .copied()
            .filter(|s| s.until - s.from >= Self::MIN_LENGTH)
            .collect()
    }

    /// Does the outro reach the end of the file? Then "Next episode" is the offer
    /// (Sections.swift:181-185). Without a duration it behaves as before: `true`.
    fn suffices_end(credits: &Segment, duration: f64) -> bool {
        if duration.is_nan() || duration <= 0.0 {
            return true;
        }
        credits.until >= duration - Self::CREDITS_TOLERANCE
    }

    /// Which button applies at this position (Sections.swift:187-216).
    pub fn offering(
        position: f64,
        duration: f64,
        sections: &[Segment],
        has_next_episode: bool,
    ) -> ButtonOffering {
        let sections = Self::valid(sections);

        // 1. Inside a skippable section; an outro only if something comes after it.
        if let Some(here) = sections.iter().find(|s| {
            s.art.skippable()
                && s.contains(position)
                && (s.until - position) > Self::MIN_REMAINING
                && !(s.art == Art::Credits && Self::suffices_end(s, duration))
        }) {
            return ButtonOffering::Skip {
                to: here.until,
                art: here.art,
            };
        }

        if !has_next_episode {
            return ButtonOffering::Nobody;
        }

        // 2. If there is outro information, it applies, and alone.
        if let Some(credits) = sections.iter().find(|s| s.art == Art::Credits) {
            let since = if Self::suffices_end(credits, duration) {
                credits.from
            } else {
                credits.until
            };
            return if position >= since {
                ButtonOffering::NextEpisode
            } else {
                ButtonOffering::Nobody
            };
        }

        // 3. Otherwise as before.
        if episodes_end::button_show(position, duration) {
            ButtonOffering::NextEpisode
        } else {
            ButtonOffering::Nobody
        }
    }

    /// The section that "skip intro and outro automatically" acts on now (Sections.swift:225-240).
    /// Only intro and outro, and only exactly where the manual button would appear.
    pub fn automatic(
        position: f64,
        duration: f64,
        sections: &[Segment],
        has_next_episode: bool,
    ) -> Option<Automatic> {
        let now = Self::offering(position, duration, sections, has_next_episode);
        if !now.visible() {
            return None;
        }
        let here = Self::valid(sections)
            .into_iter()
            .find(|s| matches!(s.art, Art::IntroSegment | Art::Credits) && s.contains(position))?;
        match now {
            ButtonOffering::Skip { art, .. } if art == here.art => Some(Automatic {
                segment: here,
                offering: now,
            }),
            ButtonOffering::NextEpisode if here.art == Art::Credits => Some(Automatic {
                segment: here,
                offering: now,
            }),
            _ => None,
        }
    }

    /// Whether the "Next episode" card opens by itself (Sections.swift:257-273): only with an
    /// outro section reaching the end, from the start of the outro. With `remaining_window`
    /// (iPhone, TV) and no outro the card comes in the last so many seconds; `None` is the old
    /// behaviour.
    pub fn card_due(
        position: f64,
        duration: f64,
        sections: &[Segment],
        has_next_episode: bool,
        remaining_window: Option<f64>,
    ) -> bool {
        // Without a duration nothing is "at the end"; before the first picture it is 0.
        if duration.is_nan() || duration <= 0.0 {
            return false;
        }
        let credits = Self::valid(sections)
            .into_iter()
            .find(|s| s.art == Art::Credits);
        if credits.is_none()
            && let Some(window) = remaining_window
        {
            return duration - position <= window
                && Self::offering(position, duration, sections, has_next_episode)
                    == ButtonOffering::NextEpisode;
        }
        let Some(credits) = credits else {
            return false;
        };
        if !Self::suffices_end(&credits, duration) || position.is_nan() || position < credits.from {
            return false;
        }
        Self::offering(position, duration, sections, has_next_episode)
            == ButtonOffering::NextEpisode
    }

    /// How long the card's fill runs when it opens at this position: [`COUNTDOWN`], but never
    /// beyond the end of the file (Sections.swift:277-280).
    pub fn countdown(position: f64, duration: f64) -> f64 {
        if duration.is_nan() || duration <= 0.0 {
            return COUNTDOWN;
        }
        COUNTDOWN.min((duration - position).max(1.0))
    }

    /// Swift overload `countdown(position:dauer:abschnitte:restfenster:)` (Sections.swift:284-290):
    /// without an outro section and with a `remaining_window` the countdown runs to the end of
    /// the file.
    pub fn countdown_with_sections(
        position: f64,
        duration: f64,
        sections: &[Segment],
        remaining_window: Option<f64>,
    ) -> f64 {
        if remaining_window.is_none()
            || duration.is_nan()
            || duration <= 0.0
            || Self::valid(sections).iter().any(|s| s.art == Art::Credits)
        {
            return Self::countdown(position, duration);
        }
        (duration - position).max(1.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decode(json: &str) -> SectionResponse {
        serde_json::from_str(json).expect("decodes")
    }

    // MARK: SectionInReadTests (5)

    /// Exactly the shape `MediaSegmentDto` has in the OpenAPI description of the server.
    const ANSWER: &str = r#"
    { "Items": [
        { "Id": "a1", "ItemId": "e1", "Type": "Intro",
          "StartTicks": 0, "EndTicks": 900000000 },
        { "Id": "a2", "ItemId": "e1", "Type": "Outro",
          "StartTicks": 13200000000, "EndTicks": 13800000000 }
      ], "TotalRecordCount": 2, "StartIndex": 0 }"#;

    #[test]
    fn ticks() {
        let a = decode(ANSWER);
        assert_eq!(a.items.len(), 2);
        assert_eq!(a.items[0].art, Art::IntroSegment);
        assert_eq!(a.items[0].from, 0.0);
        assert_eq!(a.items[0].until, 90.0); // 900,000,000 ticks
        assert_eq!(a.items[1].art, Art::Credits);
        assert_eq!(a.items[1].from, 1320.0);
    }

    #[test]
    fn empty() {
        assert!(
            decode(r#"{ "Items": [], "TotalRecordCount": 0, "StartIndex": 0 }"#)
                .items
                .is_empty()
        );
    }

    #[test]
    fn without_items() {
        assert!(decode(r#"{ "TotalRecordCount": 0 }"#).items.is_empty());
    }

    #[test]
    fn unknown_art() {
        let d =
            r#"{ "Items": [ { "Type": "Werbepause2030", "StartTicks": 0, "EndTicks": 10000000 },"#
                .to_string()
                + r#" { "Type": "Intro", "StartTicks": 0, "EndTicks": 900000000 } ] }"#;
        let a = decode(&d);
        assert_eq!(a.items.len(), 2);
        assert_eq!(a.items[0].art, Art::Unknown);
        assert_eq!(a.items[0].until, 1.0);
        assert_eq!(a.items[1].art, Art::IntroSegment);
    }

    #[test]
    fn broken_section() {
        let d = r#"{ "Items": [ { "Type": "Intro", "StartTicks": "neun", "EndTicks": 1 },"#
            .to_string()
            + r#" { "Type": "Outro", "StartTicks": 0, "EndTicks": 10000000 }, 42, null ] }"#;
        let a = decode(&d);
        assert_eq!(
            a.items.iter().map(|s| s.art).collect::<Vec<_>>(),
            [Art::Credits]
        );
    }

    // MARK: SectionLogicTests (22)

    fn intro_segment() -> Segment {
        Segment::new(Art::IntroSegment, 12.0, 90.0)
    }
    fn credits() -> Segment {
        Segment::new(Art::Credits, 1320.0, 1380.0)
    }
    fn skip(to: f64, art: Art) -> ButtonOffering {
        ButtonOffering::Skip { to, art }
    }
    fn offering(position: f64, sections: &[Segment], next: bool) -> ButtonOffering {
        SectionLogic::offering(position, 1500.0, sections, next)
    }

    #[test]
    fn without_sections() {
        // 1400 of 1500 s counts as "near the end" after the episode ends.
        assert_eq!(offering(1400.0, &[], true), ButtonOffering::NextEpisode);
        assert_eq!(offering(300.0, &[], true), ButtonOffering::Nobody);
    }

    #[test]
    fn same_timestamp() {
        for i in 0..=300 {
            let spot = f64::from(i) * 5.0;
            let old = episodes_end::button_show(spot, 1500.0);
            let new = offering(spot, &[], true);
            assert_eq!(new == ButtonOffering::NextEpisode, old, "bei {spot} s");
        }
    }

    #[test]
    fn no_next() {
        assert_eq!(
            offering(1400.0, &[credits()], false),
            ButtonOffering::Nobody
        );
    }

    #[test]
    fn in_intro() {
        assert_eq!(
            offering(30.0, &[intro_segment(), credits()], true),
            skip(90.0, Art::IntroSegment)
        );
    }

    #[test]
    fn beside_intro() {
        assert_eq!(
            offering(5.0, &[intro_segment()], false),
            ButtonOffering::Nobody
        );
        assert_eq!(
            offering(95.0, &[intro_segment()], false),
            ButtonOffering::Nobody
        );
    }

    #[test]
    fn edges() {
        assert_eq!(
            offering(12.0, &[intro_segment()], false),
            skip(90.0, Art::IntroSegment)
        );
        assert_eq!(
            offering(90.0, &[intro_segment()], false),
            ButtonOffering::Nobody
        );
    }

    #[test]
    fn short_pre_end() {
        assert_eq!(
            offering(89.0, &[intro_segment()], false),
            ButtonOffering::Nobody
        );
    }

    #[test]
    fn other_kinds() {
        for art in [Art::LookBack, Art::Preview, Art::Ads] {
            let a = Segment::new(art, 10.0, 60.0);
            assert_eq!(offering(20.0, &[a], false), skip(60.0, art));
        }
    }

    #[test]
    fn unknown() {
        let a = Segment::new(Art::Unknown, 10.0, 60.0);
        assert_eq!(offering(20.0, &[a], false), ButtonOffering::Nobody);
    }

    #[test]
    fn credits_applies() {
        let until_end = Segment::new(Art::Credits, 1320.0, 1499.0);
        // 1200 of 1500 would not be anything by the remaining-time rule, nor by credits.
        assert_eq!(offering(1200.0, &[until_end], true), ButtonOffering::Nobody);
        assert_eq!(
            offering(1320.0, &[until_end], true),
            ButtonOffering::NextEpisode
        );
    }

    #[test]
    fn credits_with_scene_after() {
        // `credits` ends 120 s before the end: another scene lies behind it.
        assert_eq!(
            offering(1330.0, &[credits()], true),
            skip(1380.0, Art::Credits)
        );
        assert_eq!(
            offering(1330.0, &[credits()], false),
            skip(1380.0, Art::Credits),
            "auch in der letzten Folge will man zur Szene danach"
        );
        assert_eq!(
            offering(1400.0, &[credits()], true),
            ButtonOffering::NextEpisode
        );
        assert!(
            !SectionLogic::card_due(1400.0, 1500.0, &[credits()], true, None),
            "die Szene nach dem Abspann bekommt keine Karte ins Bild"
        );
        assert!(
            !SectionLogic::card_due(1491.0, 1500.0, &[credits()], true, None),
            "auch nicht kurz vor Schluss"
        );
    }

    #[test]
    fn credits_tolerance() {
        let tight = Segment::new(Art::Credits, 1400.0, 1498.0);
        let prior = Segment::new(Art::Credits, 1400.0, 1497.0);
        assert_eq!(
            offering(1410.0, &[tight], true),
            ButtonOffering::NextEpisode
        );
        assert_eq!(offering(1410.0, &[prior], true), skip(1497.0, Art::Credits));
    }

    #[test]
    fn credits_until_end_last_episode() {
        let until_end = Segment::new(Art::Credits, 1320.0, 1500.0);
        assert_eq!(
            offering(1330.0, &[until_end], false),
            ButtonOffering::Nobody
        );
    }

    #[test]
    fn min_length() {
        let short = Segment::new(Art::IntroSegment, 10.0, 12.9);
        let enough = Segment::new(Art::IntroSegment, 10.0, 13.0);
        assert_eq!(offering(10.0, &[short], false), ButtonOffering::Nobody);
        assert_eq!(
            offering(10.0, &[enough], false),
            skip(13.0, Art::IntroSegment)
        );
    }

    #[test]
    fn short_credits() {
        let short = Segment::new(Art::Credits, 1498.0, 1500.0);
        assert_eq!(
            offering(1400.0, &[short], true),
            ButtonOffering::NextEpisode
        );
    }

    #[test]
    fn card_without_sections() {
        assert_eq!(offering(1400.0, &[], true), ButtonOffering::NextEpisode);
        assert!(!SectionLogic::card_due(1400.0, 1500.0, &[], true, None));
        assert!(!SectionLogic::card_due(1499.0, 1500.0, &[], true, None));
        let intro = Segment::new(Art::IntroSegment, 10.0, 60.0);
        assert!(!SectionLogic::card_due(
            1499.0,
            1500.0,
            &[intro],
            true,
            None
        ));
    }

    #[test]
    fn countdown_length() {
        assert_eq!(SectionLogic::countdown(1320.0, 1500.0), 7.0);
        assert_eq!(SectionLogic::countdown(1496.0, 1500.0), 4.0);
        assert_eq!(SectionLogic::countdown(1500.0, 1500.0), 1.0);
    }

    #[test]
    fn card_with_credits() {
        let until_end = Segment::new(Art::Credits, 1320.0, 1500.0);
        assert!(!SectionLogic::card_due(
            1319.0,
            1500.0,
            &[until_end],
            true,
            None
        ));
        assert!(SectionLogic::card_due(
            1320.0,
            1500.0,
            &[until_end],
            true,
            None
        ));
    }

    #[test]
    fn earlier_credits() {
        let early = Segment::new(Art::Credits, 1100.0, 1500.0);
        assert!(
            !episodes_end::button_show(1100.0, 1500.0),
            "nach der alten Regel wäre hier noch nichts"
        );
        assert_eq!(
            offering(1100.0, &[early], true),
            ButtonOffering::NextEpisode
        );
    }

    #[test]
    fn later_credits() {
        let late = Segment::new(Art::Credits, 1490.0, 1500.0);
        assert!(
            episodes_end::button_show(1400.0, 1500.0),
            "nach der alten Regel stünde er hier"
        );
        assert_eq!(
            offering(1400.0, &[late], true),
            ButtonOffering::Nobody,
            "die Angabe des Servers gilt allein"
        );
    }

    #[test]
    fn intro_wins() {
        let everywhere = Segment::new(Art::Credits, 0.0, 1500.0);
        assert_eq!(
            offering(30.0, &[everywhere, intro_segment()], true),
            skip(90.0, Art::IntroSegment)
        );
    }

    /// findroid#1123: after jumping to the segment end the player stood just before it and
    /// offered the same jump again.
    #[test]
    fn no_second_offering() {
        // An end that cannot be written evenly in milliseconds.
        let json = r#"{"Type":"Intro","StartTicks":120000000,"EndTicks":899999999}"#;
        let intro: Segment = serde_json::from_str(json).expect("decodes");
        let ButtonOffering::Skip { to, .. } = offering(20.0, &[intro], true) else {
            panic!("kein Angebot im Vorspann");
        };
        // The way the player jumps: whole milliseconds, truncated.
        let landed = (to * 1000.0).trunc() / 1000.0;
        for beside in [0.0, 0.001, 0.5, 1.0, SectionLogic::MIN_REMAINING - 0.01] {
            assert_eq!(
                offering(landed - beside, &[intro], true),
                ButtonOffering::Nobody,
                "gelandet {beside} s vor dem Ende"
            );
        }
    }

    // MARK: SectionAutomaticTests (5)

    fn parts() -> [Segment; 3] {
        [
            Segment::new(Art::IntroSegment, 10.0, 70.0),
            Segment::new(Art::LookBack, 80.0, 120.0),
            Segment::new(Art::Credits, 1300.0, 1400.0),
        ]
    }

    #[test]
    fn automatic_intro() {
        let a = SectionLogic::automatic(12.0, 1400.0, &parts(), true);
        assert_eq!(a.map(|a| a.offering), Some(skip(70.0, Art::IntroSegment)));
    }

    #[test]
    fn automatic_recap() {
        assert!(SectionLogic::automatic(90.0, 1400.0, &parts(), true).is_none());
    }

    #[test]
    fn automatic_credits() {
        assert_eq!(
            SectionLogic::automatic(1301.0, 1400.0, &parts(), true).map(|a| a.offering),
            Some(ButtonOffering::NextEpisode)
        );
        assert!(SectionLogic::automatic(1301.0, 1400.0, &parts(), false).is_none());
    }

    #[test]
    fn automatic_credits_then_scene() {
        let a = SectionLogic::automatic(1301.0, 1500.0, &parts(), true);
        assert_eq!(a.map(|a| a.offering), Some(skip(1400.0, Art::Credits)));
    }

    #[test]
    fn automatic_outside() {
        assert!(SectionLogic::automatic(500.0, 1400.0, &parts(), true).is_none());
    }

    // MARK: EpisodesCardTests (2 of 7, the ones that need Segment/SectionLogic)

    #[test]
    fn no_credits_in_last_thirty_seconds() {
        let broad = SectionLogic::card_due(1400.0, 1500.0, &[], true, Some(30.0));
        let near = SectionLogic::card_due(1471.0, 1500.0, &[], true, Some(30.0));
        assert!(!broad && near);
        // Without a window the old behavior stays.
        assert!(!SectionLogic::card_due(1471.0, 1500.0, &[], true, None));
        // The countdown then runs to the end, not seven seconds.
        assert_eq!(
            SectionLogic::countdown_with_sections(1471.0, 1500.0, &[], Some(30.0)),
            29.0
        );
        let credits = Segment::new(Art::Credits, 1320.0, 1500.0);
        assert_eq!(
            SectionLogic::countdown_with_sections(1400.0, 1500.0, &[credits], Some(30.0)),
            7.0
        );
    }

    #[test]
    fn with_credits_applies_credits() {
        let credits = Segment::new(Art::Credits, 1320.0, 1500.0);
        assert!(SectionLogic::card_due(
            1320.0,
            1500.0,
            &[credits],
            true,
            Some(30.0)
        ));
        let with_scene = Segment::new(Art::Credits, 1300.0, 1380.0);
        assert!(!SectionLogic::card_due(
            1480.0,
            1500.0,
            &[with_scene],
            true,
            Some(30.0)
        ));
    }

    // Extra (not in Swift): wire names, labels and the tick round trip.
    #[test]
    fn wire_names_labels_and_encode() {
        let s = Segment::new(Art::LookBack, 1.5, 3.0);
        let json = serde_json::to_string(&s).expect("encodes");
        assert_eq!(
            json,
            r#"{"Type":"Recap","StartTicks":15000000,"EndTicks":30000000}"#
        );
        let back: Segment = serde_json::from_str(&json).expect("decodes");
        assert_eq!(back, s);
        assert_eq!(Art::Ads.label(), "Werbung überspringen");
        assert_eq!(ButtonOffering::NextEpisode.label(), "Nächste Folge");
        assert_eq!(skip(1.0, Art::Preview).symbol_text(), "forward.fill");
        assert_eq!(
            ButtonOffering::NextEpisode.symbol_text(),
            "forward.end.fill"
        );
        assert!(!ButtonOffering::Nobody.visible());
    }
}
