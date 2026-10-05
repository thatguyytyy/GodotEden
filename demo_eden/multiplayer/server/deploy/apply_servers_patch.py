"""Makes ~/eden_server.py answer GET /servers.json (the game's official server list, from ~/eden-server/servers.json)
to the game's User-Agent (EdenGame/*). Run on the server once; refuses to run twice."""
import os

target = os.path.expanduser("~/eden_server.py")
s = open(target).read()
assert "servers.json" not in s, "already patched"
patch = '''    # The game asks which official servers exist (so an address change needs no game update)
    def do_GET(self):
        if self.path.split("?")[0] == "/servers.json" and self.headers.get("User-Agent", "").startswith("EdenGame/"):
            try:
                body = open(os.path.expanduser("~/eden-server/servers.json"), "rb").read()
            except OSError:
                body = b"[]"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

'''
s = s.replace("    def send_head(self):", patch + "    def send_head(self):", 1)
open(target, "w").write(s)
