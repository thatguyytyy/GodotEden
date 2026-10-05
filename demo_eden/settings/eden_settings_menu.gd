class_name EdenSettingsMenu
extends CanvasLayer
## Options, in the game's UI look (EdenUITheme), as tabs:
##   Graphics  quality level and its individual settings, display (through EdenGraphics, remembered in
##             user://graphics.cfg). Touching a single setting switches the level to Custom, starting from the level
##             it was on. Sliders apply when released.
##   Controls  mouse sensitivity, invert Y, field of view        } EdenOptions (user://options.cfg), saved as they
##   Audio     master volume                                       } change; EdenPlayer reads them live
##   Profile   player name (what others see online), on-screen help
## In game (Esc) it is the pause menu too: Resume, Main menu, Quit. From the main menu (in_game = false) it has Back.

signal closed

var graphics: EdenGraphics
var in_game := true
var _quality: OptionButton
var _rows := {} # preset property -> control
var _vsync: CheckButton
var _fps_cap: OptionButton
var _show_fps: CheckButton
var _refreshing := false
var _root: Control
var _invite: Button

const FPS_CAPS := [0, 30, 60, 120, 144]
## [preset property, label, kind, min, max, step, unit]
const SETTINGS := [
	["render_scale", "Render resolution", "slider", 0.5, 1.0, 0.01, "%"],
	["antialiasing", "Anti-aliasing", "option", ["Off", "FXAA", "MSAA 2x", "MSAA 4x"]],
	["grass_density", "Grass density", "slider", 0.0, 2.0, 0.05, "%"],
	["grass_distance", "Grass distance", "slider", 15.0, 150.0, 5.0, " m"],
	["grass_blades", "Grass detail (blades)", "slider", 2, 12, 1, ""],
	["foliage_density", "Tree & rock density", "slider", 0.1, 2.0, 0.05, "%"],
	["foliage_detail_distance", "Tree detail distance", "slider", 0.0, 400.0, 10.0, " m"],
	["foliage_far_detail", "Distant tree detail", "slider", 0.3, 2.0, 0.05, "%"],
	["foliage_far_visibility", "Tree view distance", "slider", 50.0, 1500.0, 25.0, ""],
	["ssao", "Ambient occlusion", "check"],
	["glow", "Glow", "check"],
	["light_ray_samples", "Light shafts (samples)", "slider", 0, 256, 16, ""],
	["ocean_reflection_steps", "Ocean reflections (steps)", "slider", 0, 64, 4, ""],
	["volumetric_clouds", "Volumetric clouds", "check"],
	["cloud_style", "Cloud style", "option", ["Low-poly", "Smooth"]],
	["cloud_steps", "Cloud quality (samples)", "slider", 16, 128, 8, ""],
]


func _init() -> void:
	layer = 60
	visible = false


func setup(p_graphics: EdenGraphics, p_in_game := true) -> void:
	graphics = p_graphics
	in_game = p_in_game
	EdenOptions.ensure_loaded()
	_build()
	_refresh()


func open() -> void:
	_refresh()
	if _invite:
		var steam := get_node_or_null("/root/EdenSteam")
		_invite.visible = steam != null and steam.lobby_id != 0
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close() -> void:
	visible = false
	if in_game:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()


# ------------------------------------------------------------------------------------------------------------

func _build() -> void:
	_root = Control.new()
	_root.theme = EdenUITheme.theme()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.01, 0.02, 0.03, 0.6 if in_game else 0.0)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(900, 640)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	panel.add_child(box)

	var title := EdenUITheme.title("PAUSED" if in_game else "OPTIONS", 32)
	title.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(title)

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(tabs)
	tabs.add_child(_graphics_tab())
	tabs.add_child(_controls_tab())
	tabs.add_child(_audio_tab())
	tabs.add_child(_profile_tab())

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 24)
	box.add_child(buttons)
	if in_game:
		_button(buttons, "RESUME", close)
		# Hosting a world on Steam (EdenSteam): Steam's invite dialog, shown only while a lobby is open (see open())
		_invite = _button(buttons, "INVITE FRIENDS", func():
			var steam := get_node_or_null("/root/EdenSteam")
			if steam:
				steam.invite_friends())
		_button(buttons, "MAIN MENU", func():
			visible = false
			var app := get_node_or_null("/root/EdenApp")
			if app:
				app.main_menu())
		_button(buttons, "QUIT", _quit)
	else:
		_button(buttons, "BACK", close)


