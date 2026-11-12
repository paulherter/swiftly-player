//! The shared focus engine: a pure model (no tree, no clock of its own, no render) that tells which focusable gets focus
//! when the D-pad, the arrow keys, Tab, Enter or Back arrive. The tvOS rules it follows (RF 4 and the Swift tvOS app):
//!
//! * one focused item; a move picks the nearest item in the pressed direction and prefers items that overlap the
//!   current one across the axis; a vertical run keeps its column (the anchor) through rows of different widths;
//! * nothing in that direction: focus stays and [`Outcome::Failed`] is reported (no wrap, unless a scope asks for it);
//! * sections ([`ScopeKind::Section`]) can remember their last focused child: entering a remembering section from
//!   outside lands there, not on the geometrically nearest item (tab bar to content and back);
//! * a trap ([`ScopeKind::Trap`], sheet or modal) confines focus; Back closes it and focus returns to what had focus
//!   before it opened (DESIGN rule `overlay-focus-return`);
//! * a press that is held for [`tuning::LONG_PRESS_MS`] fires the long action, a shorter one activates.
//!
//! The model is fed a [`FocusMap`] (frames in screen points, tree order) that `Ui` builds from the live tree, or tests
//! build by hand. Every constant is in [`tuning`].

use crate::tuning;
use crate::view::Action;
use std::collections::HashMap;
use swiftly_layout::Rect;

/// Identity of a focusable item or a scope.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct FocusId(pub u64);

impl From<&str> for FocusId {
    fn from(s: &str) -> FocusId {
        FocusId(crate::view::Key::from(s).0)
    }
}
impl From<u64> for FocusId {
    fn from(v: u64) -> FocusId {
        FocusId(v)
    }
}
impl From<usize> for FocusId {
    fn from(v: usize) -> FocusId {
        FocusId(v as u64)
    }
}

/// A direction of the D-pad or the arrow keys.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dir {
    /// Up.
    Up,
    /// Down.
    Down,
    /// Left.
    Left,
    /// Right.
    Right,
}

impl Dir {
    fn horizontal(self) -> bool {
        matches!(self, Dir::Left | Dir::Right)
    }
}

/// What a scope is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScopeKind {
    /// A plain section (a rail, a grid, a button row).
    Section,
    /// The tab bar: Back from content moves focus here before it pops.
    Bar,
    /// A sheet or modal: focus cannot leave it, Back closes it.
    Trap,
}

/// A group of items: where focus is remembered, trapped or wrapped.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScopeSpec {
    /// Identity.
    pub id: FocusId,
    /// Kind.
    pub kind: ScopeKind,
    /// Entering from outside lands on the last focused child (when it still exists).
    pub remember: bool,
    /// A move past the last item wraps to the first (not on tvOS; for the alphabet rail and the desktop).
    pub wrap: bool,
}

impl ScopeSpec {
    /// A section that does not remember and does not wrap.
    pub fn section(id: impl Into<FocusId>) -> ScopeSpec {
        ScopeSpec {
            id: id.into(),
            kind: ScopeKind::Section,
            remember: false,
            wrap: false,
        }
    }
    /// A section that hands focus to the child that had it last.
    #[must_use]
    pub fn remembering(mut self) -> ScopeSpec {
        self.remember = true;
        self
    }
    /// A section that wraps at its ends.
    #[must_use]
    pub fn wrapping(mut self) -> ScopeSpec {
        self.wrap = true;
        self
    }
    /// The tab bar (remembers its selected tab).
    pub fn bar(id: impl Into<FocusId>) -> ScopeSpec {
        ScopeSpec {
            kind: ScopeKind::Bar,
            remember: true,
            ..ScopeSpec::section(id)
        }
    }
    /// A sheet or modal.
    pub fn trap(id: impl Into<FocusId>) -> ScopeSpec {
        ScopeSpec {
            kind: ScopeKind::Trap,
            remember: true,
            ..ScopeSpec::section(id)
        }
    }
}

/// One focusable item.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Item {
    /// Identity.
    pub id: FocusId,
    /// Frame in screen points.
    pub rect: Rect,
    /// Innermost scope.
    pub scope: Option<FocusId>,
    /// Gets focus first when nothing else is asked for.
    pub default: bool,
    /// Reported on activation.
    pub tap: Option<Action>,
    /// Reported on a long press; without it a long press activates like a click.
    pub long: Option<Action>,
}

