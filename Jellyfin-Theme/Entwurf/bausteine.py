"""Gemeinsame Werte und Bausteine für die Entwurfstafeln.

Jede Zahl hier stammt aus dem Code der Mac-Fassung — `Sources/Shared/Farben.swift`,
`Sources/macOS/Stil.swift`, `Sources/macOS/Macbausteine.swift`. Nichts ist
gerundet und nichts auf ein 4er-Raster gezogen.
"""

# --- A · Farbe · Sources/Shared/Farben.swift -------------------------------
GRUND = "#0B0B0D"
FLAECHE = "#161619"
ERHOEHT = "#1E1E22"
AKZENT = "#5CD1C2"
WARNUNG = "#E8833A"
SCHRIFT = "#ffffff"
LEISE = "rgba(255,255,255,.62)"
SEHR_LEISE = "rgba(255,255,255,.38)"
LINIE = "rgba(255,255,255,.07)"
RAND = "rgba(255,255,255,.12)"
SCHWEBEN = "rgba(255,255,255,.06)"

# --- B · Form · Sources/macOS/Stil.swift -----------------------------------
ECKE = 10          # Knöpfe, Plakate, Kacheln
ECKE_FELD = 12     # Such- und Eingabefelder
ECKE_FLAECHE = 16  # Blätter, Tafeln
ECKE_MARKE = 9     # Kachelmarke
ECKE_PLAKETTE = 8

# --- Maße ------------------------------------------------------------------
SEITENLEISTE = 220
AMPEL = 40
INHALT_OBEN = 52
RAND_ABSTAND = 24
KACHEL_ABSTAND = 12
REIHEN_ABSTAND = 28
ZEILE = 32
KACHEL_B, KACHEL_H = 150, 225
QUER_B, QUER_H = 280, 158
HAUPTKNOPF_H, HAUPTKNOPF_B = 48, 200
FOLGE_B, FOLGE_H = 160, 90

SCHRIFTFAMILIE = ('-apple-system, BlinkMacSystemFont, "SF Pro Text", '
                  '"SF Pro Display", "Helvetica Neue", Arial, sans-serif')

RAHMEN_B, RAHMEN_H = 1440, 900


