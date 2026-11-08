// aether-probe <url> [label]: loads one URL in AetherEngine, muted, hosted in an offscreen window,
// and prints JSON lines (one event per line) on stdout. One process per title.
import AppKit
import Combine
import SwiftlyAether

let t0 = Date()
let outLock = NSLock()

func emit(_ ev: String, _ fields: [String: Any] = [:]) {
    var d = fields
    d["ev"] = ev
    d["t"] = (Date().timeIntervalSince(t0) * 1000).rounded() / 1000
    guard JSONSerialization.isValidJSONObject(d),
          let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]),
          let s = String(data: data, encoding: .utf8) else { return }
    outLock.lock(); print(s); fflush(stdout); outLock.unlock()
}

func trackDict(_ t: TrackInfo) -> [String: Any] {
    ["id": t.id, "name": t.name, "codec": t.codec, "lang": t.language ?? "", "ch": t.channels,
     "default": t.isDefault, "forced": t.isForced, "atmos": t.isAtmos, "dtsx": t.isDTSX]
}

let args = CommandLine.arguments
let env = ProcessInfo.processInfo.environment
guard args.count >= 2, let url = URL(string: args[1]) else {
    FileHandle.standardError.write(Data("usage: aether-probe <url> [label]\n".utf8)); exit(2)
}
let label = args.count > 2 ? args[2] : url.lastPathComponent

EngineLog.handler = { line in emit("log", ["line": line]) }

@MainActor func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

