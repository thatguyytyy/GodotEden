class_name EdenNet
extends Node
## Multiplayer through SpacetimeDB (the `eden` module in multiplayer/server). Speaks SpacetimeDB's JSON WebSocket
## protocol (v1.json.spacetimedb) straight from GDScript, no SDK:
##   - subscribes to the `player` and `voxel_edit` tables; other players appear as EdenRemotePlayer avatars that
##     follow their updates (smoothed), voxel edits by anyone are applied to the local terrain (all of them on
##     joining, so the world keeps its changes);
##   - sends this player's position/state ~10 times a second (update_player) and every dig/place (add_voxel_edit).
## The world is the save: joining again puts the player back where the server last saw them, with the inventory
## they left with (player_inventory, sent when it changes). The identity token is kept per server
## (EdenWorlds.token, user://eden_tokens.cfg) so a restart is the same player.
## Made by EdenPlayer when Scene Setup > online is on, the main menu joined a world, or `-- --online`.

signal connected(identity: String)
signal players_changed
## A chat line from the server (`live` false while the recent history loads on joining)
signal chat_received(sender: String, sender_name: String, text: String, kind: int, live: bool)
## The server turned a line down (too fast, too long)
signal chat_rejected(reason: String)

const PROTOCOL := "v1.json.spacetimedb"
const SEND_INTERVAL := 0.1
## At most one inventory save per this many seconds
const INVENTORY_INTERVAL := 1.0
## The host sends its weather this often (everyone else's follows it)
const WEATHER_INTERVAL := 5.0
## Footprints in snow go out this often, and trails within TRAIL_RANGE m of the player are pressed into its snow
const TRAIL_INTERVAL := 1.0
const TRAIL_RANGE := 20.0

@export var server_url := "ws://127.0.0.1:3180"
@export var database := "eden"
@export var player_name := "Explorer"

## Connection state for the HUD and tests: "offline", "connecting", "online", "error"
var status := "offline"
var identity := ""
## identity -> row Dictionary (all players the server knows, online or not)
var players := {}
## identity -> EdenRemotePlayer
var avatars := {}
var edits_applied := 0
## World clock rows received (the calendar follows the server's)
var clock_updates := 0
## Where the last edit from someone else was applied (world space), for tests
var last_edit_position := Vector3.ZERO
## What joining restored: "position" and/or "inventory" -> true (for tests and the HUD)
var restored := {}
## Chat lines received, oldest first: {id, sender, name, text, kind}
var chat_log: Array[Dictionary] = []
var chat: EdenChat

var _player: EdenPlayer
var _ws := WebSocketPeer.new()
var _send_t := 0.0
var _request := 0
var _last_sent := {}
var _token := ""
var _idle := 0.0
var _inventory_dirty := false
var _inventory_t := 0.0
var _joined := false
var _weather_t := 0.0
## The world's owner (world_meta): its host. Others leave when the host does. "" for a world without one (tests).
var host_identity := ""
## Snow trails the server keeps (snow_trail): id -> {at (unix s), points (world), center, radius, near}. `near`: pressed
## into our snow since it last came within TRAIL_RANGE (our own are, as we walk them)
var trails := {}
var _trail_t := 0.0
var _trail_check := 0.0


func setup(player: EdenPlayer) -> void:
	_player = player
	_token = EdenWorlds.token(_http_base())
	_ws.supported_protocols = PackedStringArray([PROTOCOL])
	_ws.inbound_buffer_size = 1 << 22
	if _token != "":
		_ws.handshake_headers = PackedStringArray(["Authorization: Bearer " + _token])
	var url := "%s/v1/database/%s/subscribe" % [server_url, database]
	var err := _ws.connect_to_url(url)
	status = "connecting" if err == OK else "error"
	if player.miner:
		player.miner.edited.connect(_on_local_edit)
		player.miner.inventory_changed.connect(func(): _inventory_dirty = true)
	if player.builder:
		player.builder.place_requested.connect(func(k: String, xf: Transform3D):
			var o := xf.origin - _player._center()
			var q := xf.basis.get_rotation_quaternion()
			_call("place_piece", [k, o.x, o.y, o.z, q.x, q.y, q.z, q.w]))
		player.builder.remove_requested.connect(func(id: int): _call("remove_piece", [id]))
	if player.calendar:
		player.calendar.clock_set.connect(func(d: float, rate: float): _call("set_clock", [d, rate]))
	chat = EdenChat.new()
	chat.name = "Chat"
	add_child(chat)
	chat.setup(self, player)


