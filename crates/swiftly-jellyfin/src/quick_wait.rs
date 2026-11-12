//! Waiting for a Quick Connect approval (`QuickConnectWait.swift`) as a state machine.
//!
//! Rules (the Android ones, now for every platform): the deadline is on the clock, not counted
//! rounds; a beat that has passed since the last request asks right at the first tick after
//! waking; a network error does not end the wait; only approval, an expired code or the
//! deadline do; dropping the driver ends everything.
//!
//! [`QuickConnectWait`] is pure: it gets the time and the answers and says what to show and
//! when to ask. [`JellyfinClient::quick_connect_wait`] is the thin loop over a [`WaitClock`].

use swiftly_net::HttpTransport;

use crate::client::JellyfinClient;
use crate::login::{LoginCode, QuickConnectDeadline, QuickConnectState};

/// What the wait tells the screen (`QuickConnectWait.AppEvent`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WaitEvent {
    /// Seconds until the deadline, once per tick.
    Rest(i64),
    /// The code is approved; now sign in with it.
    Released,
    /// The wait is over without approval; `last` picks the closing sentence.
    End(QuickConnectState),
}

/// The answer to one tick.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WaitStep {
    /// What to show, if anything.
    pub event: Option<WaitEvent>,
    /// Ask the server now and pass the answer to [`QuickConnectWait::answer`].
    pub ask: bool,
}

/// The state machine.
#[derive(Debug, Clone)]
pub struct QuickConnectWait {
    end: f64,
    poll: f64,
    last_query: f64,
    last: QuickConnectState,
    finished: bool,
}

impl QuickConnectWait {
    /// Starts at `now` (seconds on any steady clock) with the standard 300 s / 2 s.
    pub fn start(now: f64) -> Self {
        Self::with(
            now,
            QuickConnectDeadline::SECONDS as f64,
            QuickConnectDeadline::TICK as f64,
        )
    }

    /// Different timing, for tests.
    pub fn with(now: f64, deadline: f64, poll: f64) -> Self {
        Self {
            end: now + deadline,
            poll,
            last_query: now,
            last: QuickConnectState::Opened,
            finished: false,
        }
    }

    /// The first event, before the first sleep.
    pub fn first(&self, now: f64) -> WaitEvent {
        WaitEvent::Rest(Self::remaining(self.end - now))
    }

    /// Has the wait ended (an `End` or `Released` was returned)?
    pub fn is_finished(&self) -> bool {
        self.finished
    }

    /// One clock tick (every second in the app).
    pub fn tick(&mut self, now: f64) -> WaitStep {
        if self.finished {
            return WaitStep {
                event: None,
                ask: false,
            };
        }
        let rest = Self::remaining(self.end - now);
        if rest <= 0 {
            self.finished = true;
            let last = if self.last == QuickConnectState::Failed {
                QuickConnectState::Failed
            } else {
                QuickConnectState::Expired
            };
            return WaitStep {
                event: Some(WaitEvent::End(last)),
                ask: false,
            };
        }
        let ask = now - self.last_query >= self.poll;
        if ask {
            self.last_query = now;
        }
        WaitStep {
            event: Some(WaitEvent::Rest(rest)),
            ask,
        }
    }

    /// The answer to the question a tick asked for.
    pub fn answer(&mut self, state: QuickConnectState) -> Option<WaitEvent> {
        self.last = state;
        match state {
            QuickConnectState::Released => {
                self.finished = true;
                Some(WaitEvent::Released)
            }
            QuickConnectState::Expired => {
                self.finished = true;
                Some(WaitEvent::End(QuickConnectState::Expired))
            }
            _ => None,
        }
    }

    /// Rounded up: "0:01" shows until the deadline has really passed.
    fn remaining(d: f64) -> i64 {
        if d <= 0.0 { 0 } else { d.ceil() as i64 }
    }
}

/// The clock the loop sleeps on.
#[allow(async_fn_in_trait)] // used with concrete clocks, never boxed
pub trait WaitClock {
    /// Steady seconds.
    fn now(&self) -> f64;
    /// Sleeps for `seconds`.
    async fn sleep(&self, seconds: f64);
}

impl<T: HttpTransport> JellyfinClient<T> {
    /// Waits for the approval of `code` (`quickConnectWait`). Every event goes to `on_event`;
    /// returning `false` from it is the cancel: the loop stops and asks no more.
    pub async fn quick_connect_wait<C: WaitClock>(
        &self,
        code: &LoginCode,
        clock: &C,
        mut on_event: impl FnMut(WaitEvent) -> bool,
    ) {
        let mut wait = QuickConnectWait::start(clock.now());
        if !on_event(wait.first(clock.now())) {
            return;
        }
        while !wait.is_finished() {
            clock.sleep(1.0).await;
            let step = wait.tick(clock.now());
            if let Some(e) = step.event
                && !on_event(e)
            {
                return;
            }
            if step.ask {
                let state = self.quick_connect_ask_again(code).await;
                if let Some(e) = wait.answer(state)
                    && !on_event(e)
                {
                    return;
                }
            }
        }
    }
}
