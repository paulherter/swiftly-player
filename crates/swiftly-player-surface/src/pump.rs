//! The render pump: a dedicated thread that turns the engine's pictures into RGBA frames, so the UI thread never waits
//! for a video frame.
//!
//! The engine (libmpv) draws on the pump's thread, into a small ring of buffers. The UI side asks for the newest finished
//! frame with [`RenderPump::take`] and gets it by a buffer swap; when there is none it gets "unchanged" at once. Neither
//! side ever waits for the other: the one mutex both use is held for a pointer move only, never while a frame is made.
//! A frame the UI did not take before the next one is done is dropped (latest wins). A renderer that is slower than the
//! video therefore costs video frames, never UI frames.
//!
//! The pump knows nothing about libmpv: it drives a [`Renderer`], so the pacing (and the "a slow renderer never stalls the
//! UI" guarantee) is tested with a fake one that sleeps.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crate::{FrameBuffer, FrameStatus};

/// Buffers kept for reuse (the one being drawn, the newest finished one and the UI's own come on top).
const SPARE_LIMIT: usize = 2;
/// How many render times the percentiles are taken from.
const SAMPLES: usize = 512;
/// The pump looks again at least this often even when nothing wakes it (a lost wake-up costs one tick, never a hang).
const IDLE_WAIT: Duration = Duration::from_millis(250);

/// What wakes the host when something new is ready (a frame, an engine event): the host's event loop must not poll while
/// the picture is still. Set once by the host; the render threads and libmpv's wake-up callback call it.
pub type Waker = Arc<dyn Fn() + Send + Sync>;

/// A place for the host's [`Waker`], shared by the engine and its render thread.
#[derive(Default)]
pub struct WakeSlot(Mutex<Option<Waker>>);

impl WakeSlot {
    /// Registers the host's waker.
    pub fn set(&self, waker: Waker) {
        *lock(&self.0) = Some(waker);
    }

    /// Whether a host registered one (the host then redraws on wake-ups instead of at every vsync).
    pub fn is_set(&self) -> bool {
        lock(&self.0).is_some()
    }

    /// Calls the host's waker, if any. Cheap; safe from any thread.
    pub fn fire(&self) {
        let w = lock(&self.0).clone();
        if let Some(w) = w {
            w();
        }
    }
}

/// What the pump draws with. It lives on the pump's thread only.
pub trait Renderer: Send + 'static {
    /// Asks the engine whether a new picture is due (libmpv: `mpv_render_context_update` has `UPDATE_FRAME`).
    fn frame_due(&mut self) -> bool;
    /// Draws the current picture as `width x height` RGBA into `rgba` (`width * height * 4` bytes). `false` = nothing drawn.
    /// `skip_alpha`: the host's shader ignores the fourth byte, so the renderer need not set it.
    fn render(&mut self, width: u32, height: u32, rgba: &mut [u8], skip_alpha: bool) -> bool;
    /// The frame size changes (before the first frame at the new size is drawn): libass sizes are relative to it.
    fn resized(&mut self, _width: u32, _height: u32) {}
}

struct Frame {
    rgba: Vec<u8>,
    width: u32,
    height: u32,
}

#[derive(Default)]
struct Slots {
    /// The size the UI wants (0 = it has not asked yet, so nothing is drawn).
    want: (u32, u32),
    /// The newest finished frame the UI has not taken.
    latest: Option<Frame>,
    /// Buffers ready for reuse.
    spare: Vec<Vec<u8>>,
    /// The size of the last frame that was drawn.
    drawn: (u32, u32),
    /// Something woke the pump (the engine has news, or the wanted size changed).
    wake: bool,
    stop: bool,
    /// A frame has been handed to the UI at least once.
    delivered: bool,
    /// Render times in ms, newest last (a ring of [`SAMPLES`]).
    times: Vec<f32>,
    skip_alpha: bool,
}

