#![allow(clippy::clone_on_ref_ptr, clippy::redundant_async_block)] // test code clones shared handles freely
//! Executor semantics, determinism, stress, panics.
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Duration;
use swiftly_runtime::testing::Rt;
use swiftly_runtime::*;

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

#[test]
fn timers_fire_in_deadline_order_only_when_the_fake_clock_moves() {
    let rt = Rt::manual();
    let log = Rc::new(RefCell::new(vec![]));
    for d in [30u64, 10, 20, 10] {
        let l = log.clone();
        spawn_local(async move {
            sleep(ms(d)).await.unwrap();
            l.borrow_mut().push(d);
        });
    }
    rt.run_until_stalled();
    assert!(log.borrow().is_empty());
    rt.advance(ms(9));
    assert!(log.borrow().is_empty());
    while rt.advance_to_next_timer() {}
    assert_eq!(*log.borrow(), [10, 10, 20, 30]);
}

#[test]
fn ready_tasks_run_in_wake_order() {
    let rt = Rt::manual();
    let log = Rc::new(RefCell::new(vec![]));
    for i in 0..5 {
        let l = log.clone();
        spawn_local(async move {
            l.borrow_mut().push(("a", i));
            yield_now().await;
            l.borrow_mut().push(("b", i));
        });
    }
    rt.run_until_stalled();
    let l = log.borrow();
    assert_eq!(l[..5], [("a", 0), ("a", 1), ("a", 2), ("a", 3), ("a", 4)]);
    assert_eq!(l[5..], [("b", 0), ("b", 1), ("b", 2), ("b", 3), ("b", 4)]);
}

#[test]
fn hard_cancel_drops_the_future_and_runs_destructors() {
    struct D(Rc<Cell<bool>>);
    impl Drop for D {
        fn drop(&mut self) {
            self.0.set(true);
        }
    }
    let rt = Rt::manual();
    let dropped = Rc::new(Cell::new(false));
    let d = D(dropped.clone());
    let h = spawn_local(async move {
        let _d = d;
        sleep(Duration::from_secs(3600)).await.unwrap();
    });
    rt.run_until_stalled();
    assert!(!dropped.get());
    h.cancel();
    rt.run_until_stalled();
    assert!(dropped.get());
    assert_eq!(h.try_take(), Some(Err(JoinError::Cancelled)));
    assert_eq!(
        rt.ex.next_deadline(),
        None,
        "the canceled sleep left no live timer"
    );
}

#[test]
fn cooperative_cancel_wakes_sleep_with_an_error_and_lets_the_body_finish() {
    let rt = Rt::manual();
    let h = spawn_cooperative(async {
        let r = sleep(Duration::from_secs(3600)).await; // try? await Task.sleep
        (r, is_cancelled())
    });
    rt.run_until_stalled();
    h.cancel();
    rt.run_until_stalled();
    assert_eq!(h.try_take(), Some(Ok((Err(Cancelled), true))));
}

#[test]
fn a_panicking_task_does_not_kill_the_loop() {
    let rt = Rt::manual();
    let ok = Rc::new(Cell::new(0));
    let bad = spawn_local(async {
        yield_now().await;
        panic!("boom (expected by the test)");
    });
    for _ in 0..3 {
        let ok = ok.clone();
        spawn_local(async move {
            yield_now().await;
            yield_now().await;
            ok.set(ok.get() + 1);
        });
    }
    rt.run_until_stalled();
    assert_eq!(ok.get(), 3);
    assert_eq!(bad.try_take(), Some(Err(JoinError::Panicked)));
    assert_eq!(rt.ex.panic_count(), 1);
    let ok2 = ok.clone();
    spawn_local(async move { ok2.set(99) });
    rt.run_until_stalled();
    assert_eq!(ok.get(), 99, "the executor keeps working after a panic");
}

#[test]
fn a_panic_in_a_drop_during_cancel_is_contained() {
    struct Bomb;
    impl Drop for Bomb {
        fn drop(&mut self) {
            if !std::thread::panicking() {
                panic!("drop bomb (expected by the test)");
            }
        }
    }
    let rt = Rt::manual();
    let h = spawn_local(async {
        let _b = Bomb;
        sleep(ms(10)).await.unwrap();
    });
    rt.run_until_stalled();
    h.cancel();
    rt.run_until_stalled();
    assert_eq!(rt.ex.panic_count(), 1);
    assert_eq!(rt.ex.live_tasks(), 0);
}

