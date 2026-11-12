#!/usr/bin/env python3 -I
"""Plex shape of the playback bench media (run after pruefstand-medien.py).

usage: pruefstand-plex.py <media-dir>

For a few `bm-*` titles it writes what a Plex server would answer, next to the media files:
  plex-<ratingKey>.json   the Metadata object (Media > Part > Stream, Plex codec names, stream ids unrelated to the
                          position in the file, `index` = position, an external subtitle with a `key`)
  plex-<ratingKey>.media  the media file name served at /library/parts/<ratingKey>/1/file.<ext>
  plex-stream-<id>.<ext>  the external subtitle files served at /library/streams/<id>
`xtask/src/fixture_plex.rs` serves them when SWIFTLY_FIXTURE_MEDIA_DIR is set.
"""
import json, os, shutil, sys

OUT = sys.argv[1]
TITLES = {9001: "bm-multi-mkv", 9002: "bm-pgs-mkv", 9003: "bm-ext-subs"}
# 9003 and 9001 are also episodes 1 and 2 of one series (rating key 80), so a next-episode switch can be played.
EPISODES = {9003: 1, 9001: 2}
PLEX_CODEC = {"hdmv_pgs_subtitle": "pgs", "subrip": "srt", "dvd_subtitle": "vobsub", "mov_text": "mov_text"}
EXT_FILE = {"srt": "cues.srt", "ass": "cues.ass", "vtt": "cues.vtt"}


def stream_id(rating_key, position):
    # Plex stream ids are large and unrelated to the place in the file.
    return 412900 + (rating_key % 100) * 100 + position * 3 + 5


for rating_key, bm in TITLES.items():
    path = f"{OUT}/{bm}.json"
    if not os.path.isfile(path):
        continue
    doc = json.load(open(path))
    source = doc["source"]
    streams, first_audio_done = [], False
    for s in source["MediaStreams"]:
        kind = {"Video": 1, "Audio": 2, "Subtitle": 3}[s["Type"]]
        external = s.get("IsExternal", False)
        sid = stream_id(rating_key, s["Index"])
        codec = PLEX_CODEC.get(s["Codec"], s["Codec"])
        p = {"id": sid, "streamType": kind, "codec": codec}
        if not external:
            p["index"] = s["Index"]
        if s.get("Language"):
            p["languageCode"] = s["Language"]
        p["displayTitle"] = s.get("DisplayTitle", codec)
        if kind == 1:
            p.update(width=s.get("Width"), height=s.get("Height"), frameRate=24.0, bitDepth=s.get("BitDepth", 8))
        if kind == 2:
            p["channels"] = s.get("Channels", 2)
            if not first_audio_done:
                p["selected"] = True
                first_audio_done = True
        if kind == 3:
            if s.get("DisplayTitle") == "Forced":
                p["forced"] = True
            if external:
                ext = s["DeliveryUrl"].rsplit(".", 1)[-1]
                p["key"] = f"/library/streams/{sid}"
                p["format"] = ext
                shutil.copy(f"{OUT}/{EXT_FILE.get(ext, 'cues.srt')}", f"{OUT}/plex-stream-{sid}.{ext}")
        streams.append(p)
    file = doc["file"]
    ext = file.rsplit(".", 1)[-1]
    ms = int(source["RunTimeTicks"] // 10_000)
    metadata = {
        "ratingKey": str(rating_key), "type": "movie", "title": f"Plex {bm}", "year": 2020, "duration": ms,
        "thumb": f"/library/metadata/{rating_key}/thumb/1", "art": f"/library/metadata/{rating_key}/art/1",
        "addedAt": 1700000000,
        "Media": [{"id": rating_key, "duration": ms, "container": ext, "videoCodec": "h264", "width": 320, "height": 180,
                   "Part": [{"id": rating_key, "key": f"/library/parts/{rating_key}/1/file.{ext}", "container": ext,
                             "size": source["Size"], "duration": ms, "Stream": streams}]}],
    }
    if rating_key in EPISODES:
        metadata.update(type="episode", index=EPISODES[rating_key], parentIndex=1, parentRatingKey="81", grandparentRatingKey="80",
                        grandparentTitle="Plex Bench Serie", parentTitle="Staffel 1")
        del metadata["year"]
    if doc["resumeTicks"] and rating_key not in EPISODES:
        metadata["viewOffset"] = int(doc["resumeTicks"] // 10_000)
        metadata["lastViewedAt"] = 1700000000
    json.dump(metadata, open(f"{OUT}/plex-{rating_key}.json", "w"))
    open(f"{OUT}/plex-{rating_key}.media", "w").write(file)
leaves = [json.load(open(f"{OUT}/plex-{k}.json")) for k in EPISODES if os.path.isfile(f"{OUT}/plex-{k}.json")]
json.dump(leaves, open(f"{OUT}/plex-leaves-80.json", "w"))
print("plex titles:", ", ".join(str(k) for k in TITLES if os.path.isfile(f"{OUT}/plex-{k}.json")))