func _quit() -> void:
	var app := get_node_or_null("/root/EdenApp")
	if app:
		app.quit()
	else:
		get_tree().quit()


func _button(parent: Control, text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(240, 0)
	b.pressed.connect(action)
	parent.add_child(b)
	return b


## A scrolling page of label/control rows
func _page(tab_name: String) -> Array:
	var scroll := ScrollContainer.new()
	scroll.name = tab_name
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	scroll.add_child(margin)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 12)
	margin.add_child(grid)
	return [scroll, grid]


func _graphics_tab() -> Control:
	var page := _page("Graphics")
	var grid: GridContainer = page[1]
	_quality = OptionButton.new()
	for n in EdenGraphics.QUALITY_NAMES:
		_quality.add_item(n)
	_quality.item_selected.connect(func(i):
		if not _refreshing and graphics:
			graphics.quality = i
			graphics.apply()
			_refresh())
	_row(grid, "Graphics quality", _quality, true)
	for s in SETTINGS:
		var key: String = s[0]
		var control: Control
		match s[2]:
			"slider":
				control = _slider(s[3], s[4], s[5], s[6], func(v): _set_value(key, v))
			"option":
				var ob := OptionButton.new()
				for item in s[3]:
					ob.add_item(item)
				ob.item_selected.connect(func(i): _set_value(key, i))
				control = ob
			"check":
				var cb := CheckButton.new()
				cb.text = "On"
				cb.toggled.connect(func(on): _set_value(key, on))
				control = cb
		_rows[key] = control
		# (foliage settings take effect when a world loads: see EdenGraphics.apply)
		var later: bool = in_game and (key.begins_with("grass_") or key.begins_with("foliage_"))
		_row(grid, s[1] + (" (next load)" if later else ""), control)
	_vsync = CheckButton.new()
	_vsync.text = "On"
	_vsync.toggled.connect(func(on):
		if not _refreshing and graphics:
			graphics.vsync = on)
	_row(grid, "VSync", _vsync, true)
	_fps_cap = OptionButton.new()
	for c in FPS_CAPS:
		_fps_cap.add_item("Unlimited" if c == 0 else "%d fps" % c)
	_fps_cap.item_selected.connect(func(i):
		if not _refreshing and graphics:
			graphics.max_fps = FPS_CAPS[i])
	_row(grid, "Frame rate cap", _fps_cap)
	_show_fps = CheckButton.new()
	_show_fps.text = "On"
	_show_fps.toggled.connect(func(on):
		if not _refreshing and graphics:
			graphics.show_fps = on)
	_row(grid, "Show FPS", _show_fps)
	return page[0]


func _controls_tab() -> Control:
	var page := _page("Controls")
	var grid: GridContainer = page[1]
	var sens := _slider(0.25, 3.0, 0.05, "x", func(v):
		EdenOptions.mouse_sensitivity = v
		EdenOptions.save_options())
	_set_slider(sens, EdenOptions.mouse_sensitivity)
	_row(grid, "Mouse sensitivity", sens)
	var inv := CheckButton.new()
	inv.text = "On"
	inv.button_pressed = EdenOptions.invert_y
	inv.toggled.connect(func(on):
		EdenOptions.invert_y = on
		EdenOptions.save_options())
	_row(grid, "Invert mouse Y", inv)
	var fov := _slider(50.0, 100.0, 1.0, " deg", func(v):
		EdenOptions.fov = v
		EdenOptions.save_options())
	_set_slider(fov, EdenOptions.fov)
	_row(grid, "Field of view", fov)
	return page[0]