/// State shared between the UI side, the engine's callback and the pump's thread.
pub struct Shared {
    slots: Mutex<Slots>,
    cond: Condvar,
    rendered: AtomicU64,
    superseded: AtomicU64,
    render_ns: AtomicU64,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Shared {
    /// Wakes the pump. Safe to call from any thread, including libmpv's update callback (it only sets a flag).
    pub fn notify(&self) {
        lock(&self.slots).wake = true;
        self.cond.notify_one();
    }
}

/// Counters of the pump since it started.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct PumpStats {
    /// Frames drawn.
    pub rendered: u64,
    /// Frames dropped because the UI had not taken them when the next one was done.
    pub superseded: u64,
    /// Mean draw time in ms.
    pub avg_ms: f64,
    /// Median draw time of the last frames in ms.
    pub p50_ms: f64,
    /// 99th percentile draw time of the last frames in ms.
    pub p99_ms: f64,
    /// Size of the last frame drawn.
    pub size: (u32, u32),
}

/// The thread and its ring. Dropping it stops and joins the thread.
pub struct RenderPump {
    shared: Arc<Shared>,
    thread: Option<JoinHandle<()>>,
}

impl RenderPump {
    /// Starts the pump thread around `renderer`; `wake` is called after every frame it finishes.
    pub fn spawn_with(renderer: impl Renderer, wake: Arc<WakeSlot>) -> std::io::Result<RenderPump> {
        let shared = Arc::new(Shared {
            slots: Mutex::new(Slots::default()),
            cond: Condvar::new(),
            rendered: AtomicU64::new(0),
            superseded: AtomicU64::new(0),
            render_ns: AtomicU64::new(0),
        });
        let worker = Arc::clone(&shared);
        let thread = std::thread::Builder::new()
            .name("video-render".into())
            .spawn(move || run(&worker, renderer, &wake))?;
        Ok(RenderPump {
            shared,
            thread: Some(thread),
        })
    }
}

impl RenderPump {
    /// Starts the pump thread around `renderer` (no host to wake).
    pub fn spawn(renderer: impl Renderer) -> std::io::Result<RenderPump> {
        RenderPump::spawn_with(renderer, Arc::new(WakeSlot::default()))
    }

    /// The handle the engine's update callback wakes the pump with.
    pub fn shared(&self) -> &Arc<Shared> {
        &self.shared
    }

    /// Wakes the pump (the engine has news).
    pub fn notify(&self) {
        self.shared.notify();
    }

    /// Tells the pump which size the UI wants and whether it needs the alpha byte. A changed size wakes the pump, so a
    /// paused picture is drawn again at the new size.
    pub fn want(&self, width: u32, height: u32, skip_alpha: bool) {
        let mut s = lock(&self.shared.slots);
        s.skip_alpha = skip_alpha;
        if s.want != (width, height) {
            s.want = (width, height);
            s.wake = true;
            drop(s);
            self.shared.cond.notify_one();
        }
    }

    /// Hands the newest finished frame to `out` by swapping buffers. Never waits for a frame.
    pub fn take(&self, out: &mut FrameBuffer) -> FrameStatus {
        let mut s = lock(&self.shared.slots);
        match s.latest.take() {
            Some(f) => {
                (out.width, out.height) = (f.width, f.height);
                let old = std::mem::replace(&mut out.rgba, f.rgba);
                if s.spare.len() < SPARE_LIMIT && old.capacity() > 0 {
                    s.spare.push(old);
                }
                s.delivered = true;
                FrameStatus::New
            }
            None if s.delivered => FrameStatus::Unchanged,
            None => FrameStatus::NotReady,
        }
    }

    /// Forgets the frame on hand and what was delivered (a new title starts: its first frame is "new" again).
    pub fn reset(&self) {
        let mut s = lock(&self.shared.slots);
        if let Some(f) = s.latest.take() {
            s.spare.push(f.rgba);
        }
        s.delivered = false;
        s.drawn = (0, 0);
    }

    /// The counters.
    pub fn stats(&self) -> PumpStats {
        let s = lock(&self.shared.slots);
        let mut t = s.times.clone();
        let size = s.drawn;
        drop(s);
        t.sort_by(f32::total_cmp);
        let at = |p: f64| {
            t.get(((t.len() as f64 - 1.0).max(0.0) * p) as usize)
                .copied()
                .map_or(0.0, f64::from)
        };
        let rendered = self.shared.rendered.load(Ordering::Relaxed);
        let ns = self.shared.render_ns.load(Ordering::Relaxed);
        PumpStats {
            rendered,
            superseded: self.shared.superseded.load(Ordering::Relaxed),
            avg_ms: if rendered == 0 {
                0.0
            } else {
                ns as f64 / 1.0e6 / rendered as f64
            },
            p50_ms: at(0.5),
            p99_ms: at(0.99),
            size,
        }
    }

