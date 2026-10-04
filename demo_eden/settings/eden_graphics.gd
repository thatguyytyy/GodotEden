@tool
class_name EdenGraphics
extends Node
## Graphics quality for the planet scenes: pick Low / Medium / High / Ultra (or Custom) and it sets the viewport
## (render scale, upscaler, anti-aliasing, vsync, frame cap) and the planet's nodes (EdenFoliage grass and trees,
## EdenAmbience SSAO/glow, EdenPlanetAtmosphere light rays, EdenPlanetOcean reflections).
##
## In the editor: put one in the scene, choose the Quality the game starts with and edit the presets in the
## inspector (they live in settings/eden_graphics_presets.tres). Foliage and effects follow the choice in the editor
## viewport too. In game: the settings menu (Esc, EdenSettingsMenu) changes it; the player's choice is kept in
## user://graphics.cfg and wins over the scene's default. `-- --quality=low|medium|high|ultra` overrides both.

signal changed

enum Quality { LOW, MEDIUM, HIGH, ULTRA, CUSTOM }
const QUALITY_NAMES := ["Low", "Medium", "High", "Ultra", "Custom"]
const SAVE_PATH := "user://graphics.cfg"

@export var quality := Quality.MEDIUM:
	set(v):
		quality = v
		_queue_apply()
## The four levels (expand to edit them: it is the shared settings/eden_graphics_presets.tres). Empty: built-in defaults
@export var presets: EdenGraphicsPresets = preload("res://settings/eden_graphics_presets.tres"):
	set(v):
		presets = v
		_queue_apply()
## The Custom level (the settings menu edits it; starts as a copy of the level it was switched from)
@export var custom: EdenGraphicsPreset
@export_group("Display")
@export var vsync := true:
	set(v):
		vsync = v
		_queue_apply()
## Frame cap, 0 = none
@export_range(0, 360, 1) var max_fps := 0:
	set(v):
		max_fps = v
		_queue_apply()
## FPS and frame time in the corner (in game)
@export var show_fps := false:
	set(v):
		show_fps = v
		_queue_apply()
@export_group("")
## Keep the player's choice between runs (user://graphics.cfg)
@export var remember_player_choice := true

var _pending := false
var _foliage_applied := false
var _fps_label: Label


func _ready() -> void:
	_pending = true # (setters below don't queue an apply: one at the end)
	if not Engine.is_editor_hint():
		if remember_player_choice:
			_load()
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--quality="):
				var i := QUALITY_NAMES.map(func(n): return n.to_lower()).find(a.trim_prefix("--quality=").to_lower())
				if i >= 0:
					quality = i
	_pending = false
	apply()


func current() -> EdenGraphicsPreset:
	if quality == Quality.CUSTOM:
		if custom == null:
			custom = _level(Quality.HIGH).duplicate()
			custom.name = "Custom"
		return custom
	return _level(quality)


func _level(q: int) -> EdenGraphicsPreset:
	var list: Array = presets.presets if presets and presets.presets.size() >= 4 else EdenGraphicsPreset.defaults()
	return list[clampi(q, 0, 3)]


## Switches to Custom starting from the current level, for per-setting changes (the menu's sliders)
func edit_custom() -> EdenGraphicsPreset:
	if quality != Quality.CUSTOM:
		custom = current().duplicate()
		custom.name = "Custom"
		quality = Quality.CUSTOM
	return custom


func _queue_apply() -> void:
	if not is_inside_tree() or _pending:
		return
	_pending = true
	(func():
		if _pending: # (an apply() since then already did it)
			apply()).call_deferred()


