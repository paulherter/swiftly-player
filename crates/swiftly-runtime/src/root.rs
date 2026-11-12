//! `UiRoot<App>`: the one owner of the UI state, reached only through closures so no borrow can span an `.await`.
use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};

thread_local! {
    /// Number of roots currently borrowed on this thread (0 or 1 in correct code).
    static BORROWED: Cell<usize> = const { Cell::new(0) };
}

/// Debug assert used by `UiExecutor::poll_frame`: tasks must run outside the root borrow.
pub(crate) fn assert_root_unborrowed() {
    debug_assert!(
        BORROWED.with(Cell::get) == 0,
        "poll_frame called while the UI root is borrowed"
    );
}

struct BorrowMark;
impl BorrowMark {
    fn new() -> Self {
        BORROWED.with(|b| b.set(b.get() + 1));
        BorrowMark
    }
}
impl Drop for BorrowMark {
    fn drop(&mut self) {
        BORROWED.with(|b| b.set(b.get() - 1));
    }
}

/// Runs `f` with exclusive access. A re-entrant attempt fails a debug assert; in release it yields `None`.
fn run<T: ?Sized, R>(cell: &RefCell<T>, f: impl FnOnce(&mut T) -> R) -> Option<R> {
    let Ok(mut guard) = cell.try_borrow_mut() else {
        debug_assert!(false, "re-entrant borrow of the UI root");
        return None;
    };
    let _mark = BorrowMark::new();
    Some(f(&mut guard))
}

/// Strong owner of the application state (`Rc<RefCell<App>>`).
pub struct UiRoot<App>(Rc<RefCell<App>>);

impl<App> UiRoot<App> {
    pub fn new(app: App) -> Self {
        UiRoot(Rc::new(RefCell::new(app)))
    }

    /// Exclusive access for one input event, frame, inbox drain or task step.
    pub fn with<R>(&self, f: impl FnOnce(&mut App) -> R) -> Option<R> {
        run(&self.0, f)
    }

    /// Weak pointer to the root; pass it to `UiRef::new` to get a handle to a trait object (`UiRef<dyn Trait>`).
    pub fn weak(&self) -> Weak<RefCell<App>> {
        Rc::downgrade(&self.0)
    }
}

/// Weak handle for async code (`Swift [weak self]`): `None` once the root is gone.
pub struct UiRef<T: ?Sized>(Weak<RefCell<T>>);

impl<T: ?Sized> UiRef<T> {
    /// Takes `root.weak()`; the argument position coerces `Weak<RefCell<App>>` to `Weak<RefCell<dyn Trait>>`.
    pub fn new(weak: Weak<RefCell<T>>) -> Self {
        UiRef(weak)
    }

    /// Closure-only access. `None` if the root is gone (or, in release, borrowed re-entrantly).
    pub fn with<R>(&self, f: impl FnOnce(&mut T) -> R) -> Option<R> {
        let root = self.0.upgrade()?;
        run(&root, f)
    }

    pub fn is_alive(&self) -> bool {
        self.0.strong_count() > 0
    }
}

impl<T: ?Sized> Clone for UiRef<T> {
    fn clone(&self) -> Self {
        UiRef(Weak::clone(&self.0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::Rt;

    trait Counter {
        fn bump(&mut self) -> u32;
    }
    struct App(u32);
    impl Counter for App {
        fn bump(&mut self) -> u32 {
            self.0 += 1;
            self.0
        }
    }

    fn handle(root: &UiRoot<App>) -> UiRef<dyn Counter> {
        UiRef::new(root.weak())
    }

    #[test]
    fn with_reaches_the_app_through_a_trait_handle() {
        let root = UiRoot::new(App(0));
        let h = handle(&root);
        assert_eq!(h.with(|c| c.bump()), Some(1));
        assert_eq!(root.with(|a| a.0), Some(1));
    }

    #[test]
    fn handle_is_none_after_the_root_is_dropped() {
        let root = UiRoot::new(App(0));
        let h = handle(&root);
        drop(root);
        assert!(!h.is_alive());
        assert_eq!(h.with(|c| c.bump()), None);
    }

    #[test]
    #[cfg(debug_assertions)]
    #[should_panic(expected = "re-entrant borrow")]
    fn reentrant_borrow_is_caught() {
        let root = UiRoot::new(App(0));
        let h = handle(&root);
        let h2 = h.clone();
        h.with(|_| h2.with(|c| c.bump()));
    }

    #[test]
    #[cfg(debug_assertions)]
    #[should_panic(expected = "poll_frame called while the UI root is borrowed")]
    fn poll_frame_inside_the_root_borrow_is_caught() {
        let rt = Rt::manual();
        let root = UiRoot::new(App(0));
        root.with(|_| rt.ex.poll_frame());
    }

    #[test]
    fn poll_frame_outside_the_borrow_is_fine_and_borrow_state_resets() {
        let rt = Rt::manual();
        let root = UiRoot::new(App(0));
        root.with(|a| a.bump());
        rt.ex.poll_frame();
        assert_eq!(root.with(|a| a.bump()), Some(2));
    }

    #[test]
    fn task_uses_the_root_in_short_closures_across_an_await() {
        let rt = Rt::manual();
        let root = UiRoot::new(App(0));
        let h = handle(&root);
        let out = Rc::new(Cell::new(0));
        let o = Rc::clone(&out);
        let (ask, answer) = crate::modal::<u32>();
        crate::spawn_local(async move {
            h.with(|c| c.bump());
            let v = ask.await;
            o.set(h.with(|c| c.bump()).unwrap_or(0) + v);
        });
        rt.run_until_stalled();
        assert!(answer.answer(10));
        rt.run_until_stalled();
        assert_eq!(out.get(), 12);
    }
}
