extends Node
## Autoload (EdenApp): what the whole game needs whatever scene runs. Loads the player's options, loads mods
## (resource packs in user://mods not switched off in the Mods screen), goes back to the main menu, and stops a
## SpacetimeDB server the game started when it quits (window closed or Quit).

const MENU_SCENE := "res://menu/main_menu.tscn"
const PLAY_SCENE := "res://eden_play.tscn"
const MODS_DIR := "user://mods"
const MODS_CFG := "user://mods.cfg"

## Packs loaded this run: file name -> true
var loaded_mods := {}


func _ready() -> void:
	get_tree().auto_accept_quit = false
	EdenOptions.load_options()
	EdenOptions.apply()
	load_mods()
	_follow_steam.call_deferred() # (EdenSteam is the next autoload)


## A Steam lobby joined (an invite, or the Play screen's Steam list): into its world, from wherever we are
func _follow_steam() -> void:
	var steam := get_node_or_null("/root/EdenSteam")
	if steam:
		steam.world_ready_to_join.connect(func(): get_tree().change_scene_to_file(PLAY_SCENE))


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		quit()


func quit() -> void:
	_leave_steam()
	EdenWorlds.stop_local_server()
	var tele := get_node_or_null("/root/EdenTelemetry")
	if tele:
		await tele.clean_exit()
	get_tree().quit()


func main_menu() -> void:
	_leave_steam()
	EdenSession.active = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file(MENU_SCENE)


func _leave_steam() -> void:
	var steam := get_node_or_null("/root/EdenSteam")
	if steam:
		steam.leave()


# ------------------------------------------------------------------------------------------------------------
# Mods: resource packs (.pck / .zip) that add or replace res:// files

## [{file, enabled, loaded}]
static func mods() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	DirAccess.make_dir_recursive_absolute(MODS_DIR)
	var off := _disabled()
	var app = Engine.get_main_loop().root.get_node_or_null("EdenApp") if Engine.get_main_loop() else null
	for f in DirAccess.get_files_at(MODS_DIR):
		if f.get_extension().to_lower() in ["pck", "zip"]:
			out.append({"file": f, "enabled": not off.has(f), "loaded": app != null and app.loaded_mods.has(f)})
	return out


static func set_mod_enabled(file: String, on: bool) -> void:
	var off := _disabled()
	if on:
		off.erase(file)
	elif not off.has(file):
		off.append(file)
	var cfg := ConfigFile.new()
	cfg.set_value("mods", "disabled", off)
	cfg.save(MODS_CFG)


static func _disabled() -> Array:
	var cfg := ConfigFile.new()
	return cfg.get_value("mods", "disabled", []) if cfg.load(MODS_CFG) == OK else []


func load_mods() -> void:
	for m in mods():
		if m.enabled and ProjectSettings.load_resource_pack(MODS_DIR.path_join(m.file)):
			loaded_mods[m.file] = true
			print("EdenApp: loaded mod ", m.file)
