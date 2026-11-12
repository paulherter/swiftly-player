//! `ModalAsk`: a future resolved later by the UI calling `answer()`; the `withCheckedContinuation` of `ShellHost.ask`.
use std::cell::RefCell;
use std::future::Future;
use std::pin::Pin;
use std::rc::Rc;
use std::task::{Context, Poll, Waker};

struct State<R> {
    answer: Option<R>,
    waker: Option<Waker>,
    answered: bool,
    asker_gone: bool,
}
pub struct ModalAsk<R>(Rc<RefCell<State<R>>>);
pub struct ModalAnswer<R>(Rc<RefCell<State<R>>>);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Dismissed;

pub fn modal<R>() -> (ModalAsk<R>, ModalAnswer<R>) {
    let s = Rc::new(RefCell::new(State {
        answer: None,
        waker: None,
        answered: false,
        asker_gone: false,
    }));
    (ModalAsk(Rc::clone(&s)), ModalAnswer(s))
}
impl<R> ModalAnswer<R> {
    /// Resolves the waiting task (it runs at the next `poll_frame`). False if already answered or the asker is gone.
    pub fn answer(&self, r: R) -> bool {
        let w = {
            let mut s = self.0.borrow_mut();
            if s.answered || s.asker_gone {
                return false;
            }
            s.answered = true;
            s.answer = Some(r);
            s.waker.take()
        };
        if let Some(w) = w {
            w.wake();
        }
        true
    }
    pub fn is_answered(&self) -> bool {
        self.0.borrow().answered
    }
    /// The task that asked was dropped (canceled) while the dialog was open.
    pub fn asker_gone(&self) -> bool {
        self.0.borrow().asker_gone
    }
}
impl<R> Future for ModalAsk<R> {
    type Output = R;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<R> {
        let mut s = self.0.borrow_mut();
        match s.answer.take() {
            Some(r) => Poll::Ready(r),
            None => {
                s.waker = Some(cx.waker().clone());
                Poll::Pending
            }
        }
    }
}
impl<R> Drop for ModalAsk<R> {
    fn drop(&mut self) {
        self.0.borrow_mut().asker_gone = true;
    }
}
