#!/usr/bin/env python3
"""Schreibt die Entwurfstafeln (.dc.html) und canvas.json.

Eine Tafel je Jellyfin-Seite, alle im Aussehen der macOS-Fassung von Swiftly.
Nichts hier ist geschätzt: die Werte stehen in `bausteine.py`, und dort steht,
aus welcher Datei jede stammt.
"""
import json
import pathlib

from bausteine import *  # noqa: F403

HIER = pathlib.Path(__file__).parent


def schreiben(name, inhalt_html, breite=RAHMEN_B, hoehe=RAHMEN_H, extra=""):
    (HIER / name).write_text(huelle(inhalt_html, breite, hoehe, extra), encoding="utf-8")
    return name


# ===========================================================================
# Startseite — die Einstiegstafel
# ===========================================================================

def startseite():
    weiter = kachel("Beauty &amp; The Nerd", "S7:E3 · Folge 3", VERLAEUFE[2],
                    QUER_B, QUER_H, fortschritt=0.42, zeichen_name="tv", schwebt=True)

    naechste = "".join(
        kachel(t, z, VERLAEUFE[i % len(VERLAEUFE)], marke=m, zeichen_name="tv")
        for i, (t, z, m) in enumerate([
            ("The Mentalist", "S5 · E2", None),
            ("Die Höhle der Löwen", "S20 · E2", "12 offen"),
            ("Game of Thrones", "S1 · E5", None),
            ("Furious", "S1 · E4", None),
            ("Adults", "S2 · E1", "3 offen"),
            ("FROM", "S4 · E1", None),
        ]))

    zuletzt = "".join(
        kachel(t, z, VERLAEUFE[(i + 3) % len(VERLAEUFE)], marke=m)
        for i, (t, z, m) in enumerate([
            ("Exit 8", "2025", None),
            ("Grand Theft Auto VI", "2026", None),
            ("Obsession", "2026", None),
            ("Old", "2021", zeichen("haken", 12, SCHRIFT, 2.6)),
            ("Zurück in die Zukunft", "1985", None),
            ("Young Sheldon", "2017", "7 Staffeln"),
        ]))

    koerper = f'''
{kopfleiste()}
{inhalt(f"""
  <div style="display:flex;flex-direction:column;gap:{REIHEN_ABSTAND}px">
    <section>
      {reihentitel("Weiterschauen")}
      <div style="display:flex;gap:{KACHEL_ABSTAND}px">{weiter}</div>
    </section>
    <section>
      {reihentitel("Nächste Folge", mit_pfeilen=True)}
      <div style="display:flex;gap:{KACHEL_ABSTAND}px">{naechste}</div>
    </section>
    <section>
      {reihentitel("Zuletzt hinzugefügt")}
      <div style="display:flex;gap:{KACHEL_ABSTAND}px">{zuletzt}</div>
    </section>
  </div>
""", oben=30)}'''
    return schreiben("Main.dc.html", koerper, hoehe=1000)


# ===========================================================================
# Anmeldung
# ===========================================================================

def anmeldung():
    def feld(beschriftung, platzhalter):
        return f'''<div style="display:flex;flex-direction:column;gap:8px">
  <span style="font-size:11px;font-weight:600;letter-spacing:1.2px;text-transform:uppercase;
    color:{SEHR_LEISE}">{beschriftung}</span>
  {eingabefeld(platzhalter, "person" if beschriftung == "Benutzer" else "schloss", 420)}
</div>'''

    koerper = f'''
<div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center">
  <div style="width:420px;display:flex;flex-direction:column;gap:0">
    <div style="display:flex;align-items:center;gap:11px;margin-bottom:30px">
      <div style="width:34px;height:34px;border-radius:8px;background:{ERHOEHT};
        border:1px solid {RAND};flex:none"></div>
      <span style="font-size:28px;font-weight:700;letter-spacing:-.6px">Pauls Kiste</span>
    </div>
    <div style="display:flex;flex-direction:column;gap:18px">
      {feld("Benutzer", "paul")}
      {feld("Passwort", "••••••••")}
    </div>
    <div style="display:flex;align-items:center;gap:12px;margin:22px 0 26px">
      <span style="font-size:15px">Angemeldet bleiben</span>
      <div style="flex-grow:1"></div>
      {schalter(True)}
    </div>
    <div style="display:flex;flex-direction:column;gap:10px">
      {hauptknopf("Anmelden", "winkel_r", breite=420)}
      <div style="display:flex;gap:10px">
        <div style="flex-grow:1;height:44px;border-radius:{ECKE}px;background:rgba(255,255,255,.14);
          display:flex;align-items:center;justify-content:center;gap:8px;font-size:15px;
          font-weight:500">{zeichen("sprechblase", 17, SCHRIFT, 1.6)}Quick Connect</div>
        <div style="flex-grow:1;height:44px;border-radius:{ECKE}px;background:transparent;
          border:1px solid {RAND};display:flex;align-items:center;justify-content:center;
          font-size:15px;color:{LEISE}">Passwort vergessen</div>
      </div>
    </div>
  </div>
</div>'''
    return schreiben("Anmeldung.dc.html", koerper)


# ===========================================================================
# Bibliothek
# ===========================================================================

