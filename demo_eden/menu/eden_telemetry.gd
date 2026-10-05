extends Node
## Autoload (EdenTelemetry): anonymous diagnostics for the developer's dashboard (Projects/eden-telemetry). Sends PC specs
## once per run, a performance summary every 30 s (average/min FPS, 99th-percentile frame time, hitches, memory),
## hitches and error-log lines in batches, and, when the previous run never exited cleanly, that run's log tail
## as a crash report. The main menu and the game world are measured apart: each time the scene changes between them a
## new session starts ("<run>-menu1", "<run>-game2", ...), so menu frame rates never blend into the world's, and a crash is
## attributed to the one it happened in. Identified only by a random install id; players switch it off in Settings
## (or the launcher's menu).
## Shared with the launcher through %APPDATA%/EdenProject/telemetry.json: {enabled, install_id}.
## Off in the editor unless run with `-- --telemetry`.

const URL := "https://edenprojectgame.com/t"
const REPORT_EVERY := 30.0
const FLUSH_EVERY := 60.0
const HITCH_MS := 100.0
const LOG_TAIL := 60_000
const MARKER := "user://telemetry_running.json"

## A new session's first seconds (loading the world, building the menu) aren't measured
const SEGMENT_GRACE_MS := 4000

var enabled := true
var install_id := ""
## The current session ("" until the first scene is known) and what it measures: "menu" or "game"
var session_id := ""
var context := ""

var _run_id := ""
var _seg_n := 0
var _seg_ms := 0
var _ctx_t := 0.0
var _pending := 0 # reports sent and not yet answered
var _url := URL
var _hitches: Array[Dictionary] = []
var _hitch_count := 0
var _errors := {} # message -> count; filled from the engine's logger thread
var _lock := Mutex.new()
var _frames := 0
var _time := 0.0
var _buckets := PackedInt32Array() # frame-time histogram, 1 ms steps, last bucket is 500 ms+
var _min_fps := 0.0
var _win_frames := 0
var _win_t := 0.0
var _report_t := REPORT_EVERY
var _flush_t := FLUSH_EVERY
var _version := ""


class ErrorLogger extends Logger:
	var owner_node: Node

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _bt: Array[ScriptBacktrace]) -> void:
		var kind: String = ["ERROR", "WARNING", "SCRIPT", "SHADER"][clampi(error_type, 0, 3)]
		if kind != "WARNING":
			owner_node.note_error("%s %s:%d (%s) %s" % [kind, file.get_file(), line, function, rationale if rationale != "" else code])


static func settings_path() -> String:
	return OS.get_data_dir().path_join("EdenProject/telemetry.json")


## {enabled, install_id}; creates the file with a fresh id the first time
static func load_settings() -> Dictionary:
	var d = null
	if FileAccess.file_exists(settings_path()):
		d = JSON.parse_string(FileAccess.get_file_as_string(settings_path()))
	if not d is Dictionary:
		d = {}
	if str(d.get("install_id", "")) == "":
		d.install_id = Crypto.new().generate_random_bytes(12).hex_encode()
	d.enabled = bool(d.get("enabled", true))
	return d


static func save_settings(d: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(settings_path().get_base_dir())
	var f := FileAccess.open(settings_path(), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"enabled": d.enabled, "install_id": d.install_id}))


func set_enabled(on: bool) -> void:
	enabled = on
	save_settings({"enabled": on, "install_id": install_id})
	set_process(on and _active())


func _active() -> bool:
	return enabled and (not OS.has_feature("editor") or OS.get_cmdline_user_args().has("--telemetry"))


