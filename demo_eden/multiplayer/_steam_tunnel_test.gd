extends SceneTree
## Multiplayer through Steam on one machine (needs Steam running and logged in, and a window): hosts a world on a
## private SpacetimeDB, then plays it through EdenSteam's tunnel, as a friend would.
##   1. Loopback: the tunnel over a Steam socket pair (Steam's own send/receive path, no network): the world's
##      metadata over HTTP, then joining the world (its WebSocket) until the player is online.
##   2. Lobby: EdenSteam opens a lobby for the world; Steam's lobby search finds it with its name and settings.
##   3. Relay: a real Steam P2P connection to this same account through the tunnel (Steam may refuse to connect an
##      account to itself; reported, not failed).
##   godot --audio-driver Dummy --path demo_eden --resolution 1280x720 -s res://multiplayer/_steam_tunnel_test.gd --
##       --stdb-port=3192 --stdb-data=<scratch dir>

const SETTINGS := {"template": "continents", "temperature": "hot", "rainfall": "wet"}
var ok := true
var worlds: EdenWorlds
var es: Node


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	es = root.get_node_or_null("EdenSteam")
	_check(es != null and es.available, "Steam is running (EdenSteam on)")
	if not ok:
		return _finish()
	var steam: Object = es.steam
	worlds = EdenWorlds.new()
	root.add_child(worlds)
	var server := EdenWorlds.local_url()
	var r := await worlds.host_world("Steam Test", 777, "Tester", false, SETTINGS)
	_check(r.has("database"), "hosted a world %s" % [r])
	if not r.has("database"):
		return _finish()
	var db: String = r.database

	# 1. Loopback: each local TCP connection gets a Steam socket pair; the far end is piped to the SpacetimeDB
	es.hosting = {"port": EdenWorlds.local_port}
	es.open_to_host = func(_host: int) -> int:
		var me: int = steam.getSteamID()
		var pair: Dictionary = steam.createSocketPair(true, me, me)
		if not pair.get("success", false):
			print("STEAM_TEST info createSocketPair failed: %s" % [pair])
		var tcp := StreamPeerTCP.new()
		tcp.connect_to_host("127.0.0.1", EdenWorlds.local_port)
		es.link(int(pair.connection2), tcp)
		return int(pair.connection1)
	var url: String = es.tunnel_to(steam.getSteamID())
	var meta := await worlds.world_meta(url, db)
	_check(meta.get("name", "") == "Steam Test" and meta.get("settings", {}) == SETTINGS, "HTTP through the tunnel: %s" % [meta])
	EdenSession.play_online(url, db, meta.name, meta.seed, meta.settings)
	var player := await _join()
	_check(player != null, "joined the world through the tunnel (WebSocket online)")
	if player:
		_check(int(player._planet.generator.seed) == 777, "with the world's seed")
	change_scene_to_file("res://menu/main_menu.tscn")
	await _seconds(1.0)
	es.leave()

	# 2. Lobby
	es.open_to_host = func(host: int) -> int: return steam.connectP2P(host, EdenSteam.VIRTUAL_PORT, {})
	es.host({"name": "Steam Test", "database": db, "seed": 777, "settings": SETTINGS, "port": EdenWorlds.local_port})
	var t0 := Time.get_ticks_msec()
	while es.lobby_id == 0 and Time.get_ticks_msec() - t0 < 15000:
		await process_frame
	_check(es.lobby_id != 0, "opened a lobby (%d)" % es.lobby_id)
	await _seconds(2.0)
	es.find_lobbies()
	var found: Array = (await es.lobbies_found).filter(func(l): return l.lobby == es.lobby_id)
	_check(found.size() == 1 and found[0].name == "Steam Test" and found[0].settings == SETTINGS,
			"Steam's lobby search finds it with its world: %s" % [found])

	# 3. Relay to ourselves (informational)
	url = es.tunnel_to(steam.getSteamID())
	var t1 := Time.get_ticks_msec()
	var relay := await worlds.world_meta(url, db)
	print("STEAM_TEST info relay to self: %s after %.1f s" % ["works, " + str(relay) if not relay.is_empty() else "no answer (Steam doesn't connect an account to itself)",
			(Time.get_ticks_msec() - t1) / 1000.0])
	es.leave()
	await worlds.delete_world(db)
	_finish()


## Loads the play scene (EdenSession set) and returns the player once online and on the ground, or null
func _join() -> EdenPlayer:
	change_scene_to_file("res://eden_play.tscn")
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 120000:
		await process_frame
		for n in current_scene.find_children("*", "CharacterBody3D", true, false) if current_scene else []:
			if n is EdenPlayer and n.ready_to_move and n.net and n.net.status == "online" and n.net._joined:
				print("STEAM_TEST info joined in %.1f s" % ((Time.get_ticks_msec() - t0) / 1000.0))
				return n
	return null


func _finish() -> void:
	EdenWorlds.stop_local_server()
	print("STEAM_TEST ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func _check(cond: bool, msg: String) -> void:
	print("STEAM_TEST %s %s" % ["ok  " if cond else "FAIL", msg])
	ok = ok and cond


func _seconds(s: float) -> void:
	var end := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < end:
		await process_frame
