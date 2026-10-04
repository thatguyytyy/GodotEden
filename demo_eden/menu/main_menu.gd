@tool
class_name EdenMainMenu
extends Node3D
## The main menu: the planet from orbit behind a title and five buttons (Play, Options, Schematica, Mods, Quit).
## The background is the real planet (the probe scene: V4 terrain, atmosphere, clouds, ocean, rings, space) with
## its player and cameras taken out. The camera is placed each frame so the planet fills the left of the screen and
## the (real) moon hangs beside the title; the moon is held near full, opposite the sun, so the side of the planet
## we see is in daylight. As the calendar runs the sun, moon, stars and panorama turn round the planet; the planet and camera stay put.
##   Play        EdenPlayScreen: worlds on SpacetimeDB servers (join, host, delete), or the offline sandbox
##   Options     EdenSettingsMenu (graphics, controls, audio, profile)
##   Schematica  what it will be (design gear and planets before playing; design/gdd/schematica-system.md)
##   Mods        resource packs in user://mods, on or off (EdenApp loads them at startup)
## In the editor the planet and sky are built too (not saved into the scene): select MenuCamera and tick Preview to
## see the menu's framing. The buttons and music only run in the game (F6).

const WORLD_SCENE := "res://_ocean_editor_probe.tscn"
const PLAY_SCENE := "res://eden_play.tscn"
## Camera distance from the planet's centre, in planet radii
@export var orbit_distance := 4.1
## Where the planet's centre and the moon sit on screen (fractions of its width and height)
@export var planet_screen := Vector2(0.22, 0.46)
@export var moon_screen := Vector2(0.8, 0.45)
## The moon's phase held in the menu (0.5 full, opposite the sun) and its size
@export var moon_phase := 0.5
@export var moon_angular_radius := 0.045
## Roll of the view round the moon (radians): turns the rings' sweep across the screen
@export var roll := -0.68
## The terrain's LOD distance in the menu. The camera is ~120 km out: at the scene's 128 m it meshes the planet from
## ~1 km voxels, and coastal sea floor pokes through the ocean. Measured (menu/_menu_capture.gd --lod=, GTX 750 Ti,
## 1080p, settled): 128 -> 13.2 ms/frame; 1024 -> 14.7 ms, detail like the finest; 512 keeps hitching (up to 300 ms)
## as a moving camera drags a LOD boundary across the planet.
@export var terrain_lod_distance := 1024.0
@export var ring_tint := Color(0.82, 0.9, 1.0)
@export var ring_opacity := 0.75
## Seconds the camera takes to move between the screens' views
@export var view_time := 1.8

## The camera's view on each screen (the main one is the settings above): planet radii out, where the planet's
## centre and the moon sit on screen (off-screen is fine: a horizon), roll round the moon. The screens' panels sit in
## the middle, so the planet frames them.
const VIEWS := {
	# The whole planet beside the Play panel (which takes the left of the screen), the moon high on the right
	"play": {"orbit_distance": 4.1, "planet_screen": Vector2(0.78, 0.52), "moon_screen": Vector2(0.93, 0.12), "roll": 0.0},
	# Close, filling the right side
	"options": {"orbit_distance": 2.0, "planet_screen": Vector2(1.05, 0.55), "moon_screen": Vector2(0.08, 0.2),
		"roll": -1.2},
	# Far out: the whole planet small in the corner with its rings, the moon across the sky
	"schematica": {"orbit_distance": 7.0, "planet_screen": Vector2(0.14, 0.24), "moon_screen": Vector2(0.86, 0.78),
		"roll": 0.5},
	# Close, rising from the bottom left
	"mods": {"orbit_distance": 1.8, "planet_screen": Vector2(-0.1, 1.1), "moon_screen": Vector2(0.86, 0.18),
		"roll": -0.3},
}

var world: Node3D
var camera: Camera3D
var _terrain: Node3D
var _radius := 40000.0
var _orbit_axis := Vector3.UP
var _atmosphere: Node
var _time := 0.0
var _ref_moon := Vector3.ZERO
var _ui: Control
var _buttons: VBoxContainer
var _title: Control
var _screen: Control
var _options: EdenSettingsMenu
var _graphics: EdenGraphics
var _loading: Label
var _loading_box: VBoxContainer
var _loading_bar: EdenLoadingBar
## The menu planet's generator as first built: previews copy it
var _base_gen: Resource
var _preview_id := 0
var _views := VIEWS.duplicate()
var _view := "main"
var _view_tween: Tween


func _ready() -> void:
	_views["main"] = {"orbit_distance": orbit_distance, "planet_screen": planet_screen, "moon_screen": moon_screen,
			"roll": roll}
	if Engine.is_editor_hint():
		if world == null:
			_build_world()
		return
	EdenOptions.ensure_loaded()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build_world()
	_build_ui()
	var music := get_node_or_null("/root/EdenMusic")
	if music:
		music.play_menu()


