class_name EdenWorlds
extends Node
## Worlds on SpacetimeDB servers, for the main menu's Play screen. A world is a database running the eden module
## (multiplayer/server); SpacetimeDB keeps it, so there is nothing to save by hand. Each server also runs one
## database named eden-lobby (the same module) whose world_listing table is its directory of worlds.
##
## - Servers: "This computer" (a local SpacetimeDB on local_port, started on demand) plus any added by address,
##   kept in user://servers.cfg.
## - Hosting creates a world on this computer: publishes the module (the prebuilt .wasm, ~1 s) under a new
##   database name, names it and fixes its seed (create_world), and lists it in the lobby.
## - Identity: one SpacetimeDB token per server in user://eden_tokens.cfg, shared with EdenNet, so the player is the
##   same person every time they join a world there (and owns the worlds they host).
## Needs the spacetime CLI to host (on PATH, or %LOCALAPPDATA%/SpacetimeDB). Joining only needs HTTP/WebSocket.

const LOBBY := "eden-lobby"
const SERVERS_PATH := "user://servers.cfg"
const TOKENS_PATH := "user://eden_tokens.cfg"
const MODULE_WASM := "res://multiplayer/server/spacetimedb/bin/Release/net10.0/wasi-wasm/publish/StdbModule.wasm"

## The local server's port and data folder (the saved worlds). Tests move them with -- --stdb-port= / --stdb-data=
static var local_port := 3180
static var local_data := "user://spacetime"
## A server this game started (stopped again when the game quits); -1 if none
static var _local_pid := -1
static var _starting := false


static func _static_init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--stdb-port="):
			local_port = int(a.trim_prefix("--stdb-port="))
		elif a.begins_with("--stdb-data="):
			local_data = a.trim_prefix("--stdb-data=")


static func local_url() -> String:
	return "http://127.0.0.1:%d" % local_port


# ------------------------------------------------------------------------------------------------------------
# Server list and tokens

## The developer's dedicated server(s). The list is fetched from OFFICIAL_LIST_URL (so the address can change without
## a game update); this is used until that answers, or when it can't be reached.
const OFFICIAL_LIST_URL := "https://edenprojectgame.com/servers.json"
const OFFICIAL_FALLBACK := [{"name": "Eden Test Server", "url": "https://test.edenprojectgame.com:443"}]
static var official: Array = OFFICIAL_FALLBACK.duplicate()


## [{name, url, local, official}]: this computer first, then the official servers, then the added ones
static func servers() -> Array[Dictionary]:
	var list: Array[Dictionary] = [{"name": "This computer", "url": local_url(), "local": true}]
	for s in official:
		list.append({"name": str(s.name), "url": normalize_url(str(s.url)), "local": false, "official": true})
	var cfg := ConfigFile.new()
	if cfg.load(SERVERS_PATH) == OK:
		for s in cfg.get_value("servers", "list", []):
			if not list.any(func(o): return o.url == str(s.url)):
				list.append({"name": str(s.name), "url": str(s.url), "local": false})
	return list


## Refreshes `official` from the server list on the developer's file server; keeps the current one if it can't
func fetch_official() -> void:
	var r: Dictionary = await _http(OFFICIAL_LIST_URL, HTTPClient.METHOD_GET, "", PackedStringArray(["User-Agent: EdenGame/list"]))
	var data = JSON.parse_string(r.text) if r.ok else null
	if data is Array and not data.is_empty() and data.all(func(s): return s is Dictionary and s.has("name") and s.has("url")):
		official = data


static func add_server(server_name: String, address: String) -> String:
	var url := normalize_url(address)
	var cfg := ConfigFile.new()
	cfg.load(SERVERS_PATH)
	var list: Array = cfg.get_value("servers", "list", [])
	list = list.filter(func(s): return s.url != url)
	list.append({"name": server_name.strip_edges() if server_name.strip_edges() != "" else url, "url": url})
	cfg.set_value("servers", "list", list)
	cfg.save(SERVERS_PATH)
	return url


static func remove_server(url: String) -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SERVERS_PATH) != OK:
		return
	cfg.set_value("servers", "list", (cfg.get_value("servers", "list", []) as Array).filter(func(s): return s.url != url))
	cfg.save(SERVERS_PATH)


## "host", "host:port" or a URL -> http://host:port (3180 when no port is given)
static func normalize_url(address: String) -> String:
	var a := address.strip_edges().trim_suffix("/")
	if a.begins_with("ws://"):
		a = "http://" + a.trim_prefix("ws://")
	elif a.begins_with("wss://"):
		a = "https://" + a.trim_prefix("wss://")
	elif not a.begins_with("http://") and not a.begins_with("https://"):
		a = "http://" + a
	var host := a.get_slice("://", 1)
	if not ":" in host:
		a += ":3180"
	return a