# --- Zeichen ---------------------------------------------------------------
# Strichzeichnungen auf dem 24er-Raster, ein Stil für alle.
PFADE = {
    "haus": "M3 10.5 12 3l9 7.5M5.5 9.5V20h13V9.5",
    "film": "M3.5 5.5h17v13h-17zM8 5.5v13M16 5.5v13M3.5 12h17",
    "tv": "M3 5.5h18v11H3zM8.5 20.5h7",
    "herz": "M12 20s-7.5-4.6-7.5-9.4A4.1 4.1 0 0 1 12 8a4.1 4.1 0 0 1 7.5 2.6C19.5 15.4 12 20 12 20z",
    "lupe": "M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14zM16.2 16.2 21 21",
    "pfeil_ab": "M12 4v13M6.5 11.5 12 17l5.5-5.5",
    "merken": "M6.5 3.5h11v17l-5.5-4-5.5 4z",
    "zahnrad": "M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM12 2.5v2.2M12 19.3v2.2M4.2 4.2l1.6 1.6M18.2 18.2l1.6 1.6M2.5 12h2.2M19.3 12h2.2M4.2 19.8l1.6-1.6M18.2 5.8l1.6-1.6",
    "person": "M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4.5 20.5c0-3.6 3.4-5.5 7.5-5.5s7.5 1.9 7.5 5.5",
    "spielen": "M7 4.5 19.5 12 7 19.5z",
    "punkte": "M12 6.6v.02M12 12v.02M12 17.4v.02",
    "winkel_l": "M15 4.5 7.5 12 15 19.5",
    "winkel_r": "M9 4.5 16.5 12 9 19.5",
    "winkel_ab": "M4.5 9 12 16.5 19.5 9",
    "haken": "M4.5 12.5 9.5 17.5 19.5 6.5",
    "stern": "M12 3.5l2.6 5.6 6 .8-4.4 4.2 1.1 6L12 17.2 6.7 20.1l1.1-6L3.4 9.9l6-.8z",
    "trichter": "M3.5 5h17l-6.8 8v6.5l-3.4-2V13z",
    "zurueck": "M4.5 12a7.5 7.5 0 1 0 2.6-5.7M4.5 4.5V9h4.5",
    "sprechblase": "M4.5 5.5h15v10h-9l-4.2 3.4v-3.4h-1.8z",
    "abmelden": "M9.5 4.5H5.5v15h4M12.5 12h8M17 8.5 20.5 12 17 15.5",
    "ton": "M4.5 9.5h3.5L12.5 6v12L8 14.5H4.5zM16 9.5a4 4 0 0 1 0 5M18.5 7a7.5 7.5 0 0 1 0 10",
    "untertitel": "M3.5 5.5h17v13h-17zM7 11h4M13 11h4M7 14.5h10",
    "vor": "M4.5 5.5 13 12l-8.5 6.5zM17.5 5.5v13",
    "bild_im_bild": "M3.5 5.5h17v13h-17zM12.5 12h6.5v5.5h-6.5z",
    "vollbild": "M4 9V4.5h5M20 9V4.5h-5M4 15v4.5h5M20 15v4.5h-5",
    "balken": "M5 15.5v4M10 10.5v9M15 6.5v13M20 12.5v7",
    "monitor": "M3.5 5h17v11h-17zM8.5 20h7M12 16v4",
    "schloss": "M6.5 10.5h11v9h-11zM8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5",
    "takt": "M12 7v5l3.2 2M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17z",
}


def zeichen(name, groesse=20, farbe="currentColor", staerke=1.6, fuellen=False):
    """Ein Zeichen als Inline-SVG. Strichgezeichnet, damit es mitskaliert."""
    d = PFADE[name]
    if fuellen:
        return (f'<svg width="{groesse}" height="{groesse}" viewBox="0 0 24 24" '
                f'fill="{farbe}" style="flex:none;display:block">'
                f'<path d="{d}"/></svg>')
    return (f'<svg width="{groesse}" height="{groesse}" viewBox="0 0 24 24" fill="none" '
            f'stroke="{farbe}" stroke-width="{staerke}" stroke-linecap="round" '
            f'stroke-linejoin="round" style="flex:none;display:block">'
            f'<path d="{d}"/></svg>')


def huelle(inhalt, breite=RAHMEN_B, hoehe=RAHMEN_H, extra_css=""):
    """Das Gerüst einer Tafel. Die Zeile mit support.js bleibt, wie sie ist."""
    return f'''<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
  <style>
    body {{
      margin: 0;
      width: {breite}px;
      height: {hoehe}px;
      overflow: hidden;
      background: {GRUND};
      color: {SCHRIFT};
      font-family: {SCHRIFTFAMILIE};
      font-size: 15px;
      -webkit-font-smoothing: antialiased;
    }}
    a {{ color: {AKZENT}; text-decoration: none; }}
    a:hover {{ color: #7FDDD0; }}
    * {{ box-sizing: border-box; }}
{extra_css}
  </style>
</helmet>
{inhalt}
</x-dc>
</body>
</html>
'''


# --- Die Seitenleiste ------------------------------------------------------

BEREICHE_OBEN = [("haus", "Start"), ("film", "Filme"), ("tv", "Serien"), ("lupe", "Suche")]
BEREICHE_MEINS = [("merken", "Merkliste"), ("pfeil_ab", "Downloads")]
BIBLIOTHEKEN = [("film", "Filmabend"), ("tv", "Lieblingsfolgen")]