def bibliothek():
    marken = [None, None, zeichen("haken", 12, SCHRIFT, 2.6), None, None, "7 Staffeln",
              None, None, None, zeichen("haken", 12, SCHRIFT, 2.6), None, None]
    titel = ["Exit 8", "Grand Theft Auto VI", "Obsession", "Old", "Zurück in die Zukunft",
             "Young Sheldon", "Attack on Titan", "Outer Banks", "Chicago P.D.",
             "Malcolm mittendrin", "Legend of the Seeker", "Orange Is the New Black"]
    jahre = ["2025", "2026", "2026", "2021", "1985", "2017", "2013", "2020", "2014",
             "2000", "2008", "2013"]
    raster = "".join(
        kachel(t, j, VERLAEUFE[i % len(VERLAEUFE)], marke=m, fortschritt=(0.28 if i == 1 else None))
        for i, (t, j, m) in enumerate(zip(titel, jahre, marken)))

    koerper = f'''
{kopfleiste("Filme")}
{inhalt(f"""
  <div style="display:flex;align-items:flex-start;justify-content:space-between">
    <div style="display:flex;flex-direction:column;gap:3px">
      <span style="font-size:28px;font-weight:700;letter-spacing:-.6px">Filme</span>
      <span style="font-size:13px;color:{SEHR_LEISE}">Pauls Kiste</span>
    </div>
    <span style="font-size:13px;font-weight:500;color:{SEHR_LEISE};
      font-variant-numeric:tabular-nums">128</span>
  </div>
  <div style="display:flex;align-items:center;margin:20px 0 24px">
    <div style="display:flex;gap:8px">
      {chip("Alle", True)}{chip("Angefangen")}{chip("Merkliste")}{chip("Ungesehen")}
    </div>
    <div style="flex-grow:1"></div>
    <div style="display:flex;gap:8px">
      {chip("A–Z", True, "trichter")}{chip("Zuletzt")}{chip("Bewertung")}{chip("Jahr")}
    </div>
  </div>
  <div style="display:flex;flex-wrap:wrap;gap:20px 12px">{raster}</div>
""")}'''
    return schreiben("Bibliothek.dc.html", koerper)


# ===========================================================================
# Detailseiten
# ===========================================================================

KULISSE_MASKE = """
    -webkit-mask-image:
      linear-gradient(to right, rgba(0,0,0,0) 0%, rgba(0,0,0,.05) 15%, rgba(0,0,0,.22) 29%,
        rgba(0,0,0,.50) 45%, rgba(0,0,0,.75) 57%, rgba(0,0,0,.90) 70%, rgba(0,0,0,.98) 85%,
        rgba(0,0,0,1) 100%),
      linear-gradient(to bottom, rgba(0,0,0,1) 0%, rgba(0,0,0,1) 50%, rgba(0,0,0,.88) 60%,
        rgba(0,0,0,.62) 70%, rgba(0,0,0,.34) 80%, rgba(0,0,0,.14) 89%, rgba(0,0,0,.04) 95%,
        rgba(0,0,0,0) 100%);
    -webkit-mask-composite: source-in;
    mask-composite: intersect;
"""


def kulisse(hoehe=616):
    """Rechts, nicht über die volle Breite, und mit einer **Maske** statt eines
    Anstrichs ausgeblendet. Die Kurven stammen unverändert aus `Kulissenblende`."""
    return f'''<div style="position:absolute;top:0;right:0;width:62%;height:{hoehe}px;
  background:
    radial-gradient(120% 90% at 72% 22%, rgba(214,196,168,.55), rgba(0,0,0,0) 62%),
    radial-gradient(80% 70% at 38% 66%, rgba(74,96,120,.55), rgba(0,0,0,0) 70%),
    linear-gradient(150deg, #3A4553, #1A2028 70%);
  pointer-events:none;{KULISSE_MASKE}"></div>'''


def detailkopf(titel_sichtbar=False):
    titel = (f'<span style="font-size:17px;font-weight:600">{titel_sichtbar}</span>'
             if titel_sichtbar else "")
    return f'''<div style="position:absolute;left:0;right:0;top:0;height:{INHALT_OBEN + 34}px;
  display:flex;align-items:flex-end;gap:4px;padding:0 {RAND_ABSTAND}px 10px
  {RAND_ABSTAND - 8}px;z-index:3">
  <div style="width:40px;height:40px;display:flex;align-items:center;justify-content:center">
    {zeichen("winkel_l", 20, SCHRIFT, 2.2)}</div>
  {titel}
</div>'''


def heldkopf(titel, angaben, beschreibung, direct_play=True, knoepfe=None):
    """Der Kopf der Detailseite. **Kein Zurueckpfeil mehr** — Jellyfin setzt
    ihn selbst in die Kopfleiste, und zwei waeren einer zu viel."""
    beleg_farbe = AKZENT if direct_play else WARNUNG
    beleg_text = "Direct Play" if direct_play else "Transkodiert"
    beleg_zeichen = zeichen("haken", 12, beleg_farbe, 2.6) if direct_play else ""
    knoepfe = knoepfe or (hauptknopf("Abspielen") + nebenknopf("merken") + nebenknopf("punkte"))
    return f'''<div style="position:relative;height:380px">
  {kulisse()}
  <div style="position:absolute;left:{RAND_ABSTAND}px;top:150px;width:640px;height:230px">
    <div style="position:absolute;top:0;height:42px;width:640px;display:flex;align-items:center">
      <span style="font-size:34px;font-weight:700;letter-spacing:-.8px">{titel}</span>
    </div>
    <div style="position:absolute;top:54px;height:20px;width:640px;display:flex;
      align-items:center;gap:14px;font-size:14px;color:{LEISE}">
      <span>{angaben}</span>
      <span style="display:flex;align-items:center;gap:5px">
        {zeichen("stern", 12, LEISE, 0, True)}
        <span style="font-size:13px;font-weight:500">8.4</span></span>
      {plakette("FSK-16")}
      <span style="display:flex;align-items:center;gap:6px;color:{beleg_farbe};
        font-size:13px;font-weight:500">{beleg_zeichen}{beleg_text}</span>
    </div>
    <div style="position:absolute;top:92px;height:66px;width:640px;overflow:hidden;
      font-size:15px;line-height:22px;color:rgba(255,255,255,.62)">{beschreibung}</div>
    <div style="position:absolute;top:182px;height:48px;display:flex;gap:12px">{knoepfe}</div>
  </div>
</div>'''