static func token(server: String) -> String:
	var cfg := ConfigFile.new()
	cfg.load(TOKENS_PATH)
	return str(cfg.get_value("tokens", server.replace(":", "|"), ""))


static func save_token(server: String, tok: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(TOKENS_PATH)
	cfg.set_value("tokens", server.replace(":", "|"), tok)
	cfg.save(TOKENS_PATH)


## A database name from a world name: lowercase letters, digits and dashes, plus a short random tag
static func database_name(world_name: String) -> String:
	var slug := ""
	for ch in world_name.to_lower():
		slug += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") else "-"
	while "--" in slug:
		slug = slug.replace("--", "-")
	slug = slug.strip_edges().trim_prefix("-").trim_suffix("-").left(24)
	return "eden-%s-%04x" % [slug if slug != "" else "world", randi() % 0x10000]


# ------------------------------------------------------------------------------------------------------------
# HTTP

## {ok, code, text}
func _http(url: String, method := HTTPClient.METHOD_GET, body := "", headers := PackedStringArray()) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = 5.0
	add_child(req)
	var err := req.request(url, headers, method, body)
	if err != OK:
		req.queue_free()
		return {"ok": false, "code": 0, "text": error_string(err)}
	var r: Array = await req.request_completed
	req.queue_free()
	var code: int = r[1]
	return {"ok": r[0] == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300, "code": code,
			"text": (r[3] as PackedByteArray).get_string_from_utf8()}


func ping(server: String) -> bool:
	return (await _http(server + "/v1/ping")).ok


func database_exists(server: String, db: String) -> bool:
	return (await _http("%s/v1/database/%s" % [server, db])).ok


## The rows (arrays in column order) of a query, or null if it failed
func sql(server: String, db: String, query: String) -> Variant:
	var r: Dictionary = await _http("%s/v1/database/%s/sql" % [server, db], HTTPClient.METHOD_POST, query,
			PackedStringArray(["Authorization: Bearer " + await ensure_token(server)]))
	if not r.ok:
		return null
	var data = JSON.parse_string(r.text)
	return data[0].rows if data is Array and data.size() > 0 else []


## Calls a reducer as this player (the server's token); true if it ran without error
func call_reducer(server: String, db: String, reducer: String, args: Array) -> bool:
	var r: Dictionary = await _http("%s/v1/database/%s/call/%s" % [server, db, reducer], HTTPClient.METHOD_POST,
			JSON.stringify(args, "", true, true),
			PackedStringArray(["Content-Type: application/json", "Authorization: Bearer " + await ensure_token(server)]))
	if not r.ok:
		push_warning("EdenWorlds: %s on %s failed (%d): %s" % [reducer, db, r.code, r.text])
	return r.ok


## This player's token on a server (asks the server for a new identity the first time)
func ensure_token(server: String) -> String:
	var tok := token(server)
	if tok != "":
		return tok
	var r: Dictionary = await _http(server + "/v1/identity", HTTPClient.METHOD_POST)
	var data = JSON.parse_string(r.text) if r.ok else null
	if data is Dictionary and data.has("token"):
		tok = data.token
		save_token(server, tok)
	return tok


## The worlds a server lists: [{database, name, seed, host, online, players, settings}] (online: players in it now;
## settings from the world's own world_meta, EdenWorldSettings). Empty if the server doesn't answer or has no lobby.
func list_worlds(server: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var rows = await sql(server, LOBBY, "SELECT * FROM world_listing")
	if rows == null:
		return out
	for row in rows: # database name seed host_name lister listed_at
		var players = await sql(server, str(row[0]), "SELECT * FROM player")
		if players == null:
			continue # listed but gone
		var meta := await world_meta(server, str(row[0]))
		var online := 0
		for p in players: # identity name online ...
			# (a dedicated server's own agent, the owner named "Server", is there, not playing)
			if p[2] and not (str(p[1]) == "Server" and str(p[0]) == str(meta.get("owner", ""))):
				online += 1
		out.append({"database": str(row[0]), "name": str(row[1]), "seed": int(row[2]), "host": str(row[3]), "online": online,
				"players": players.size(), "settings": meta.get("settings", EdenWorldSettings.DEFAULTS)})
	return out


## A world's name, seed and settings from its world_meta ({} if it has none). Worlds made before world settings
## have no settings column: the defaults.
func world_meta(server: String, db: String) -> Dictionary:
	var rows = await sql(server, db, "SELECT * FROM world_meta")
	if rows == null or rows.is_empty():
		return {}
	var row: Array = rows[0] # id name seed owner created_at settings
	return {"name": str(row[1]), "seed": int(row[2]), "owner": row[3], "settings": EdenWorldSettings.from_json(str(row[5]) if row.size() > 5 else "")}


# ------------------------------------------------------------------------------------------------------------
# Hosting (this computer)

## The spacetime CLI, or "" if it isn't installed
static func cli() -> String:
	var local := OS.get_environment("LOCALAPPDATA").path_join("SpacetimeDB/spacetime.exe")
	if OS.get_name() == "Windows" and FileAccess.file_exists(local):
		return local
	var out := []
	if OS.execute("spacetime", ["--version"], out, true) == 0:
		return "spacetime"
	return ""


## Starts the local server if it isn't running (listening on all interfaces when `lan`, so others can join).
## Returns "" or what went wrong.
func ensure_local_server(lan := false) -> String:
	while _starting: # (another call is starting it)
		await get_tree().process_frame
	if await ping(local_url()):
		return ""
	_starting = true
	var err := await _start_local_server(lan)
	_starting = false
	return err


func _start_local_server(lan: bool) -> String:
	var exe := cli()
	if exe == "":
		return "SpacetimeDB isn't installed (spacetime CLI not found)"
	var dir := ProjectSettings.globalize_path(local_data)
	DirAccess.make_dir_recursive_absolute(dir)
	var addr := "%s:%d" % ["0.0.0.0" if lan else "127.0.0.1", local_port]
	_local_pid = OS.create_process(exe, ["start", "--listen-addr", addr, "--data-dir", dir])
	if _local_pid <= 0:
		return "Couldn't start SpacetimeDB"
	for i in 60:
		await get_tree().create_timer(0.5).timeout
		if await ping(local_url()):
			await _after_start()
			return ""
	return "SpacetimeDB didn't start"


## The server was just started: nobody is connected yet. Brings each hosted world up to this game's module (new
## tables and reducers; SpacetimeDB migrates in place) and marks everyone offline (players connected when it was
## stopped never got their disconnect, so their worlds read "1 online" forever).
func _after_start() -> void:
	var server := local_url()
	if not await database_exists(server, LOBBY):
		return
	_publish(LOBBY)
	var rows = await sql(server, LOBBY, "SELECT * FROM world_listing")
	for row in rows if rows != null else []:
		var db := str(row[0])
		if await database_exists(server, db) and _publish(db) == "":
			await call_reducer(server, db, "all_offline", [])


## True if worlds have been hosted on this computer before (its server's data folder exists)
static func has_local_worlds() -> bool:
	return DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(local_data))


## Publishes the eden module as `db` on the local server (the prebuilt .wasm)
func _publish(db: String) -> String:
	var wasm := ProjectSettings.globalize_path(MODULE_WASM)
	if not FileAccess.file_exists(MODULE_WASM):
		return "The server module isn't built (spacetime build -p multiplayer/server/spacetimedb)"
	if OS.has_feature("template"): # exported: the .wasm is inside the .pck, which the CLI can't read
		wasm = OS.get_user_data_dir().path_join("StdbModule.wasm")
		var f := FileAccess.open(wasm, FileAccess.WRITE)
		if f == null:
			return "Couldn't write %s" % wasm
		f.store_buffer(FileAccess.get_file_as_bytes(MODULE_WASM))
		f.close()
	var out := []
	var code := OS.execute(cli(), ["publish", db, "--bin-path", wasm, "-s", local_url(), "-y"], out, true)
	if code != 0:
		return "Publishing %s failed: %s" % [db, "".join(out).strip_edges().right(300)]
	return ""


## Creates a world on this computer. Returns {database} or {error}.
func host_world(world_name: String, world_seed: int, host_name: String, lan := false,
		settings := EdenWorldSettings.DEFAULTS) -> Dictionary:
	var err := await ensure_local_server(lan)
	if err != "":
		return {"error": err}
	var server := local_url()
	if not await database_exists(server, LOBBY):
		err = _publish(LOBBY)
		if err != "":
			return {"error": err}
	var db := database_name(world_name)
	err = _publish(db)
	if err != "":
		return {"error": err}
	if not await call_reducer(server, db, "create_world", [world_name, world_seed, JSON.stringify(EdenWorldSettings.normalized(settings))]):
		return {"error": "Couldn't set the world up"}
	await call_reducer(server, LOBBY, "list_world", [db, world_name, world_seed, EdenOptions.valid_name(host_name)])
	return {"database": db}


## Deletes a world hosted on this computer (its database, and its listing)
func delete_world(db: String) -> bool:
	await call_reducer(local_url(), LOBBY, "unlist_world", [db])
	var out := []
	return OS.execute(cli(), ["delete", db, "-s", local_url(), "-y"], out, true) == 0


## Stops the server this game started (at quit): the whole process tree, since `spacetime start` runs the real
## server as a child
static func stop_local_server() -> void:
	if _local_pid <= 0:
		return
	if OS.get_name() == "Windows":
		OS.execute("taskkill", ["/T", "/F", "/PID", str(_local_pid)], [], true)
	else:
		OS.kill(_local_pid)
	_local_pid = -1
