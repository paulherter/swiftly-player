"""Deterministic recorded-server stand-in for the home differential test.
Run: python3 -I make_fixtures.py <output dir>. Writes views.json, resume.json, nextup.json,
latest.json, catalog.json, ancestors.json (what a Jellyfin server answered for one account with
two series libraries holding the same shows, a movie library and a mixed library)."""
import json, sys, os

out = sys.argv[1]
views = [
    {"Id": "v_mov", "Name": "Filme", "Type": "CollectionFolder", "CollectionType": "movies"},
    {"Id": "v_ser", "Name": "Serien", "Type": "CollectionFolder", "CollectionType": "tvshows"},
    {"Id": "v_ser2", "Name": "Serien Kinder", "Type": "CollectionFolder", "CollectionType": "tvshows"},
    {"Id": "v_mix", "Name": "Heimvideos", "Type": "CollectionFolder"},
]
catalog, ancestors = {}, {}


def put(item, lib):
    catalog[item["Id"]] = item
    ancestors[item["Id"]] = [{"Id": "folder-" + item["Id"], "Name": "x"}, {"Id": lib, "Name": "lib"}]
    return item


def series(n, copy=False):
    sid = "s%02d%s" % (n, "b" if copy else "")
    ids = {"Tvdb": str(1000 + n)}
    if not copy or n % 2:
        ids["Tmdb"] = str(2000 + n)
    if copy and n % 2 == 0:
        ids = {"Tvdb": str(1000 + n)}
    return put({"Id": sid, "Name": "Serie %02d" % n, "Type": "Series", "ProductionYear": 2000 + n,
                "ProviderIds": ids}, "v_ser2" if copy else "v_ser")


def episode(n, season, ep, copy=False, pos=None, played=False):
    sid = "s%02d%s" % (n, "b" if copy else "")
    eid = "e%02d_%d_%d%s" % (n, season, ep, "b" if copy else "")
    ud = {"PlaybackPositionTicks": (pos or 0) * 600_000_000, "Played": played,
          "PlayedPercentage": 40.0 if pos else (100.0 if played else 0.0)}
    if pos:
        ud["LastPlayedDate"] = "2026-11-0%dT20:00:00.0000000Z" % (1 + n % 8)
    return put({"Id": eid, "Name": "Folge %d" % ep, "Type": "Episode", "SeriesName": "Serie %02d" % n,
                "SeriesId": sid, "ParentIndexNumber": season, "IndexNumber": ep,
                "RunTimeTicks": 45 * 600_000_000, "UserData": ud,
                "ProviderIds": {"Tvdb": str(900000 + n * 100 + ep)}},
               "v_ser2" if copy else "v_ser")


def movie(n, copy=False, pos=None, played=False):
    mid = "m%02d%s" % (n, "b" if copy else "")
    ud = {"PlaybackPositionTicks": (pos or 0) * 600_000_000, "Played": played,
          "PlayedPercentage": 30.0 if pos else (100.0 if played else 0.0)}
    return put({"Id": mid, "Name": "Film %02d" % n, "Type": "Movie", "ProductionYear": 2010 + n,
                "RunTimeTicks": 110 * 600_000_000, "UserData": ud,
                "ProviderIds": {"Tmdb": str(5000 + n), "Imdb": "tt%07d" % (7000 + n)}},
               "v_mix" if copy else "v_mov")


for n in range(1, 31):
    series(n)
for n in range(1, 9):
    series(n, copy=True)

resume = []
# several episodes of the same series, started
resume += [episode(1, 1, 3, pos=12), episode(1, 1, 4, pos=3), episode(1, 2, 1, pos=5)]
resume += [episode(2, 1, 7, pos=20), episode(2, 1, 8, pos=2)]
for n in range(3, 15):
    resume.append(episode(n, 1, 2 + n % 4, pos=5 + n))
# the same episodes again from the second library (hardlinked copy)
resume.insert(4, episode(3, 1, 2 + 3 % 4, copy=True, pos=5 + 3))
resume.insert(9, episode(5, 1, 2 + 5 % 4, copy=True, pos=5 + 5))
resume.insert(15, episode(7, 1, 2 + 7 % 4, copy=True, pos=5 + 7))
# movies, one twin in the mixed library
for n in range(1, 7):
    resume.append(movie(n, pos=10 + n))
resume.insert(12, movie(2, copy=True, pos=12))
resume.insert(22, movie(4, copy=True, pos=14))
# finished ones the server still lists
resume += [episode(20, 1, 9, played=True), episode(21, 2, 1, played=True), movie(8, played=True)]
# filler to 40 started items: further series, one episode each
for n in range(22, 31):
    resume.append(episode(n, 1, 1, pos=9))
assert len(resume) >= 40, len(resume)

nextup = []
nextup.append(episode(1, 1, 5))                   # series 1 also has resume episodes
nextup.append(episode(2, 1, 9))
nextup.append(catalog[resume[0]["Id"]])           # overlaps resume (same id)
nextup.append(catalog[resume[5]["Id"]])           # overlaps resume
nextup.append(episode(3, 1, 3 + 3 % 4, copy=True))  # twin from the second library
nextup.append(episode(3, 1, 3 + 3 % 4))
nextup.append(episode(5, 1, 3 + 5 % 4))
for n in range(15, 20):
    nextup.append(episode(n, 1, 1))
nextup.append(episode(6, 1, 2 + 6 % 4, copy=True))  # overlaps the twin of a resume episode
nextup.append(episode(20, 1, 10))
nextup.append(episode(23, 1, 2))                  # series 23 also in resume
nextup.append(episode(30, 1, 1))
for n in range(25, 29):
    nextup.append(episode(n, 1, 2, played=True))   # server lists played ones
assert len(nextup) >= 20, len(nextup)

latest = []
for n in (30, 29, 28, 30, 27, 1, 1, 3, 2):
    latest.append(episode(n, 3, 40 + len(latest)))
latest.append(episode(3, 3, 60, copy=True))
latest.insert(2, movie(9))
latest.insert(4, movie(1, copy=True))
latest.insert(5, movie(1))
for n in range(4, 20):
    latest.append(episode(n, 3, 70 + n))
latest.append(episode(8, 1, 1, copy=True))

os.makedirs(out, exist_ok=True)


def wrap(items):
    return {"Items": items, "TotalRecordCount": len(items)}


def dump(name, data):
    with open(os.path.join(out, name), "w") as f:
        json.dump(data, f, indent=1, sort_keys=True)
        f.write("\n")


dump("views.json", wrap(views))
dump("resume.json", wrap(resume))
dump("nextup.json", wrap(nextup))
dump("latest.json", wrap(latest))
dump("catalog.json", wrap(sorted(catalog.values(), key=lambda i: i["Id"])))
dump("ancestors.json", ancestors)
print(len(resume), len(nextup), len(latest), len(catalog))
