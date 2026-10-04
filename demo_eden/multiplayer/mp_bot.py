"""A second player for testing Eden multiplayer without a second game window: connects to the SpacetimeDB `eden`
module with the same JSON protocol the game uses, finds another online player, walks circles around them for a
while (update_player at 10 Hz) and digs one hole next to them (add_voxel_edit). Checks it saw the other player move.

    python demo_eden/multiplayer/mp_bot.py [--server ws://127.0.0.1:3180] [--db eden] [--seconds 20]
Prints BOT lines; exit code 0 when the other player was seen moving and both reducers were accepted.
"""
import argparse
import asyncio
import json
import math
import sys

import websockets


def row(r):
    return json.loads(r) if isinstance(r, str) else r


def ident(v):
    if isinstance(v, list) and len(v) == 1:
        return v[0]
    return next(iter(v.values())) if isinstance(v, dict) and len(v) == 1 else json.dumps(v)


def as_player(r):
    if isinstance(r, list):
        keys = ["identity", "name", "online", "x", "y", "z", "yaw", "state", "speed"]
        r = dict(zip(keys, r))
    return r


async def main(args):
    url = f"{args.server}/v1/database/{args.db}/subscribe"
    players, me, failures, accepted = {}, None, [], set()
    rows_seen = {}
    chat = []
    request = 0

    async with websockets.connect(url, subprotocols=["v1.json.spacetimedb"], max_size=1 << 24) as ws:
        async def call(reducer, a):
            nonlocal request
            request += 1
            await ws.send(json.dumps({"CallReducer": {"reducer": reducer, "args": json.dumps(a), "request_id": request, "flags": 0}}))

        def apply(db_update):
            for t in db_update.get("tables", []):
                if t["table_name"] == "chat_message":
                    for qu in t.get("updates", []):
                        for r in qu.get("Uncompressed", qu).get("inserts", []):
                            m = row(r)
                            if isinstance(m, list):
                                m = dict(zip(["id", "sender", "name", "text", "kind", "at"], m))
                            chat.append((m["name"], m["text"], m["kind"]))
                    continue
                if t["table_name"] != "player":
                    continue
                for qu in t.get("updates", []):
                    u = qu.get("Uncompressed", qu)
                    for r in u.get("inserts", []):
                        p = as_player(row(r))
                        players[ident(p["identity"])] = p
                        rows_seen[ident(p["identity"])] = rows_seen.get(ident(p["identity"]), 0) + 1

        async def pump(timeout):
            try:
                msg = json.loads(await asyncio.wait_for(ws.recv(), timeout))
            except asyncio.TimeoutError:
                return
            nonlocal me
            if "IdentityToken" in msg:
                me = ident(msg["IdentityToken"]["identity"])
                await ws.send(json.dumps({"Subscribe": {"query_strings": ["SELECT * FROM player", "SELECT * FROM chat_message"], "request_id": 1}}))
                await call("set_name", ["Bot"])
            elif "InitialSubscription" in msg:
                apply(msg["InitialSubscription"]["database_update"])
            elif "TransactionUpdateLight" in msg: # other clients' transactions
                apply(msg["TransactionUpdateLight"]["update"])
            elif "TransactionUpdate" in msg:
                tu = msg["TransactionUpdate"]
                st = tu.get("status", {})
                red = tu.get("reducer_call", {}).get("reducer_name", "")
                if "Committed" in st:
                    apply(st["Committed"])
                    accepted.add(red)
                elif "Failed" in st:
                    failures.append((red, st["Failed"]))

        # Wait for someone else to be online
        other = None
        for _ in range(600):
            await pump(0.1)
            # (a player still at the origin hasn't placed itself yet)
            others = [p for k, p in players.items() if k != me and p.get("online") and abs(p["x"]) + abs(p["y"]) + abs(p["z"]) > 1.0]
            if others and me:
                other = others[0]
                break
        if other is None:
            print("BOT FAIL no other player online")
            return 1
        oid = ident(other["identity"])
        first = (other["x"], other["y"], other["z"])
        print(f"BOT sees {other['name']} at {first[0]:.1f},{first[1]:.1f},{first[2]:.1f}")
        # A tangent frame at the other player
        c = [first[0], first[1], first[2]]
        rlen = math.sqrt(sum(v * v for v in c))
        up = [v / rlen for v in c]
        e = [up[2], 0.0, -up[0]]
        el = math.sqrt(sum(v * v for v in e)) or 1.0
        e = [v / el for v in e]
        n = [up[1] * e[2] - up[2] * e[1], up[2] * e[0] - up[0] * e[2], up[0] * e[1] - up[1] * e[0]]
        dug = False
        t = 0.0
        while t < args.seconds:
            a = t * 0.8
            pos = [c[i] + e[i] * 3.0 * math.cos(a) + n[i] * 3.0 * math.sin(a) + up[i] * 0.3 for i in range(3)]
            await call("update_player", [pos[0], pos[1], pos[2], a + math.pi / 2, "walk", 2.4])
            if not dug and t > 2.0:
                hole = [c[i] + e[i] * 4.0 - up[i] * 0.2 for i in range(3)]
                await call("add_voxel_edit", [hole[0], hole[1], hole[2], 1.3, 0, 0])
                print(f"BOT dug at {hole[0]:.2f},{hole[1]:.2f},{hole[2]:.2f}")
                # And a stone floor on the ground beside the other player, turned to stand upright there
                spot = [c[i] - e[i] * 3.0 + up[i] * 0.2 for i in range(3)]
                axis = [-up[2], 0.0, up[0]]  # (0,1,0) x up
                al = math.sqrt(sum(v * v for v in axis)) or 1.0
                ang = math.acos(max(-1.0, min(1.0, up[1])))
                s = math.sin(ang / 2) / al
                await call("place_piece", ["stone_floor", spot[0], spot[1], spot[2], axis[0] * s, axis[1] * s, axis[2] * s, math.cos(ang / 2)])
                print("BOT placed a stone floor")
                # And set the world's clock: day 100.5 (midday), paused, so the game's calendar can be checked
                await call("set_clock", [100.5, 0.0])
                print("BOT set the world clock to day 100.5, paused")
                dug = True
                # Chat: a line, and a second right behind it that the server's rate limit must turn down
                await call("send_chat", ["hello from bot", 0])
                await call("send_chat", ["too fast", 0])
                await call("send_chat", ["bad\u0007bell", 0])
                print("BOT said hello")
            end = asyncio.get_event_loop().time() + 0.1
            while asyncio.get_event_loop().time() < end:
                await pump(max(end - asyncio.get_event_loop().time(), 0.001))
            t += 0.1
        last = players.get(oid, other)
        moved = math.dist(first, (last["x"], last["y"], last["z"]))
        rejected = [f for f in failures if f[0] == "send_chat"]
        failures = [f for f in failures if f[0] != "send_chat"]
        chat_ok = ("Bot", "hello from bot", 0) in chat and not any(c[1] == "too fast" for c in chat) \
            and not any("bell" in c[1] for c in chat) and len(rejected) == 2 and "Slow down" in str(rejected[0]) \
            and any("plain text" in str(f) for f in rejected)
        heard = ("Tester", "hello bot", 0) in chat and ("Tester", "waves", 1) in chat
        ok = moved > 1.0 and "update_player" in accepted and "add_voxel_edit" in accepted and "place_piece" in accepted and "set_clock" in accepted and not failures and chat_ok and heard
        print(f"BOT chat: rate limit and bad text turned down {len(rejected)} lines, own line accepted {chat_ok}, heard the game's lines {heard}")
        print(f"BOT {oid[:10]} moved {moved:.1f} m while watched; accepted {sorted(accepted)}; failures {failures}; their row updates seen {rows_seen.get(oid, 0)}")
        print("BOT", "PASS" if ok else "FAIL")
        return 0 if ok else 1


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", default="ws://127.0.0.1:3180")
    ap.add_argument("--db", default="eden")
    ap.add_argument("--seconds", type=float, default=20.0)
    sys.exit(asyncio.run(main(ap.parse_args())))