func _audio_tab() -> Control:
	var page := _page("Audio")
	var grid: GridContainer = page[1]
	var vol := _slider(0.0, 1.0, 0.05, "%", func(v):
		EdenOptions.master_volume = v
		EdenOptions.apply()
		EdenOptions.save_options())
	_set_slider(vol, EdenOptions.master_volume)
	_row(grid, "Master volume", vol)
	return page[0]


func _profile_tab() -> Control:
	var page := _page("Profile")
	var grid: GridContainer = page[1]
	var name_edit := LineEdit.new()
	name_edit.text = EdenOptions.player_name
	name_edit.max_length = 24
	name_edit.text_changed.connect(func(t):
		EdenOptions.player_name = EdenOptions.valid_name(t)
		EdenOptions.save_options())
	_row(grid, "Player name", name_edit)
	var help := CheckButton.new()
	help.text = "On"
	help.button_pressed = EdenOptions.show_help
	help.toggled.connect(func(on):
		EdenOptions.show_help = on
		EdenOptions.save_options())
	_row(grid, "On-screen help", help)
	var telemetry := CheckButton.new()
	telemetry.text = "On"
	telemetry.tooltip_text = "Sends anonymous PC specs, performance numbers and crash logs to the developer to help fix problems. No name or account is attached."
	var tele := get_node_or_null("/root/EdenTelemetry") # (looked up by path: a name wouldn't compile in test runs without autoloads)
	telemetry.button_pressed = tele.enabled if tele else false
	telemetry.disabled = tele == null
	telemetry.toggled.connect(func(on): if tele: tele.set_enabled(on))
	_row(grid, "Share diagnostics", telemetry)
	return page[0]


func _row(grid: GridContainer, text: String, control: Control, strong := false) -> void:
	var label := Label.new()
	label.text = text
	if strong:
		label.add_theme_color_override("font_color", EdenUITheme.GOLD)
	grid.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.custom_minimum_size.x = 320
	grid.add_child(control)


## A slider with its value shown; `apply` gets the value when it is let go (graphics settings rebuild things, which
## shouldn't happen on every step of a drag)
func _slider(lo: float, hi: float, step: float, unit: String, apply: Callable) -> Control:
	var row := HBoxContainer.new()
	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = step
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var value := Label.new()
	value.custom_minimum_size.x = 96
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var show := func(v: float):
		match unit:
			"%": value.text = "%d%%" % roundi(v * 100.0)
			"x": value.text = "%.2fx" % v
			_: value.text = "%d%s" % [roundi(v), unit]
	slider.value_changed.connect(show)
	slider.drag_ended.connect(func(changed): if changed: apply.call(slider.value))
	row.add_child(slider)
	row.add_child(value)
	row.set_meta("slider", slider)
	row.set_meta("show", show)
	return row


func _set_slider(row: Control, v: float) -> void:
	(row.get_meta("slider") as HSlider).set_value_no_signal(v)
	row.get_meta("show").call(v)


func _set_value(key: String, value) -> void:
	if _refreshing or graphics == null:
		return
	var p := graphics.edit_custom()
	p.set(key, int(value) if typeof(p.get(key)) == TYPE_INT else value)
	graphics.apply()
	_refresh()


# The controls from the current level
func _refresh() -> void:
	if graphics == null or _quality == null:
		return
	_refreshing = true
	var p := graphics.current()
	_quality.select(graphics.quality)
	for key in _rows:
		var c: Control = _rows[key]
		var v = p.get(key)
		if c.has_meta("slider"):
			_set_slider(c, float(v))
		elif c is OptionButton:
			c.select(int(v))
		elif c is CheckButton:
			c.set_pressed_no_signal(v)
	_vsync.set_pressed_no_signal(graphics.vsync)
	_fps_cap.select(maxi(FPS_CAPS.find(graphics.max_fps), 0))
	_show_fps.set_pressed_no_signal(graphics.show_fps)
	_refreshing = false