impl Item {
    /// An item with a frame and no actions.
    pub fn new(id: impl Into<FocusId>, rect: Rect) -> Item {
        Item {
            id: id.into(),
            rect,
            scope: None,
            default: false,
            tap: None,
            long: None,
        }
    }
}

/// The focusables of one screen in tree order, and their scopes.
#[derive(Clone, Debug, Default)]
pub struct FocusMap {
    items: Vec<Item>,
    scopes: Vec<(ScopeSpec, Option<FocusId>)>,
}

impl FocusMap {
    /// An empty map.
    pub fn new() -> FocusMap {
        FocusMap::default()
    }
    /// Adds a scope inside `parent` (tree order: before its items).
    pub fn add_scope(&mut self, spec: ScopeSpec, parent: Option<FocusId>) {
        self.scopes.push((spec, parent));
    }
    /// Adds an item (tree order).
    pub fn add_item(&mut self, item: Item) {
        self.items.push(item);
    }
    /// Builder form of [`add_scope`](Self::add_scope).
    #[must_use]
    pub fn scope(mut self, spec: ScopeSpec, parent: Option<FocusId>) -> FocusMap {
        self.add_scope(spec, parent);
        self
    }
    /// Builder form of [`add_item`](Self::add_item): an item at `(x, y, w, h)` in `scope`.
    #[must_use]
    pub fn item(
        mut self,
        id: impl Into<FocusId>,
        scope: Option<FocusId>,
        (x, y, w, h): (f32, f32, f32, f32),
    ) -> FocusMap {
        let mut it = Item::new(id, Rect::new(x, y, w, h));
        it.scope = scope;
        self.add_item(it);
        self
    }
    /// The items in tree order.
    pub fn items(&self) -> &[Item] {
        &self.items
    }
    /// An item by id.
    pub fn get(&self, id: FocusId) -> Option<&Item> {
        self.items.iter().find(|i| i.id == id)
    }

    fn spec(&self, id: FocusId) -> Option<&(ScopeSpec, Option<FocusId>)> {
        self.scopes.iter().find(|(s, _)| s.id == id)
    }
    /// Scope ids from the innermost outwards.
    fn chain(&self, mut scope: Option<FocusId>) -> Vec<FocusId> {
        let mut out = vec![];
        while let Some(id) = scope {
            if out.contains(&id) {
                break;
            }
            out.push(id);
            scope = self.spec(id).and_then(|(_, p)| *p);
        }
        out
    }
    fn chain_of(&self, item: &Item) -> Vec<FocusId> {
        self.chain(item.scope)
    }
    fn within(&self, item: &Item, scope: FocusId) -> bool {
        self.chain_of(item).contains(&scope)
    }
    /// The topmost trap that has items (the last in tree order), if any.
    fn active_trap(&self) -> Option<FocusId> {
        self.scopes
            .iter()
            .rev()
            .filter(|(s, _)| s.kind == ScopeKind::Trap)
            .map(|(s, _)| s.id)
            .find(|t| self.items.iter().any(|i| self.within(i, *t)))
    }
    /// Items focus may be on: those inside the active trap, or all.
    fn eligible(&self) -> Vec<&Item> {
        match self.active_trap() {
            Some(t) => self.items.iter().filter(|i| self.within(i, t)).collect(),
            None => self.items.iter().collect(),
        }
    }
}

/// A key the engine understands, already mapped from the window system.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NavKey {
    /// An arrow key or a D-pad direction.
    Arrow(Dir),
    /// Tab.
    Tab,
    /// Shift+Tab.
    ShiftTab,
    /// Enter, Space or the remote's select button.
    Enter,
    /// Esc or the remote's Menu button.
    Escape,
}

/// What Back does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BackOutcome {
    /// The trap scope must be closed by the app; focus returns to what had it before the trap opened.
    CloseTrap(FocusId),
    /// Focus moved to the tab bar item.
    ToBar(FocusId),
    /// Nothing to do inside the screen: the app pops the page (or leaves).
    Pop,
}