func _process(delta: float) -> void:
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			while _ws.get_available_packet_count() > 0:
				_on_message(_ws.get_packet().get_string_from_utf8())
			_send_t -= delta
			if _send_t <= 0.0 and status == "online":
				_send_t = SEND_INTERVAL
				_send_state()
			_inventory_t -= delta
			if _inventory_dirty and _inventory_t <= 0.0 and status == "online":
				_send_inventory()
			_weather_t -= delta
			if _weather_t <= 0.0 and status == "online" and _is_weather_authority() and _player._ambience:
				_weather_t = WEATHER_INTERVAL
				_call("set_weather", [Array(_player._ambience.get_weather_state())])
			_trail_t -= delta
			if _trail_t <= 0.0 and status == "online":
				_trail_t = TRAIL_INTERVAL
				_send_trail()
			_trail_check -= delta
			if _trail_check <= 0.0:
				_trail_check = 0.5
				_press_near_trails()
		WebSocketPeer.STATE_CLOSED:
			if status != "error":
				var was_online := status == "online"
				status = "error"
				push_warning("EdenNet: connection closed (%d %s)" % [_ws.get_close_code(), _ws.get_close_reason()])
				if was_online:
					_leave("Lost the connection to the world.")


## Says `text` to everyone (kind 0), or as an emote (kind 1, "/me")
func send_chat(text: String, kind := 0) -> void:
	if status == "online":
		_call("send_chat", [text, kind])


func online_count() -> int:
	var n := 0
	for id in players:
		if players[id].get("online", false):
			n += 1
	return n


# ------------------------------------------------------------------------------------------------------------
# Outgoing

func _call(reducer: String, args: Array) -> void:
	_request += 1
	_ws.send_text(JSON.stringify({"CallReducer": {
		"reducer": reducer, "args": JSON.stringify(args, "", true, true), "request_id": _request, "flags": 0}}))


func _send_state() -> void:
	if not _player.ready_to_move:
		return
	var p := _player.global_position - _player._center()
	var state := {"x": p.x, "y": p.y, "z": p.z, "yaw": _facing_angle(), "state": _player.animator.state,
			"speed": snappedf(_player.animator.ground_speed, 0.05)}
	# Standing still sends nothing new: only changes go out (plus a keep-alive every 2 s)
	_idle += SEND_INTERVAL
	if state == _last_sent and _idle < 2.0:
		return
	_idle = 0.0
	_last_sent = state
	_call("update_player", [p.x, p.y, p.z, state.yaw, state.state, state.speed])


# The inventory as it is (not while the debug creative mode fills it: that isn't the player's)
func _send_inventory() -> void:
	_inventory_dirty = false
	_inventory_t = INVENTORY_INTERVAL
	if _player.miner == null or (_player.debug and _player.debug.creative):
		return
	_call("set_inventory", [Array(_player.miner.counts)])


## The server as an http base (the key its token is kept under)
func _http_base() -> String:
	return server_url.replace("wss://", "https://").replace("ws://", "http://")


# The body's facing as an angle from planet north (what the avatar is turned by on the other side)
func _facing_angle() -> float:
	var up := _player.up_direction
	return EdenPlayer._north(up).signed_angle_to(_player._facing, up)


func _on_local_edit(world_pos: Vector3, radius: float, mode: int, material: int) -> void:
	if status != "online":
		return
	var p := world_pos - _player._center()
	_call("add_voxel_edit", [p.x, p.y, p.z, radius, mode, material])


# ------------------------------------------------------------------------------------------------------------
# Incoming