#[test]
fn a_panic_in_a_worker_job_is_reported_and_the_pool_survives() {
    let rt = Rt::threaded(2);
    let out = Rc::new(RefCell::new(vec![]));
    let (pool, o) = (rt.pool.clone(), out.clone());
    spawn_local(async move {
        let a = pool
            .run(|_| -> u32 { panic!("worker boom (expected by the test)") })
            .await;
        let b = pool.run(|_| 7u32).await;
        o.borrow_mut().push((a, b));
    });
    rt.wait_until(|| !out.borrow().is_empty());
    assert_eq!(out.borrow()[0], (Err(WorkerPanic), Ok(7)));
}

#[test]
fn wakeups_from_worker_threads_are_delivered() {
    let rt = Rt::threaded(4);
    let n = Rc::new(Cell::new(0));
    for i in 0..500u64 {
        let (pool, n) = (rt.pool.clone(), n.clone());
        spawn_local(async move {
            let v = pool.run(move |_| i * 2).await.unwrap();
            assert_eq!(v, i * 2);
            n.set(n.get() + 1);
        });
    }
    rt.wait_until(|| n.get() == 500);
}

#[test]
fn dropping_the_future_skips_a_queued_worker_job() {
    let rt = Rt::manual();
    let ran = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let (pool, r) = (rt.pool.clone(), ran.clone());
    let h = spawn_local(async move {
        let _ = pool
            .run(move |_| r.store(true, std::sync::atomic::Ordering::SeqCst))
            .await;
    });
    rt.ex.poll_frame();
    h.cancel();
    rt.run_until_stalled(); // the job is stepped but sees the flag
    assert!(!ran.load(std::sync::atomic::Ordering::SeqCst));
}

#[test]
fn modal_answer_semantics() {
    let rt = Rt::manual();
    let (ask, ans) = modal::<u8>();
    let h = spawn_local(async move { ask.await });
    rt.run_until_stalled();
    assert!(!h.is_finished());
    assert!(ans.answer(5));
    assert!(!ans.answer(6), "answers once");
    rt.run_until_stalled();
    assert_eq!(h.try_take(), Some(Ok(5)));
    // asker canceled while the dialog is open: Swift keeps the continuation, here the answer is refused
    let (ask, ans) = modal::<u8>();
    let h = spawn_local(async move { ask.await });
    rt.run_until_stalled();
    h.cancel();
    rt.run_until_stalled();
    assert!(ans.asker_gone());
    assert!(!ans.answer(1));
}

#[test]
fn task_group_cancels_children_when_the_owner_is_canceled() {
    let rt = Rt::manual();
    let finished = Rc::new(Cell::new(0));
    let dropped = Rc::new(Cell::new(0));
    struct D(Rc<Cell<i32>>);
    impl Drop for D {
        fn drop(&mut self) {
            self.0.set(self.0.get() + 1);
        }
    }
    let (f, d) = (finished.clone(), dropped.clone());
    let owner = spawn_local(async move {
        let mut g = TaskGroup::new();
        for i in 0..4u64 {
            let d = D(d.clone());
            g.spawn(async move {
                let _d = d;
                sleep(ms(10 * (i + 1))).await.unwrap();
                i
            });
        }
        // for await: first two results, then the owner is canceled with two children left
        while let Some(r) = g.next().await {
            r.unwrap();
            f.set(f.get() + 1);
            if f.get() == 2 {
                sleep(Duration::from_secs(100)).await.unwrap();
            }
        }
    });
    rt.run_until_stalled();
    rt.advance(ms(20));
    assert_eq!(finished.get(), 2);
    assert_eq!(dropped.get(), 2);
    owner.cancel();
    rt.run_until_stalled();
    rt.run_until_stalled();
    assert_eq!(dropped.get(), 4, "children were canceled with the owner");
    assert_eq!(rt.ex.live_tasks(), 0);
}

