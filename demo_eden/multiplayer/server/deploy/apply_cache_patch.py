"""Run on the server: makes ~/eden_server.py let Cloudflare cache a file requested as <path>?v=<sha256> (the launcher asks for
game files that way), so the big downloads come from Cloudflare's edge instead of this connection. Everything else
(manifest, news, anything without ?v=) stays no-store. Refuses to run twice."""
import os

target = os.path.expanduser("~/eden_server.py")
s = open(target).read()
old = '''    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()
'''
new = '''    def end_headers(self):
        # a file asked for by its hash never changes: let the edge keep it; anything else must always be fresh
        if "?v=" in self.path:
            self.send_header("Cache-Control", "public, max-age=31536000, immutable")
        else:
            self.send_header("Cache-Control", "no-store")
        super().end_headers()
'''
assert old in s, "end_headers not as expected (already patched?)"
open(target, "w").write(s.replace(old, new, 1))
