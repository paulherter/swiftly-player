# Accepts PUT uploads from the Windows VM and stores them in ~/empfang.
import http.server, os, pathlib
target = pathlib.Path.home() / "empfang"; target.mkdir(exist_ok=True)
class H(http.server.BaseHTTPRequestHandler):
    def do_PUT(self):
        n = int(self.headers.get("Content-Length", 0))
        name = os.path.basename(self.path) or "datei"
        (target / name).write_bytes(self.rfile.read(n))
        self.send_response(201); self.end_headers()
        print("empfangen", name, n, flush=True)
http.server.ThreadingHTTPServer(("0.0.0.0", 8097), H).serve_forever()