def detail_film():
    besetzung = "".join(
        f'''<div style="width:96px;display:flex;flex-direction:column;gap:8px;align-items:center">
  <div style="width:96px;height:96px;border-radius:50%;background:{VERLAEUFE[i % len(VERLAEUFE)]};
    display:flex;align-items:center;justify-content:center">
    <div style="opacity:.20">{zeichen("person", 30, SCHRIFT, 1.4)}</div></div>
  <div style="display:flex;flex-direction:column;gap:1px;align-items:center;text-align:center">
    <span style="font-size:14px;font-weight:500">{n}</span>
    <span style="font-size:12px;color:{LEISE}">{r}</span></div>
</div>'''
        for i, (n, r) in enumerate([
            ("Simon Baker", "Patrick Jane"), ("Robin Tunney", "Teresa Lisbon"),
            ("Tim Kang", "Kimball Cho"), ("Owain Yeoman", "Wayne Rigsby"),
            ("Amanda Righetti", "Grace Van Pelt"), ("Rockmond Dunbar", "Dennis Abbott"),
        ]))

    aehnlich = "".join(
        kachel(t, j, VERLAEUFE[(i + 5) % len(VERLAEUFE)])
        for i, (t, j) in enumerate([("Old", "2021"), ("Obsession", "2026"),
                                    ("Exit 8", "2025"), ("Furious", "2026"),
                                    ("Adults", "2025"), ("FROM", "2022")]))

    koerper = f'''
{kopfleiste("Filme")}
<main style="position:absolute;left:0;right:0;top:0;bottom:0;overflow:hidden">
  {heldkopf("The Mentalist", "2008 · Krimi, Drama · 41 Min.",
            "Der Job des charismatischen Ex-TV-Show-Stars Patrick Jane innerhalb des "
            "California Bureau of Investigation ist es, die Ermittlungen einer Spezialeinheit "
            "zu unterstützen. Jane, der seine Karriere als „Mentalist“ mit vermeintlich "
            "übersinnlichen Fähigkeiten nach einer familiären Tragödie aufgab, arbeitet …")}
  <div style="padding:26px {RAND_ABSTAND}px 0;display:flex;flex-direction:column;gap:26px">
    <section>
      {reihentitel("Besetzung")}
      <div style="display:flex;gap:{KACHEL_ABSTAND}px">{besetzung}</div>
    </section>
    <section>
      {reihentitel("Ähnliches")}
      <div style="display:flex;gap:{KACHEL_ABSTAND}px">{aehnlich}</div>
    </section>
  </div>
</main>'''
    return schreiben("DetailFilm.dc.html", koerper, hoehe=1000)


def detail_serie():
    def reiter(text, aktiv):
        rand = AKZENT if aktiv else "transparent"
        farbe = SCHRIFT if aktiv else LEISE
        gew = "600" if aktiv else "500"
        return (f'<div style="height:40px;line-height:38px;border-bottom:2px solid {rand};'
                f'color:{farbe};font-size:15px;font-weight:{gew};margin-right:32px">{text}</div>')

    def folgenzeile(nr, name, text, dauer, gesehen=False):
        haken = ""
        if gesehen:
            haken = (f'<div style="position:absolute;top:6px;right:6px;width:20px;height:20px;'
                     f'border-radius:50%;background:rgba(11,11,13,.72);display:flex;'
                     f'align-items:center;justify-content:center">'
                     f'{zeichen("haken", 11, SCHRIFT, 3)}</div>')
        deck = "opacity:.45" if gesehen else ""
        titelfarbe = LEISE if gesehen else SCHRIFT
        return f'''<div style="display:flex;align-items:flex-start;gap:18px;padding:12px 0;
  border-bottom:1px solid {LINIE}">
  <div style="position:relative;flex:none;{deck}">
    {bildflaeche(FOLGE_B, FOLGE_H, VERLAEUFE[nr % len(VERLAEUFE)], zeichen_name="tv")}
    {haken}
  </div>
  <div style="display:flex;flex-direction:column;gap:5px;flex-grow:1;min-width:0;padding-top:2px">
    <div style="display:flex;align-items:baseline;gap:8px">
      <span style="font-size:14px;font-weight:500;color:{titelfarbe}">{nr}. {name}</span>
      <div style="flex-grow:1"></div>
      <span style="font-size:12px;color:{SEHR_LEISE}">{dauer}</span>
    </div>
    <span style="font-size:12px;line-height:17px;color:{LEISE};display:-webkit-box;
      -webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden">{text}</span>
  </div>
  <div style="width:36px;height:36px;display:flex;align-items:center;justify-content:center;
    flex:none">{zeichen("pfeil_ab", 18, SEHR_LEISE, 1.7)}</div>
</div>'''

    folgen = (
        folgenzeile(1, "Rote Glasperlen",
                    "Mal wieder das FBI: Als Patrick Jane kurz davor ist, den Serienmörder Red "
                    "John endlich zu stellen, werden seine Pläne zunichte gemacht.", "39 Min.",
                    gesehen=True) +
        folgenzeile(2, "Belladonna",
                    "Der Diamantschleifer Victor Mendelssohn wird ermordet in seinem Haus "
                    "aufgefunden. Die Nachbarin Betty erklärt, sie habe kurz zuvor einen Streit "
                    "gehört.", "41 Min.") +
        folgenzeile(3, "Ticket nach Brasilien",
                    "Während eines Raubüberfalls wird ein Bankangestellter getötet. Lisbon und "
                    "ihr Team werden auf den Fall angesetzt.", "41 Min.")
    )

    koerper = f'''
{kopfleiste("Serien")}
<main style="position:absolute;left:0;right:0;top:0;bottom:0;overflow:hidden">
  {heldkopf("The Mentalist", "2008 · Krimi, Drama · 7 Staffeln",
            "Der Job des charismatischen Ex-TV-Show-Stars Patrick Jane innerhalb des "
            "California Bureau of Investigation ist es, die Ermittlungen einer Spezialeinheit "
            "zu unterstützen. Jane, der seine Karriere als „Mentalist“ mit vermeintlich "
            "übersinnlichen Fähigkeiten aufgab, arbeitet heute als Berater …",
            knoepfe=hauptknopf("Fortsetzen") + nebenknopf("zurueck") + nebenknopf("merken")
                    + nebenknopf("punkte"))}
  <div style="padding:26px {RAND_ABSTAND}px 0">
    <div style="display:flex;border-bottom:1px solid {LINIE};margin-bottom:22px">
      {reiter("Folgen", True)}{reiter("Besetzung", False)}{reiter("Ähnliches", False)}
    </div>
    <div style="display:flex;align-items:center;gap:7px;margin-bottom:6px">
      <span style="font-size:20px;font-weight:600;letter-spacing:-.2px">Staffel 5</span>
      {zeichen("winkel_ab", 17, SCHRIFT, 2.2)}
      <div style="flex-grow:1"></div>
      <span style="font-size:13px;font-weight:500;color:{SEHR_LEISE};
        font-variant-numeric:tabular-nums">22</span>
    </div>
    {folgen}
  </div>
</main>'''
    return schreiben("DetailSerie.dc.html", koerper, hoehe=1080)