# ------------------------------------------------------------------------------------------------------------
# The planet behind the menu

func _build_world() -> void:
	world = load(WORLD_SCENE).instantiate()
	# The menu drives the view: no player, no editor cameras or their terrain viewers, no ambient sound
	for n in world.find_children("*", "", true, false):
		if n is EdenPlayer or n is Camera3D:
			n.get_parent().remove_child(n)
			n.queue_free()
	for n in world.find_children("*", "EdenAmbience", true, false):
		n.set("volume_db", -80.0) # (it keeps running: the weather, snow and wind the planet shows come from it)
	# The rings pale ice, as on the menu art
	for n in world.find_children("*", "EdenPlanetRings", true, false):
		n.set("ring_tint", ring_tint)
		n.set("ring_opacity", ring_opacity)
	_terrain = world.find_children("*", "VoxelLodTerrain", true, false)[0]
	var gen = _terrain.get("generator")
	if gen and gen.get("planet_radius"):
		_radius = gen.planet_radius
	# A new random planet and sky every time the menu opens (the parent planet stays out of the menu view). Set
	# before the world enters the tree so the terrain streams the right planet from the start. On a copy of the
	# generator: the probe scene's own (shared, cached) one keeps its seed.
	var menu_seed := randi()
	if gen:
		gen = gen.duplicate()
		gen.seed = menu_seed
		_terrain.set("generator", gen)
		_base_gen = gen.duplicate()
	EdenSkyBodies.apply_world(world, menu_seed, false)
	_terrain.set("lod_distance", terrain_lod_distance)
	# The far field's disk cache is keyed by sector, not by planet: a random planet would load another's far terrain
	_terrain.set("far_cache_enabled", false)
	# Far results are only uploaded between near-terrain updates, which take ~2 s each after the Play screen swaps the
	# planet: at the default few per upload the new planet's far field took over a minute to fill in. All of them at once.
	_terrain.set("far_max_uploads_per_frame", 256)
	add_child(world)
	for n in world.find_children("*", "EdenGraphics", true, false):
		_graphics = n
	for rings in world.find_children("*", "EdenPlanetRings", true, false):
		_orbit_axis = (rings as Node3D).global_basis.y.normalized() # the view's "up": the rings sweep across it
	for a in world.find_children("*", "EdenPlanetAtmosphere", true, false):
		_atmosphere = a
		a.set("advance_moon_phase", false)
		a.set("moon_phase", moon_phase)
		a.set("moon_angular_radius", moon_angular_radius)
		# Seen from space, not through a night sky: full brightness, a crisp edge, no halo or light rays
		a.set("moon_intensity", 0.65)
		a.set("moon_tint", Color(1.0, 0.97, 0.92))
		a.set("moon_glow_intensity", 0.0)
		# Stars are hidden out to 6x the glow's size round the moon (for its glow); with no glow, only under the disc
		a.set("moon_glow_size", moon_angular_radius / 6.0)
		a.set("moon_ray_intensity", 0.0)
	camera = get_node_or_null("MenuCamera")
	if camera == null:
		camera = Camera3D.new()
		add_child(camera)
	camera.near = 20.0
	camera.far = _radius * 20.0
	camera.fov = 40.0 # (narrow: a wide lens stretches the moon near the screen edge)
	var viewer := VoxelViewer.new()
	viewer.view_distance = int(_radius * 4.0)
	camera.add_child(viewer)
	if not Engine.is_editor_hint():
		camera.make_current()
	_place_camera()


## Shows the planet a world would have (its seed and EdenWorldSettings) behind the Play screen. Waits a moment so
## typing a seed or flicking through options meshes only the last one.
func preview_world(world_seed: int, settings: Dictionary) -> void:
	_preview_id += 1
	var id := _preview_id
	await get_tree().create_timer(0.4).timeout
	if id != _preview_id or _base_gen == null:
		return
	var gen := _base_gen.duplicate()
	gen.seed = world_seed
	EdenWorldSettings.apply(gen, settings)
	_terrain.set("generator", gen)
	EdenSkyBodies.apply_world(world, world_seed, false)


## The moon's direction from the planet (it follows the sun: the phase is held)
func _moon_direction() -> Vector3:
	var m: Vector3 = _atmosphere.get("moon_direction") if _atmosphere else Vector3.ZERO
	return m.normalized() if m.length_squared() > 0.5 else Vector3(0.3, 0.4, -1.0).normalized()


