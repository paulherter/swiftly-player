use serde::{Deserialize, Deserializer, Serialize, Serializer, de::DeserializeOwned};

/// A list that skips what cannot be read.
///
/// Port of `Lenient<Amount>` (JellyfinKit/Models.swift:95): a server that
/// returns one broken entry must not make a list unusable. Each element that
/// fails to decode as `T` is dropped, the rest comes through. A value that is
/// not an array at all still fails.
#[derive(Debug, Clone, PartialEq)]
pub struct Lenient<T>(
    /// The entries that could be read, in order.
    pub Vec<T>,
);

impl<'de, T: DeserializeOwned> Deserialize<'de> for Lenient<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        // Raw slices, not `Value`s: a number that does not fit a double (`1e400`) in one entry
        // must cost only that entry, as in Swift, not the whole list.
        let raw = Vec::<Box<serde_json::value::RawValue>>::deserialize(deserializer)?;
        Ok(Self(
            raw.into_iter()
                .filter_map(|v| serde_json::from_str(v.get()).ok())
                .collect(),
        ))
    }
}

/// A number that cannot topple the response.
///
/// Port of `NumberValue` (Models.swift:623). A float is taken as is, a string
/// is parsed (`"23.976"`), anything else (null, bool, object, junk text)
/// becomes `None` instead of an error. Jellyfin writes numeric fields such as
/// `RealFrameRate` as strings or not at all depending on the source.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct NumberValue {
    /// The parsed number, `None` if the wire value was not a number.
    pub value: Option<f64>,
}

impl NumberValue {
    /// Wrap a number (Models.swift:626).
    pub fn new(value: Option<f64>) -> Self {
        Self { value }
    }
}

impl<'de> Deserialize<'de> for NumberValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = serde_json::Value::deserialize(deserializer)?;
        let value = match raw {
            serde_json::Value::Number(n) => n.as_f64(),
            serde_json::Value::String(s) => s.parse::<f64>().ok(),
            _ => None,
        };
        Ok(Self { value })
    }
}

impl Serialize for NumberValue {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self.value {
            Some(v) => serializer.serialize_f64(v),
            None => serializer.serialize_none(),
        }
    }
}

/// `decodeIfPresent(Int.self)` as Foundation's `JSONDecoder` reads it: a whole number is taken
/// even when the server wrote it with a fraction part or an exponent (`2019.0`, `7.2e10`), `null`
/// is `None`, and a fraction (`2019.5`), a string or any other type is an error, so the entry is
/// dropped by [`Lenient`] exactly as in the Swift app.
pub(crate) fn whole_number<'de, D: Deserializer<'de>>(d: D) -> Result<Option<i64>, D::Error> {
    use serde::de::{Error, Visitor};
    struct V;
    impl<'de> Visitor<'de> for V {
        type Value = Option<i64>;
        fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("a whole number or null")
        }
        fn visit_i64<E: Error>(self, v: i64) -> Result<Self::Value, E> {
            Ok(Some(v))
        }
        fn visit_u64<E: Error>(self, v: u64) -> Result<Self::Value, E> {
            i64::try_from(v).map(Some).map_err(E::custom)
        }
        fn visit_f64<E: Error>(self, v: f64) -> Result<Self::Value, E> {
            // 2^63 as f64 is exact; i64::MIN as f64 is -2^63.
            if v.is_finite()
                && v.fract() == 0.0
                && (-9_223_372_036_854_775_808.0..9_223_372_036_854_775_808.0).contains(&v)
            {
                Ok(Some(v as i64))
            } else {
                Err(E::custom("not a whole number"))
            }
        }
        fn visit_none<E: Error>(self) -> Result<Self::Value, E> {
            Ok(None)
        }
        fn visit_unit<E: Error>(self) -> Result<Self::Value, E> {
            Ok(None)
        }
        fn visit_some<D2: Deserializer<'de>>(self, d: D2) -> Result<Self::Value, D2::Error> {
            d.deserialize_any(V)
        }
    }
    d.deserialize_option(V)
}

/// `decodeIfPresent(...) ?? []`: missing and `null` both give the default.
pub(crate) fn null_default<'de, D, T>(deserializer: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de> + Default,
{
    Ok(Option::<T>::deserialize(deserializer)?.unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skips_broken_entries() {
        let l: Lenient<i64> = serde_json::from_str(r#"[1,"x",null,3]"#).unwrap();
        assert_eq!(l.0, vec![1, 3]);
        assert!(serde_json::from_str::<Lenient<i64>>(r#"{"a":1}"#).is_err());
    }

    #[test]
    fn number_value_rules() {
        let n = |s: &str| serde_json::from_str::<NumberValue>(s).unwrap().value;
        assert_eq!(n("23.976"), Some(23.976));
        assert_eq!(n(r#""23.976""#), Some(23.976));
        assert_eq!(n("24"), Some(24.0));
        assert_eq!(n(r#""abc""#), None);
        assert_eq!(n("null"), None);
        assert_eq!(n("true"), None);
        assert_eq!(n("[1]"), None);
    }
}
