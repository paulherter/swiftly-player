#!/usr/bin/env python3
"""Writes world.json: one small Jellyfin server (catalog + the lists a server would answer from).

Both routers (Swift `MethodDifferentialTests`, Rust `tests/common/world.rs`) read this file and answer
the same way, so every difference in a result is a difference in the client code. Deterministic.
"""
import json, os

cat = []          # catalog in server order
children = {}     # parent id -> ordered child ids
ancestors = {}    # item id -> [library view]


def add(item, parent=None, lib=None):
    cat.append(item)
    if parent:
        children.setdefault(parent, []).append(item["Id"])
    if lib:
        ancestors[item["Id"]] = [{"Id": lib, "Name": lib, "Type": "CollectionFolder"}]
    return item


def ud(played=False, fav=False, pos=None):
    d = {"Played": played, "IsFavorite": fav}
    if pos:
        d["PlaybackPositionTicks"] = pos
    return d


people = [
    {"Id": "p1", "Name": "Ada Actor", "Type": "Actor", "Role": "Lead"},
    {"Id": "p2", "Name": "Dan Director", "Type": "Director"},
    {"Id": "p3", "Name": "Eva Extra", "Type": "Actor", "Role": "Friend"},
]

views = [
    {"Id": "L-MOV", "Name": "Filme", "Type": "CollectionFolder", "CollectionType": "movies"},
    {"Id": "L-TV", "Name": "Serien", "Type": "CollectionFolder", "CollectionType": "tvshows"},
    {"Id": "L-MIX", "Name": "Kopie", "Type": "CollectionFolder", "CollectionType": "movies"},
    {"Id": "L-BOX", "Name": "Sammlungen", "Type": "CollectionFolder", "CollectionType": "boxsets"},
    {"Id": "L-PL", "Name": "Playlists", "Type": "UserView", "CollectionType": "playlists"},
]

# movies: names chosen for the natural order (digits, accents, other scripts, articles, numbers in names)
movie_names = ["The Matrix", "Ärger im Paradies", "Zorro", "10 Cloverfield Lane", "007 Skyfall", "Éclair",
               "Äpfel", "中文电影", "Яблоко", "Straße", "X-Men 2", "X-Men 10", "X-Men 9", "A Quiet Place",
               "Der Pate", "der kleine Prinz", "Ölprinz", "Ice Age 3", "Ice Age 12", "Alpha", "alpha",
               "Beta", "Über uns", "Mad Max"]
genres = [["Action"], ["Action,Adventure"], ["Drama", "Action"], [], ["Comedy"]]
for n, name in enumerate(movie_names):
    i = f"m{n:02d}"
    add({"Id": i, "Name": name, "SortName": name.lower(), "Type": "Movie", "ParentId": "L-MOV",
         "ProductionYear": 1990 + n, "RunTimeTicks": 60000000000 + n,
         "DateCreated": f"2024-{1 + n % 12:02d}-{1 + n:02d}T10:00:00.0000000Z",
         "ProviderIds": {"Tmdb": str(1000 + n), "Imdb": f"tt{n:07d}"}, "Genres": genres[n % 5],
         "People": [people[n % 3], people[(n + 1) % 3]] if n % 2 == 0 else [people[0]],
         "UserData": ud(played=n % 5 == 0, fav=n % 4 == 1, pos=3000000000 if n % 7 == 3 else None),
         "MediaType": "Video"}, "L-MOV", "L-MOV")
# the same movies again in a second library (hardlinks)
for n in (0, 1, 2, 3, 12, 13):
    base = [c for c in cat if c["Id"] == f"m{n:02d}"][0]
    copy = dict(base, Id=f"m{n:02d}b", ParentId="L-MIX", UserData=ud())
    add(copy, "L-MIX", "L-MIX")
# the broken entries a server (or a proxy) can deliver
add({"Id": "w01", "Name": "Float year", "SortName": "float year", "Type": "Movie", "ProductionYear": 2019.0,
     "ProviderIds": {"Tmdb": "5001"}}, "L-MOV", "L-MOV")
