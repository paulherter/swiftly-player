//! Which look the app wears, and what trying one on may change (`LookTryOn.swift`). The rules
//! as one value, testable without a screen.

use std::collections::BTreeSet;

use crate::look::{Look, LookSelection};

/// What "Keep" does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeepResult {
    /// Stored; the preview is closed.
    Kept,
    /// Nothing stored; the support sheet should open.
    NeedsSupport,
    /// There was no preview to keep.
    Nothing,
}

/// The try-on state machine.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct LookTryOn {
    saved: LookSelection,
    preview: Option<LookSelection>,
    pending_keep: Option<LookSelection>,
    is_supporter: bool,
    owned: BTreeSet<String>,
}

impl LookTryOn {
    /// A state from what is stored.
    pub fn new(saved: LookSelection, is_supporter: bool, owned: BTreeSet<String>) -> Self {
        Self {
            saved,
            preview: None,
            pending_keep: None,
            is_supporter,
            owned,
        }
    }

    /// The stored choice.
    pub fn saved(&self) -> &LookSelection {
        &self.saved
    }
    /// The look being tried on.
    pub fn preview(&self) -> Option<&LookSelection> {
        self.preview.as_ref()
    }
    /// "Keep" by a non-supporter, waiting for the purchase.
    pub fn pending_keep(&self) -> Option<&LookSelection> {
        self.pending_keep.as_ref()
    }
    /// Whether this device belongs to a supporter.
    pub fn is_supporter(&self) -> bool {
        self.is_supporter
    }
    /// The gifts picked up, by look id.
    pub fn owned(&self) -> &BTreeSet<String> {
        &self.owned
    }

    /// What the app draws with now.
    pub fn shown(&self) -> LookSelection {
        if let Some(preview) = &self.preview {
            return preview.clone();
        }
        if self.may_wear(&self.saved) {
            self.saved.clone()
        } else {
            LookSelection::original()
        }
    }

    /// The original and picked-up gifts for everyone (glow and icon free), a picked accent
    /// colour and every other look for a supporter.
    pub fn may_wear(&self, selection: &LookSelection) -> bool {
        if self.is_supporter {
            return true;
        }
        let look = selection.look();
        if !(look == Look::ORIGINAL || (look.is_gift && self.owned.contains(look.id))) {
            return false;
        }
        selection.accent_id.is_none()
    }

    /// Picked up at least one gift.
    pub fn owns_look(&self) -> bool {
        !self.owned.is_empty()
    }

    /// Whether a preview is open.
    pub fn is_previewing(&self) -> bool {
        self.preview.is_some()
    }

    /// Opens the preview on exactly what is shown now.
    pub fn begin(&mut self) {
        self.preview = Some(self.shown());
        self.pending_keep = None;
    }

    /// One change inside the preview; ignored without one.
    pub fn try_on(&mut self, selection: LookSelection) {
        if self.preview.is_some() {
            self.preview = Some(selection);
        }
    }

    /// "End preview" or the preview going away for any other reason.
    pub fn end(&mut self) {
        self.preview = None;
        self.pending_keep = None;
    }

    /// "Keep".
    pub fn keep(&mut self) -> KeepResult {
        let Some(preview) = self.preview.clone() else {
            return KeepResult::Nothing;
        };
        if self.may_wear(&preview) {
            self.saved = preview;
            self.preview = None;
            self.pending_keep = None;
            return KeepResult::Kept;
        }
        self.pending_keep = Some(preview);
        KeepResult::NeedsSupport
    }

    /// The support sheet closed: a waiting wish is forgotten.
    pub fn support_sheet_closed(&mut self) {
        self.pending_keep = None;
    }

    /// A purchase went through. A look waiting for it is stored and the preview ends; returns
    /// that look.
    pub fn purchase_completed(&mut self) -> Option<LookSelection> {
        self.is_supporter = true;
        let pending = self.pending_keep.take()?;
        self.saved = pending.clone();
        self.preview = None;
        Some(pending)
    }

    /// The supporter state changed from elsewhere (restore, refund, the preview reset).
    pub fn set_supporter(&mut self, supporter: bool) {
        self.is_supporter = supporter;
        if !supporter {
            self.pending_keep = None;
        }
    }

    /// A look picked directly; ignored (false) when it may not be worn.
    pub fn choose(&mut self, selection: LookSelection) -> bool {
        if !self.may_wear(&selection) {
            return false;
        }
        self.saved = selection;
        true
    }

    /// "Grab it": the gift is picked up for good and worn right away. Anything that is not a
    /// gift is ignored. Returns the selection now stored.
    pub fn claim(&mut self, look: &Look) -> Option<LookSelection> {
        if !look.is_gift {
            return None;
        }
        self.owned.insert(look.id.to_owned());
        self.saved = LookSelection::of(look.id);
        self.preview = None;
        self.pending_keep = None;
        Some(self.saved.clone())
    }

    /// Back to a fresh install.
    pub fn reset(&mut self) {
        *self = Self::default();
    }
}