def leistenzeile(sym, text, aktiv=False, schwebt=False):
    if aktiv:
        farbe, grund = AKZENT, "rgba(92,209,194,.10)"
    elif schwebt:
        farbe, grund = SCHRIFT, SCHWEBEN
    else:
        farbe, grund = LEISE, "transparent"
    return (
        f'<div style="display:flex;align-items:center;gap:10px;height:{ZEILE}px;'
        f'padding:0 10px;border-radius:{ECKE}px;background:{grund};color:{farbe}">'
        f'{zeichen(sym, 17, "currentColor", 1.5)}'
        f'<span style="font-size:15px;font-weight:500;letter-spacing:-.1px">{text}</span>'
        f'</div>'
    )


def rubrik(text):
    return (f'<div style="font-size:11px;font-weight:600;letter-spacing:.7px;'
            f'text-transform:uppercase;color:{SEHR_LEISE};padding:0 10px;'
            f'margin:26px 0 8px">{text}</div>')


def seitenleiste(aktiv="Start", schwebt=None):
    oben = "".join(leistenzeile(s, t, t == aktiv, t == schwebt) for s, t in BEREICHE_OBEN)
    meins = "".join(leistenzeile(s, t, t == aktiv, t == schwebt) for s, t in BEREICHE_MEINS)
    bibs = "".join(leistenzeile(s, t, t == aktiv, t == schwebt) for s, t in BIBLIOTHEKEN)
    return f'''
<aside style="position:absolute;left:0;top:0;bottom:0;width:{SEITENLEISTE}px;
  background:{FLAECHE};border-right:1px solid {LINIE};display:flex;flex-direction:column">
  <div style="height:{AMPEL}px"></div>
  <div style="display:flex;align-items:center;gap:9px;padding:0 20px 18px">
    <div style="width:24px;height:24px;border-radius:6px;background:{ERHOEHT};
      border:1px solid {RAND};flex:none"></div>
    <span style="font-size:17px;font-weight:600;letter-spacing:-.2px">Pauls Kiste</span>
  </div>
  <div style="display:flex;flex-direction:column;gap:2px;padding:0 12px">{oben}</div>
  <div style="padding:0 12px">{rubrik("Meins")}</div>
  <div style="display:flex;flex-direction:column;gap:2px;padding:0 12px">{meins}</div>
  <div style="padding:0 12px">{rubrik("Bibliotheken")}</div>
  <div style="display:flex;flex-direction:column;gap:2px;padding:0 12px">{bibs}</div>
  <div style="flex-grow:1"></div>
  <div style="height:1px;background:{LINIE};margin:0 0 12px"></div>
  <div style="display:flex;align-items:center;gap:10px;padding:0 22px 12px">
    <div style="width:26px;height:26px;border-radius:50%;
      background:linear-gradient(135deg,#3B4A5A,#26313D);border:1.5px solid {AKZENT};flex:none"></div>
    <div style="display:flex;flex-direction:column;gap:1px;min-width:0">
      <span style="font-size:14px;font-weight:500">paul</span>
      <span style="font-size:11px;color:{SEHR_LEISE}">Pauls Kiste</span>
    </div>
  </div>
</aside>'''


def inhalt(kinder, oben=INHALT_OBEN):
    return (f'<main style="position:absolute;left:{SEITENLEISTE}px;right:0;top:0;bottom:0;'
            f'padding:{oben}px {RAND_ABSTAND}px 0;overflow:hidden">{kinder}</main>')


# --- Kacheln ---------------------------------------------------------------

# Gedämpfte Verläufe statt echter Plakate: geliehene Bilder gehören nicht in
# einen Entwurf, und eine leere Fläche zeigt den Aufbau ehrlicher.
VERLAEUFE = [
    "linear-gradient(160deg,#2A3440,#171D24)",
    "linear-gradient(160deg,#3A3340,#1D1A22)",
    "linear-gradient(160deg,#24363A,#151F22)",
    "linear-gradient(160deg,#3A3128,#201B16)",
    "linear-gradient(160deg,#2C3348,#181B26)",
    "linear-gradient(160deg,#333A2E,#1B1E19)",
    "linear-gradient(160deg,#402D34,#221A1E)",
    "linear-gradient(160deg,#25303B,#161C21)",
]