func _on_message(text: String) -> void:
	var msg = JSON.parse_string(text)
	if not msg is Dictionary:
		return
	if msg.has("IdentityToken"):
		var t: Dictionary = msg.IdentityToken
		identity = _id(t.identity)
		if t.get("token", "") != "" and t.token != _token:
			_token = t.token
			EdenWorlds.save_token(_http_base(), t.token)
		_request += 1
		_ws.send_text(JSON.stringify({"Subscribe": {
			"query_strings": ["SELECT * FROM player", "SELECT * FROM voxel_edit", "SELECT * FROM build_piece", "SELECT * FROM world_clock",
					"SELECT * FROM player_inventory", "SELECT * FROM world_meta", "SELECT * FROM world_weather", "SELECT * FROM snow_trail", "SELECT * FROM chat_message", "SELECT * FROM ban"], "request_id": _request}}))
		_call("set_name", [player_name])
	elif msg.has("InitialSubscription"):
		_apply_update(msg.InitialSubscription.database_update)
		_restore()
		status = "online"
		if _player.builder:
			_player.builder.online = true
		connected.emit(identity)
		_check_host()
	elif msg.has("TransactionUpdate"):
		var tu: Dictionary = msg.TransactionUpdate
		var st = tu.get("status", {})
		if st is Dictionary and st.has("Committed"):
			_apply_update(st.Committed)
			_check_host()
		elif st is Dictionary and st.has("Failed"):
			if tu.get("reducer_call", {}).get("reducer_name", "") == "send_chat":
				chat_rejected.emit(str(st.Failed).split("\n")[0])
			push_warning("EdenNet: reducer failed: %s" % str(st.Failed))
	elif msg.has("TransactionUpdateLight"):
		_apply_update(msg.TransactionUpdateLight.update)
		_check_host()


## Back to the main menu, saying why (the host left, the server went away). Only in a world joined from the menu.
func _leave(reason: String) -> void:
	push_warning("EdenNet: " + reason)
	var app := get_node_or_null("/root/EdenApp")
	if app and EdenSession.active:
		EdenSession.notice = reason
		app.main_menu()


# Playing without the host (it left to the menu, quit or crashed: its connection closed) isn't allowed
func _check_host() -> void:
	# (a dedicated world's owner never joins as a player: no row, nobody to wait for)
	if status == "online" and host_identity != "" and identity != host_identity and players.has(host_identity) \
			and not players[host_identity].get("online", false):
		status = "left"
		_leave("The host left the world.")


## Who sets the world's weather: its host; in a dedicated world (no host player) the online player whose identity
## sorts first, which every client works out the same way
func _is_weather_authority() -> bool:
	if host_identity == "" or players.has(host_identity):
		return identity == host_identity
	var first := ""
	for id in players:
		if players[id].get("online", false) and (first == "" or id < first):
			first = id
	return first == identity


func _apply_update(db_update: Dictionary) -> void:
	for table in db_update.get("tables", []):
		for qu in table.get("updates", []):
			# Query updates arrive plain or wrapped as {"Uncompressed": {...}}
			var u: Dictionary = qu.get("Uncompressed", qu) if qu is Dictionary else {}
			var deletes: Array = u.get("deletes", [])
			var inserts: Array = u.get("inserts", [])
			match table.table_name:
				"player":
					for r in deletes:
						_player_row(_row(r), false)
					for r in inserts:
						_player_row(_row(r), true)
					players_changed.emit()
				"voxel_edit":
					for r in inserts:
						_edit_row(_row(r))
				"world_clock":
					for r in inserts:
						_clock_row(_row(r))
				"chat_message": # column order: id sender name text kind at
					var fresh := []
					for r in inserts:
						var row := _row(r)
						if row.has("_array"):
							var a: Array = row._array
							row = {"id": a[0], "sender": a[1], "name": a[2], "text": a[3], "kind": a[4]}
						fresh.append(row)
					fresh.sort_custom(func(a, b): return int(a.id) < int(b.id))
					for row in fresh:
						chat_log.append({"id": int(row.id), "sender": _id(row.sender), "name": str(row.name), "text": str(row.text), "kind": int(row.kind)})
						if chat_log.size() > 100:
							chat_log.pop_front()
						chat_received.emit(_id(row.sender), str(row.name), str(row.text), int(row.kind), status == "online")
				"ban": # column order: identity name reason at
					for r in inserts:
						var row := _row(r)
						if _id(row._array[0] if row.has("_array") else row.identity) == identity and status == "online":
							status = "left"
							_leave("You were removed from this server.")
				"world_meta": # column order: id name seed owner created_at settings
					for r in inserts:
						var row := _row(r)
						host_identity = _id(row._array[3] if row.has("_array") else row.owner)
				"snow_trail":
					for r in deletes:
						var row := _row(r)
						trails.erase(int(row._array[0] if row.has("_array") else row.id))
					for r in inserts:
						_trail_row(_row(r))
				"world_weather": # column order: id state
					for r in inserts:
						var row := _row(r)
						var state: Array = row._array[1] if row.has("_array") else row.state
						if not _is_weather_authority() and _player._ambience:
							_player._ambience.set_weather_state(PackedFloat32Array(state))
				"player_inventory":
					for r in inserts:
						var row := _row(r)
						if row.has("_array"): # column order: identity counts
							row = {"identity": row._array[0], "counts": row._array[1]}
						if _id(row.identity) == identity:
							_own_inventory = row.counts
				"build_piece":
					for r in deletes:
						var row := _piece_row(_row(r))
						if _player.builder:
							_player.builder.despawn_net(int(row.id))
					for r in inserts:
						var row := _piece_row(_row(r))
						if _player.builder:
							var q := Quaternion(row.qx, row.qy, row.qz, row.qw).normalized()
							_player.builder.spawn(str(row.kind), Transform3D(Basis(q), _player._center() + Vector3(row.x, row.y, row.z)), int(row.id))