## Applies the current level now
func apply() -> void:
	_pending = false
	if not is_inside_tree():
		return
	var p := current()
	var scene := get_tree().edited_scene_root if Engine.is_editor_hint() else get_tree().current_scene
	if scene == null:
		scene = get_tree().root
	# Viewport and display: the game only (the editor's viewport is the editor's business)
	if not Engine.is_editor_hint():
		var vp := get_viewport()
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if p.upscaler == 1 else Viewport.SCALING_3D_MODE_BILINEAR
		vp.scaling_3d_scale = p.render_scale
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if p.antialiasing == 1 else Viewport.SCREEN_SPACE_AA_DISABLED
		vp.msaa_3d = [Viewport.MSAA_DISABLED, Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X][p.antialiasing]
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = max_fps
		_update_fps_label()
	# Foliage settings rebuild its whole instance library, regenerated synchronously by the VoxelInstancer: 30-60 s
	# frozen per change in a loaded world (it read as a crash). In game they take once, when the world loads; changed
	# later they're saved and apply next load. ponytail: async regeneration in the fork would make them live again
	var foliage_now := Engine.is_editor_hint() or not _foliage_applied
	if not Engine.is_editor_hint():
		_foliage_applied = true
	for n in scene.find_children("*", "", true, false):
		if n is EdenFoliage and not foliage_now:
			continue
		if n is EdenFoliage:
			n.apply_quality({
				"grass_density_scale": p.grass_density,
				"grass_fade_start": maxf(p.grass_distance - 15.0, 5.0),
				"grass_fade_end": p.grass_distance,
				"grass_wind_fade_start": minf(20.0, p.grass_distance * 0.4),
				"grass_wind_fade_end": minf(35.0, p.grass_distance * 0.65),
				"blades_per_tuft": p.grass_blades,
				"grass_lod_distance": p.grass_lod_distance,
				"far_blades_per_tuft": p.grass_far_blades,
				"density_scale": p.foliage_density,
				"detail_distance": p.foliage_detail_distance,
				"far_resolution_scale": p.foliage_far_detail,
				"far_visibility": p.foliage_far_visibility,
			})
		elif n.is_class("EdenAmbience"):
			n.set("ssao_enabled", p.ssao)
			n.set("glow_enabled", p.glow)
		elif n.is_class("EdenPlanetAtmosphere"):
			n.set("light_rays_enabled", p.light_ray_samples > 0)
			if p.light_ray_samples > 0:
				n.set("light_ray_samples", p.light_ray_samples)
		elif n.is_class("EdenSpaceEnvironment") and not Engine.is_editor_hint():
			# Stars are ~1.5 px across at full resolution: rendered smaller (Medium, Low) they fell between pixels
			# and vanished. A coarser star lattice makes them as big in screen pixels as before, more of them as many
			if not n.has_meta("base_stars"):
				n.set_meta("base_stars", [n.get("star_scale"), n.get("star_density")])
			var base: Array = n.get_meta("base_stars")
			n.set("star_scale", base[0] * p.render_scale)
			n.set("star_density", minf(base[1] / (p.render_scale * p.render_scale), 0.2))
		elif n.is_class("EdenCloudShell"):
			n.set("volumetric", p.volumetric_clouds)
			n.set("vol_facet_mix", 1.0 if p.cloud_style == 0 else 0.0)
			n.set("vol_steps", int(p.cloud_steps))
		elif n.is_class("EdenPlanetOcean"):
			var m = n.get("material")
			if m is ShaderMaterial:
				m.set_shader_parameter("ssr_steps", p.ocean_reflection_steps)
				m.set_shader_parameter("ssr_strength", 1.0 if p.ocean_reflection_steps > 0 else 0.0)
	if not Engine.is_editor_hint() and remember_player_choice:
		_save()
	changed.emit()


func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("graphics", "quality", quality)
	cfg.set_value("graphics", "vsync", vsync)
	cfg.set_value("graphics", "max_fps", max_fps)
	cfg.set_value("graphics", "show_fps", show_fps)
	if custom:
		for prop in custom.get_property_list():
			if prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
				cfg.set_value("custom", prop.name, custom.get(prop.name))
	cfg.save(SAVE_PATH)


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	if cfg.has_section("custom"):
		custom = EdenGraphicsPreset.new()
		for k in cfg.get_section_keys("custom"):
			custom.set(k, cfg.get_value("custom", k))
	quality = cfg.get_value("graphics", "quality", quality)
	vsync = cfg.get_value("graphics", "vsync", vsync)
	max_fps = cfg.get_value("graphics", "max_fps", max_fps)
	show_fps = cfg.get_value("graphics", "show_fps", show_fps)


func _update_fps_label() -> void:
	if show_fps and _fps_label == null:
		var layer := CanvasLayer.new()
		layer.layer = 50
		add_child(layer)
		_fps_label = Label.new()
		_fps_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
		_fps_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		_fps_label.position += Vector2(-16, 12)
		_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_fps_label.add_theme_color_override("font_outline_color", Color.BLACK)
		_fps_label.add_theme_constant_override("outline_size", 5)
		layer.add_child(_fps_label)
	if _fps_label:
		_fps_label.get_parent().visible = show_fps
	if show_fps:
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	set_process(show_fps and not Engine.is_editor_hint())


func _process(_delta: float) -> void:
	if _fps_label:
		var gpu := RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
		_fps_label.text = "%d fps  %.1f ms%s\n%s" % [Engine.get_frames_per_second(), 1000.0 / maxf(Engine.get_frames_per_second(), 1.0),
				"  GPU %.1f ms" % gpu if gpu > 0.0 else "", QUALITY_NAMES[quality]]