func _ready() -> void:
	if "--server" in OS.get_cmdline_user_args(): # the dedicated server (server/eden_server.gd) isn't a player
		set_process(false)
		enabled = false
		return
	var s := load_settings()
	install_id = s.install_id
	enabled = s.enabled
	save_settings(s)
	process_mode = Node.PROCESS_MODE_ALWAYS
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--telemetry-url="):
			_url = a.trim_prefix("--telemetry-url=")
	if not _active():
		set_process(false)
		return
	_version = str(ProjectSettings.get_setting("application/config/version", "dev"))
	_run_id = Crypto.new().generate_random_bytes(8).hex_encode()
	_buckets.resize(501)
	var lg := ErrorLogger.new()
	lg.owner_node = self
	OS.add_logger(lg)
	_report_previous_crash()
	_write_marker()
	_send({"kind": "hello", "specs": _specs(), "game_version": _version})


func note_error(msg: String) -> void: # (any thread)
	_lock.lock()
	if _errors.size() < 200 or _errors.has(msg):
		_errors[msg] = int(_errors.get(msg, 0)) + 1
	_lock.unlock()


## "menu" or "game" for the scene that is running, "" for anything else (the current session carries on)
func _context_now() -> String:
	var scene := get_tree().current_scene
	if scene == null:
		return ""
	var path := scene.scene_file_path
	if "main_menu" in path:
		return "menu"
	if "eden_play" in path:
		return "game"
	return ""


## Closes the session that was running (its last numbers and events go out under its own id) and starts the next
func _switch_context(c: String) -> void:
	if context != "":
		_flush()
		if _frames >= 30:
			_send(_perf(true))
	context = c
	_seg_n += 1
	session_id = "%s-%s%d" % [_run_id, c, _seg_n]
	_frames = 0
	_time = 0.0
	_buckets.fill(0)
	_min_fps = 0.0
	_win_frames = 0
	_win_t = 0.0
	_hitch_count = 0
	_hitches.clear()
	_report_t = REPORT_EVERY
	_flush_t = FLUSH_EVERY
	_seg_ms = Time.get_ticks_msec()
	_write_marker()


func _process(delta: float) -> void:
	_ctx_t -= delta
	if _ctx_t <= 0.0:
		_ctx_t = 0.25
		var c := _context_now()
		if c != "" and c != context:
			_switch_context(c)
	if context == "" or Time.get_ticks_msec() < 8000 or Time.get_ticks_msec() - _seg_ms < SEGMENT_GRACE_MS:
		return # (start-up and loading are slow by nature)
	_frames += 1
	_time += delta
	_buckets[mini(int(delta * 1000.0), 500)] += 1
	_win_frames += 1
	_win_t += delta
	if _win_t >= 1.0:
		var fps := _win_frames / _win_t
		_min_fps = fps if _min_fps == 0.0 else minf(_min_fps, fps)
		_win_frames = 0
		_win_t = 0.0
	if delta * 1000.0 > HITCH_MS and get_window().has_focus() and _hitches.size() < 20:
		_hitch_count += 1
		_hitches.append({"ms": snappedf(delta * 1000.0, 0.1), "scene": context, "at_s": snappedf(_time, 0.1)})
	elif delta * 1000.0 > HITCH_MS and get_window().has_focus():
		_hitch_count += 1
	_report_t -= delta
	if _report_t <= 0.0:
		_report_t = REPORT_EVERY
		_send(_perf(false))
	_flush_t -= delta
	if _flush_t <= 0.0:
		_flush_t = FLUSH_EVERY
		_flush()


func _perf(clean: bool) -> Dictionary:
	var count := 0
	for b in _buckets:
		count += b
	var p99 := 0
	var acc := 0
	for i in _buckets.size():
		acc += _buckets[i]
		if acc >= count * 0.99:
			p99 = i
			break
	return {"kind": "perf", "ended_clean": clean, "game_version": _version, "avg_fps": _frames / maxf(_time, 0.001) if _frames > 0 else 0.0,
			"min_fps": _min_fps, "p99_ms": p99, "hitches": _hitch_count, "mem_mb": _system_ram_used_mb(), # (the engine's own counter reads 0 in release builds)
			"scene": context}


