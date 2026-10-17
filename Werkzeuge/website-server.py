#!/usr/bin/env python3
"""Preview server for the website.

Two things the built-in http.server cannot do, and which produced misleading
errors here for hours:

1. **Range requests.** SimpleHTTPRequestHandler answers a `Range:` header
   with 200 and the whole file, but `video.currentTime = 7.6` is exactly such
   a request. Without a 206 the browser reloads the file from the start on
   every loop jump and reports `waiting` in between, which looked like a
   broken recording.
2. **Caching.** Last-Modified makes the browser hold on to a stale page.
   `no-store` for everything would be wrong too: the videos could not be kept
   and would reload on every seek. So no-store applies only to pages, styles
   and scripts.
"""
import os, re, sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

FRESH = (".html", ".htm", ".css", ".js", ".json", ".md")
SECTION = re.compile(r"^bytes=(\d*)-(\d*)$")

class Handler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # /blog/ is PHP, which this server cannot run. PHP's built-in server runs
    # next to it (with website-router.php) and requests are proxied to it.
    # Videos and everything else stay on the Python server because it handles
    # range requests and PHP's does not.
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

    def _fresh(self):
        return os.path.splitext(self.path.split("?")[0])[1].lower() in FRESH

    def end_headers(self):
        if self._fresh():
            self.send_header("Cache-Control", "no-store, must-revalidate")
        else:
            self.send_header("Cache-Control", "no-cache")
        self.send_header("Accept-Ranges", "bytes")
        super().end_headers()

    def send_header(self, key, value):
        if self._fresh() and key.lower() in ("last-modified", "etag"):
            return
        super().send_header(key, value)

    def send_head(self):
        """Like the original, but answers range requests with 206."""
        header = self.headers.get("Range")
        if not header:
            return super().send_head()
        hit = SECTION.match(header.strip())
        if not hit:
            return super().send_head()

        path = self.translate_path(self.path)
        if os.path.isdir(path):
            return super().send_head()
        try:
            f = open(path, "rb")
        except OSError:
            self.send_error(404, "File not found")
            return None

        total = os.fstat(f.fileno()).st_size
        fromValue, until = hit.group(1), hit.group(2)
        if fromValue == "":                                  # bytes=-500: the last 500
            length = min(int(until or 0), total)
            start = total - length
            end = total - 1
        else:
            start = int(fromValue)
            end = int(until) if until else total - 1
            end = min(end, total - 1)
        if start >= total or start > end:
            f.close()
            self.send_response(416)
            self.send_header("Content-Range", "bytes */%d" % total)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return None

        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, total))
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        f.seek(start)
        self.remaining = end - start + 1
        return f

    def copyfile(self, source, target):
        """For a 206, write only the requested range."""
        remaining = getattr(self, "remaining", None)
        if remaining is None:
            return super().copyfile(source, target)
        self.remaining = None
        while remaining > 0:
            brocken = source.read(min(64 * 1024, remaining))
            if not brocken:
                break
            target.write(brocken)
            remaining -= len(brocken)

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8788
    folder = sys.argv[2] if len(sys.argv) > 2 else "Website"
    # Localhost only by default. "0.0.0.0" as the third argument makes the site
    # reachable on the local network, e.g. for testing on a phone.
    host = sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1"
    import atexit, shutil, subprocess
    folder_abs = os.path.abspath(folder)
    php = shutil.which("php")
    router = os.path.join(os.path.dirname(os.path.abspath(__file__)), "website-router.php")
    if php and os.path.isdir(os.path.join(folder_abs, "blog")) and os.path.exists(router):
        Handler.php_port = port + 100
        proc = subprocess.Popen([php, "-S", "127.0.0.1:%d" % Handler.php_port, "-t", folder_abs, router],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        atexit.register(proc.terminate)
    ThreadingHTTPServer((host, port),
        lambda *a, **k: Handler(*a, directory=folder, **k)).serve_forever()
