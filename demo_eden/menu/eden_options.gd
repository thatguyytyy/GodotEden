class_name EdenOptions
## Player options kept in user://options.cfg: profile, controls and audio (graphics are EdenGraphics', in
## user://graphics.cfg). Loaded at startup by EdenApp; EdenPlayer reads them when it starts, and the options screen
## saves on every change.

const PATH := "user://options.cfg"

static var player_name := "Explorer"
## Multiplies EdenPlayer.mouse_sensitivity
static var mouse_sensitivity := 1.0
static var invert_y := false
static var fov := 75.0
static var master_volume := 0.8
static var show_help := true

static var _loaded := false


static func load_options() -> void:
	_loaded = true
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	player_name = str(cfg.get_value("profile", "name", player_name))
	mouse_sensitivity = float(cfg.get_value("controls", "mouse_sensitivity", mouse_sensitivity))
	invert_y = bool(cfg.get_value("controls", "invert_y", invert_y))
	fov = float(cfg.get_value("controls", "fov", fov))
	master_volume = float(cfg.get_value("audio", "master", master_volume))
	show_help = bool(cfg.get_value("interface", "show_help", show_help))


static func save_options() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("profile", "name", player_name)
	cfg.set_value("controls", "mouse_sensitivity", mouse_sensitivity)
	cfg.set_value("controls", "invert_y", invert_y)
	cfg.set_value("controls", "fov", fov)
	cfg.set_value("audio", "master", master_volume)
	cfg.set_value("interface", "show_help", show_help)
	cfg.save(PATH)


static func ensure_loaded() -> void:
	if not _loaded:
		load_options()


## What can be applied globally (the rest is read by EdenPlayer)
static func apply() -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(master_volume, 0.0001)))
	AudioServer.set_bus_mute(0, master_volume <= 0.001)


## A player name the server accepts (1-24 characters)
static func valid_name(n: String) -> String:
	n = n.strip_edges().left(24)
	return n if n != "" else "Explorer"
