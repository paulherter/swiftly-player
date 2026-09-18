#!/usr/bin/env python3
"""Laedt App/Website per FTPS zu All-Inkl hoch, in EINER Sitzung.

curl meldet sich nach jedem Fehler fuer die naechste Datei neu an; nach ein
paar Anmeldungen sperrt All-Inkl mit 530 (Schutz gegen Passwortraten). Hier
gibt es genau eine Anmeldung. Faellt eine Datei mit 4xx, wird sie in derselben
Sitzung nach einer Pause wiederholt. Scheitert die Anmeldung, bricht das
Skript sofort ab, damit die Sperre nicht laenger wird.
Zugang aus dem Schluesselbund; das Passwort steht in keiner Datei.

  website-hochladen.py                     alles hochladen
  website-hochladen.py --trocken           nur auflisten, keine Anmeldung
  website-hochladen.py --nur-geaendert     nur Dateien, deren Inhalt sich seit dem
                                           letzten erfolgreichen Hochladen geaendert
                                           hat; unter blog/ werden lokal geloeschte
                                           Dateien auch auf dem Server geloescht.
                                           Nichts zu tun = keine Anmeldung.
  website-hochladen.py --nur blog/ sitemap.xml llms.txt
                                           nur diese Pfade (Ordner mit /)

Nie hochgeladen: Markdown-Quellen (blog/quellen/, seiten/quellen/, *.md,
DESIGN.md), versteckte Dateien und Ordner (.impeccable, .DS_Store) ausser
.htaccess. Die .htaccess der Wurzel ersetzt die Server-Datei nicht: nur der
Block "# BEGIN swiftly-blog ... # END swiftly-blog" wird eingesetzt, alles
andere darin (z. B. HTTPS-Weiterleitung) bleibt.
"""
import ftplib, hashlib, io, json, os, re, subprocess, sys, time

SERVER = "w0198283.kasserver.com"
ORDNER = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Website"))
STAND = os.path.expanduser("~/Library/Application Support/swiftly-website/hochgeladen.json")
AUSNAHME_ORDNER = {"blog/quellen", "seiten/quellen"}
LOESCHBAR = "blog/"          # nur hier darf das Skript auf dem Server loeschen


def ausgenommen(rel):
    teile = rel.split("/")
    if any(t.startswith(".") and t != ".htaccess" for t in teile):
        return True
    if any(rel == o or rel.startswith(o + "/") for o in AUSNAHME_ORDNER):
        return True
    return rel.endswith(".md")


def dateien():
    out = []
    for wurzel, ordner, namen in os.walk(ORDNER):
        rel_wurzel = os.path.relpath(wurzel, ORDNER).replace(os.sep, "/")
        rel_wurzel = "" if rel_wurzel == "." else rel_wurzel + "/"
        ordner[:] = sorted(o for o in ordner if not ausgenommen(rel_wurzel + o))
        for n in namen:
            rel = rel_wurzel + n
            if not ausgenommen(rel):
                out.append(rel)
    return sorted(out)


def pruefsumme(rel):
    h = hashlib.sha256()
    with open(os.path.join(ORDNER, rel), "rb") as d:
        for brocken in iter(lambda: d.read(1 << 20), b""):
            h.update(brocken)
    return h.hexdigest()


def stand_lesen():
    try:
        with open(STAND) as h:
            return json.load(h)
    except (OSError, ValueError):
        return {}


def stand_schreiben(stand):
    os.makedirs(os.path.dirname(STAND), exist_ok=True)
    tmp = STAND + ".tmp"
    with open(tmp, "w") as h:
        json.dump(stand, h, indent=1, sort_keys=True)
    os.replace(tmp, STAND)


def zugang():
    def sec(*a):
        return subprocess.run(["security", "find-internet-password", "-s", SERVER, "-r", "ftp ", *a],
                              capture_output=True, text=True).stdout
    nutzer = next((z.split("=", 1)[1].strip().strip('"') for z in sec().splitlines() if '"acct"' in z), "")
    passwort = sec("-w").strip()
    if not nutzer or not passwort:
        sys.exit("Kein FTP-Eintrag im Schluesselbund.")
    return nutzer, passwort


def htaccess_zusammenfuehren(ftp, f, lokal):
    """Wurzel-.htaccess: Server-Datei lesen, unseren Block ersetzen/anhaengen."""
    if f != ".htaccess":
        return lokal
    alt = bytearray()
    try:
        ftp.retrbinary("RETR .htaccess", alt.extend)
    except ftplib.error_perm:
        pass                                   # keine Datei auf dem Server
    rest = re.sub(r"\n?# BEGIN swiftly-blog.*?# END swiftly-blog\n?", "\n",
                  alt.decode("utf-8", "replace"), flags=re.S).strip()
    if rest:
        print(f"      .htaccess: vorhandene Server-Regeln ({len(rest)} Zeichen) bleiben erhalten", flush=True)
    return ((rest + "\n\n") if rest else "").encode() + lokal.strip() + b"\n"