## RAM in use on the whole machine
func _system_ram_used_mb() -> float:
	var m := OS.get_memory_info()
	return maxf(0.0, float(m.get("physical", 0)) - float(m.get("free", 0))) / 1048576.0


func _flush() -> void:
	if not _hitches.is_empty():
		_send({"kind": "hitch", "data": JSON.stringify(_hitches)})
		_hitches.clear()
	_lock.lock()
	var errs := _errors
	_errors = {}
	_lock.unlock()
	if not errs.is_empty():
		var lines := []
		for m in errs:
			lines.append("x%d %s" % [errs[m], m])
		_send({"kind": "error", "data": "\n".join(lines.slice(0, 50))})


## Called by EdenApp.quit(): the run ended normally
func clean_exit() -> void:
	if not _active():
		return
	_flush()
	if context != "" and _frames >= 30:
		_send(_perf(true))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(MARKER))
	# let the last reports leave before the process ends (a fixed short wait lost the final one when the game was busy)
	var waited := 0.0
	while _pending > 0 and waited < 1.5:
		await get_tree().create_timer(0.05).timeout
		waited += 0.05


func _write_marker() -> void:
	var f := FileAccess.open(MARKER, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"run": _run_id, "session": session_id, "context": context}))


## A leftover marker means the previous run died: report it with that run's log
func _report_previous_crash() -> void:
	if not FileAccess.file_exists(MARKER):
		return
	var m = JSON.parse_string(FileAccess.get_file_as_string(MARKER))
	# (the session that was running; a run that died before any scene was known only has its run id)
	var prev := (str(m.get("session", "")) if str(m.get("session", "")) != "" else str(m.get("run", ""))) if m is Dictionary else ""
	if prev == "":
		return
	var newest := ""
	var newest_t := 0
	for f in DirAccess.get_files_at("user://logs"):
		if f == "godot.log": # this run's
			continue
		var t := FileAccess.get_modified_time("user://logs/" + f)
		if t > newest_t:
			newest_t = t
			newest = f
	var text := ""
	if newest != "":
		var lf := FileAccess.open("user://logs/" + newest, FileAccess.READ)
		if lf:
			var n := lf.get_length()
			lf.seek(maxi(0, n - LOG_TAIL))
			text = lf.get_buffer(mini(n, LOG_TAIL)).get_string_from_utf8()
	_send({"kind": "crashed", "session": prev})
	_send({"kind": "crash", "session": prev, "data": text if text != "" else "(no log found)"})


func _specs() -> Dictionary:
	var mem := OS.get_memory_info()
	var scr := DisplayServer.screen_get_size()
	return {
		"os": "%s %s" % [OS.get_name(), OS.get_version()],
		"cpu": OS.get_processor_name(), "cores": OS.get_processor_count(),
		"gpu": RenderingServer.get_video_adapter_name(), "gpu_vendor": RenderingServer.get_video_adapter_vendor(),
		"gpu_api": RenderingServer.get_video_adapter_api_version(), "gpu_driver": str(OS.get_video_adapter_driver_info()),
		"ram_gb": snappedf(float(mem.get("physical", 0)) / 1073741824.0, 0.5),
		"screen": "%dx%d @%dHz" % [scr.x, scr.y, int(DisplayServer.screen_get_refresh_rate())],
		"locale": OS.get_locale(), "renderer": RenderingServer.get_current_rendering_method(),
	}


## Fire and forget; telemetry must never get in the player's way, so failures are dropped
func _send(body: Dictionary) -> void:
	if not body.has("session"):
		body.session = session_id
	body.install = install_id
	var req := HTTPRequest.new()
	req.timeout = 10.0
	add_child(req)
	_pending += 1
	req.request_completed.connect(func(_r, _c, _h, _b):
		_pending -= 1
		req.queue_free())
	if req.request(_url, ["Content-Type: application/json", "User-Agent: EdenGame/" + _version], HTTPClient.METHOD_POST, JSON.stringify(body, "", true, true)) != OK:
		_pending -= 1
		req.queue_free()