/// The result of an input.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Outcome {
    /// Nothing happened.
    None,
    /// Focus is shown for the first time (desktop: on the first key press); it did not move.
    Shown(FocusId),
    /// Focus moved.
    Moved {
        /// Where it was.
        from: FocusId,
        /// Where it is.
        to: FocusId,
    },
    /// No item in that direction: focus stays (the shake of the remote's "movement failed").
    Failed(Dir),
    /// The focused item was activated.
    Activated(FocusId, Option<Action>),
    /// The focused item was long-pressed.
    LongPressed(FocusId, Option<Action>),
    /// Back.
    Back(BackOutcome),
}

#[derive(Clone, Copy, Debug)]
struct Held {
    since: f64,
    fired: bool,
}

/// The focus state: which item has focus, the remembered column, the scope memory and a held press.
#[derive(Clone, Debug, Default)]
pub struct Focus {
    current: Option<FocusId>,
    anchor: (f32, f32),
    memory: HashMap<FocusId, FocusId>,
    trap: Option<FocusId>,
    returns: Vec<FocusId>,
    held: Option<Held>,
}

fn center(r: Rect) -> (f32, f32) {
    (r.x + r.w / 2.0, r.y + r.h / 2.0)
}

fn overlap(a0: f32, a1: f32, b0: f32, b1: f32) -> f32 {
    a1.min(b1) - a0.max(b0)
}

impl Focus {
    /// A focus with nothing focused.
    pub fn new() -> Focus {
        Focus::default()
    }

    /// The focused item.
    pub fn current(&self) -> Option<FocusId> {
        self.current
    }

    /// The item remembered for a scope.
    pub fn remembered(&self, scope: FocusId) -> Option<FocusId> {
        self.memory.get(&scope).copied()
    }

    /// Whether a press is held right now.
    pub fn is_held(&self) -> bool {
        self.held.is_some()
    }

    /// Puts focus on `id` (when it is eligible). Returns whether it is now there.
    pub fn set(&mut self, map: &FocusMap, id: FocusId) -> bool {
        if !map.eligible().iter().any(|i| i.id == id) {
            return false;
        }
        self.land(map, id, None);
        true
    }

    fn land(&mut self, map: &FocusMap, id: FocusId, dir: Option<Dir>) {
        let Some(item) = map.get(id) else { return };
        let c = center(item.rect);
        self.anchor = match dir {
            Some(Dir::Up | Dir::Down) => (self.anchor.0, c.1),
            _ => c,
        };
        for s in map.chain_of(item) {
            self.memory.insert(s, id);
        }
        self.current = Some(id);
        self.held = None;
    }

    /// Repairs focus after the map changed: keeps it when it is still eligible, otherwise falls back to what was
    /// focused before a trap opened, the trap's remembered child, a default item, or the first item.
    pub fn sync(&mut self, map: &FocusMap) {
        let trap = map.active_trap();
        if trap != self.trap {
            if let (None, Some(_)) = (self.trap, trap)
                && let Some(c) = self.current
            {
                self.returns.push(c);
            }
            self.trap = trap;
        }
        let eligible = map.eligible();
        if let Some(c) = self.current
            && eligible.iter().any(|i| i.id == c)
        {
            return;
        }
        self.held = None;
        let pick = if trap.is_none() {
            // A trap closed: return to what had focus before it.
            let mut back = None;
            while let Some(r) = self.returns.pop() {
                if eligible.iter().any(|i| i.id == r) {
                    back = Some(r);
                    break;
                }
            }
            back
        } else {
            None
        };
        let pick = pick
            .or_else(|| {
                trap.and_then(|t| self.memory.get(&t).copied())
                    .filter(|m| eligible.iter().any(|i| i.id == *m))
            })
            .or_else(|| eligible.iter().find(|i| i.default).map(|i| i.id))
            .or_else(|| eligible.first().map(|i| i.id));
        match pick {
            Some(id) => self.land(map, id, None),
            None => self.current = None,
        }
    }

    // ---- directional move ---------------------------------------------------------------------------------