add({"Id": "w02", "Name": "Exponent runtime", "SortName": "exponent runtime", "Type": "Movie",
     "RunTimeTicks": 7.2e10, "ProviderIds": {"Tmdb": "5002"}}, "L-MOV", "L-MOV")
add({"Id": "w03", "Name": "Half year", "Type": "Movie", "ProductionYear": 2019.5}, "L-MOV", "L-MOV")
add({"Id": "w04", "Type": "Movie"}, "L-MOV", "L-MOV")
add({"Id": "w05", "Name": "Percent too high", "SortName": "percent too high", "Type": "Movie",
     "UserData": {"Played": False, "PlayedPercentage": 250.0, "PlaybackPositionTicks": 5}}, "L-MOV", "L-MOV")
add({"Id": "w06", "Name": "Numbers as strings", "SortName": "numbers as strings", "Type": "Movie",
     "ProductionYear": "2020", "CommunityRating": "7.5"}, "L-MOV", "L-MOV")
add({"Id": "w07", "Name": "Null fields", "SortName": None, "Type": "Movie", "Genres": None, "People": None,
     "ProviderIds": None, "UserData": None, "ImageTags": None}, "L-MOV", "L-MOV")
add({"Id": "w08", "Name": "Rating as int", "SortName": "rating as int", "Type": "Movie", "CommunityRating": 8,
     "CriticRating": 70, "ChildCount": 3.0}, "L-MOV", "L-MOV")

# series: each with seasons 0 (specials), 1, 2 and explicit server order of episodes
series_names = ["Breaking Point", "Die Serie", "Åre Krimi", "Show 2", "Show 10", "the wire tap", "Zeit", "Lost Time"]
world_seasons, world_eps, nextup_series = {}, {}, {}
for n, name in enumerate(series_names):
    s = f"s{n}"
    add({"Id": s, "Name": name, "SortName": name.lower(), "Type": "Series", "ParentId": "L-TV",
         "ProductionYear": 2000 + n, "DateCreated": f"2023-0{1 + n}-15T08:00:00.0000000Z",
         "ProviderIds": {"Tmdb": str(2000 + n), "Tvdb": str(3000 + n)},
         "Genres": genres[n % 5], "People": [people[n % 3]], "UserData": ud(fav=n % 3 == 0),
         "ChildCount": 3}, "L-TV", "L-TV")
    world_seasons[s], world_eps[s] = [], []
    for sn in (0, 1, 2):
        sid = f"{s}-{sn}"
        add({"Id": sid, "Name": "Specials" if sn == 0 else f"Staffel {sn}", "Type": "Season", "SeriesId": s,
             "SeriesName": name, "IndexNumber": sn, "ParentId": s, "UserData": ud()}, s)
        world_seasons[s].append(sid)
        for en in range(1, 4 if sn != 2 else 12):
            eid = f"{s}-{sn}-{en}"
            ep = {"Id": eid, "Name": f"Folge {en}", "SortName": f"folge {en}", "Type": "Episode", "SeriesId": s,
                  "SeriesName": name, "SeasonId": sid, "ParentIndexNumber": sn, "IndexNumber": en,
                  "ProviderIds": {"Tvdb": str(9000 + n * 100 + sn * 20 + en)},
                  "RunTimeTicks": 25000000000, "UserData": ud(played=sn == 1 or en < 3), "ParentId": sid,
                  "DateCreated": f"2024-0{1 + n}-{10 + en}T08:00:00.0000000Z",
                  "MediaSources": [{"Id": eid + "-src", "Name": "v1"}]}
            if n == 1 and sn == 2 and en == 11:
                ep["IndexNumber"] = 20  # S2E20 after S2E10 in the order the server gives
            add(ep, sid)
            world_eps[s].append(eid)
    nextup_series[s] = [f"{s}-2-3"] if n % 2 == 0 else []