@MainActor func runProbe() async {
    emit("start", ["label": label])
    let engine: AetherEngine
    do { engine = try AetherEngine() } catch { emit("fatal", ["error": "\(error)"]); return }
    engine.volume = 0

    // Offscreen host window (far outside any display), so the render layer is attached to a real view.
    let view = AetherPlayerView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    let win = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 640, height: 360),
                       styleMask: [.borderless], backing: .buffered, defer: false)
    win.contentView = view
    win.orderFrontRegardless()
    engine.bind(view: view)

    var bag = Set<AnyCancellable>()
    var state: PlaybackState = .idle
    var firstPresent: Double?
    var loadStart = Date()
    engine.$state.sink { s in
        state = s
        emit("state", ["state": "\(s)"])
    }.store(in: &bag)
    engine.$videoRoute.sink { emit("route", ["route": $0.rawValue]) }.store(in: &bag)
    engine.$videoFormat.sink { emit("videoFormat", ["format": "\($0)"]) }.store(in: &bag)
    engine.$dolbyVisionConversion.sink { emit("dvConversion", ["value": $0.map { "\($0)" } ?? "none"]) }.store(in: &bag)
    engine.$audioDelivery.sink { emit("audioDelivery", ["value": $0.rawValue]) }.store(in: &bag)
    engine.$activeAudioDecoder.sink { emit("audioDecoder", ["value": $0 ?? "nil"]) }.store(in: &bag)
    engine.$activeAudioTrackIndex.sink { emit("activeAudio", ["index": $0 ?? -1]) }.store(in: &bag)
    engine.$activeSubtitleTrackIndex.sink { emit("activeSubtitle", ["index": $0 ?? -1]) }.store(in: &bag)
    engine.$errorInfo.sink { i in
        guard let i else { return }
        emit("errorInfo", ["kind": i.kind.rawValue, "message": i.message, "domain": i.underlyingDomain ?? "",
                           "code": i.underlyingCode ?? 0, "ffmpeg": i.ffmpegErrorCode ?? 0])
    }.store(in: &bag)
    engine.$startupProgress.sink { p in
        guard let p else { return }
        emit("startup", ["checkpoint": "\(p.checkpoint)"])
        if p.checkpoint == .presenting, firstPresent == nil {
            firstPresent = Date().timeIntervalSince(loadStart)
            emit("firstFrame", ["timeToFirstFrameS": firstPresent!])
        }
    }.store(in: &bag)
    engine.seekEvents.sink { emit("seekEvent", ["event": "\($0)"]) }.store(in: &bag)
    var cueCount = 0
    engine.$subtitleCues.sink { cueCount = $0.count }.store(in: &bag)

    // Load
    loadStart = Date()
    var probeInfo: SourceProbe?
    var loadOptions = LoadOptions()
    if env["PROBE_POLICY"] != "off" { loadOptions.applySwiftlyAudioPolicy() }
    if let l = env["PROBE_LANG"] { loadOptions.preferredAudioLanguages = [l] }
    switch env["PROBE_OBJ"] ?? "" {   // experiments: apac714, lpcm714, lpcm512, apac512
    case "apac714": loadOptions.objectAudioRendering = .apac(.l714)
    case "lpcm714": loadOptions.objectAudioRendering = .lpcm(.l714)
    case "lpcm512": loadOptions.objectAudioRendering = .lpcm(.l512)
    case "apac512": loadOptions.objectAudioRendering = .apac(.l512)
    default: break
    }
    emit("options", ["policy": env["PROBE_POLICY"] ?? "app", "objectAudio": "\(loadOptions.objectAudioRendering)",
                     "bridge": "\(loadOptions.audioBridgeMode)",
                     "truehdBuilt": AetherEngine.OptionalComponent.trueHDObjectAudio.isBuiltIn,
                     "dtsxBuilt": AetherEngine.OptionalComponent.dtsxObjectAudio.isBuiltIn])
    do {
        probeInfo = try await engine.load(url: url, options: loadOptions)
    } catch {
        emit("loadError", ["error": "\(error)"])
    }
    let loadReturned = Date().timeIntervalSince(loadStart)
    if let p = probeInfo {
        var f: [String: Any] = [
            "duration": p.durationSeconds, "codec": p.videoCodecName ?? "", "w": Int(p.videoWidth),
            "h": Int(p.videoHeight), "fps": p.videoFrameRate ?? 0, "isDV": p.isDolbyVision,
            "dvProfile": p.dvProfile ?? 0, "probeFormat": "\(p.videoFormat)",
            "hdr10plus": p.carriesHDR10PlusMetadata,
        ]
        if let sf = p.videoStreamFormat {
            f["pix"] = sf.pixelFormat ?? ""; f["bits"] = sf.bitDepth ?? 0
            f["transfer"] = sf.transfer ?? ""; f["primaries"] = sf.colorPrimaries ?? ""
            f["profile"] = sf.profile ?? ""
        }
        emit("sourceProbe", f)
    }
    engine.volume = 0
    engine.play()

    // Wait for .playing (max 15 s)
    var waited = 0.0
    while state != .playing && waited < 15 { await sleep(0.1); waited += 0.1 }
    emit("playing", ["reached": state == .playing, "loadReturnedS": loadReturned,
                     "timeToPlayingS": Date().timeIntervalSince(loadStart),
                                          "route": engine.videoRoute.rawValue, "format": "\(engine.videoFormat)",
                     "duration": engine.duration])
    emit("audioOut", ["delivery": engine.audioDelivery.rawValue, "decoder": engine.activeAudioDecoder ?? "nil"])
    emit("tracks", ["audio": engine.audioTracks.map(trackDict), "subtitles": engine.subtitleTracks.map(trackDict),
                    "activeAudio": engine.activeAudioTrackIndex ?? -1])

    guard state == .playing else { emit("abort", ["reason": "never playing"]); finish(engine, win); return }

    // 5 s of play
    let p0 = engine.currentTime
    await sleep(5)
    emit("position5s", ["from": p0, "to": engine.currentTime, "state": "\(state)"])

    if let sub = env["PROBE_PGS"] { await pgsWindow(engine, trackId: Int(sub) ?? -1, seekTo: Double(env["PROBE_SEEK"] ?? "") ?? 0,
                                                    window: Double(env["PROBE_WINDOW"] ?? "") ?? 60); finish(engine, win); return }

    // Seek +60 and back
    let origin = engine.currentTime
    let dur = engine.duration
    let target = dur > 0 ? min(origin + 60, max(dur - 10, 0)) : origin + 60
    let ts = Date()
    await engine.seek(to: target)
    await sleep(2)
    emit("seekForward", ["target": target, "from": origin, "position": engine.currentTime,
                         "state": "\(state)", "returnedS": Date().timeIntervalSince(ts),
                         "ok": abs(engine.currentTime - (target + 2)) < 3])
    let back = origin
    await engine.seek(to: back)
    await sleep(2)
    emit("seekBack", ["target": back, "position": engine.currentTime, "state": "\(state)",
                      "ok": abs(engine.currentTime - (back + 2)) < 3])

    // Audio tracks: TrueHD first, then the others (max 6), 2 s each; check the clock still moves.
    let audio = engine.audioTracks
    let ordered = audio.filter { $0.codec == "truehd" } + audio.filter { $0.codec != "truehd" }
    for t in ordered.prefix(6) where t.id != engine.activeAudioTrackIndex || t.codec == "truehd" {
        let before = engine.currentTime
        engine.selectAudioTrack(index: t.id)
        if t.codec == "truehd" {
            for _ in 0..<8 { await sleep(1); emit("clockSample", ["currentTime": engine.currentTime, "clock": engine.clock.currentTime, "source": engine.clock.sourceTime, "state": "\(state)"]) }
        } else { await sleep(2.5) }
        emit("audioSelect", ["track": trackDict(t), "active": engine.activeAudioTrackIndex ?? -1,
                             "decoder": engine.activeAudioDecoder ?? "nil", "delivery": engine.audioDelivery.rawValue, "state": "\(state)",
                             "posBefore": before, "posAfter": engine.clock.currentTime,
                             "moving": engine.clock.currentTime > before + 0.5])
    }

    // Subtitles: PGS first, else first one
    let subs = engine.subtitleTracks
    if let s = subs.first(where: { $0.codec.contains("pgs") }) ?? subs.first {
        let cuesBefore = cueCount
        engine.selectSubtitleTrack(index: s.id)
        await sleep(3)
        emit("subtitleSelect", ["track": trackDict(s), "active": engine.activeSubtitleTrackIndex ?? -1,
                                "cuesBefore": cuesBefore, "cuesAfter": cueCount, "state": "\(state)"])
    } else {
        emit("subtitleSelect", ["skipped": "no subtitle tracks"])
    }

    emit("final", ["state": "\(state)", "position": engine.currentTime, "route": engine.videoRoute.rawValue])
    finish(engine, win)
}