    /// Moves focus one step in `dir`.
    pub fn move_dir(&mut self, map: &FocusMap, dir: Dir) -> Outcome {
        self.sync(map);
        let Some(from_id) = self.current else {
            return Outcome::Failed(dir);
        };
        let Some(from) = map.get(from_id).copied() else {
            return Outcome::Failed(dir);
        };
        let eligible = map.eligible();
        let best = eligible
            .iter()
            .filter(|i| i.id != from_id)
            .filter_map(|i| self.score(&from, i, dir).map(|s| (s, i.id)))
            .min_by(|a, b| a.0.total_cmp(&b.0))
            .map(|(_, id)| id)
            .or_else(|| self.wrap_target(map, &from, dir));
        let Some(mut to) = best else {
            return Outcome::Failed(dir);
        };
        // Entering a remembering section from outside lands on its remembered child.
        if let Some(target) = map.get(to) {
            let before = map.chain_of(&from);
            let entered: Vec<FocusId> = map
                .chain_of(target)
                .into_iter()
                .filter(|s| !before.contains(s))
                .collect();
            for s in entered.into_iter().rev() {
                let remembers = map.spec(s).is_some_and(|(spec, _)| spec.remember);
                if remembers
                    && let Some(m) = self.memory.get(&s).copied()
                    && eligible.iter().any(|i| i.id == m)
                {
                    to = m;
                    break;
                }
            }
        }
        self.land(map, to, Some(dir));
        Outcome::Moved { from: from_id, to }
    }

    /// Lower is better; `None` when `cand` is not in direction `dir`.
    fn score(&self, from: &Item, cand: &Item, dir: Dir) -> Option<f32> {
        let (a, b) = (from.rect, cand.rect);
        let tol = tuning::FOCUS_AHEAD_TOLERANCE_PT;
        // Gap along the axis between the facing edges (negative: they overlap along the axis).
        let gap = match dir {
            Dir::Right => b.x - (a.x + a.w),
            Dir::Left => a.x - (b.x + b.w),
            Dir::Down => b.y - (a.y + a.h),
            Dir::Up => a.y - (b.y + b.h),
        };
        if gap < -tol {
            return None;
        }
        // Across the axis the focused item counts as sitting at the remembered column (the anchor).
        let (ov, centre) = if dir.horizontal() {
            let lo = self.anchor.1 - a.h / 2.0;
            (
                overlap(lo, lo + a.h, b.y, b.y + b.h),
                (center(b).1 - self.anchor.1).abs(),
            )
        } else {
            let lo = self.anchor.0 - a.w / 2.0;
            (
                overlap(lo, lo + a.w, b.x, b.x + b.w),
                (center(b).0 - self.anchor.0).abs(),
            )
        };
        let miss = (-ov).max(0.0);
        let gap = gap.max(0.0);
        // Overlapping candidates always beat the others (tvOS searches the strip in front of the item first);
        // among them the nearest row wins, the remembered column breaks ties and tilts close calls.
        Some(if ov > 0.0 {
            gap + tuning::FOCUS_OVERLAP_CENTRE_WEIGHT * centre
        } else {
            tuning::FOCUS_NO_OVERLAP_PENALTY + gap + tuning::FOCUS_MISS_WEIGHT * miss + centre
        })
    }

    /// The target of a wrapping scope when nothing lies ahead: the far end of the same row or column.
    fn wrap_target(&self, map: &FocusMap, from: &Item, dir: Dir) -> Option<FocusId> {
        let scope = map.chain_of(from).into_iter().find(|s| {
            map.spec(*s)
                .is_some_and(|(spec, _)| spec.wrap && spec.kind != ScopeKind::Trap)
        })?;
        let a = from.rect;
        let eligible = map.eligible();
        eligible
            .iter()
            .filter(|i| i.id != from.id && map.within(i, scope))
            .filter(|i| {
                let b = i.rect;
                if dir.horizontal() {
                    overlap(a.y, a.y + a.h, b.y, b.y + b.h) > 0.0
                } else {
                    overlap(a.x, a.x + a.w, b.x, b.x + b.w) > 0.0
                }
            })
            .map(|i| {
                let r = i.rect;
                let far = match dir {
                    Dir::Right => r.x,
                    Dir::Left => -(r.x + r.w),
                    Dir::Down => r.y,
                    Dir::Up => -(r.y + r.h),
                };
                (far, i.id)
            })
            .min_by(|a, b| a.0.total_cmp(&b.0))
            .map(|(_, id)| id)
    }

