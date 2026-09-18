# Nimmt PUT-Uploads aus der Windows-VM an und legt sie in ~/empfang ab.
import http.server, os, pathlib
ziel = pathlib.Path.home() / "empfang"; ziel.mkdir(exist_ok=True)
class H(http.server.BaseHTTPRequestHandler):
    def do_PUT(self):
        n = int(self.headers.get("Content-Length", 0))
        name = os.path.basename(self.path) or "datei"
        (ziel / name).write_bytes(self.rfile.read(n))
        self.send_response(201); self.end_headers()
        print("empfangen", name, n, flush=True)
http.server.ThreadingHTTPServer(("0.0.0.0", 8097), H).serve_forever()
