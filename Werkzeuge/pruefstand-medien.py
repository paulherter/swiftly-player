#!/usr/bin/env python3 -I
"""Generates the media matrix of the playback bench (Wiedergabe-Pruefstand) with ffmpeg into one folder.

usage: pruefstand-medien.py <out-dir>

Per title `<id>.json` (what `cargo xtask fixture-server` serves as item + PlaybackInfo, MediaStreams read back
with ffprobe, so the metadata is what a Jellyfin would say) next to the media file. Codecs the local ffmpeg cannot
encode are listed in `skipped.txt` (the matrix shows them as "not covered").
"""
import json, os, subprocess, sys

OUT = sys.argv[1]
DUR = 10
os.makedirs(OUT, exist_ok=True)
skipped = []

def run(args):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"] + args, capture_output=True, text=True)
    return r.returncode == 0, r.stderr.strip()[-300:]

def have(encoder):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"], capture_output=True, text=True)
    return any(l.split()[1:2] == [encoder] for l in r.stdout.splitlines() if l.startswith(" "))

VIDEO = {
    "h264": ["-c:v", "libx264", "-preset", "ultrafast", "-g", "24", "-pix_fmt", "yuv420p"],
    "hevc8": ["-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "keyint=24:log-level=none", "-pix_fmt", "yuv420p", "-tag:v", "hvc1"],
    "hevc10": ["-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "keyint=24:log-level=none", "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1"],
    "av1": ["-c:v", "libsvtav1", "-preset", "12", "-g", "24", "-pix_fmt", "yuv420p"],
    "vp9": ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-g", "24"],
    "mpeg4": ["-c:v", "mpeg4", "-q:v", "5", "-g", "24"],
}
VENC = {"h264": "libx264", "hevc8": "libx265", "hevc10": "libx265", "av1": "libsvtav1", "vp9": "libvpx-vp9", "mpeg4": "mpeg4"}
AUDIO = {
    "aac": ["-c:a", "aac", "-b:a", "96k"],
    "ac3": ["-c:a", "ac3", "-b:a", "192k"],
    "eac3": ["-c:a", "eac3", "-b:a", "192k"],
    "flac": ["-c:a", "flac"],
    "opus": ["-c:a", "libopus", "-b:a", "64k"],
    "truehd": ["-c:a", "truehd", "-strict", "-2"],
    "mp3": ["-c:a", "libmp3lame", "-b:a", "96k"],
}
AENC = {"aac": "aac", "ac3": "ac3", "eac3": "eac3", "flac": "flac", "opus": "libopus", "truehd": "truehd", "mp3": "libmp3lame"}

def src(freq, i=0):
    return ["-f", "lavfi", "-i", f"sine=frequency={freq}:sample_rate=48000:duration={DUR}"]

VSRC = ["-f", "lavfi", "-i", f"testsrc2=size=320x180:rate=24:duration={DUR}"]
# A flat mid-grey picture: a coloured cue (yellow fill) cannot hide in the colour bars of testsrc2 there.
VSRC_FLAT = ["-f", "lavfi", "-i", f"color=c=0x646464:size=320x180:rate=24:duration={DUR}"]

SRT = "1\n00:00:01,000 --> 00:00:03,000\nBench cue one\n\n2\n00:00:04,000 --> 00:00:06,000\nBench cue two\n\n3\n00:00:07,000 --> 00:00:09,000\nBench cue three\n"
ASS = ("[Script Info]\nScriptType: v4.00+\nPlayResX: 320\nPlayResY: 180\n\n[V4+ Styles]\n"
       "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
       "Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1\n\n[Events]\n"
       "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
       "Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\i1}Bench ass one{\\i0}\n"
       "Dialogue: 0,0:00:04.00,0:00:06.00,Default,,0,0,0,,Bench ass two\n"
       "Dialogue: 0,0:00:07.00,0:00:09.00,Default,,0,0,0,,Bench ass three\n")
open(f"{OUT}/cues.srt", "w").write(SRT)
VTT = "WEBVTT\n\n00:01.000 --> 00:03.000\nBench vtt one\n\n00:04.000 --> 00:06.000\nBench vtt two\n\n00:07.000 --> 00:09.000\nBench vtt three\n"
open(f"{OUT}/cues.ass", "w").write(ASS)
# What the real server answers for an ASS track asked for as `.srt`: the same lines, as SRT.
ASS_AS_SRT = SRT.replace("Bench cue", "Bench ass")
open(f"{OUT}/cues.vtt", "w").write(VTT)
# Styled ASS (yellow, bold, italic, red outline), served as `.ssa`: Android line 3 (file style on/off).
open(f"{OUT}/cues.ssa", "w").write(ASS.replace("Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,", "Style: Default,Arial,20,&H0000FFFF,&H000000FF,&H000000FF,&H00000000,-1,-1,"))

def probe(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", path], capture_output=True, text=True)
    return json.loads(r.stdout)

CONTAINER = {"matroska,webm": "mkv", "mov,mp4,m4a,3gp,3g2,mj2": "mp4", "mpegts": "ts", "avi": "avi"}

def describe(id_, file, extra_streams=(), kind="Movie", series=None, number=1, season=1, resume=0, title=None, external=(), video_extra=None,
             source_extra=None, transcode=None, burned=()):
    p = probe(f"{OUT}/{file}")
    fmt = p["format"]
    streams, first_audio = [], None
    for s in p["streams"]:
        t = s["codec_type"]
        if t not in ("video", "audio", "subtitle"):
            continue
        tags = s.get("tags", {})
        m = {"Index": s["index"], "Type": t.capitalize(), "Codec": s["codec_name"],
             "Language": tags.get("language"), "DisplayTitle": tags.get("title") or s["codec_name"].upper(),
             "IsDefault": s.get("disposition", {}).get("default") == 1}
        if t == "subtitle":
            m["IsForced"] = s.get("disposition", {}).get("forced") == 1
        if t == "video":
            m.update(Width=s["width"], Height=s["height"], BitDepth=10 if "10" in s.get("pix_fmt", "") else 8,
                     Profile=s.get("profile"), VideoRangeType="SDR", RealFrameRate=24.0)
            m.update(video_extra or {})
        if t == "audio":
            m.update(Channels=s.get("channels", 2), SampleRate=int(s.get("sample_rate", 48000)))
            first_audio = first_audio if first_audio is not None else s["index"]
        if t == "subtitle":
            m.update(IsTextSubtitleStream=s["codec_name"] in ("subrip", "ass", "srt", "mov_text"), DeliveryMethod="Embed")
        streams.append({k: v for k, v in m.items() if v is not None})
    nxt = max(s["Index"] for s in streams) + 1
    for lang, ext, codec, name in external:
        streams.append({"Index": nxt, "Type": "Subtitle", "Codec": codec, "Language": lang, "DisplayTitle": name,
                        "IsExternal": True, "IsTextSubtitleStream": True, "SupportsExternalStream": True,
                        "DeliveryMethod": "External",
                        "DeliveryUrl": f"/Videos/{id_}/src-{id_}/Subtitles/{nxt}/0/Stream.{ext}"})
        nxt += 1
    for s in streams:  # an ASS / SSA track asked for as .srt is answered with its own text (the app does that by default)
        if s["Type"] == "Subtitle" and s.get("Codec") in ("ass", "ssa"):
            open(f"{OUT}/{id_}.sub{s['Index']}.srt", "w").write(ASS_AS_SRT)
    has_dur = "noduration" not in id_
    run_seconds = {"bm-resume": 150, "bm-pgs-mkv": 260}.get(id_, DUR)
    source = {"Id": f"src-{id_}", "Name": title or id_, "Container": CONTAINER.get(fmt["format_name"], fmt["format_name"]),
              "Size": os.path.getsize(f"{OUT}/{file}"), "RunTimeTicks": run_seconds * 10_000_000,
              "SupportsDirectPlay": True, "SupportsDirectStream": True, "SupportsTranscoding": True,
              "DefaultAudioStreamIndex": first_audio, "DefaultSubtitleStreamIndex": -1, "MediaStreams": streams}
    source.update(source_extra or {})
    doc = {"id": id_, "file": file, "type": kind, "name": title or id_, "series": series, "number": number,
           "resumeTicks": resume, "headerHasDuration": has_dur, "source": source}
    json.dump(doc, open(f"{OUT}/{id_}.json", "w"), indent=1)
    # What the fixture server answers (it has no JSON library): the item, its PlaybackInfo and the media file name.
    item = {"Id": id_, "Name": title or id_, "Type": kind, "RunTimeTicks": run_seconds * 10_000_000, "MediaSources": [source],
            "UserData": {"PlaybackPositionTicks": resume, "Played": False}}
    if series:
        item.update(SeriesId=series, SeriesName="Bench Series", SeasonId=f"bm-s{season}", ParentIndexNumber=season, IndexNumber=number)
    json.dump(item, open(f"{OUT}/{id_}.item.json", "w"))
    json.dump({"MediaSources": [source], "PlaySessionId": f"ps-{id_}"}, open(f"{OUT}/{id_}.info.json", "w"))
    if transcode:
        # What the server answers when the client turns direct play off or the bitrate limit is below the title's bitrate:
        # the same streams (bitmap subtitles it burns in marked `Encode`), no direct play, an HLS address.
        t = json.loads(json.dumps(source))
        t.update(SupportsDirectPlay=False, SupportsDirectStream=False, SupportsTranscoding=True,
                 TranscodingUrl=f"/videos/{id_}/master.m3u8?MediaSourceId=src-{id_}&VideoCodec=h264&SubtitleMethod=Encode",
                 TranscodingSubProtocol="hls", TranscodingContainer=transcode)
        for st in t["MediaStreams"]:
            if st["Type"] == "Subtitle" and st["Index"] in burned:
                st["DeliveryMethod"] = "Encode"
            elif st["Type"] == "Subtitle" and st.get("IsTextSubtitleStream"):
                # An HLS stream cannot carry a text track: the real server hands it out as a file (External + DeliveryUrl,
                # `IsExternal` stays false for a track inside the container).
                st.update(DeliveryMethod="External", SupportsExternalStream=True,
                          DeliveryUrl=f"/Videos/{id_}/{t['Id']}/Subtitles/{st['Index']}/0/Stream.srt")
        json.dump({"MediaSources": [t], "PlaySessionId": f"ps-{id_}"}, open(f"{OUT}/{id_}.info.transcode.json", "w"))
    open(f"{OUT}/{id_}.media", "w").write(file)
    return has_dur

def make(id_, vcodec, acodec, ext, extra=(), flat=False, **kw):
    if not have(VENC[vcodec]) or not have(AENC[acodec]):
        skipped.append(f"{id_}: encoder missing ({VENC[vcodec]}/{AENC[acodec]})")
        return
    file = f"{id_}.{ext}"
    ok, err = run((VSRC_FLAT if flat else VSRC) + src(440) + VIDEO[vcodec] + AUDIO[acodec] + ["-t", str(DUR), f"{OUT}/{file}"])
    if not ok:
        skipped.append(f"{id_}: ffmpeg failed: {err}")
        return
    describe(id_, file, **kw)

make("bm-h264-aac-mp4", "h264", "aac", "mp4")
make("bm-h264-aac-mkv", "h264", "aac", "mkv")
make("bm-h264-ac3-mkv", "h264", "ac3", "mkv")
make("bm-h264-eac3-mp4", "h264", "eac3", "mp4")
make("bm-h264-flac-mkv", "h264", "flac", "mkv")
make("bm-h264-opus-mkv", "h264", "opus", "mkv")
make("bm-h264-truehd-mkv", "h264", "truehd", "mkv")
make("bm-h264-aac-ts", "h264", "aac", "ts")
make("bm-hevc8-aac-mp4", "hevc8", "aac", "mp4")
make("bm-hevc10-eac3-mkv", "hevc10", "eac3", "mkv")
make("bm-av1-opus-mkv", "av1", "opus", "mkv")
make("bm-vp9-opus-webm", "vp9", "opus", "webm")
make("bm-mpeg4-mp3-avi", "mpeg4", "mp3", "avi")
# Resume needs a long title: the rule resumes only after 60 s and not within 60 s of the end.
ok, err = run(["-f", "lavfi", "-i", "testsrc2=size=160x90:rate=12:duration=150", "-f", "lavfi", "-i", "sine=frequency=330:duration=150"] +
              VIDEO["h264"] + ["-crf", "40", "-g", "12"] + AUDIO["aac"] + ["-t", "150", f"{OUT}/bm-resume.mp4"])
if ok:
    describe("bm-resume", "bm-resume.mp4", resume=800_000_000, title="Resume at 80 s of 150 s")
else:
    skipped.append(f"bm-resume: ffmpeg failed: {err}")
# PGS (bitmap) subtitles in an mkv, like a Blu-ray rip: ffmpeg cannot encode PGS, so write the .sup by hand (a solid
# bar per display set, one every 10 s from 3 s, 2 s long) and mux two PGS tracks + one SRT next to a 200 s title.
import struct
def pgs_segment(kind, pts, payload):
    return b"PG" + struct.pack(">II", int(pts * 90000), 0) + bytes([kind]) + struct.pack(">H", len(payload)) + payload
def pgs_display_set(start, end, w=320, h=180, bar_w=200, bar_h=24, comp=0):
    def pcs(pts, shown, n):
        body = struct.pack(">HHBHBBBB", w, h, 0x10, n, 0x80, 0, 0, 1 if shown else 0)
        if shown:
            body += struct.pack(">HBBHH", 0, 0, 0, (w - bar_w) // 2, h - bar_h - 20)
        return pgs_segment(0x16, pts, body)
    wds = struct.pack(">BBHHHH", 1, 0, (w - bar_w) // 2, h - bar_h - 20, bar_w, bar_h)
    pds = struct.pack(">BB", 0, 0) + bytes([1, 235, 128, 128, 255])
    # run of `bar_w` pixels of colour 1: 00 01LLLLLL.. for L < 64, 00 11LLLLLL LLLLLLLL cc for larger runs
    line = bytes([0, 0xC0 | (bar_w >> 8), bar_w & 0xFF, 1]) + bytes([0, 0])
    rle = line * bar_h
    ods = struct.pack(">HBB", 0, 0, 0xC0) + struct.pack(">I", len(rle) + 4)[1:] + struct.pack(">HH", bar_w, bar_h) + rle
    return (pcs(start, True, comp) + pgs_segment(0x17, start, wds) + pgs_segment(0x14, start, pds)
            + pgs_segment(0x15, start, ods) + pgs_segment(0x80, start, b"")
            + pcs(end, False, comp + 1) + pgs_segment(0x17, end, struct.pack(">BBHHHH", 1, 0, (w - bar_w) // 2, h - bar_h - 20, bar_w, bar_h))
            + pgs_segment(0x80, end, b""))
PGS_LONG = 260
for name, every, first in (("forced", 60, 124), ("full", 10, 124)):
    with open(f"{OUT}/pgs-{name}.sup", "wb") as f:
        t = first
        while t + 2 < PGS_LONG:
            f.write(pgs_display_set(t, t + 2, comp=(t * 2) % 60000))
            t += every
open(f"{OUT}/pgs.srt", "w").write("1\n00:00:03,000 --> 00:00:05,000\nBench text\n")
ok, err = run(["-copyts", "-f", "lavfi", "-i", f"testsrc2=size=320x180:rate=12:duration={PGS_LONG}", "-f", "lavfi", "-i", f"sine=frequency=330:duration={PGS_LONG}",
               "-i", f"{OUT}/pgs-forced.sup", "-i", f"{OUT}/pgs-full.sup", "-i", f"{OUT}/pgs.srt"] +
              VIDEO["h264"] + ["-crf", "40", "-g", "12"] + AUDIO["aac"] +
              ["-map", "0:v", "-map", "1:a", "-map", "2:s", "-map", "3:s", "-map", "4:s", "-c:s:0", "copy", "-c:s:1", "copy", "-c:s:2", "srt",
               "-metadata:s:s:0", "language=eng", "-metadata:s:s:1", "language=eng", "-metadata:s:s:2", "language=eng",
               "-metadata:s:s:0", "title=Forced", "-disposition:s:0", "forced", "-t", str(PGS_LONG), f"{OUT}/bm-pgs-mkv.mkv"])
if ok:
    describe("bm-pgs-mkv", "bm-pgs-mkv.mkv", resume=1_200_000_000, title="PGS + text subtitles, resume at 120 s of 260 s, first PGS cue at 124 s")
else:
    skipped.append(f"bm-pgs-mkv: ffmpeg failed: {err}")
make("bm-ep1", "h264", "aac", "mp4", kind="Episode", series="bm-series", number=1, title="Bench Episode 1")
make("bm-ep2", "h264", "aac", "mp4", kind="Episode", series="bm-series", number=2, title="Bench Episode 2")
# Season 2 of the series (the episodes layer's season picker and a switch to another season's card).
make("bm-ep3", "h264", "aac", "mp4", kind="Episode", series="bm-series", season=2, number=1, title="Bench Episode 3")
make("bm-ep4", "h264", "aac", "mp4", kind="Episode", series="bm-series", season=2, number=2, title="Bench Episode 4")

# Multi audio (aac eng, ac3 deu, eac3 fra) + embedded SRT and ASS.
open(f"{OUT}/embedded.srt", "w").write(SRT)
ok, err = run(VSRC + src(440) + src(660) + src(880) + ["-i", f"{OUT}/embedded.srt", "-i", f"{OUT}/cues.ass"] +
              VIDEO["h264"] + ["-c:a:0", "aac", "-c:a:1", "ac3", "-c:a:2", "eac3", "-c:s:0", "srt", "-c:s:1", "ass"] +
              ["-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:a", "-map", "4:s", "-map", "5:s",
               "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=deu", "-metadata:s:a:2", "language=fra",
               "-metadata:s:s:0", "language=eng", "-metadata:s:s:1", "language=deu", "-disposition:a:0", "default", "-t", str(DUR), f"{OUT}/bm-multi-mkv.mkv"])
if ok:
    describe("bm-multi-mkv", "bm-multi-mkv.mkv", title="Multi audio + embedded subs")
    # The "single audio rebuilt" download (server remux with audioStreamIndex: no duration in the header, written to a pipe).
    for idx in (2, 3):
        with open(f"{OUT}/bm-multi-mkv.a{idx}.mkv", "wb") as f:
            r = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", f"{OUT}/bm-multi-mkv.mkv", "-map", "0:v", "-map", f"0:{idx}",
                                "-c", "copy", "-f", "matroska", "pipe:1"], stdout=f)
else:
    skipped.append(f"bm-multi-mkv: ffmpeg failed: {err}")

# External subtitle files next to an mp4 (SRT + ASS).
make("bm-ext-subs", "h264", "aac", "mp4", external=(("eng", "srt", "subrip", "English (SRT)"), ("deu", "ass", "ass", "Deutsch (ASS)")))

# Additive (Android subtitle contract): an external WebVTT file, and an MP4 with an embedded text track (mov_text).
make("bm-ass-styled", "h264", "aac", "mp4", flat=True, external=(("eng", "ssa", "ass", "English (styled ASS)"),))
make("bm-ext-vtt", "h264", "aac", "mp4", external=(("eng", "vtt", "webvtt", "English (VTT)"),))
ok, err = run(VSRC + src(440) + ["-i", f"{OUT}/embedded.srt"] + VIDEO["h264"] + AUDIO["aac"] +
              ["-c:s", "mov_text", "-map", "0:v", "-map", "1:a", "-map", "2:s", "-metadata:s:s:0", "language=eng", "-t", str(DUR), f"{OUT}/bm-mp4-text.mp4"])
if ok:
    describe("bm-mp4-text", "bm-mp4-text.mp4", title="MP4 with an embedded text track")
else:
    skipped.append(f"bm-mp4-text: ffmpeg failed: {err}")

# A flat mid-grey picture with one SRT track: the look check (fill colour, dark outline) needs a background without detail.
ok, err = run(["-f", "lavfi", "-i", f"color=c=0x646464:size=320x180:rate=24:duration={DUR}"] + src(440) + ["-i", f"{OUT}/embedded.srt"] + VIDEO["h264"] + AUDIO["aac"] +
              ["-c:s", "srt", "-map", "0:v", "-map", "1:a", "-map", "2:s", "-metadata:s:s:0", "language=eng", "-t", str(DUR), f"{OUT}/bm-flat-grey.mkv"])
if ok:
    describe("bm-flat-grey", "bm-flat-grey.mkv", title="Flat grey picture + SRT (look check)")
else:
    skipped.append(f"bm-flat-grey: ffmpeg failed: {err}")

# A file with no duration in its header (a built download, a pipe): mkv + ts.
with open(f"{OUT}/bm-noduration-mkv.mkv", "wb") as f:
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"] + VSRC + src(440) + VIDEO["h264"] + AUDIO["aac"] + ["-t", str(DUR), "-f", "matroska", "pipe:1"], stdout=f)
describe("bm-noduration-mkv", "bm-noduration-mkv.mkv", title="mkv without header duration")


# ---------------------------------------------------------------------------------------------------------------------
# HDR / Dolby Vision / AV1 10-bit / server transcode (apple-100 wave): 640x360, 10 s, AAC + embedded SRT, and a PGS track in
# the mkv variants. The Dolby Vision RPUs are generated (`dovi_tool generate`, flat default metadata) and injected into the
# HEVC base layer; `MP4Box` writes the dvcC/dvvC record. Profile 10 (AV1): the record is real, the AV1 stream carries no RPU
# OBUs (no tool writes them), so it is "DV 10 by configuration record". Needs dovi_tool, MP4Box (gpac), x265 + svt-av1.
import shutil, tempfile
W = f"{OUT}/_work"
os.makedirs(W, exist_ok=True)
HVSRC = ["-f", "lavfi", "-i", f"testsrc2=size=640x360:rate=24:duration={DUR}"]
HDR_MD = "master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400"

def tool(cmd, *args):
    r = subprocess.run([cmd, *args], capture_output=True, text=True)
    return r.returncode == 0, (r.stderr or r.stdout).strip()[-200:]

# A 10 s PGS track for the mkv variants (cue at 2 s and 6 s, 2 s long): the same hand-written display sets as above.
with open(f"{W}/pgs10.sup", "wb") as f:
    for t in (2, 6):
        f.write(pgs_display_set(t, t + 2, w=640, h=360, bar_w=400, bar_h=48, comp=t * 2))
open(f"{W}/cues10.srt", "w").write("1\n00:00:01,000 --> 00:00:03,000\nBench cue one\n\n2\n00:00:04,000 --> 00:00:06,000\nBench cue two\n\n3\n00:00:07,000 --> 00:00:09,000\nBench cue three\n")
ok, err = run(["-f", "lavfi", "-i", f"sine=frequency=440:sample_rate=48000:duration={DUR}", "-c:a", "aac", "-b:a", "96k", f"{W}/a.m4a"])

def hdr_video_extra(range_type, transfer=None, dv=None):
    m = {"VideoRange": "SDR" if range_type == "SDR" else "HDR", "VideoRangeType": range_type}
    if range_type != "SDR":
        m.update(ColorSpace="bt2020nc", ColorPrimaries="bt2020", ColorTransfer=transfer or "smpte2084")
    if dv:
        m.update(DvVersionMajor=1, DvVersionMinor=0, DvProfile=dv[0], DvLevel=dv[2] if len(dv) > 2 else 6,
                 RpuPresentFlag=1 if dv[3:4] != (0,) else 0, ElPresentFlag=0, BlPresentFlag=1, DvBlSignalCompatibilityId=dv[1])
    return m

def to_mkv(mp4, out, pgs=True):
    """Same streams in an mkv (copy keeps the Dolby Vision record), plus a PGS and an SRT track."""
    args = ["-i", mp4, "-i", f"{W}/cues10.srt"] + (["-i", f"{W}/pgs10.sup"] if pgs else [])
    maps = ["-map", "0:v", "-map", "0:a", "-map", "1:s"] + (["-map", "2:s"] if pgs else [])
    # `dvh1` (Dolby Vision profile 5 in an mp4) is no tag the matroska muxer takes: write the plain HEVC one.
    tag = ["-tag:v", "hvc1"] if "dv5" in os.path.basename(mp4) else []
    meta = ["-c", "copy"] + tag + ["-c:s:0", "srt", "-metadata:s:s:0", "language=eng", "-metadata:s:s:0", "title=English (SRT)"]
    if pgs:
        meta += ["-c:s:1", "copy", "-metadata:s:s:1", "language=eng", "-metadata:s:s:1", "title=English (PGS)"]
    return run(["-copyts"] + args + maps + meta + ["-t", str(DUR), out])

def hdr_set(id_base, video_in, vlabel, extra, dv_flag=None):
    """mp4 (video + AAC + SRT as tx3g) and mkv (+ PGS) titles of one base layer. `video_in`: file for MP4Box (raw hevc / ivf)."""
    flag = f":{dv_flag}" if dv_flag else ""
    mp4 = f"{OUT}/{id_base}-mp4.mp4"
    okm, errm = tool("MP4Box", "-quiet", "-add", f"{video_in}{flag}:fps=24", "-add", f"{W}/a.m4a", "-add", f"{W}/cues10.srt:lang=eng", "-new", mp4)
    if not okm or not os.path.isfile(mp4):
        skipped.append(f"{id_base}: MP4Box failed ({dv_flag}): {errm}")
        return None
    describe(f"{id_base}-mp4", f"{id_base}-mp4.mp4", title=f"{vlabel} (mp4, SRT)", video_extra=extra)
    mkv = f"{OUT}/{id_base}-mkv.mkv"
    okk, errk = to_mkv(mp4, mkv)
    if not okk:
        skipped.append(f"{id_base}-mkv: ffmpeg failed: {errk}")
        return mp4
    describe(f"{id_base}-mkv", f"{id_base}-mkv.mkv", title=f"{vlabel} (mkv, SRT + PGS)", video_extra=extra)
    return mp4

dovi = shutil.which("dovi_tool") and shutil.which("MP4Box")
VIDEO_HDR = ["-c:v", "libx265", "-preset", "ultrafast", "-pix_fmt", "yuv420p10le"]

if have("libx265") and shutil.which("MP4Box"):
    # HEVC HDR10 with mastering display + content light level.
    ok, err = run(HVSRC + VIDEO_HDR + ["-x265-params", f"keyint=24:log-level=none:repeat-headers=1:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:range=limited:{HDR_MD}", "-f", "hevc", f"{W}/hdr10.hevc"])
    if ok:
        hdr_set("bm-hdr10", f"{W}/hdr10.hevc", "HEVC HDR10 (PQ, mastering metadata)", hdr_video_extra("HDR10"))
    else:
        skipped.append(f"bm-hdr10: x265 failed: {err}")
    # HLG.
    ok, err = run(HVSRC + VIDEO_HDR + ["-x265-params", "keyint=24:log-level=none:repeat-headers=1:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:range=limited", "-f", "hevc", f"{W}/hlg.hevc"])
    if ok:
        hdr_set("bm-hlg", f"{W}/hlg.hevc", "HEVC HLG", hdr_video_extra("HLG", "arib-std-b67"))
    else:
        skipped.append(f"bm-hlg: x265 failed: {err}")
else:
    skipped.append("bm-hdr10, bm-hlg: libx265 or MP4Box (gpac) missing")

if dovi and have("libx265"):
    cfg = lambda profile: ('{"cm_version":"V29","profile":"%s","length":%d,"level6":{"max_display_mastering_luminance":1000,"min_display_mastering_luminance":1,'
                           '"max_content_light_level":1000,"max_frame_average_light_level":400},"default_metadata_blocks":[{"Level1":{"min_pq":0,"max_pq":3079,"avg_pq":1200}},'
                           '{"Level2":{"target_max_pq":2081,"trim_slope":2048,"trim_offset":2048,"trim_power":2048,"trim_chroma_weight":2048,"trim_saturation_gain":2048,"ms_weight":2048}}]}') % (profile, DUR * 24)
    for name, profile, base, flag, label, extra in (
        ("bm-dv81", "8.1", "hdr10.hevc", "dv-profile=8.1", "Dolby Vision profile 8.1 (HDR10 base + RPU)", hdr_video_extra("DOVIWithHDR10", dv=(8, 1))),
        ("bm-dv5", "5", None, "dv-profile=5", "Dolby Vision profile 5 (IPT-PQ-c2 + RPU)", hdr_video_extra("DOVI", dv=(5, 0))),
    ):
        open(f"{W}/{name}.json", "w").write(cfg(profile))
        ok1, e1 = tool("dovi_tool", "generate", "-j", f"{W}/{name}.json", "-o", f"{W}/{name}.rpu")
        base_file = f"{W}/{base}" if base else f"{W}/p5base.hevc"
        if base is None:   # profile 5: a plain 10-bit base layer without HDR10 signalling (the IPT picture)
            run(HVSRC + VIDEO_HDR + ["-x265-params", "keyint=24:log-level=none:repeat-headers=1", "-f", "hevc", base_file])
        if not ok1 or not os.path.isfile(base_file):
            skipped.append(f"{name}: dovi_tool generate failed: {e1}")
            continue
        ok2, e2 = tool("dovi_tool", "inject-rpu", "-i", base_file, "--rpu-in", f"{W}/{name}.rpu", "-o", f"{W}/{name}.hevc")
        if not ok2 or not os.path.isfile(f"{W}/{name}.hevc"):
            skipped.append(f"{name}: dovi_tool inject-rpu failed: {e2}")
            continue
        hdr_set(name, f"{W}/{name}.hevc", label, extra, dv_flag=flag)
else:
    skipped.append("bm-dv5, bm-dv81: dovi_tool/MP4Box missing (brew install dovi_tool gpac)")

# AV1 10-bit: plain (BT.709), and the HDR10 base for Dolby Vision profile 10.
if have("libsvtav1"):
    ok, err = run(HVSRC + ["-c:v", "libsvtav1", "-preset", "12", "-g", "24", "-pix_fmt", "yuv420p10le", "-f", "ivf", f"{W}/av1-10.ivf"])
    if ok:
        hdr_set("bm-av110", f"{W}/av1-10.ivf", "AV1 10-bit (SDR)", {"BitDepth": 10})
    else:
        skipped.append(f"bm-av110: svt-av1 failed: {err}")
    pq = ("color-primaries=9:transfer-characteristics=16:matrix-coefficients=9:color-range=0:"
          "mastering-display=G(0.265,0.690)B(0.150,0.060)R(0.680,0.320)WP(0.3127,0.3290)L(1000,0.0001):content-light=1000,400")
    ok, err = run(HVSRC + ["-c:v", "libsvtav1", "-preset", "12", "-g", "24", "-pix_fmt", "yuv420p10le", "-svtav1-params", pq, "-f", "ivf", f"{W}/av1-pq.ivf"])
    if ok and shutil.which("MP4Box"):
        # 10.1: HDR10 base layer under the picture, plays everywhere. 10.0: no base layer, the one that shows green without Dolby Vision.
        hdr_set("bm-dv10", f"{W}/av1-pq.ivf", "Dolby Vision profile 10.1 (AV1, config record)", hdr_video_extra("DOVIWithHDR10", dv=(10, 1)), dv_flag="dv-profile=10.1")
        # 10.0 only as mkv (an mp4 would need the `dav1` sample entry, which no tool but Dolby's reads): the 10.1 mkv with the
        # record's compatibility id patched to 0 (`01 00 14 0d 10` -> `01 00 14 0d 00` inside the BlockAdditionMapping).
        okm, _ = tool("MP4Box", "-quiet", "-add", f"{W}/av1-pq.ivf:dv-profile=10.1:fps=24", "-add", f"{W}/a.m4a", "-add", f"{W}/cues10.srt:lang=eng", "-new", f"{W}/dv100.mp4")
        okk, errk = to_mkv(f"{W}/dv100.mp4", f"{OUT}/bm-dv100-mkv.mkv") if okm else (False, "MP4Box failed")
        if okk:
            data = open(f"{OUT}/bm-dv100-mkv.mkv", "rb").read()
            if data.count(b"dvvC\x41\xed\x98\x01\x00\x14\x0d\x10") == 1:
                open(f"{OUT}/bm-dv100-mkv.mkv", "wb").write(data.replace(b"dvvC\x41\xed\x98\x01\x00\x14\x0d\x10", b"dvvC\x41\xed\x98\x01\x00\x14\x0d\x00"))
                describe("bm-dv100-mkv", "bm-dv100-mkv.mkv", title="Dolby Vision profile 10.0 (AV1, no base layer, mkv, SRT + PGS)", video_extra=hdr_video_extra("DOVI", dv=(10, 0)))
            else:
                skipped.append("bm-dv100-mkv: could not find the dvvC record to patch")
        else:
            skipped.append(f"bm-dv100-mkv: {errk}")
    else:
        skipped.append(f"bm-dv10: svt-av1/MP4Box failed: {err}")
else:
    skipped.append("bm-av110, bm-dv10: libsvtav1 missing")

# Server transcodes (HLS made by ffmpeg): `bm-dv100-transcode` = the 10.0 file, the server converts it (fMP4 segments, the PGS
# track burned into the picture at 2-4 s and 6-8 s in the `-burn3` folder, which the re-plan for track 3 gets); `bm-limit-transcode` = the HDR10 file with a declared bitrate above the
# limit (TS segments, the text subtitle stays a separate file). The hls folder of a title: `<id>.hls/`.
# The picture subtitle file starts at 0 in an overlay graph: shifted by 2 s so its cues (2-4 s, 6-8 s in the file's own clock) land there.
def hls(id_, fmp4, burn):
    d = f"{OUT}/{id_}.hls"
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    vf = (["-filter_complex", "[0:v][1:s]overlay=eof_action=pass,format=yuv420p[v]", "-map", "[v]"] if burn else ["-vf", "format=yuv420p", "-map", "0:v"])
    inputs = HVSRC + (["-itsoffset", "2", "-i", f"{W}/pgs10.sup"] if burn else []) + ["-f", "lavfi", "-i", f"sine=frequency=440:sample_rate=48000:duration={DUR}"]
    audio_index = 2 if burn else 1
    seg = (["-hls_segment_type", "fmp4", "-hls_fmp4_init_filename", "init.mp4", "-hls_segment_filename", f"{d}/seg%d.m4s"] if fmp4
           else ["-hls_segment_type", "mpegts", "-hls_segment_filename", f"{d}/seg%d.ts"])
    return run(inputs + vf + ["-map", f"{audio_index}:a", "-c:v", "libx264", "-preset", "ultrafast", "-g", "24", "-c:a", "aac", "-b:a", "96k", "-t", str(DUR),
                "-f", "hls", "-hls_time", "4", "-hls_playlist_type", "vod", "-master_pl_name", "master.m3u8"] + seg + [f"{d}/main.m3u8"])

if os.path.isfile(f"{OUT}/bm-dv100-mkv.mkv"):
    # The plain stream has no subtitle in the picture; the viewer's pick of the PGS track (index 3) is a re-plan that the fixture
    # answers with `bm-dv100-transcode-burn3` (the same stream with the bitmap burned in), like a server does.
    ok, err = hls("bm-dv100-transcode", True, False)
    if ok:
        ok, err = hls("bm-dv100-transcode-burn3", True, True)
    if ok:
        describe("bm-dv100-transcode", "bm-dv100-mkv.mkv", title="DV 10.0 that the server converts (HLS, PGS burned in)",
                 video_extra=hdr_video_extra("DOVI", dv=(10, 0)), transcode="mp4", burned=(3,))
        # The plain 10.0 title answers a transcode too: a host without AV1 hardware (M1/M2 Mac, older phones) asks for one
        # (`HardwareAV1`), and a server without that answer made the matrix play the file direct, which cannot start there.
        # Same HLS folder (the url names it); only the source id is the plain title's.
        info = json.load(open(f"{OUT}/bm-dv100-transcode.info.transcode.json"))
        info["MediaSources"][0]["Id"] = "src-bm-dv100-mkv"
        info["PlaySessionId"] = "ps-bm-dv100-mkv"
        for st in info["MediaSources"][0]["MediaStreams"]:
            if st.get("DeliveryUrl"): st["DeliveryUrl"] = st["DeliveryUrl"].replace("bm-dv100-transcode", "bm-dv100-mkv")
        json.dump(info, open(f"{OUT}/bm-dv100-mkv.info.transcode.json", "w"))
    else:
        skipped.append(f"bm-dv100-transcode: hls failed: {err}")
if os.path.isfile(f"{OUT}/bm-dv5-mkv.mkv"):
    # Profile 5 has no HDR10 base layer: a device without a Dolby Vision decoder gets this transcode (h264 TS, text subtitle separate).
    ok, err = hls("bm-dv5-transcode", False, False)
    if ok:
        describe("bm-dv5-transcode", "bm-dv5-mkv.mkv", title="DV profile 5 that the server converts (HLS)",
                 video_extra=hdr_video_extra("DOVI", dv=(5, 0)), transcode="ts")
    else:
        skipped.append(f"bm-dv5-transcode: hls failed: {err}")
if os.path.isfile(f"{OUT}/bm-hdr10-mkv.mkv"):
    ok, err = hls("bm-limit-transcode", False, False)
    if ok:
        describe("bm-limit-transcode", "bm-hdr10-mkv.mkv", title="Bitrate above the limit: the server converts (HLS, text subtitle)",
                 video_extra=hdr_video_extra("HDR10"), source_extra={"Bitrate": 200_000_000}, transcode="ts")
    else:
        skipped.append(f"bm-limit-transcode: hls failed: {err}")
shutil.rmtree(W, ignore_errors=True)

open(f"{OUT}/skipped.txt", "w").write("\n".join(skipped) + ("\n" if skipped else ""))
print(f"generated {len([f for f in os.listdir(OUT) if f.endswith('.json')])} titles; skipped: {len(skipped)}")
for s in skipped:
    print("  skipped", s)