    /// Tab (or Shift+Tab): the next item in tree order inside the active trap; wraps at the ends.
    pub fn tab(&mut self, map: &FocusMap, reverse: bool) -> Outcome {
        self.sync(map);
        let eligible = map.eligible();
        let (Some(from), n) = (self.current, eligible.len()) else {
            return Outcome::None;
        };
        let Some(pos) = eligible.iter().position(|i| i.id == from) else {
            return Outcome::None;
        };
        if n < 2 {
            return Outcome::None;
        }
        let next = if reverse {
            (pos + n - 1) % n
        } else {
            (pos + 1) % n
        };
        let to = eligible[next].id;
        self.land(map, to, None);
        Outcome::Moved { from, to }
    }

    // ---- activation, long press, back ---------------------------------------------------------------------

    /// The select button goes down at `now` ms.
    pub fn press(&mut self, map: &FocusMap, now: f64) {
        self.sync(map);
        if self.current.is_some() && self.held.is_none() {
            self.held = Some(Held {
                since: now,
                fired: false,
            });
        }
    }

    /// Advances the long-press timer: fires once after [`tuning::LONG_PRESS_MS`] when the item has a long action.
    pub fn tick(&mut self, map: &FocusMap, now: f64) -> Outcome {
        let (Some(h), Some(id)) = (self.held, self.current) else {
            return Outcome::None;
        };
        if h.fired || now - h.since < tuning::LONG_PRESS_MS {
            return Outcome::None;
        }
        let Some(long) = map.get(id).and_then(|i| i.long) else {
            return Outcome::None;
        };
        self.held = Some(Held { fired: true, ..h });
        Outcome::LongPressed(id, Some(long))
    }

    /// The select button goes up: a click unless the long press already fired.
    pub fn release(&mut self, map: &FocusMap, now: f64) -> Outcome {
        let fired = self.tick(map, now);
        if fired != Outcome::None {
            self.held = None;
            return fired;
        }
        let Some(h) = self.held.take() else {
            return Outcome::None;
        };
        match self.current {
            Some(id) if !h.fired => Outcome::Activated(id, map.get(id).and_then(|i| i.tap)),
            _ => Outcome::None,
        }
    }

    /// Back (Menu, Esc): close a trap, else go to the tab bar when focus is elsewhere, else pop.
    pub fn back(&mut self, map: &FocusMap) -> Outcome {
        self.sync(map);
        if let Some(t) = map.active_trap() {
            return Outcome::Back(BackOutcome::CloseTrap(t));
        }
        let in_bar = |this: &Focus, bar: FocusId| {
            this.current
                .and_then(|c| map.get(c))
                .is_some_and(|i| map.within(i, bar))
        };
        let bar = map
            .scopes
            .iter()
            .map(|(s, _)| s)
            .find(|s| s.kind == ScopeKind::Bar && !in_bar(self, s.id));
        if let Some(bar) = bar {
            let target = self
                .memory
                .get(&bar.id)
                .copied()
                .filter(|m| map.get(*m).is_some())
                .or_else(|| {
                    map.items()
                        .iter()
                        .find(|i| map.within(i, bar.id))
                        .map(|i| i.id)
                });
            if let Some(t) = target {
                self.land(map, t, None);
                return Outcome::Back(BackOutcome::ToBar(t));
            }
        }
        Outcome::Back(BackOutcome::Pop)
    }

    /// One key event. Arrows and Tab act on key down (OS key repeat moves again); Enter presses on down and clicks on
    /// up; Esc acts on down.
    pub fn key(&mut self, map: &FocusMap, key: NavKey, down: bool, now: f64) -> Outcome {
        match (key, down) {
            (NavKey::Arrow(d), true) => self.move_dir(map, d),
            (NavKey::Tab, true) => self.tab(map, false),
            (NavKey::ShiftTab, true) => self.tab(map, true),
            (NavKey::Enter, true) => {
                self.press(map, now);
                Outcome::None
            }
            (NavKey::Enter, false) => self.release(map, now),
            (NavKey::Escape, true) => self.back(map),
            _ => Outcome::None,
        }
    }
}
