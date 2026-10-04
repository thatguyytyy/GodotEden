# Eden multiplayer (SpacetimeDB)

Players on the same planet see each other move and animate, and every dig or placed block is shared and kept.

- `server/`: the SpacetimeDB module (C#). Tables `player` (position, facing, animation state, online) and
  `voxel_edit` (every dig/place, replayed to anyone who joins). Reducers `set_name`, `update_player` and
  `add_voxel_edit` check their input: names 1-24 characters, finite positions, edits within 12 m of the player,
  radius at most 2 m.
- `eden_net.gd` (EdenNet): the game's client. It uses SpacetimeDB's JSON WebSocket protocol
  (`v1.json.spacetimedb`) directly from GDScript, so no SDK or C# build is needed on the Godot side.
- `eden_remote_player.gd` (EdenRemotePlayer): another player's avatar. It uses the same model and procedural
  animator and moves smoothly between updates.

## Chat

Enter (or `/`) opens the chat box, Enter sends, Esc closes, Up/Down recall earlier lines (`eden_chat.gd`, EdenChat).
Lines go through the server's `chat_message` table (last 100 kept, 500 characters, plain text, one line per 0.3 s per
player), so everyone sees them and joiners get the recent history. A line starting with `/` is a command, shown only
to whoever ran it: `/help [command]`, `/me <action>` (shared), `/who`, `/name <new name>`, `/tp <player>`, `/pos`,
`/time`, `/clear`. `//text` says a line that begins with a slash. Add commands in `_register_commands()`.

## From the main menu

The demo starts at the main menu (menu/main_menu.tscn). PLAY lists the worlds on this computer and on any server
you add (by address). HOST NEW creates a world here: it starts a local SpacetimeDB (port 3180, data in the
game's user folder) if none is running, publishes this module under a new database name, sets the world's name and
seed (create_world) and lists it in the server's eden-lobby database (the same module; its world_listing table is
the server's directory). JOIN loads the planet with the world's seed. The world is the save: SpacetimeDB keeps the
players (where they are), their inventories (player_inventory), dug terrain, buildings and the clock, so joining
again puts you back where you left. The game stops a server it started when it quits.

Needs the spacetime CLI to host; joining only needs the server's address. After changing server/spacetimedb/Lib.cs,
run `spacetime build -p demo_eden/multiplayer/server/spacetimedb` (hosting publishes the prebuilt .wasm).
Test: `godot --path demo_eden -s res://menu/_worlds_test.gd -- --stdb-port=3191 --stdb-data=<dir>`.

## Run it

```
spacetime start --listen-addr 127.0.0.1:3180 --data-dir demo_eden/multiplayer/.stdb
spacetime publish eden --module-path demo_eden/multiplayer/server/spacetimedb -s http://127.0.0.1:3180
```

Then play `eden_play.tscn` with the EdenPlayer's **Scene Setup > Online** ticked, or run the game with
`-- --online [--name=You] [--server=ws://host:3180]`. Start a second copy the same way to see two players.
The HUD shows the connection state and how many players are online.

Port 3180 is used because 3000, SpacetimeDB's default, is often taken by other dev servers. To serve other
machines, listen on `0.0.0.0:3180` and point clients at `--server=ws://<this machine>:3180`.

To wipe the world's edits and players, publish again with `--delete-data`.

## Test

```
python demo_eden/multiplayer/mp_test.py bin/godot.windows.editor.x86_64.console.exe
```

The test starts SpacetimeDB if needed, publishes the module fresh, runs the game online (`_mp_test.gd`), and adds
a bot player (`mp_bot.py`) that walks circles around you and digs a hole next to you. It passes when:

- the game sees the bot's avatar and the bot's dig;
- the bot sees the game's player move;
- both reducers were accepted.