def bildflaeche(b, h, verlauf, fortschritt=None, marke=None, zeichen_name="film", ecke=ECKE):
    """Bild einer Kachel. Der Fortschritt liegt **in** der Maske, nicht darüber —
    sonst stehen seine eckigen Enden über die runden Ecken hinaus."""
    balken = ""
    if fortschritt is not None:
        balken = (f'<div style="position:absolute;left:0;right:0;bottom:0;height:3px;'
                  f'background:rgba(255,255,255,.16)">'
                  f'<div style="width:{int(fortschritt*100)}%;height:100%;background:{AKZENT}"></div></div>')
    plakette = ""
    if marke is not None:
        plakette = (
            f'<div style="position:absolute;top:7px;right:7px;display:flex;align-items:center;'
            f'gap:3px;height:20px;padding:0 6px;border-radius:{ECKE_MARKE}px;'
            f'background:rgba(11,11,13,.78);border:1px solid {RAND};'
            f'font-size:11px;font-weight:600;color:{SCHRIFT}">{marke}</div>')
    return (
        f'<div style="position:relative;width:{b}px;height:{h}px;border-radius:{ecke}px;'
        f'background:{verlauf};overflow:hidden;display:flex;align-items:center;'
        f'justify-content:center">'
        f'<div style="opacity:.20">{zeichen(zeichen_name, 34, SCHRIFT, 1.4)}</div>'
        f'{balken}{plakette}</div>')


def kachel(titel, zweitzeile, verlauf, b=KACHEL_B, h=KACHEL_H, fortschritt=None,
           marke=None, zeichen_name="film", schwebt=False):
    lupe = "transform:scale(1.04);" if schwebt else ""
    zweit = (f'<span style="font-size:12px;color:{LEISE};white-space:nowrap;'
             f'overflow:hidden;text-overflow:ellipsis">{zweitzeile}</span>') if zweitzeile else ""
    return f'''<div style="width:{b}px;display:flex;flex-direction:column;gap:8px">
  <div style="{lupe}transform-origin:center">{bildflaeche(b, h, verlauf, fortschritt, marke, zeichen_name)}</div>
  <div style="display:flex;flex-direction:column;gap:1px;min-width:0">
    <span style="font-size:14px;font-weight:500;white-space:nowrap;overflow:hidden;
      text-overflow:ellipsis">{titel}</span>{zweit}
  </div>
</div>'''


def reihentitel(text, mit_pfeilen=False):
    pfeile = ""
    if mit_pfeilen:
        knopf = (lambda sym, an: f'<div style="width:34px;height:34px;border-radius:50%;'
                 f'background:rgba(11,11,13,.72);border:1px solid {RAND};display:flex;'
                 f'align-items:center;justify-content:center;opacity:{"1" if an else ".35"}">'
                 f'{zeichen(sym, 15, SCHRIFT, 2)}</div>')
        pfeile = (f'<div style="display:flex;gap:6px">{knopf("winkel_l", False)}'
                  f'{knopf("winkel_r", True)}</div>')
    return (f'<div style="display:flex;align-items:center;justify-content:space-between;'
            f'margin-bottom:11px">'
            f'<span style="font-size:20px;font-weight:600;letter-spacing:-.2px">{text}</span>'
            f'{pfeile}</div>')


# --- Knöpfe ----------------------------------------------------------------

