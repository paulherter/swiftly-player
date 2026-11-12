//! Language tags.

/// A language tag such as `de`, `ru`, `pt-BR` or `zh-Hans-CN`, split into the parts
/// the catalogue lookup needs.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Locale {
    language: String,
    region: Option<String>,
}

impl Locale {
    /// The language the keys are written in.
    pub const SOURCE_LANGUAGE: &'static str = "de";

    /// Parses a tag. `_` and `-` both separate; `.UTF-8` or `@calendar` suffixes are
    /// dropped; an empty or broken tag gives the source language.
    pub fn parse(tag: &str) -> Self {
        let cut = tag.split(['.', '@']).next().unwrap_or("");
        let mut parts = cut.split(['-', '_']).filter(|p| !p.is_empty());
        let language = match parts.next() {
            Some(l)
                if l.len() >= 2 && l.len() <= 3 && l.chars().all(|c| c.is_ascii_alphabetic()) =>
            {
                l.to_ascii_lowercase()
            }
            _ => return Self::default(),
        };
        let region = parts
            .find(|p| {
                (p.len() == 2 && p.chars().all(|c| c.is_ascii_alphabetic()))
                    || (p.len() == 3 && p.chars().all(|c| c.is_ascii_digit()))
            })
            .map(str::to_ascii_uppercase);
        Self { language, region }
    }

    /// The primary language subtag, lower case (`"pt"`).
    pub fn language(&self) -> &str {
        &self.language
    }

    /// The region subtag, upper case (`"BR"`), if the tag had one.
    pub fn region(&self) -> Option<&str> {
        self.region.as_deref()
    }

    /// `language` or `language-REGION`; used to pick plural rules (pt-PT differs from pt).
    pub fn tag(&self) -> String {
        match &self.region {
            Some(r) => format!("{}-{}", self.language, r),
            None => self.language.clone(),
        }
    }

    /// The languages to try for a lookup, in order: own language, English, German.
    pub fn fallback_chain(&self) -> Vec<&str> {
        let mut chain = vec![self.language.as_str()];
        for l in ["en", Self::SOURCE_LANGUAGE] {
            if !chain.contains(&l) {
                chain.push(l);
            }
        }
        chain
    }
}

impl Default for Locale {
    fn default() -> Self {
        Self {
            language: Self::SOURCE_LANGUAGE.to_owned(),
            region: None,
        }
    }
}