# a copy of two series and four of their episodes in the second library (same provider ids)
for n in (0, 1):
    s = f"s{n}"
    base = [c for c in cat if c["Id"] == s][0]
    add(dict(base, Id=s + "b", ParentId="L-MIX", UserData=ud()), "L-MIX", "L-MIX")
    for e in [c for c in cat if c.get("SeriesId") == s and c["Type"] == "Episode"][:4]:
        add(dict(e, Id=e["Id"] + "b", SeriesId=s + "b", ParentId=s + "b"), s + "b", "L-MIX")
# two episodes without provider ids whose series are the same work in two libraries
add({"Id": "s5b", "Name": "the wire tap", "SortName": "the wire tap", "Type": "Series", "ParentId": "L-MIX",
     "ProviderIds": {"Tmdb": "2005", "Tvdb": "3005"}, "UserData": ud()}, "L-MIX", "L-MIX")
add({"Id": "x1", "Name": "Pilot", "Type": "Episode", "SeriesId": "s5", "SeriesName": "the wire tap",
     "ParentIndexNumber": 1, "IndexNumber": 1, "ProviderIds": {}, "UserData": ud()}, "s5-1", "L-TV")
add({"Id": "x2", "Name": "Pilot", "Type": "Episode", "SeriesId": "s5b", "SeriesName": "the wire tap",
     "ParentIndexNumber": 1, "IndexNumber": 1, "ProviderIds": {}, "UserData": ud()}, "s5b", "L-MIX")
ancestors["x1"] = [{"Id": "L-TV"}]
ancestors["x2"] = [{"Id": "L-MIX"}]

# collections and playlists
for b, members in (("bs1", ["m00", "m01", "s0", "m05b"]), ("bs2", ["m02"])):
    add({"Id": b, "Name": "Sammlung " + b, "SortName": "sammlung " + b, "Type": "BoxSet", "ParentId": "L-BOX",
         "UserData": ud()}, "L-BOX", "L-BOX")
    children[b] = members
add({"Id": "bs3", "Name": "Leere Sammlung", "Type": "BoxSet", "ParentId": "L-BOX", "UserData": ud()},
    "L-BOX", "L-BOX")
playlists = {"pl1": ["m04", "s1", "m00", "a1", "m09"], "pl2": ["a1", "a2"], "pl3": []}
add({"Id": "a1", "Name": "Song", "Type": "Audio", "MediaType": "Audio"})
add({"Id": "a2", "Name": "Song 2", "Type": "Audio", "MediaType": "Audio"})
for pl in playlists:
    add({"Id": pl, "Name": "Liste " + pl, "SortName": "liste " + pl, "Type": "Playlist",
         "MediaType": "Audio" if pl == "pl2" else "Video", "ParentId": "L-PL", "UserData": ud()}, "L-PL", "L-PL")

world = {
    "views": views, "catalog": cat, "children": children, "ancestors": ancestors,
    "seasons": world_seasons, "episodes": world_eps, "nextup_series": nextup_series,
    "playlists": playlists,
    "similar": {"m00": ["m00", "m00b", "m01", "m01b", "m02", "m04", "m05"], "m05": ["m00", "m01"],
                "s0": ["s0", "s0b", "s1"]},
    "extras": {"m00": ["m01"], "m02": []},
    "trailers": {"m00": ["m03"]},
    "genres": [{"Id": "g1", "Name": "Action"}, {"Id": "g2", "Name": "Action,Adventure"},
               {"Id": "g3", "Name": "Drama"}],
    "resume": ["m03", "s0-2-3", "s0-2-3b", "m03b", "s1-2-3"],
    "nextup": ["s0-2-3", "s2-2-3", "x1", "x2"],
}
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "world.json")
with open(out, "w") as f:
    json.dump(world, f, indent=1, ensure_ascii=False, sort_keys=True)
print(len(cat), "items")