    /// Stops the thread and waits for it (the frame in the making is finished first).
    pub fn stop(&mut self) {
        lock(&self.shared.slots).stop = true;
        self.shared.cond.notify_all();
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

impl Drop for RenderPump {
    fn drop(&mut self) {
        self.stop();
    }
}

fn run(shared: &Shared, mut renderer: impl Renderer, wake: &WakeSlot) {
    let mut announced = (0, 0);
    loop {
        // Wait for news, then take what the UI wants. The mutex is released while a frame is drawn.
        let (want, skip_alpha, drawn) = {
            let mut s = lock(&shared.slots);
            while !s.wake && !s.stop {
                s = match shared.cond.wait_timeout(s, IDLE_WAIT) {
                    Ok((g, _)) => g,
                    Err(e) => e.into_inner().0,
                };
                // Looking again after the idle wait also covers an engine whose callback was missed.
                if s.want.0 != 0 {
                    break;
                }
            }
            if s.stop {
                return;
            }
            s.wake = false;
            (s.want, s.skip_alpha, s.drawn)
        };
        if want.0 == 0 || want.1 == 0 {
            continue;
        }
        // Nothing new and the size is the same: nothing to draw.
        if !renderer.frame_due() && drawn == want {
            continue;
        }
        if announced != want {
            renderer.resized(want.0, want.1);
            announced = want;
        }
        let mut buffer = lock(&shared.slots).spare.pop().unwrap_or_default();
        let len = want.0 as usize * want.1 as usize * 4;
        if buffer.len() != len {
            buffer.resize(len, 0);
        }
        let started = Instant::now();
        let ok = renderer.render(want.0, want.1, &mut buffer, skip_alpha);
        let took = started.elapsed();
        let mut s = lock(&shared.slots);
        if !ok {
            s.spare.push(buffer);
            continue;
        }
        s.drawn = want;
        shared.rendered.fetch_add(1, Ordering::Relaxed);
        shared.render_ns.fetch_add(
            u64::try_from(took.as_nanos()).unwrap_or(u64::MAX),
            Ordering::Relaxed,
        );
        if s.times.len() >= SAMPLES {
            s.times.remove(0);
        }
        s.times.push(took.as_secs_f32() * 1000.0);
        if let Some(old) = s.latest.replace(Frame {
            rgba: buffer,
            width: want.0,
            height: want.1,
        }) {
            // The UI never took it: latest wins.
            shared.superseded.fetch_add(1, Ordering::Relaxed);
            if s.spare.len() < SPARE_LIMIT {
                s.spare.push(old.rgba);
            }
        }
        // The engine may already have the next picture: look again without waiting for its callback.
        s.wake = true;
        drop(s);
        wake.fire();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A renderer that takes `cost` per frame and has a new picture whenever asked (a video that never waits). With `made` it
    /// reports the number of every frame it draws (from inside `render`, before the pump stores the frame), so a test can
    /// wait for that event instead of for a time.
    struct Slow {
        cost: Duration,
        frames: Arc<AtomicU64>,
        made: Option<std::sync::mpsc::Sender<u64>>,
    }

    impl Renderer for Slow {
        fn frame_due(&mut self) -> bool {
            true
        }
        fn render(&mut self, w: u32, h: u32, rgba: &mut [u8], _skip_alpha: bool) -> bool {
            std::thread::sleep(self.cost);
            let n = self.frames.fetch_add(1, Ordering::Relaxed) + 1;
            rgba[0] = (n % 251) as u8;
            assert_eq!(rgba.len(), w as usize * h as usize * 4);
            if let Some(made) = &self.made {
                let _ = made.send(n);
            }
            true
        }
    }

    fn slow_pump(cost_ms: u64) -> (RenderPump, Arc<AtomicU64>) {
        let frames = Arc::new(AtomicU64::new(0));
        let pump = RenderPump::spawn(Slow {
            cost: Duration::from_millis(cost_ms),
            frames: Arc::clone(&frames),
            made: None,
        })
        .expect("thread starts");
        (pump, frames)
    }

    /// Like `slow_pump`, plus the receiver of the number of every frame the renderer has drawn.
    fn counting_pump(cost_ms: u64) -> (RenderPump, Arc<AtomicU64>, std::sync::mpsc::Receiver<u64>) {
        let frames = Arc::new(AtomicU64::new(0));
        let (made, drawn) = std::sync::mpsc::channel();
        let pump = RenderPump::spawn(Slow {
            cost: Duration::from_millis(cost_ms),
            frames: Arc::clone(&frames),
            made: Some(made),
        })
        .expect("thread starts");
        (pump, frames, drawn)
    }

    /// The UI side of a host: asks for a frame every `tick` and measures how long each ask took. With `wait_for_frame`
    /// the UI also waits (up to `FRAME_DEADLINE`, outside the measured ask) for the renderer's next frame before the
    /// next tick. Returns the slowest ask, the number of fresh frames and the total elapsed time.
    fn ui_ticks(
        pump: &RenderPump,
        ticks: u32,
        tick: Duration,
        wait_for_frame: bool,
    ) -> (Duration, u32, Duration) {
        const FRAME_DEADLINE: Duration = Duration::from_secs(5);
        let mut buf = FrameBuffer::default();
        let (mut worst, mut fresh) = (Duration::ZERO, 0);
        let begun = Instant::now();
        for _ in 0..ticks {
            let t = Instant::now();
            pump.want(1920, 1080, true);
            let mut got = pump.take(&mut buf) == FrameStatus::New;
            worst = worst.max(t.elapsed());
            let deadline = Instant::now() + FRAME_DEADLINE;
            while wait_for_frame && !got && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(1));
                got = pump.take(&mut buf) == FrameStatus::New;
            }
            if got {
                fresh += 1;
            }
            std::thread::sleep(tick);
        }
        (worst, fresh, begun.elapsed())
    }

    /// The regression this module exists for: a renderer that needs 100 ms per frame (a 4K picture on the CPU) must not
    /// hold a single UI tick. Before the pump the UI thread called the renderer itself and every tick took that long.
    #[test]
    fn a_slow_renderer_never_holds_a_ui_tick() {
        let (pump, frames) = slow_pump(100);
        let (worst, fresh, elapsed) = ui_ticks(&pump, 120, Duration::from_millis(8), false);
        assert!(
            worst < Duration::from_millis(30),
            "a UI tick waited {worst:?} for the video renderer"
        );
        // No frame storm: every frame costs the renderer 100 ms of sleep, so however long a loaded machine stretches the
        // ticks, at most one frame per 100 ms of elapsed time (plus the one in flight) can have been made and taken.
        let most = elapsed.as_millis() / 100 + 1;
        assert!(
            u128::from(fresh) <= most,
            "{fresh} frames in {elapsed:?} from a 100 ms renderer (at most {most})"
        );
        // The renderer keeps its pace while the UI ticks: at least one frame per 400 ms got through (and one at all).
        let least = (elapsed.as_millis() / 400).max(1);
        assert!(
            u128::from(fresh) >= least,
            "only {fresh} frames arrived in {elapsed:?} (at least {least})"
        );
        assert!(frames.load(Ordering::Relaxed) >= u64::from(fresh));
    }

    /// A 1 ms renderer is never the bottleneck: every UI tick that waits for its frame gets a new one. The UI waits for
    /// the pump thread (bounded) instead of counting on a loaded machine scheduling it within one 4 ms tick.
    #[test]
    fn a_fast_renderer_delivers_every_frame_the_ui_asks_for() {
        let (pump, _) = slow_pump(1);
        let (worst, fresh, _) = ui_ticks(&pump, 100, Duration::from_millis(4), true);
        assert!(worst < Duration::from_millis(100), "tick took {worst:?}");
        assert_eq!(fresh, 100, "only {fresh} of 100 ticks had a new frame");
    }

    /// The UI does not look for a while: the pump keeps drawing, only the newest frame stays and the buffers do not pile up.
    /// The test waits for the event (the renderer has drawn `MADE` frames, bounded by a hang guard) instead of sleeping a
    /// time: a 2 ms renderer drew only 9 frames in 120 ms on a shared CI runner, and how fast the pump thread is scheduled
    /// is not what this promises.
    #[test]
    fn the_ui_gets_the_newest_frame_and_old_ones_are_dropped() {
        const MADE: u64 = 20;
        const HANG_GUARD: Duration = Duration::from_secs(10);
        let (pump, frames, drawn_frames) = counting_pump(2);
        pump.want(64, 64, false);
        loop {
            let n = drawn_frames
                .recv_timeout(HANG_GUARD)
                .expect("the pump keeps drawing while the UI does not look");
            if n >= MADE {
                break;
            }
        }
        let mut buf = FrameBuffer::default();
        assert_eq!(pump.take(&mut buf), FrameStatus::New);
        assert_eq!(
            (buf.width, buf.height, buf.rgba.len()),
            (64, 64, 64 * 64 * 4)
        );
        let drawn = frames.load(Ordering::Relaxed);
        assert!(drawn >= MADE, "{drawn} frames drawn");
        // The frame on hand is a late one, not the first: when frame `MADE` was announced, the frames before it were all
        // finished and stored (one pump thread, one frame at a time), and the UI took none of them. The counter in the
        // first byte wraps at 251.
        assert!(
            drawn > 250 || u64::from(buf.rgba[0]) >= MADE - 1,
            "stale frame {} after {drawn} drawn",
            buf.rgba[0]
        );
        // Every finished frame the UI did not take was replaced by the next one.
        assert!(
            pump.stats().superseded >= MADE - 2,
            "{} frames superseded after {drawn} drawn",
            pump.stats().superseded
        );
        // The ring is bounded: the buffers do not pile up while the UI sleeps.
        assert!(lock(&pump.shared.slots).spare.len() <= SPARE_LIMIT);
    }

    #[test]
    fn nothing_is_drawn_until_the_ui_asks_and_a_resize_redraws() {
        struct Idle(Arc<AtomicU64>);
        impl Renderer for Idle {
            fn frame_due(&mut self) -> bool {
                false
            }
            fn render(&mut self, _w: u32, _h: u32, _rgba: &mut [u8], _s: bool) -> bool {
                self.0.fetch_add(1, Ordering::Relaxed);
                true
            }
        }
        let count = Arc::new(AtomicU64::new(0));
        let pump = RenderPump::spawn(Idle(Arc::clone(&count))).expect("thread starts");
        let mut buf = FrameBuffer::default();
        pump.notify();
        std::thread::sleep(Duration::from_millis(30));
        assert_eq!(count.load(Ordering::Relaxed), 0, "drew before the UI asked");
        assert_eq!(pump.take(&mut buf), FrameStatus::NotReady);
        // A picture that is not due is still drawn once at a new size (a paused video in a resized window).
        pump.want(320, 180, true);
        std::thread::sleep(Duration::from_millis(60));
        assert_eq!(count.load(Ordering::Relaxed), 1);
        assert_eq!(pump.take(&mut buf), FrameStatus::New);
        assert_eq!(pump.take(&mut buf), FrameStatus::Unchanged);
        pump.want(640, 360, true);
        std::thread::sleep(Duration::from_millis(60));
        assert_eq!(count.load(Ordering::Relaxed), 2);
        assert_eq!(pump.take(&mut buf), FrameStatus::New);
        assert_eq!((buf.width, buf.height), (640, 360));
        // The same size and nothing due: nothing more is drawn.
        std::thread::sleep(Duration::from_millis(60));
        assert_eq!(count.load(Ordering::Relaxed), 2);
    }

    #[test]
    fn stop_joins_even_while_a_frame_is_in_the_making() {
        let (mut pump, _) = slow_pump(80);
        pump.want(16, 16, true);
        std::thread::sleep(Duration::from_millis(20));
        let t = Instant::now();
        pump.stop();
        assert!(t.elapsed() < Duration::from_millis(500));
        drop(pump);
    }
}