def hauptknopf(text, sym="spielen", breite=HAUPTKNOPF_B):
    b = f"width:{breite}px;" if breite else "padding:0 30px;"
    return (f'<div style="{b}height:{HAUPTKNOPF_H}px;border-radius:{ECKE}px;background:{SCHRIFT};'
            f'color:{GRUND};display:flex;align-items:center;justify-content:center;gap:9px">'
            f'{zeichen(sym, 16, GRUND, 0, True)}'
            f'<span style="font-size:16px;font-weight:600">{text}</span></div>')


def nebenknopf(sym):
    return (f'<div style="width:{HAUPTKNOPF_H}px;height:{HAUPTKNOPF_H}px;border-radius:{ECKE}px;'
            f'background:rgba(255,255,255,.14);display:flex;align-items:center;'
            f'justify-content:center">{zeichen(sym, 20, SCHRIFT, 1.7)}</div>')


def chip(text, aktiv=False, sym=None):
    if aktiv:
        stil = f'background:{SCHRIFT};color:{GRUND};border:1px solid transparent;font-weight:600'
    else:
        stil = f'background:transparent;color:{LEISE};border:1px solid {RAND};font-weight:400'
    z = zeichen(sym, 12, "currentColor", 2) if sym else ""
    return (f'<div style="display:flex;align-items:center;gap:6px;height:28px;padding:0 12px;'
            f'border-radius:999px;font-size:13px;{stil}">{z}{text}</div>')


def schalter(an=True):
    knopf_farbe = GRUND if an else SCHRIFT
    grund = AKZENT if an else "rgba(255,255,255,.14)"
    links = "19px" if an else "3px"
    return (f'<div style="position:relative;width:38px;height:22px;border-radius:999px;'
            f'background:{grund};flex:none">'
            f'<div style="position:absolute;top:3px;left:{links};width:16px;height:16px;'
            f'border-radius:50%;background:{knopf_farbe}"></div></div>')


def eingabefeld(platzhalter, sym="lupe", breite=420, fokus=False):
    kante = "rgba(92,209,194,.5)" if fokus else RAND
    return (f'<div style="width:{breite}px;height:38px;border-radius:{ECKE_FELD}px;'
            f'background:{FLAECHE};border:1px solid {kante};display:flex;align-items:center;'
            f'gap:9px;padding:0 12px">{zeichen(sym, 14, SEHR_LEISE, 1.7)}'
            f'<span style="font-size:15px;color:{SEHR_LEISE}">{platzhalter}</span></div>')


def gruppentitel(text):
    return (f'<div style="font-size:11px;font-weight:600;letter-spacing:1.2px;'
            f'text-transform:uppercase;color:rgba(255,255,255,.4);'
            f'margin:26px 0 8px">{text}</div>')


def zeilengruppe(zeilen):
    inner = f'<div style="height:1px;background:{LINIE}"></div>'.join(zeilen)
    return (f'<div style="border-top:1px solid {LINIE};border-bottom:1px solid {LINIE}">'
            f'{inner}</div>')


def einstellungszeile(sym, titel, unter=None, rechts="", akzent=False):
    farbe = AKZENT if akzent else SCHRIFT
    sym_farbe = AKZENT if akzent else LEISE
    u = (f'<span style="font-size:12px;color:rgba(255,255,255,.45)">{unter}</span>') if unter else ""
    return f'''<div style="display:flex;align-items:center;gap:14px;min-height:44px;padding:8px 12px">
  <div style="width:22px;display:flex;justify-content:center">{zeichen(sym, 17, sym_farbe, 1.6)}</div>
  <div style="display:flex;flex-direction:column;gap:2px;flex-grow:1;min-width:0">
    <span style="font-size:15px;color:{farbe}">{titel}</span>{u}
  </div>
  {rechts}
</div>'''


def plakette(text):
    return (f'<span style="display:inline-flex;align-items:center;height:18px;padding:0 6px;'
            f'border:1px solid {RAND};border-radius:{ECKE_PLAKETTE}px;font-size:10px;'
            f'font-weight:600;color:{LEISE}">{text}</span>')