var _own_inventory = null


# Joining: put the player back where the server last saw them, with their inventory (once, on the first
# subscription; a new player has no position yet and keeps the scene's spawn)
func _restore() -> void:
	if _joined:
		return
	_joined = true
	var me: Dictionary = players.get(identity, {})
	var pos := Vector3(float(me.get("x", 0.0)), float(me.get("y", 0.0)), float(me.get("z", 0.0)))
	if pos.length() > 1.0:
		_player.restore_position(pos, float(me.get("yaw", 0.0)))
		restored["position"] = true
	if _own_inventory is Array and _player.miner:
		for i in mini(_own_inventory.size(), _player.miner.counts.size()):
			_player.miner.counts[i] = int(_own_inventory[i])
		_player.miner.refresh()
		_inventory_dirty = false
		restored["inventory"] = true


# A row arrives as JSON text of the row (an object by field name, or an array in column order)
func _row(r) -> Dictionary:
	var v = JSON.parse_string(r) if r is String else r
	if v is Array:
		return {"_array": v}
	return v if v is Dictionary else {}


# Identities come as {"__identity__": "0x.."} (rows by field name), ["0x.."] (rows as arrays) or a plain string
static func _id(v) -> String:
	if v is Array and v.size() == 1:
		return str(v[0])
	if v is Dictionary:
		return str(v.values()[0]) if v.size() == 1 else JSON.stringify(v)
	return str(v)


func _player_row(r: Dictionary, inserted: bool) -> void:
	if r.has("_array"): # column order: identity name online x y z yaw state speed
		var a: Array = r._array
		r = {"identity": a[0], "name": a[1], "online": a[2], "x": a[3], "y": a[4], "z": a[5], "yaw": a[6], "state": a[7], "speed": a[8]}
	var id := _id(r.identity)
	if not inserted:
		# An update is a delete then an insert of the same key: keep the avatar, the insert refreshes it
		players.erase(id)
		return
	players[id] = r
	if id == identity:
		return
	var avatar: EdenRemotePlayer = avatars.get(id)
	# (a player who has joined but not yet sent where they are sits at the planet's centre)
	if not r.online or Vector3(r.x, r.y, r.z).length() < 1.0:
		if avatar:
			avatar.queue_free()
			avatars.erase(id)
		return
	if avatar == null:
		avatar = EdenRemotePlayer.create(_player._planet, _player)
		avatars[id] = avatar
		get_tree().current_scene.add_child(avatar)
	avatar.set_target(_player._center() + Vector3(r.x, r.y, r.z), float(r.yaw), str(r.state), float(r.speed), str(r.name))


