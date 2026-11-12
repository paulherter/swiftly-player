//! The look store over a [`KeyValueStore`]: load, the save funnel, the owned set, the effects
//! switch and reset (`Sources/Shared/LookStore.swift`). Observation and locking stay with the
//! host; this is the part that decides what is read and written.

use std::collections::BTreeSet;

use swiftly_settings::{KeyValueStore, StoreError, Value};

use crate::gift::{GiftContext, LookGift};
use crate::look::{Look, LookSelection, storage_key};
use crate::time::{Calendar, Timestamp};
use crate::try_on::{KeepResult, LookTryOn};

/// The look state plus the store it is saved to.
pub struct LookStore<S: KeyValueStore> {
    store: S,
    state: LookTryOn,
    effects: bool,
}

impl<S: KeyValueStore> LookStore<S> {
    /// Loads like `LookStore.init` (`LookStore.swift:35-39`): the selection from its JSON, the
    /// owned list, the effects switch (default on).
    pub fn load(store: S) -> Self {
        let selection = LookSelection::decoded(store.get_data(storage_key::SELECTION).as_deref());
        let owned: BTreeSet<String> = match store.get(storage_key::OWNED) {
            Some(Value::StrList(list)) => list.into_iter().collect(),
            _ => BTreeSet::new(),
        };
        let effects = store.get_bool(storage_key::EFFECTS).unwrap_or(true);
        Self {
            store,
            state: LookTryOn::new(selection, false, owned),
            effects,
        }
    }

    /// The store underneath.
    pub fn store(&self) -> &S {
        &self.store
    }
    /// The rules value.
    pub fn state(&self) -> &LookTryOn {
        &self.state
    }
    /// What the app shows right now.
    pub fn selection(&self) -> LookSelection {
        self.state.shown()
    }
    /// "Bats and details".
    pub fn effects_on(&self) -> bool {
        self.effects
    }

    /// Sets the effects switch and stores it.
    pub fn set_effects_on(&mut self, on: bool) -> Result<(), StoreError> {
        self.effects = on;
        self.store.set(storage_key::EFFECTS, Value::Bool(on))
    }

    /// The funnel (`change()`, `LookStore.swift:152-166`): runs the change, then stores the
    /// selection (sorted-key JSON) only if the saved one changed, and the owned ids (sorted)
    /// only if that set changed.
    pub fn change<R>(&mut self, body: impl FnOnce(&mut LookTryOn) -> R) -> Result<R, StoreError> {
        let before = self.state.saved().clone();
        let owned_before = self.state.owned().clone();
        let result = body(&mut self.state);
        if *self.state.saved() != before {
            self.store.set(
                storage_key::SELECTION,
                Value::Data(self.state.saved().encoded()),
            )?;
        }
        if *self.state.owned() != owned_before {
            let sorted: Vec<String> = self.state.owned().iter().cloned().collect();
            self.store.set(storage_key::OWNED, Value::StrList(sorted))?;
        }
        Ok(result)
    }

    /// From the support state.
    pub fn set_supporter(&mut self, supporter: bool) -> Result<(), StoreError> {
        self.change(|s| s.set_supporter(supporter))
    }
    /// Opens a preview.
    pub fn begin_preview(&mut self) -> Result<(), StoreError> {
        self.change(LookTryOn::begin)
    }
    /// One change inside the preview.
    pub fn try_on(&mut self, selection: LookSelection) -> Result<(), StoreError> {
        self.change(|s| s.try_on(selection))
    }
    /// Ends the preview.
    pub fn end_preview(&mut self) -> Result<(), StoreError> {
        self.change(LookTryOn::end)
    }
    /// "Keep".
    pub fn keep(&mut self) -> Result<KeepResult, StoreError> {
        self.change(LookTryOn::keep)
    }
    /// The support sheet closed.
    pub fn support_sheet_closed(&mut self) -> Result<(), StoreError> {
        self.change(LookTryOn::support_sheet_closed)
    }
    /// A purchase went through.
    pub fn purchase_completed(&mut self) -> Result<Option<LookSelection>, StoreError> {
        self.change(LookTryOn::purchase_completed)
    }
    /// A look picked directly.
    pub fn choose(&mut self, selection: LookSelection) -> Result<bool, StoreError> {
        self.change(|s| s.choose(selection))
    }
    /// "Grab it".
    pub fn claim(&mut self, look: &Look) -> Result<Option<LookSelection>, StoreError> {
        self.change(|s| s.claim(look))
    }

