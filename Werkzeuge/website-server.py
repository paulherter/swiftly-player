#!/usr/bin/env python3
"""Vorschau-Server fuer die Website.

Zwei Dinge, die der eingebaute http.server nicht kann und die hier
stundenlang Fehler vorgetaeuscht haben:

1. **Bereichsanfragen.** SimpleHTTPRequestHandler beantwortet ein
   `Range:` mit 200 und der ganzen Datei. Ein `video.currentTime = 7.6`
   ist aber genau so eine Anfrage. Ohne 206 laedt der Browser die Datei
   von vorn, bei jedem Schleifensprung wieder, und meldet dazwischen
   `waiting`. Das sah aus wie eine kaputte Aufnahme.
2. **Zwischenspeicher.** Last-Modified laesst den Browser eine alte
   Seite festhalten. `no-store` fuer alles waere aber falsch: dann darf
   er auch die Filme nicht behalten und laedt sie bei jedem Sprung neu.
   Also no-store nur fuer Seite, Stil und Skript.
"""
import os, re, sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

FRISCH = (".html", ".htm", ".css", ".js", ".json", ".md")
BEREICH = re.compile(r"^bytes=(\d*)-(\d*)$")

class Handler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # /blog/ ist PHP. Der Python-Server kann es nicht, also laeuft daneben PHPs
    # eingebauter Server (mit website-router.php), und hierher kommt nur die
    # Weiterleitung. Videos und alles andere bleiben beim Python-Server, weil
    # der Bereichsanfragen kann und PHP nicht.
    php_port = None

    def _php(self):
        import http.client
        try:
            c = http.client.HTTPConnection("127.0.0.1", self.php_port, timeout=20)
            c.request(self.command, self.path, headers={"Accept": self.headers.get("Accept", "*/*")})
            r = c.getresponse(); body = r.read()
        except Exception as e:
            self.send_error(502, "PHP nicht erreichbar: %s" % e); return
        self.send_response(r.status)
        for k, v in r.getheaders():
            if k.lower() not in ("connection", "transfer-encoding", "content-length", "date", "server", "cache-control"):
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        if self.php_port and self.path.split("?")[0].startswith("/blog"):
            return self._php()
        return super().do_GET()

    def do_HEAD(self):
        if self.php_port and self.path.split("?")[0].startswith("/blog"):
            return self._php()
        return super().do_HEAD()

    def _frisch(self):
        return os.path.splitext(self.path.split("?")[0])[1].lower() in FRISCH

    def end_headers(self):
        if self._frisch():
            self.send_header("Cache-Control", "no-store, must-revalidate")
        else:
            self.send_header("Cache-Control", "no-cache")
        self.send_header("Accept-Ranges", "bytes")
        super().end_headers()

    def send_header(self, key, value):
        if self._frisch() and key.lower() in ("last-modified", "etag"):
            return
        super().send_header(key, value)

    def send_head(self):
        """Wie das Original, aber mit 206 fuer Bereichsanfragen."""
        kopf = self.headers.get("Range")
        if not kopf:
            return super().send_head()
        treffer = BEREICH.match(kopf.strip())
        if not treffer:
            return super().send_head()

        pfad = self.translate_path(self.path)
        if os.path.isdir(pfad):
            return super().send_head()
        try:
            f = open(pfad, "rb")
        except OSError:
            self.send_error(404, "File not found")
            return None

        gesamt = os.fstat(f.fileno()).st_size
        von, bis = treffer.group(1), treffer.group(2)
        if von == "":                                  # bytes=-500: die letzten 500
            laenge = min(int(bis or 0), gesamt)
            anfang = gesamt - laenge
            ende = gesamt - 1
        else:
            anfang = int(von)
            ende = int(bis) if bis else gesamt - 1
            ende = min(ende, gesamt - 1)
        if anfang >= gesamt or anfang > ende:
            f.close()
            self.send_response(416)
            self.send_header("Content-Range", "bytes */%d" % gesamt)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return None

        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(pfad))
        self.send_header("Content-Range", "bytes %d-%d/%d" % (anfang, ende, gesamt))
        self.send_header("Content-Length", str(ende - anfang + 1))
        self.end_headers()
        f.seek(anfang)
        self.uebrig = ende - anfang + 1
        return f

    def copyfile(self, quelle, ziel):
        """Beim 206 nur den angefragten Abschnitt schreiben."""
        uebrig = getattr(self, "uebrig", None)
        if uebrig is None:
            return super().copyfile(quelle, ziel)
        self.uebrig = None
        while uebrig > 0:
            brocken = quelle.read(min(64 * 1024, uebrig))
            if not brocken:
                break
            ziel.write(brocken)
            uebrig -= len(brocken)

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8788
    ordner = sys.argv[2] if len(sys.argv) > 2 else "Website"
    # Standard nur dieser Mac. "0.0.0.0" als drittes Argument macht die Seite
    # im WLAN erreichbar, etwa zum Testen auf dem Handy.
    host = sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1"
    import atexit, shutil, subprocess
    ordner_abs = os.path.abspath(ordner)
    php = shutil.which("php")
    router = os.path.join(os.path.dirname(os.path.abspath(__file__)), "website-router.php")
    if php and os.path.isdir(os.path.join(ordner_abs, "blog")) and os.path.exists(router):
        Handler.php_port = port + 100
        proc = subprocess.Popen([php, "-S", "127.0.0.1:%d" % Handler.php_port, "-t", ordner_abs, router],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        atexit.register(proc.terminate)
    ThreadingHTTPServer((host, port),
        lambda *a, **k: Handler(*a, directory=ordner, **k)).serve_forever()