# ===========================================================================
# Suche
# ===========================================================================

def suche():
    treffer = "".join(
        kachel(t, j, VERLAEUFE[i % len(VERLAEUFE)])
        for i, (t, j) in enumerate([("The Mentalist", "Serie · 2008"),
                                    ("Old", "Film · 2021"),
                                    ("Obsession", "Film · 2026"),
                                    ("Malcolm mittendrin", "Serie · 2000")]))
    anfragbar = "".join(
        kachel(t, j, VERLAEUFE[(i + 4) % len(VERLAEUFE)])
        for i, (t, j) in enumerate([("Dune: Part Three", "Film · 2026"),
                                    ("Severance", "Serie · 2022"),
                                    ("Andor", "Serie · 2022")]))

    koerper = f'''
{kopfleiste()}
{inhalt(f"""
  <span style="font-size:28px;font-weight:700;letter-spacing:-.6px">Suche</span>
  <div style="margin-top:14px">{eingabefeld("Titel, Serie, Person", "lupe", 420, fokus=True)}</div>
  <div style="margin-top:30px">
    {reihentitel("Gefunden")}
    <div style="display:flex;gap:{KACHEL_ABSTAND}px">{treffer}</div>
  </div>
  <div style="margin-top:40px">
    <div style="display:flex;align-items:baseline;margin-bottom:18px">
      <span style="font-size:13px;font-weight:600;letter-spacing:.5px;text-transform:uppercase;
        color:{SEHR_LEISE}">Kann angefragt werden</span>
      <div style="flex-grow:1"></div>
      <span style="font-size:13px;font-weight:500;color:{SEHR_LEISE};
        font-variant-numeric:tabular-nums">3</span>
    </div>
    <div style="display:flex;gap:{KACHEL_ABSTAND}px">{anfragbar}</div>
  </div>
""")}'''
    return schreiben("Suche.dc.html", koerper)


# ===========================================================================
# Einstellungen
# ===========================================================================

def einstellungen():
    pfeil = f'<div style="display:flex;align-items:center;gap:8px">{zeichen("winkel_r", 15, SEHR_LEISE, 2)}</div>'

    def wert(text):
        return (f'<div style="display:flex;align-items:center;gap:8px">'
                f'<span style="font-size:15px;color:{LEISE}">{text}</span>'
                f'{zeichen("winkel_r", 15, SEHR_LEISE, 2)}</div>')

    qualitaet = zeilengruppe([
        einstellungszeile("spielen", "Immer Direct Play", "Nie umwandeln lassen — der Grund für diese App",
                          schalter(True)),
        einstellungszeile("balken", "Höchste Bitrate", None, wert("Unbegrenzt")),
    ])
    sprache = zeilengruppe([
        einstellungszeile("ton", "Ton", None, pfeil),
        einstellungszeile("untertitel", "Untertitel", None, pfeil),
        einstellungszeile("untertitel", "Untertitel automatisch",
                          "Nur wenn der Ton nicht in der gewählten Sprache läuft", schalter(False)),
    ])
    verhalten = zeilengruppe([
        einstellungszeile("vor", "Nächste Folge automatisch", None, schalter(True)),
        einstellungszeile("balken", "Technikschild im Player", None, schalter(False)),
        einstellungszeile("takt", "Zurückspulen", None, wert("10 s")),
        einstellungszeile("takt", "Vorspulen", None, wert("30 s")),
    ])

    koerper = f'''
{kopfleiste()}
{inhalt(f"""
  <div style="max-width:700px">
    <span style="font-size:28px;font-weight:700;letter-spacing:-.6px">Wiedergabe</span>
    <div style="font-size:15px;color:{LEISE};margin-top:6px">Gilt für alles, was neu startet.
      Im Player lässt sich jederzeit abweichen.</div>
    {gruppentitel("Qualität")}{qualitaet}
    <div style="font-size:12px;color:{SEHR_LEISE};margin-top:10px;line-height:17px">
      Die Bitrate greift nur, wenn Direct Play nicht erzwungen wird — sonst bliebe sie
      wirkungslos und stünde trotzdem da.</div>
    {gruppentitel("Sprache")}{sprache}
    {gruppentitel("Verhalten")}{verhalten}
  </div>
""")}'''
    return schreiben("Einstellungen.dc.html", koerper, hoehe=1000)


