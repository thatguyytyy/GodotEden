"""Static file server for the Eden build folder: python3 eden_server.py [dir] [port]
- no-store so Cloudflare never serves a stale .exe/.dll/manifest after an update
- no directory listings, and only requests from the launcher (User-Agent EdenLauncher/*) get files;
  browsers and scrapers get an empty 404. Obscurity, not security: fine for a closed alpha."""
import os
import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

root = sys.argv[1] if len(sys.argv) > 1 else "/var/www/eden_project"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 8473


class Handler(SimpleHTTPRequestHandler):
    server_version = "eden"
    sys_version = ""

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def send_head(self):
        ok = self.headers.get("User-Agent", "").startswith("EdenLauncher/")
        if not ok or os.path.isdir(self.translate_path(self.path)):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return None
        return super().send_head()


ThreadingHTTPServer(("127.0.0.1", port), partial(Handler, directory=root)).serve_forever()