#[test]
fn a_self_waking_task_cannot_freeze_a_frame() {
    let rt = Rt::manual();
    rt.ex.set_frame_budget(1000);
    spawn_local(async {
        loop {
            yield_now().await;
        }
    });
    let s = rt.ex.poll_frame();
    assert!(s.polled >= 1000 && s.polled < 1100, "{s:?}");
}

/// Deterministic xorshift, so the stress test is reproducible.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
}

#[test]
fn stress_10k_tasks_with_cancellation_and_nested_dialogs_manual_pool() {
    let rt = Rt::manual();
    let answers: Rc<RefCell<Vec<ModalAnswer<u32>>>> = Rc::default();
    let completed = Rc::new(Cell::new(0u32));
    let mut rng = Rng(0x9E3779B97F4A7C15);
    let mut handles = vec![];
    for i in 0..10_000u32 {
        let (pool, answers, completed) = (rt.pool.clone(), answers.clone(), completed.clone());
        let d = rng.next() % 200;
        handles.push(spawn_local(async move {
            sleep(ms(d)).await.unwrap();
            // outer dialog
            let (ask, ans) = modal::<u32>();
            answers.borrow_mut().push(ans);
            let r1 = ask.await;
            // nested: the answer opens a second dialog from a child task, awaited by the parent
            let a2 = answers.clone();
            let child = spawn_local(async move {
                let (ask, ans) = modal::<u32>();
                a2.borrow_mut().push(ans);
                ask.await + 1
            });
            let r2 = child.await.unwrap();
            let w = pool.run(move |_| r1 + r2).await.unwrap();
            let _ = (i, w);
            completed.set(completed.get() + 1);
        }));
    }
    // cancel a pseudo-random third at assorted points of the run
    let mut canceled = 0;
    let mut step = 0;
    loop {
        rt.run_until_stalled();
        // answer every open dialog: value = its index parity independent, test only needs liveness
        let open: Vec<_> = answers.borrow_mut().drain(..).collect();
        for (k, a) in open.iter().enumerate() {
            a.answer(k as u32);
        }
        if step % 3 == 0 {
            for _ in 0..300 {
                let idx = (rng.next() % 10_000) as usize;
                if !handles[idx].is_finished() {
                    handles[idx].cancel();
                    canceled += 1;
                }
            }
        }
        step += 1;
        if rt.ex.live_tasks() == 0 {
            break;
        }
        if !open.is_empty() || rt.ex.has_ready() || rt.pool.pending() > 0 {
            continue;
        }
        assert!(
            rt.advance_to_next_timer(),
            "deadlock: {} live tasks, no timer, no dialog, no job",
            rt.ex.live_tasks()
        );
        assert!(step < 100_000);
    }
    let mut ok = 0;
    let mut cancelled = 0;
    for h in &handles {
        match h.try_take() {
            Some(Ok(())) => ok += 1,
            Some(Err(JoinError::Cancelled)) => cancelled += 1,
            other => panic!("{other:?}"),
        }
    }
    assert_eq!(ok + cancelled, 10_000);
    assert_eq!(ok, completed.get());
    assert!(
        cancelled > 0 && ok > 0,
        "ok={ok} cancelled={cancelled} requested={canceled}"
    );
    assert_eq!(rt.ex.next_deadline(), None);
}

#[test]
fn stress_10k_tasks_threaded_pool_no_lost_wakeup() {
    let rt = Rt::threaded(4);
    let done = Rc::new(Cell::new(0u32));
    let mut handles = vec![];
    for i in 0..10_000u64 {
        let (pool, done) = (rt.pool.clone(), done.clone());
        handles.push(spawn_local(async move {
            let a = pool.run(move |_| i).await.unwrap();
            let b = pool.run(move |_| a + 1).await.unwrap();
            assert_eq!(b, i + 1);
            done.set(done.get() + 1);
        }));
    }
    for h in handles.iter().step_by(5) {
        h.cancel();
    }
    rt.wait_until(|| rt.ex.live_tasks() == 0);
    let done_n = done.get();
    assert!((8_000..=10_000).contains(&done_n), "{done_n}");
    assert_eq!(handles.iter().filter(|h| h.is_finished()).count(), 10_000);
}