## The camera-space direction through a point of the screen (fractions of width and height)
func _screen_dir(at: Vector2) -> Vector3:
	var size := get_viewport().get_visible_rect().size
	var t := tan(deg_to_rad(camera.fov) * 0.5)
	return Vector3((at.x * 2.0 - 1.0) * t * size.x / size.y, (1.0 - at.y * 2.0) * t, -1.0).normalized()


## Turns the camera so the moon (where it was at start) falls on moon_screen (the rest of its roll from the rings' axis),
## then backs it off so the planet's centre falls on planet_screen
func _place_camera() -> void:
	# Framed against the moon's direction at start, then locked to the planet: the sky (sun, moon, stars, panorama)
	# turns around it, and the terrain viewer never moves, so the LODs don't re-mesh.
	if _ref_moon == Vector3.ZERO:
		_ref_moon = _moon_direction()
	var m := _ref_moon
	var up := _orbit_axis.rotated(m, roll)
	var cam := _frame(_screen_dir(moon_screen), Vector3.UP)
	var world_frame := _frame(m, up)
	var basis := world_frame * cam.inverse()
	camera.global_basis = basis.orthonormalized()
	camera.global_position = _terrain.global_position - basis * _screen_dir(planet_screen) * _radius * orbit_distance


## An orthonormal frame with `forward` as its first axis and `up` (made perpendicular) as its second
static func _frame(forward: Vector3, up: Vector3) -> Basis:
	var f := forward.normalized()
	var u := (up - f * up.dot(f)).normalized()
	return Basis(f, u, f.cross(u))


## Eases the camera to a view: its distance, where the planet's centre and the moon sit on screen, its roll
func _go_to_view(view: String) -> void:
	if not _views.has(view) or view == _view:
		return
	_view = view
	if _view_tween:
		_view_tween.kill()
	_view_tween = create_tween().set_parallel().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	for k in _views[view]:
		_view_tween.tween_property(self, k, _views[view][k], view_time)


func _process(delta: float) -> void:
	_time += delta
	_place_camera()


# ------------------------------------------------------------------------------------------------------------
# UI

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_ui = Control.new()
	_ui.theme = EdenUITheme.theme()
	_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_ui)

	# Title, moon and buttons in a column on the right, as on the menu art
	var column := VBoxContainer.new()
	column.anchor_left = 0.62
	column.anchor_right = 0.98
	column.anchor_top = 0.14
	column.anchor_bottom = 0.92
	column.add_theme_constant_override("separation", 18)
	_ui.add_child(column)
	_title = VBoxContainer.new()
	_title.add_theme_constant_override("separation", 22)
	var eden := EdenUITheme.title("EDEN", 104)
	eden.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_title.add_child(eden)
	var project := EdenUITheme.title("PROJECT", 88)
	project.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_title.add_child(project)
	column.add_child(_title)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(spacer)
	_buttons = VBoxContainer.new()
	_buttons.add_theme_constant_override("separation", 24)
	_buttons.size_flags_horizontal = Control.SIZE_SHRINK_END
	column.add_child(_buttons)
	for b in [["PLAY", _show_play], ["OPTIONS", _show_options], ["SCHEMATICA", _show_schematica], ["MODS", _show_mods], ["QUIT", _quit]]:
		var button := Button.new()
		button.name = b[0]
		button.text = b[0]
		button.custom_minimum_size = Vector2(390, 0)
		button.add_theme_font_size_override("font_size", 24)
		button.pressed.connect(b[1])
		_buttons.add_child(button)

	var version := Label.new()
	version.text = "EDEN DEMO  %s" % Engine.get_version_info().string
	version.add_theme_font_size_override("font_size", 10)
	version.add_theme_color_override("font_color", Color(EdenUITheme.CREAM, 0.5))
	version.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	version.position = Vector2(16, -26)
	_ui.add_child(version)

	_loading_box = VBoxContainer.new()
	_loading_box.add_theme_constant_override("separation", 20)
	_loading_box.set_anchors_preset(Control.PRESET_CENTER)
	_loading_box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_loading_box.grow_vertical = Control.GROW_DIRECTION_BOTH
	_loading_box.visible = false
	_ui.add_child(_loading_box)
	_loading = Label.new()
	_loading.add_theme_font_size_override("font_size", 32)
	_loading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_box.add_child(_loading)
	_loading_bar = EdenLoadingBar.new()
	_loading_box.add_child(_loading_bar)

	_options = EdenSettingsMenu.new()
	add_child(_options)
	_options.setup(_graphics, false)
	_options.closed.connect(func(): _set_screen(null))

	if EdenSession.notice != "": # why we're back here (the host left...)
		var dialog := AcceptDialog.new()
		dialog.title = "Left the world"
		dialog.dialog_text = EdenSession.notice
		EdenSession.notice = ""
		_ui.add_child(dialog)
		dialog.popup_centered.call_deferred()