# The world's calendar clock (column order: id days set_at days_per_second); timestamps come as
# {"__timestamp_micros_since_unix_epoch__": n} or [n]
func _clock_row(r: Dictionary) -> void:
	if r.has("_array"):
		var a: Array = r._array
		r = {"days": a[1], "set_at": a[2], "days_per_second": a[3]}
	var ts = r.set_at
	var micros: float = float(ts.values()[0]) if ts is Dictionary else (float(ts[0]) if ts is Array else float(ts))
	if _player.calendar:
		_player.calendar.follow_server(float(r.days), micros / 1e6, float(r.days_per_second))
	clock_updates += 1


# Column order: id kind x y z qx qy qz qw author
static func _piece_row(r: Dictionary) -> Dictionary:
	if r.has("_array"):
		var a: Array = r._array
		return {"id": a[0], "kind": a[1], "x": a[2], "y": a[3], "z": a[4], "qx": a[5], "qy": a[6], "qz": a[7], "qw": a[8]}
	return r


func _send_trail() -> void:
	var prints := _player.snow_prints
	if prints.is_empty() or _player._ambience == null:
		return
	var flat := []
	for pt in prints.slice(maxi(prints.size() - 64, 0)): # (the server takes 64 a time)
		var o := pt - _player._center()
		flat.append_array([o.x, o.y, o.z])
	_player.snow_prints = PackedVector3Array()
	_call("add_snow_trail", [flat])


# Column order: id author at points. Ours (walked here, already in our snow) count as pressed; on joining, ours from
# before are pressed like anyone's
func _trail_row(r: Dictionary) -> void:
	if r.has("_array"):
		var a: Array = r._array
		r = {"id": a[0], "author": a[1], "at": a[2], "points": a[3]}
	var ts = r.at
	var micros: float = float(ts.values()[0]) if ts is Dictionary else (float(ts[0]) if ts is Array else float(ts))
	var pts := PackedVector3Array()
	var flat: Array = r.points
	var center := _player._center()
	var sum := Vector3.ZERO
	for i in range(0, flat.size() - 2, 3):
		pts.append(center + Vector3(flat[i], flat[i + 1], flat[i + 2]))
		sum += pts[-1]
	if pts.is_empty():
		return
	var mid := sum / pts.size()
	var radius := 0.0
	for pt in pts:
		radius = maxf(radius, pt.distance_to(mid))
	trails[int(r.id)] = {"at": micros / 1e6, "points": pts, "center": mid, "radius": radius,
			"near": _id(r.author) == identity and status == "online"}


# A trail coming within range is pressed in as deep as it still is for its age (snow_trail_lifetime: the clock runs
# from when it was walked, not from when we got here); from then on our snow fades it like everyone else's. Out of
# range it's forgotten (our trail map only covers ~30 m round us) and pressed again on coming back.
func _press_near_trails() -> void:
	var amb: Node = _player._ambience
	if amb == null or trails.is_empty():
		return
	var lifetime: float = amb.get("snow_trail_lifetime")
	var now := Time.get_unix_time_from_system()
	var me := _player.global_position
	for id in trails:
		var t: Dictionary = trails[id]
		var near: bool = t.center.distance_to(me) - t.radius < TRAIL_RANGE
		if near and not t.near:
			var depth: float = 1.0 - (now - float(t.at)) / lifetime if lifetime > 0.0 else 1.0
			if depth > 0.0:
				for pt in t.points:
					if pt.distance_to(me) < TRAIL_RANGE:
						amb.press_snow(pt, 0.4, depth)
		t.near = near


func _edit_row(r: Dictionary) -> void:
	if r.has("_array"): # column order: id author x y z radius mode material
		var a: Array = r._array
		r = {"author": a[1], "x": a[2], "y": a[3], "z": a[4], "radius": a[5], "mode": a[6], "material": a[7]}
	if _id(r.author) == identity and status == "online":
		return # made here (already applied); on joining, our own earlier edits are replayed like anyone's
	if _player.miner:
		_player.miner.apply_edit(_player._center() + Vector3(r.x, r.y, r.z), float(r.radius), int(r.mode), int(r.material))
		edits_applied += 1
		last_edit_position = _player._center() + Vector3(r.x, r.y, r.z)