# ===========================================================================
# Profil
# ===========================================================================

def profil():
    pfeil = zeichen("winkel_r", 15, SEHR_LEISE, 2)
    gruppe1 = zeilengruppe([
        einstellungszeile("sprechblase", "Quick Connect", "Code vom Fernseher eingeben",
                          pfeil, akzent=True),
    ])
    gruppe2 = zeilengruppe([
        einstellungszeile("spielen", "Wiedergabe", "Sprache, Untertitel, Tempo", pfeil),
        einstellungszeile("zahnrad", "Einstellungen", None, pfeil),
    ])
    gruppe3 = zeilengruppe([
        einstellungszeile("person", "Weiteres Konto hinzufügen", "Auf demselben Server", pfeil),
        einstellungszeile("abmelden", "Abmelden", None, ""),
    ])

    koerper = f'''
{kopfleiste()}
{inhalt(f"""
  <div style="max-width:700px;margin:0 auto;display:flex;flex-direction:column;align-items:center">
    <div style="display:flex;align-items:center;position:relative;height:108px">
      <div style="width:108px;height:108px;border-radius:50%;
        background:linear-gradient(135deg,#3B4A5A,#26313D);border:2px solid {AKZENT};
        display:flex;align-items:center;justify-content:center;position:relative;z-index:2">
        <div style="opacity:.25">{zeichen("person", 44, SCHRIFT, 1.3)}</div>
      </div>
      <div style="width:90px;height:90px;border-radius:50%;background:#22282F;
        margin-left:-18px;opacity:.55"></div>
    </div>
    <div style="display:flex;flex-direction:column;align-items:center;gap:4px;margin-top:16px">
      <span style="font-size:28px;font-weight:700;letter-spacing:-.6px">paul</span>
      <span style="font-size:13px;color:{SEHR_LEISE}">Pauls Kiste · Jellyfin 10.11.11</span>
    </div>
    <div style="width:100%;margin-top:34px;display:flex;flex-direction:column;gap:22px">
      {gruppe1}{gruppe2}{gruppe3}
    </div>
    <span style="font-size:12px;color:{SEHR_LEISE};margin-top:24px">Swiftly-Thema 1.0</span>
  </div>
""")}'''
    return schreiben("Profil.dc.html", koerper)


# ===========================================================================
# Player
# ===========================================================================

def player():
    def osd_zeichen(name, groesse=22):
        return (f'<div style="width:44px;height:44px;display:flex;align-items:center;'
                f'justify-content:center">{zeichen(name, groesse, SCHRIFT, 1.7)}</div>')

    koerper = f'''
<div style="position:absolute;inset:0;background:
  radial-gradient(90% 80% at 60% 35%, rgba(150,132,110,.30), rgba(0,0,0,0) 65%),
  linear-gradient(160deg,#242B33,#0C0E11)"></div>

<div style="position:absolute;left:{RAND_ABSTAND}px;top:{RAND_ABSTAND}px;
  padding:12px 14px;border-radius:{ECKE_FELD}px;background:rgba(11,11,13,.72);
  border:1px solid {RAND};display:flex;flex-direction:column;gap:4px;font-size:12px">
  <div style="display:flex;align-items:center;gap:6px;color:{AKZENT};font-weight:600">
    {zeichen("haken", 12, AKZENT, 2.6)}Direct Play</div>
  <span style="color:{LEISE}">1080p · H.264 · SDR</span>
  <span style="color:{LEISE}">German · AAC · Stereo</span>
  <span style="color:{SEHR_LEISE}">Matroska · 4,2 GB</span>
</div>

<div style="position:absolute;left:0;right:0;bottom:0;height:210px;
  background:linear-gradient(0deg, rgba(11,11,13,.88), rgba(11,11,13,0));
  padding:0 {RAND_ABSTAND}px 26px;display:flex;flex-direction:column;justify-content:flex-end">
  <div style="display:flex;flex-direction:column;gap:2px;margin-bottom:16px">
    <span style="font-size:17px;font-weight:600">Belladonna</span>
    <span style="font-size:13px;color:{LEISE}">The Mentalist · S5 E2</span>
  </div>
  <div style="display:flex;align-items:center;gap:12px;margin-bottom:6px">
    <span style="font-size:13px;color:{LEISE};font-variant-numeric:tabular-nums;
      width:44px">18:42</span>
    <div style="flex-grow:1;height:4px;border-radius:999px;background:rgba(255,255,255,.16);
      position:relative">
      <div style="width:44%;height:100%;border-radius:999px;background:{AKZENT}"></div>
      <div style="position:absolute;left:44%;top:-4px;width:12px;height:12px;border-radius:50%;
        background:{SCHRIFT};margin-left:-6px"></div>
    </div>
    <span style="font-size:13px;color:{LEISE};font-variant-numeric:tabular-nums;
      width:44px;text-align:right">41:12</span>
  </div>
  <div style="display:flex;align-items:center;gap:2px">
    {osd_zeichen("spielen", 24)}{osd_zeichen("zurueck")}{osd_zeichen("vor")}
    <div style="width:14px"></div>
    {osd_zeichen("ton")}
    <div style="flex-grow:1"></div>
    {osd_zeichen("untertitel")}{osd_zeichen("bild_im_bild")}{osd_zeichen("vollbild")}
  </div>
</div>'''
    return schreiben("Player.dc.html", koerper)