## Shows a screen (or the buttons again for null), centred over the menu, and moves the camera to its view
func _set_screen(screen: Control, view := "main") -> void:
	_go_to_view(view)
	if _screen and _screen != screen:
		_screen.queue_free()
	_screen = screen
	_buttons.visible = screen == null and not _options.visible
	_title.visible = _buttons.visible
	if screen:
		var center := CenterContainer.new()
		center.set_anchors_preset(Control.PRESET_FULL_RECT)
		if view == "play":
			center.anchor_right = 0.62 # (the planet fills the rest)
		center.add_child(screen)
		_ui.add_child(center)
		_screen = center


func _show_play() -> void:
	var play := EdenPlayScreen.new()
	play.back.connect(func(): _set_screen(null))
	play.play.connect(_start_game)
	play.preview.connect(preview_world)
	_set_screen(play, "play")
	play.refresh()


func _show_options() -> void:
	_options.open()
	_set_screen(null, "options")


func _show_schematica() -> void:
	var p := _panel("SCHEMATICA", 820)
	var text := Label.new()
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.custom_minimum_size.x = 740
	text.text = "Design before you play.\n\nSchematica is where you will design gear, armour and clothing from modular parts, and configure planets, then save them as Schematics. In the world, a Schematica Table turns a Schematic into the real thing, and designs you share may be picked up by AI factions that can build them.\n\nNot built yet: this is its place in the menu."
	p[1].add_child(text)
	_set_screen(p[0], "schematica")


func _show_mods() -> void:
	var p := _panel("MODS", 820)
	var box: VBoxContainer = p[1]
	var info := Label.new()
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.custom_minimum_size.x = 740
	info.text = "Mods are resource packs (.pck or .zip) in the mods folder. Switched-on mods load when the game starts (changes need a restart)."
	box.add_child(info)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 8)
	box.add_child(list)
	var mods := _mods()
	if mods.is_empty():
		list.add_child(_note("No mods installed."))
	for m in mods:
		var cb := CheckButton.new()
		cb.text = "%s%s" % [m.file, "   (loaded)" if m.loaded else ""]
		cb.button_pressed = m.enabled
		cb.toggled.connect(func(on): _set_mod(m.file, on))
		list.add_child(cb)
	var folder := Button.new()
	folder.text = "OPEN MODS FOLDER"
	folder.pressed.connect(func():
		DirAccess.make_dir_recursive_absolute("user://mods")
		OS.shell_open(ProjectSettings.globalize_path("user://mods")))
	box.add_child(folder)
	_set_screen(p[0], "mods")


## [{file, enabled, loaded}] from the EdenApp autoload
func _mods() -> Array:
	var app := get_node_or_null("/root/EdenApp")
	return app.mods() if app else []


func _set_mod(file: String, on: bool) -> void:
	var app := get_node_or_null("/root/EdenApp")
	if app:
		app.set_mod_enabled(file, on)


## A titled panel with a Back button: [panel, content box]
func _panel(title: String, width: float) -> Array:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = width
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 20)
	panel.add_child(box)
	var t := EdenUITheme.title(title, 32)
	t.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(t)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 14)
	box.add_child(content)
	var back := Button.new()
	back.text = "BACK"
	back.custom_minimum_size.x = 240
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back.pressed.connect(func(): _set_screen(null))
	box.add_child(back)
	return [panel, content]


func _note(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(EdenUITheme.CREAM, 0.6))
	return l


func _start_game() -> void:
	_set_screen(null, "play")
	_buttons.visible = false
	_title.visible = false
	_loading.text = "LOADING %s..." % EdenSession.world_name.to_upper()
	_loading_box.visible = true
	_loading_bar.value = 0.0
	# Load the game scene on a thread so the bar moves; building the world afterwards (EdenPlay's own loading cover)
	# still blocks a moment
	ResourceLoader.load_threaded_request(PLAY_SCENE)
	var progress := []
	var status := ResourceLoader.THREAD_LOAD_IN_PROGRESS
	while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await get_tree().process_frame
		status = ResourceLoader.load_threaded_get_status(PLAY_SCENE, progress)
		_loading_bar.value = progress[0]
	if status != ResourceLoader.THREAD_LOAD_LOADED:
		_loading.text = "COULDN'T LOAD THE GAME"
		_loading_bar.value = 0.0
		return
	_loading_bar.value = 1.0
	await get_tree().process_frame
	get_tree().change_scene_to_packed(ResourceLoader.load_threaded_get(PLAY_SCENE))


func _quit() -> void:
	var app := get_node_or_null("/root/EdenApp")
	if app:
		app.quit()
	else:
		get_tree().quit()
