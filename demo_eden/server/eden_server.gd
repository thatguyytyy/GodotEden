extends Node
## The dedicated world server's agent (run headless: `godot --headless --main-pack eden.pck res://server/eden_server.tscn
## -- --stdb=ws://127.0.0.1:3180 --db=eden-test`). It joins the world as the server's admin identity, the world's owner,
## so the game's host rules apply unchanged: the world stays up with it online, and it is the one who sets the weather.
## It simulates the roaming storms with EdenWeatherServer (no terrain, camera or rendering) and sends them every
## WEATHER_INTERVAL seconds; every client shows the server's storms. If the connection drops it reconnects.
##
## Options (after --): --stdb=<ws url> --db=<database> --name=<display name> --cli-config=<spacetime cli.toml, whose
## spacetimedb_token is this identity's> or --token=<token> --warmup=<weather seconds before the first send>

const PROTOCOL := "v1.json.spacetimedb"
const WEATHER_INTERVAL := 5.0 # as EdenNet's

var stdb := "ws://127.0.0.1:3180"
var database := "eden-test"
var display_name := "Server"
var token := ""
var warmup := 900.0

var _ws := WebSocketPeer.new()
var _weather: Node
var _request := 0
var _online := false
var _retry := 0.0
var _backoff := 2.0
var _weather_t := 0.0
var _beat_t := 60.0
var _sent := 0


func _ready() -> void:
	var cfg := OS.get_environment("HOME").path_join(".config/spacetime/cli.toml")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--stdb="):
			stdb = a.trim_prefix("--stdb=").trim_suffix("/")
		elif a.begins_with("--db="):
			database = a.trim_prefix("--db=")
		elif a.begins_with("--name="):
			display_name = a.trim_prefix("--name=")
		elif a.begins_with("--token="):
			token = a.trim_prefix("--token=")
		elif a.begins_with("--cli-config="):
			cfg = a.trim_prefix("--cli-config=")
		elif a.begins_with("--warmup="):
			warmup = float(a.trim_prefix("--warmup="))
	if token == "":
		token = _token_from(cfg)
	if token == "":
		_log("no token: pass --token= or --cli-config= (the spacetime CLI's cli.toml)")
		get_tree().quit(2)
		return
	if not ClassDB.class_exists("EdenWeatherServer"):
		_log("EdenWeatherServer isn't in this build")
		get_tree().quit(3)
		return
	_weather = ClassDB.instantiate("EdenWeatherServer")
	add_child(_weather)
	_weather.warm_up(warmup)
	_connect()


func _token_from(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	for line in FileAccess.get_file_as_string(path).split("\n"):
		line = line.strip_edges()
		if line.begins_with("spacetimedb_token"):
			return line.get_slice("=", 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
	return ""


func _log(msg: String) -> void:
	printerr("[eden-server] %s" % msg) # (stderr: stdout is silent when running from a pack; journald keeps stderr and timestamps it)


func _connect() -> void:
	_ws = WebSocketPeer.new()
	_ws.supported_protocols = PackedStringArray([PROTOCOL])
	_ws.inbound_buffer_size = 1 << 22
	_ws.handshake_headers = PackedStringArray(["Authorization: Bearer " + token])
	var err := _ws.connect_to_url("%s/v1/database/%s/subscribe" % [stdb, database])
	_log("connecting to %s/%s%s" % [stdb, database, "" if err == OK else " (failed: %s)" % error_string(err)])


func _process(delta: float) -> void:
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			while _ws.get_available_packet_count() > 0:
				_on_message(_ws.get_packet().get_string_from_utf8())
			if _online:
				_weather_t -= delta
				if _weather_t <= 0.0:
					_weather_t = WEATHER_INTERVAL
					_call("set_weather", [Array(_weather.get_weather_state())])
					_sent += 1
		WebSocketPeer.STATE_CLOSED:
			if _online:
				_log("connection closed (%d %s)" % [_ws.get_close_code(), _ws.get_close_reason()])
				_online = false
			_retry -= delta
			if _retry <= 0.0:
				_retry = _backoff
				_backoff = minf(_backoff * 2.0, 30.0)
				_connect()
	_beat_t -= delta
	if _beat_t <= 0.0:
		_beat_t = 60.0
		_log("%s, %d weather updates sent" % ["online" if _online else "offline", _sent])


func _call(reducer: String, args: Array) -> void:
	_request += 1
	_ws.send_text(JSON.stringify({"CallReducer": {
		"reducer": reducer, "args": JSON.stringify(args, "", true, true), "request_id": _request, "flags": 0}}))


func _on_message(text: String) -> void:
	var msg = JSON.parse_string(text)
	if not msg is Dictionary:
		return
	if msg.has("IdentityToken"):
		_request += 1
		_ws.send_text(JSON.stringify({"Subscribe": {"query_strings": ["SELECT * FROM world_meta"], "request_id": _request}}))
		_call("set_name", [display_name])
		_online = true
		_backoff = 2.0
		_weather_t = 0.0
		_log("online as %s" % str(msg.IdentityToken.get("identity", "")).left(14))
	elif msg.has("InitialSubscription"):
		_world_meta(msg.InitialSubscription.database_update)
	elif msg.has("TransactionUpdate"):
		var st = msg.TransactionUpdate.get("status", {})
		if st is Dictionary and st.has("Committed"):
			_world_meta(st.Committed)
		elif st is Dictionary and st.has("Failed"):
			_log("reducer %s failed: %s" % [msg.TransactionUpdate.get("reducer_call", {}).get("reducer_name", "?"), str(st.Failed).split("\n")[0]])
	elif msg.has("TransactionUpdateLight"):
		_world_meta(msg.TransactionUpdateLight.update)


# The world's seed picks this world's storms (world_meta columns: id name seed owner created_at settings)
func _world_meta(db_update: Dictionary) -> void:
	for table in db_update.get("tables", []):
		if table.table_name != "world_meta":
			continue
		for qu in table.get("updates", []):
			var u: Dictionary = qu.get("Uncompressed", qu) if qu is Dictionary else {}
			for r in u.get("inserts", []):
				var row = JSON.parse_string(r) if r is String else r
				var seed_v: int = int(row[2] if row is Array else row.get("seed", 1))
				if _weather.weather_seed != seed_v % 100001:
					_weather.weather_seed = seed_v % 100001
					_weather.warm_up(warmup)
					_log("world seed %d: storms reseeded" % seed_v)