def argumente():
    args = sys.argv[1:]
    nur = []
    if "--nur" in args:
        i = args.index("--nur") + 1
        while i < len(args) and not args[i].startswith("--"):
            nur.append(args[i].lstrip("/"))
            i += 1
        if not nur:
            sys.exit("--nur ohne Pfade.")
    return "--trocken" in args, "--nur-geaendert" in args, nur


def passt(rel, nur):
    return not nur or any(rel == p or (p.endswith("/") and rel.startswith(p)) for p in nur)


def main():
    trocken, geaendert, nur = argumente()
    stand = stand_lesen()
    alle = [f for f in dateien() if passt(f, nur)]
    summen = {f: pruefsumme(f) for f in alle} if geaendert else {}
    liste = [f for f in alle if not geaendert or stand.get(f) != summen[f]]
    weg = []
    if geaendert:
        vorhanden = set(dateien())
        weg = sorted(f for f in stand if f.startswith(LOESCHBAR) and passt(f, nur) and f not in vorhanden)

    if trocken:
        print(f"Wuerde {len(liste)} Dateien laden" + (f" und {len(weg)} loeschen" if weg else "") + ":")
        [print("  " + f) for f in liste]
        [print("  loeschen " + f) for f in weg]
        return
    if not liste and not weg:
        print("Nichts geaendert, keine Anmeldung.")
        return

    nutzer, passwort = zugang()
    try:
        ftp = ftplib.FTP_TLS(SERVER, timeout=60)
    except (EOFError, OSError) as e:
        passwort = None
        sys.exit(f"Server hat die Verbindung vor der Anmeldung geschlossen ({type(e).__name__}). "
                 "Meist eine Sperre nach zu vielen Anmeldungen. Kein weiterer Versuch.")
    try:
        ftp.login(nutzer, passwort)
    except ftplib.error_perm as e:
        sys.exit(f"Anmeldung abgelehnt ({e}). Abbruch, damit die Sperre nicht laenger wird.")
    finally:
        passwort = None
    ftp.prot_p()
    wurzel = ftp.pwd()

    angelegt = set()
    fehler = []

    def ordner_anlegen(rel_ordner):
        """Jede Ebene einzeln, von der Wurzel aus. Ein 550 heisst meist 'gibt es
        schon'; ob der Ordner wirklich da ist, zeigt ein cwd."""
        teile = [t for t in rel_ordner.split("/") if t]
        for t in range(1, len(teile) + 1):
            pfad = "/".join(teile[:t])
            if pfad in angelegt:
                continue
            try:
                ftp.mkd(pfad)
                print(f"      Ordner {pfad}/ angelegt", flush=True)
            except ftplib.error_perm:
                ftp.cwd(pfad)            # wirft, wenn er fehlt und nicht anlegbar ist
                ftp.cwd(wurzel)
            angelegt.add(pfad)

    try:
        for i, f in enumerate(liste, 1):
            with open(os.path.join(ORDNER, f), "rb") as h:
                inhalt = h.read()
            try:
                if "/" in f:
                    ordner_anlegen(f.rsplit("/", 1)[0])
                inhalt = htaccess_zusammenfuehren(ftp, f, inhalt)
                groesse = len(inhalt)
                for versuch in range(1, 5):
                    try:
                        ftp.storbinary(f"STOR {f}", io.BytesIO(inhalt))
                        live = ftp.size(f)
                        if live != groesse:
                            raise ftplib.error_temp(f"450 Groesse {live} statt {groesse}")
                        print(f"[{i:2}/{len(liste)}] ok  {f}  {groesse} B", flush=True)
                        stand[f] = summen.get(f) or pruefsumme(f)
                        break
                    except ftplib.error_temp as e:
                        print(f"[{i:2}/{len(liste)}] {e} - neuer Versuch in {versuch*10}s", flush=True)
                        time.sleep(versuch * 10)
                else:
                    fehler.append(f)
            except ftplib.error_perm as e:
                print(f"[{i:2}/{len(liste)}] abgelehnt {f}: {e}", flush=True)
                fehler.append(f)

        for f in weg:
            try:
                ftp.delete(f)
                print(f"geloescht  {f}", flush=True)
            except ftplib.error_perm as e:
                if not str(e).startswith("550"):
                    print(f"loeschen abgelehnt {f}: {e}", flush=True)
                    fehler.append(f)
                    continue
            stand.pop(f, None)
            ordner = f.rsplit("/", 1)[0]
            try:
                ftp.rmd(ordner)                   # nur wenn leer; sonst egal
                print(f"geloescht  {ordner}/", flush=True)
            except ftplib.error_perm:
                pass
        ftp.quit()
    finally:
        stand_schreiben(stand)

    print(f"Fertig: {len(liste)-len([f for f in fehler if f in liste])} von {len(liste)} Dateien"
          + (f", {len(weg)} geloescht" if weg else "") + "."
          + (f" Fehlgeschlagen: {fehler}" if fehler else ""))
    sys.exit(1 if fehler else 0)


if __name__ == "__main__":
    main()
