//! The values a [`crate::KeyValueStore`] holds.

use std::collections::BTreeMap;

/// A stored value, the set `UserDefaults` supports for our keys.
#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    /// `Bool`.
    Bool(bool),
    /// `Int`.
    Int(i64),
    /// `Double`.
    Double(f64),
    /// `String`.
    Str(String),
    /// `Data` (JSON documents, mostly).
    Data(Vec<u8>),
    /// `[String]` (`stringArray(forKey:)`).
    StrList(Vec<String>),
    /// `[String: String]` (`serverNamenCache`, per-title track rules).
    StrMap(BTreeMap<String, String>),
}

/// The type of a value, for the key registry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ValueType {
    /// Bool.
    Bool,
    /// Int.
    Int,
    /// Double.
    Double,
    /// String.
    String,
    /// Data.
    Data,
    /// `[String]`.
    StringList,
    /// `[String: String]`.
    StringMap,
}

impl Value {
    /// The type tag of this value.
    pub fn value_type(&self) -> ValueType {
        match self {
            Self::Bool(_) => ValueType::Bool,
            Self::Int(_) => ValueType::Int,
            Self::Double(_) => ValueType::Double,
            Self::Str(_) => ValueType::String,
            Self::Data(_) => ValueType::Data,
            Self::StrList(_) => ValueType::StringList,
            Self::StrMap(_) => ValueType::StringMap,
        }
    }
}