/// Selects one subtitle track, jumps to `seekTo`, plays for `window` seconds and reports every
/// distinct bitmap cue the engine publishes (size, position, canvas, time span, non-empty pixels).
@MainActor func pgsWindow(_ engine: AetherEngine, trackId: Int, seekTo: Double, window: Double) async {
    let subs = engine.subtitleTracks
    emit("pgsTracks", ["subtitles": subs.map(trackDict)])
    guard let track = subs.first(where: { $0.id == trackId }) ?? subs.first(where: { $0.codec.contains("pgs") }) else {
        emit("pgsSkipped", ["reason": "no such track"]); return
    }
    engine.selectSubtitleTrack(index: track.id)
    if seekTo > 0 { await engine.seek(to: seekTo) }
    var seen = Set<Int>()
    var texts = 0
    let end = Date().addingTimeInterval(window)
    var lastCount = -1
    while Date() < end {
        for cue in engine.subtitleCues where !seen.contains(cue.id) {
            seen.insert(cue.id)
            switch cue.body {
            case .image(let img):
                var opaque = 0
                if let d = img.cgImage.dataProvider?.data, let p = CFDataGetBytePtr(d) {
                    let len = CFDataGetLength(d), bpp = max(img.cgImage.bitsPerPixel / 8, 1)
                    var i = 3
                    while i < len { if p[i] > 8 { opaque += 1 }; i += bpp * 7 }
                }
                emit("pgsCue", ["id": cue.id, "start": cue.startTime, "end": cue.endTime,
                                "w": img.cgImage.width, "h": img.cgImage.height,
                                "pos": "\(img.position)", "canvas": "\(img.canvasSize)",
                                "forced": img.isForced, "opaqueSamples": opaque,
                                "clock": engine.currentTime])
            default: texts += 1
            }
        }
        if engine.subtitleCues.count != lastCount {
            lastCount = engine.subtitleCues.count
            emit("pgsCount", ["cues": lastCount, "clock": engine.currentTime])
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
    }
    emit("pgsSummary", ["track": trackDict(track), "distinctImageCues": seen.count - texts, "textCues": texts,
                        "seekTo": seekTo, "window": window, "state": "\(engine.state)", "clock": engine.currentTime])
}

@MainActor func finish(_ engine: AetherEngine, _ win: NSWindow) {
    engine.stop()
    win.orderOut(nil)
    emit("done")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// Hard cap so a hung engine never blocks the batch.
DispatchQueue.main.asyncAfter(deadline: .now() + (Double(env["PROBE_CAP"] ?? "") ?? 75)) { emit("timeout"); exit(3) }
Task { @MainActor in
    await runProbe()
    exit(0)
}
app.run()