# ===========================================================================
# Dashboard
# ===========================================================================

def dashboard():
    def geraet(name, was, nutzer, i):
        return f'''<div style="display:flex;align-items:center;gap:14px;padding:10px 12px">
  <div style="flex:none">{bildflaeche(96, 54, VERLAEUFE[i % len(VERLAEUFE)], 0.44, zeichen_name="tv")}</div>
  <div style="display:flex;flex-direction:column;gap:2px;flex-grow:1;min-width:0">
    <span style="font-size:15px;font-weight:500">{was}</span>
    <span style="font-size:12px;color:{LEISE}">{name} · {nutzer}</span>
  </div>
  <span style="display:flex;align-items:center;gap:6px;color:{AKZENT};font-size:13px;
    font-weight:500">{zeichen("haken", 12, AKZENT, 2.6)}Direct Play</span>
</div>'''

    werte = zeilengruppe([
        einstellungszeile("monitor", "Serverfassung", None,
                          f'<span style="font-size:15px;color:{LEISE}">10.11.11</span>'),
        einstellungszeile("takt", "Läuft seit", None,
                          f'<span style="font-size:15px;color:{LEISE}">14 Tage</span>'),
        einstellungszeile("balken", "Umwandlungen heute", None,
                          f'<span style="font-size:15px;color:{AKZENT}">0</span>'),
    ])

    koerper = f'''
{kopfleiste()}
{inhalt(f"""
  <div style="max-width:820px">
    <span style="font-size:28px;font-weight:700;letter-spacing:-.6px">Übersicht</span>
    {gruppentitel("Server")}
    {werte}
    {gruppentitel("Läuft gerade")}
    {zeilengruppe([geraet("Apple TV", "Belladonna", "paul", 0),
                   geraet("iPhone", "Exit 8", "mika", 3)])}
    {gruppentitel("Bibliotheken")}
    {zeilengruppe([
      einstellungszeile("film", "Filme", "128 Titel", f'<span style="font-size:13px;color:{SEHR_LEISE}">Zuletzt geprüft vor 2 Std.</span>'),
      einstellungszeile("tv", "Serien", "41 Serien · 1 204 Folgen", f'<span style="font-size:13px;color:{SEHR_LEISE}">Zuletzt geprüft vor 2 Std.</span>'),
    ])}
  </div>
""")}'''
    return schreiben("Dashboard.dc.html", koerper)


# ===========================================================================
# Bausteine — das Register
# ===========================================================================

