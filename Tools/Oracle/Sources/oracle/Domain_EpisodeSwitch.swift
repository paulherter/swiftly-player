import Foundation
import JellyfinKit

// Domain episode_switch (EpisodesSwitch.swift `EpisodeSwitch`): the REAL actor-free state machine driven by a
// scripted fake host. Every host call (stop, plan, start, close stop, fetch) waits on a named gate that the script
// answers; after every op the script waits until the Swift side is quiet (no new log line for a few ms), so the
// sequence of calls and outcomes is deterministic. Generator: crates/swiftly-hardening/src/inputs/episode_switch.rs.

private final class SwitchScript: @unchecked Sendable {
    let lock = NSLock()
    private var lines: [String] = []
    private var waiting: [String: CheckedContinuation<Bool, Never>] = [:]

    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return lines.count }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    func isWaiting(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return waiting[name] != nil }
    var pending: [String] { lock.lock(); defer { lock.unlock() }; return waiting.keys.sorted() }

    func gate(_ name: String) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            lock.lock(); waiting[name] = c; lock.unlock()
        }
    }

    @discardableResult
    func resolve(_ name: String, _ value: Bool) -> Bool {
        lock.lock()
        let c = waiting.removeValue(forKey: name)
        lock.unlock()
        guard let c else { return false }
        c.resume(returning: value)
        return true
    }

    /// Waits (bounded) until `cond` holds.
    func wait(_ cond: () -> Bool) {
        var spins = 0
        while !cond() && spins < 20000 { usleep(100); spins += 1 }
    }

    /// Waits until no line was added for two short sleeps.
    func settle() {
        var last = count, stable = 0
        while stable < 2 {
            usleep(500)
            let now = count
            if now == last { stable += 1 } else { stable = 0; last = now }
        }
    }
}

private func phaseName(_ p: EpisodeSwitch.Phase) -> String {
    switch p {
    case .rests: return "rests"
    case .stopAndPlant: return "stopAndPlant"
    case .starts: return "starts"
    case .closed: return "closed"
    }
}

private func outcomeName(_ o: EpisodeSwitch.Outcome) -> String {
    switch o {
    case .switched: return "switched"
    case .locked: return "locked"
    case .cancelled: return "cancelled"
    case .failed: return "failed"
    }
}

private func runSwitchScript(_ ops: [Any], _ s: SwitchScript) async {
    let sw = EpisodeSwitch()
    var execs = 0, closes = 0, lookups = 0
    func state() { s.add("st:\(phaseName(sw.phase)):\(sw.running):\(sw.messagesAllowed)") }

    func resolve(_ name: String, _ v: Bool) {
        guard s.isWaiting(name) else { return }
        let before = s.count
        s.resolve(name, v)
        s.wait { s.count > before }
        s.settle()
    }

    for raw in ops {
        let op = (raw as? [String: Any]) ?? [:]
        switch srStr(op["op"]) ?? "" {
        case "exec":
            execs += 1
            let k = execs
            let idle = sw.phase == .rests
            let before = s.count
            Task.detached {
                let steps = EpisodeSwitch.Steps<Int>(
                    stopNow: { _ = await s.gate("stop:\(k)"); s.add("stop:done:\(k)") },
                    planOut: { let ok = await s.gate("plan:\(k)"); s.add("plan:done:\(k):\(ok)"); return ok ? k : nil },
                    apply: { p in s.add("apply:\(k):\(p)") },
                    start: { p in s.add("start:begin:\(k):\(p)"); _ = await s.gate("start:\(k)"); s.add("start:done:\(k)") },
                    failed: { s.add("failed:\(k)") })
                let out = await sw.execute(steps)
                s.add("out:\(k):\(outcomeName(out))")
            }
            if idle { s.wait { s.isWaiting("stop:\(k)") && s.isWaiting("plan:\(k)") } }
            else { s.wait { s.count > before } }
            s.settle()
        case "close":
            closes += 1
            let j = closes
            let ph = sw.phase
            let before = s.count
            sw.close(stopNow: {
                s.add("cstop:begin:\(j)")
                _ = await s.gate("cstop:\(j)")
                s.add("cstop:done:\(j)")
            })
            if ph != .closed && ph != .starts { s.wait { s.count > before } }
            s.settle()
        case "lookup":
            lookups += 1
            let j = lookups
            let before = s.count
            Task.detached {
                await sw.lookUp(
                    fetch: { s.add("fetch:begin:\(j)"); _ = await s.gate("fetch:\(j)"); s.add("fetch:done:\(j)"); return j },
                    adopt: { v in s.add("adopt:\(v)") })
            }
            s.wait { s.count > before }
            s.settle()
        default:
            resolve("\(srStr(op["gate"]) ?? ""):\(srInt(op["n"]) ?? 0)", srBool(op["v"]) ?? true)
        }
        state()
    }

    // Answer everything that is still pending, one call at a time in sorted order.
    var rounds = 0
    while let name = s.pending.first, rounds < 400 {
        rounds += 1
        resolve(name, true)
        state()
    }
    s.settle()
    state()
}

private final class SwitchBox: @unchecked Sendable { var lines: [String] = [] }

let domainEpisodeSwitch = Domain("episode_switch") { raw in
    let c = try srDict(raw)
    let ops = (c["ops"] as? [Any]) ?? []
    let script = SwitchScript()
    let box = SwitchBox()
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        await runSwitchScript(ops, script)
        box.lines = script.all
        sem.signal()
    }
    sem.wait()
    return ["log": box.lines]
}
