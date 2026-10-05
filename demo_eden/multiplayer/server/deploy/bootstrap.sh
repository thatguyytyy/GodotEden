#!/bin/sh
# Brings the dedicated world server up to date: publishes the eden module as the lobby and the test world (in place,
# so saved worlds keep their data), names the world once, lists it, and marks everyone offline (nobody can be
# connected right after a start). Safe to run again. Needs the server running on 127.0.0.1:3180.
# The admin identity is the CLI's default one; it owns the world and never joins as a player (a dedicated world).
set -e
cd "$(dirname "$0")"
STDB="$HOME/eden-server/stdb/spacetime"
SERVER=http://127.0.0.1:3180
WASM="$HOME/eden-server/StdbModule.wasm"
DB=eden-test
NAME="Eden Test World"
SEED=424242
SETTINGS='{"template":"eden","temperature":"temperate","rainfall":"normal"}'

for i in $(seq 60); do curl -sf $SERVER/v1/ping >/dev/null && break; sleep 1; done
"$STDB" publish eden-lobby --bin-path "$WASM" -s $SERVER -y
"$STDB" publish $DB --bin-path "$WASM" -s $SERVER -y
"$STDB" call -s $SERVER $DB create_world "\"$NAME\"" $SEED "$(printf '%s' "$SETTINGS" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"
"$STDB" call -s $SERVER eden-lobby list_world "\"$DB\"" "\"$NAME\"" $SEED '"Eden Server"'
"$STDB" call -s $SERVER $DB all_offline