def bausteine_tafel():
    def feld_titel(t):
        return (f'<div style="font-size:11px;font-weight:600;letter-spacing:1.2px;'
                f'text-transform:uppercase;color:{SEHR_LEISE};margin-bottom:14px">{t}</div>')

    def farbfeld(name, wert, verwendung, dunkel=False):
        probe = (f'<div style="width:56px;height:56px;border-radius:{ECKE}px;background:{wert};'
                 f'border:1px solid {RAND};flex:none"></div>')
        return f'''<div style="display:flex;align-items:center;gap:12px;width:250px">
  {probe}
  <div style="display:flex;flex-direction:column;gap:2px;min-width:0">
    <span style="font-size:14px;font-weight:500">{name}</span>
    <span style="font-size:12px;color:{LEISE};font-variant-numeric:tabular-nums">{wert}</span>
    <span style="font-size:11px;color:{SEHR_LEISE}">{verwendung}</span>
  </div>
</div>'''

    farben = "".join([
        farbfeld("grund", "#0B0B0D", "Seite und beide Leisten"),
        farbfeld("flaeche", "#161619", "Felder, Blätter, Aktionsfelder"),
        farbfeld("erhoeht", "#1E1E22", "Chips und Pillen"),
        farbfeld("akzent", "#5CD1C2", "Fortschritt, Auswahl, Zustand"),
        farbfeld("warnung", "#E8833A", "nur wenn der Server transkodiert"),
        farbfeld("rand", "rgba(255,255,255,.12)", "Umrandung von Feldern"),
    ])

    def ecke_probe(wert, wofuer):
        return f'''<div style="display:flex;flex-direction:column;gap:8px;align-items:center">
  <div style="width:72px;height:52px;border-radius:{wert}px;background:{FLAECHE};
    border:1px solid {RAND}"></div>
  <span style="font-size:14px;font-weight:500">{wert}</span>
  <span style="font-size:11px;color:{SEHR_LEISE};text-align:center;width:96px">{wofuer}</span>
</div>'''

    ecken = ("".join([ecke_probe(10, "Knöpfe, Plakate, Kacheln"),
                      ecke_probe(12, "Such- und Eingabefelder"),
                      ecke_probe(16, "Blätter, Tafeln"),
                      ecke_probe(999, "Chips, Pillen, Hinweise")]))

    def grad(groesse, schnitt, wofuer, gewicht, sperrung=""):
        s = f"letter-spacing:{sperrung};" if sperrung else ""
        return f'''<div style="display:flex;align-items:baseline;gap:16px;padding:7px 0;
  border-bottom:1px solid {LINIE}">
  <span style="font-size:{groesse}px;font-weight:{gewicht};{s}width:330px">Weiterschauen</span>
  <span style="font-size:12px;color:{SEHR_LEISE};font-variant-numeric:tabular-nums;
    width:74px">{groesse} {schnitt}</span>
  <span style="font-size:12px;color:{LEISE}">{wofuer}</span>
</div>'''

    schriften = "".join([
        grad(34, "bold", "Titel im Heldbild", 700, "-.8px"),
        grad(28, "bold", "Seitentitel", 700, "-.6px"),
        grad(20, "semibold", "Reihenüberschrift, Staffelwahl", 600, "-.2px"),
        grad(17, "semibold", "Blattrubrik, Titel in der Leiste", 600),
        grad(15, "semibold", "Listenzeilen", 600),
        grad(15, "regular", "Fließtext", 400),
        grad(14, "medium", "Titel unter Plakaten", 500),
        grad(12, "regular", "Jahr, Rolle, Laufzeit", 400),
        grad(11, "semibold", "Gruppentitel (Versalien, Sperrung 1,2)", 600, "1.2px"),
    ])

    knoepfe = f'''<div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
  {hauptknopf("Abspielen")}{nebenknopf("merken")}{nebenknopf("punkte")}
  <div style="width:{HAUPTKNOPF_H}px;height:{HAUPTKNOPF_H}px;border-radius:50%;
    background:rgba(255,255,255,.09);display:flex;align-items:center;justify-content:center">
    {zeichen("herz", 20, SCHRIFT, 1.7)}</div>
  <div style="width:{HAUPTKNOPF_H}px;height:{HAUPTKNOPF_H}px;border-radius:50%;
    background:{AKZENT};display:flex;align-items:center;justify-content:center">
    {zeichen("herz", 20, GRUND, 0, True)}</div>
</div>'''

    steuern = f'''<div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">
  {chip("Alle", True)}{chip("Angefangen")}{chip("A–Z", True, "trichter")}
  <div style="width:18px"></div>{schalter(True)}{schalter(False)}
  <div style="width:18px"></div>{eingabefeld("Titel, Serie, Person", "lupe", 260)}
  {eingabefeld("Titel, Serie, Person", "lupe", 260, fokus=True)}
</div>'''

    zustaende = f'''<div style="display:flex;align-items:flex-end;gap:22px;flex-wrap:wrap">
  <div style="display:flex;flex-direction:column;gap:8px;align-items:center">
    {bildflaeche(100, 150, VERLAEUFE[0], 0.42)}
    <span style="font-size:11px;color:{SEHR_LEISE}">angefangen</span></div>
  <div style="display:flex;flex-direction:column;gap:8px;align-items:center">
    {bildflaeche(100, 150, VERLAEUFE[1], None, zeichen("haken", 12, SCHRIFT, 2.6))}
    <span style="font-size:11px;color:{SEHR_LEISE}">gesehen</span></div>
  <div style="display:flex;flex-direction:column;gap:8px;align-items:center">
    {bildflaeche(100, 150, VERLAEUFE[2], None, "12 offen")}
    <span style="font-size:11px;color:{SEHR_LEISE}">offene Folgen</span></div>
  <div style="display:flex;flex-direction:column;gap:8px;align-items:center">
    {bildflaeche(100, 150, VERLAEUFE[3], None, "7 Staffeln")}
    <span style="font-size:11px;color:{SEHR_LEISE}">Staffeln</span></div>
  <div style="display:flex;flex-direction:column;gap:8px;align-items:center">
    <div style="width:100px;height:150px;border-radius:{ECKE}px;background:{FLAECHE};
      opacity:.75"></div>
    <span style="font-size:11px;color:{SEHR_LEISE}">Ladefeld</span></div>
  <div style="display:flex;flex-direction:column;gap:9px">
    <span style="display:flex;align-items:center;gap:6px;color:{AKZENT};font-size:13px;
      font-weight:500">{zeichen("haken", 12, AKZENT, 2.6)}Direct Play</span>
    <span style="display:flex;align-items:center;gap:6px;color:{WARNUNG};font-size:13px;
      font-weight:500">Transkodiert · Untertitel</span>
    <div>{plakette("FSK-16")} {plakette("4K")} {plakette("HDR")}</div>
  </div>
</div>'''

    koerper = f'''
<div style="padding:44px {RAND_ABSTAND * 2}px;display:flex;flex-direction:column;gap:40px">
  <div>
    <span style="font-size:28px;font-weight:700;letter-spacing:-.6px">Bausteine</span>
    <div style="font-size:15px;color:{LEISE};margin-top:6px;max-width:720px">
      Das Register für den Bau. Jede Zahl steht so in <span style="color:{SCHRIFT}">
      Sources/Shared/Farben.swift</span> und <span style="color:{SCHRIFT}">
      Sources/macOS/Stil.swift</span> — nichts gerundet, nichts auf ein Raster gezogen.</div>
  </div>
  <div>{feld_titel("A · Farbe")}
    <div style="display:flex;flex-wrap:wrap;gap:22px 30px">{farben}</div></div>
  <div>{feld_titel("B · Die Eckenskala — je größer die Fläche, desto runder")}
    <div style="display:flex;gap:36px">{ecken}</div></div>
  <div>{feld_titel("C · Schrift")}
    <div style="max-width:820px">{schriften}</div></div>
  <div>{feld_titel("I · Ein gefüllter Knopf je Seite, alles daneben ist Zeichen")}
    {knoepfe}</div>
  <div>{feld_titel("I · Steuern")}{steuern}</div>
  <div>{feld_titel("Die Marke — ersetzt Jellyfins Logo in der Kopfleiste")}
    <div style="display:flex;align-items:center;gap:26px;flex-wrap:wrap">
      <div style="display:flex;align-items:center;gap:9px;padding:10px 14px;
        background:{GRUND};border:1px solid {LINIE};border-radius:{ECKE}px">
        {signet(22)}<span style="font-size:17px;font-weight:600;letter-spacing:-.2px">
        Pauls Kiste</span></div>
      <div style="display:flex;align-items:center;gap:18px">
        {signet(16)}{signet(22)}{signet(34)}{signet(52)}
      </div>
      <span style="font-size:12px;color:{LEISE};max-width:360px">
        Die Abspielform aus <span style="color:{SCHRIFT}">Marke.signetForm</span>, ohne das
        abgerundete Quadrat. Sie traegt ihre eigene Farbe
        <span style="color:{MARKE_AKZENT}">{MARKE_AKZENT}</span> — nicht den Akzent der
        Oberflaeche; so steht es in Marken.swift.</span>
    </div></div>
  <div>{feld_titel("H · Zustände — drei Zustände, drei Zeichen")}{zustaende}</div>
</div>'''
    return schreiben("Bausteine.dc.html", koerper, breite=1440, hoehe=1620)