    /// Back to a fresh install: state, the gift offers and the effects switch (`reset()`,
    /// `LookStore.swift:145-150`). Stored selection and owned ids are rewritten by the funnel.
    pub fn reset(&mut self) -> Result<(), StoreError> {
        self.change(LookTryOn::reset)?;
        self.store.remove(storage_key::GIFT_OFFERED)?;
        self.set_effects_on(true)
    }

    /// The gift offers already made.
    pub fn offered(&self) -> BTreeSet<String> {
        match self.store.get(storage_key::GIFT_OFFERED) {
            Some(Value::StrList(list)) => list.into_iter().collect(),
            _ => BTreeSet::new(),
        }
    }

    /// Remembers that the pop-up for this gift was shown in this season
    /// (`markOffered`, `LookGiftSheet.swift:119-126`).
    pub fn mark_offered(
        &self,
        look: &Look,
        now: Timestamp,
        calendar: Calendar,
    ) -> Result<(), StoreError> {
        let Some(id) = LookGift::offer_id(look, now, calendar) else {
            return Ok(());
        };
        let mut all = self.offered();
        all.insert(id);
        self.store.set(
            storage_key::GIFT_OFFERED,
            Value::StrList(all.into_iter().collect()),
        )
    }

    /// The gift context for the due check, with this store's owned and offered sets.
    pub fn gift_context(
        &self,
        now: Timestamp,
        home_ready: bool,
        playing: bool,
        asked: bool,
        seconds_on_home: f64,
    ) -> GiftContext {
        GiftContext {
            now,
            home_ready,
            playing,
            asked_this_session: asked,
            seconds_on_home,
            owned: self.state.owned().clone(),
            offered: self.offered(),
        }
    }

    /// The looks this person can pick from right now: the original, gifts picked up or in
    /// their window (`freeLooks`).
    pub fn free_looks(&self, now: Timestamp, calendar: Calendar) -> Vec<Look> {
        Look::free()
            .into_iter()
            .filter(|l| LookGift::is_available(l, self.state.owned(), now, calendar))
            .collect()
    }

    /// Every look the picker shows, the locked ones too (`pickerLooks`).
    pub fn picker_looks(&self, now: Timestamp, calendar: Calendar) -> Vec<Look> {
        Look::ALL
            .into_iter()
            .filter(|l| !l.is_gift || LookGift::is_available(l, self.state.owned(), now, calendar))
            .collect()
    }
}

/// What to do with the app icon after a look change (`LookIcon.apply`, `LookStore.swift:331-360`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IconStep<'a> {
    /// Leave the icon as it is.
    Keep,
    /// Switch to this alternate icon (`None` puts the regular one back).
    Set(Option<&'a str>),
}

/// The icon step for a look's icon name. Only the looks' own icons are switched: asking for the
/// regular icon (`None`) while a supporter icon is set leaves it alone, and an icon that is
/// already set is not set again.
pub fn look_icon_step<'a>(
    current_alternate: Option<&str>,
    wanted: Option<&'a str>,
) -> IconStep<'a> {
    if wanted.is_none()
        && !Look::ALL
            .iter()
            .filter_map(|l| l.icon_name)
            .any(|n| Some(n) == current_alternate)
    {
        return IconStep::Keep;
    }
    if current_alternate == wanted {
        return IconStep::Keep;
    }
    IconStep::Set(wanted)
}

/// The Mac Dock icon asset for a look icon: `AppIcon-X` becomes `DockIcon-X`.
pub fn dock_icon_name(icon: &str) -> String {
    icon.replacen("AppIcon-", "DockIcon-", 1)
}