# ===========================================================================

def main():
    startseite(); anmeldung(); bibliothek(); detail_film(); detail_serie()
    suche(); einstellungen(); profil(); player(); dashboard(); bausteine_tafel()

    S = 1440
    L = 120   # Luft zwischen den Spalten
    R = 180   # Luft zwischen den Reihen

    def spalte(i):
        return i * (S + L)

    artboards = [
        # Reihe 1 — die Wege durch die App
        {"file": "Anmeldung.dc.html", "x": spalte(0), "y": 0, "w": S, "h": 900},
        {"file": "Main.dc.html", "x": spalte(1), "y": 0, "w": S, "h": 1000,
         "title": "Startseite"},
        {"file": "Bibliothek.dc.html", "x": spalte(2), "y": 0, "w": S, "h": 900},
        # Reihe 2 — die Detailseiten
        {"file": "DetailFilm.dc.html", "x": spalte(0), "y": 1000 + R, "w": S, "h": 1000},
        {"file": "DetailSerie.dc.html", "x": spalte(1), "y": 1000 + R, "w": S, "h": 1080},
        {"file": "Suche.dc.html", "x": spalte(2), "y": 1000 + R, "w": S, "h": 900},
        # Reihe 3 — Konto, Wiedergabe, Server
        {"file": "Profil.dc.html", "x": spalte(0), "y": 1000 + R + 1080 + R, "w": S, "h": 900},
        {"file": "Einstellungen.dc.html", "x": spalte(1), "y": 1000 + R + 1080 + R,
         "w": S, "h": 1000},
        {"file": "Player.dc.html", "x": spalte(2), "y": 1000 + R + 1080 + R, "w": S, "h": 900},
        {"file": "Dashboard.dc.html", "x": spalte(1), "y": 1000 + R + 1080 + R + 1000 + R,
         "w": S, "h": 900},
    ]

    bausteine_ab = [{"file": "Bausteine.dc.html", "x": 0, "y": 0, "w": 1440, "h": 1620,
                     "page": "page-2"}]

    notizen = [
        {"id": "hinweis-kopfleiste", "x": spalte(0), "y": -190, "w": 470,
         "text": "Keine Seitenleiste — und das ist kein Versäumnis.\n"
                 "Jellyfins Schublade ist ein Überlagerungs-Bauteil mit Auf/Zu-Zustand; "
                 "mit CSS wird daraus keine stehende Leiste. Eine eigene zu bauen braucht "
                 "ein Skript, und das kommt nur über einen Eintrag in Jellyfins index.html "
                 "hinein — auf Pauls Server nicht schreibbar.\n"
                 "Also trägt Jellyfins eigene Kopfleiste unsere Sprache: deckend in grund, "
                 "Haarlinie, Ziele in 15 medium, das aktive im Akzent. Das Logo wird durch "
                 "die Abspielform der Marke ersetzt."},
        {"id": "hinweis-kulisse", "x": spalte(0), "y": 1000 + R - 150, "w": 460,
         "text": "Die Kulisse liegt rechts und wird von zwei Masken ausgeblendet, nicht von "
                 "einem Anstrich übermalt.\nDie Kurven stehen unverändert in Kulissenblende. "
                 "Ein Anstrich endet in undurchsichtigem grund und setzt voraus, dass der "
                 "Hintergrund genau das ist."},
        {"id": "hinweis-kein-plakat", "x": spalte(1), "y": 1000 + R - 150, "w": 460,
         "text": "Kein Plakat auf der Detailseite, kein Logo.\n"
                 "Beides ist mit CSS erreichbar: display:none auf .detailImageContainer und "
                 ".detailLogo, und :has() lässt das Plakat dort stehen, wo das Bild die Sache "
                 "selbst ist — Person, Album, Buch.\n"
                 "Die Knopfreihe wandert über flex-direction:column unter den Titel."},
        {"id": "hinweis-grenze", "x": spalte(2), "y": 1000 + R - 150, "w": 470,
         "text": "Was ein Stilblatt nicht kann — und was hier deshalb Jellyfins Aufbau bleibt:\n"
                 "• keine eigene Seitenleiste, keine eigenen Zeilen darin\n"
                 "• keine Reihe ergänzen, die es nicht gibt (z. B. „Nächste Folge“ als Plakate)\n"
                 "• die Vorschlagsliste der Suche kommt, wie Jellyfin sie baut\n"
                 "• Federn bleiben Kurven\n"
                 "Alles andere auf diesen Tafeln ist mit CSS erreichbar."},
    ]

    canvas = {
        "pages": [{"id": "page-1", "name": "Seiten"},
                  {"id": "page-2", "name": "Bausteine"}],
        "artboards": artboards + bausteine_ab,
        "annotations": notizen,
        "launch": {"view": "canvas", "page": "page-1"},
    }
    (HIER / "canvas.json").write_text(json.dumps(canvas, indent=2, ensure_ascii=False),
                                      encoding="utf-8")
    print("geschrieben:", ", ".join(sorted(p.name for p in HIER.glob("*.dc.html"))))


if __name__ == "__main__":
    main()
