class_name EdenDebug
extends CanvasLayer
## In-game debug modes for EdenPlayer (it adds one). Keys:
##   F2 god mode      a flag for anything harmful to check (the demo has no damage yet)
##   F3 creative      999 of every item, so digging, placing and building never run out (restored when off)
##   F4 fly           free flight with collision: WASD along the view, Space up, Ctrl/C down, Shift x8,
##                    Alt + mouse wheel sets the speed
##   F5 no-clip       the same flight through terrain, trees and buildings
##   F6 collisions    draws every collision shape (terrain included)
##   F7 draw mode     normal -> wireframe -> unshaded -> lighting -> overdraw
##   F8 stats         FPS, frame time, draw calls, primitives, VRAM, altitude
## The active modes show at the top right.

const DRAW_MODES := [
	["normal", Viewport.DEBUG_DRAW_DISABLED], ["wireframe", Viewport.DEBUG_DRAW_WIREFRAME],
	["unshaded", Viewport.DEBUG_DRAW_UNSHADED], ["lighting", Viewport.DEBUG_DRAW_LIGHTING],
	["overdraw", Viewport.DEBUG_DRAW_OVERDRAW],
]
# Flight speed range (m/s, before Shift's x8) and the factor one wheel notch scales it by
const FLY_SPEED_MIN := 2.0
const FLY_SPEED_MAX := 250.0
const FLY_SPEED_STEP := 1.25

var god := false
var creative := false
var fly := false
var noclip := false
var draw_mode := 0
var stats := false
var fly_speed := 12.0

var _player: EdenPlayer
var _label: Label
var _saved_counts: Array[int] = []


func setup(player: EdenPlayer) -> void:
	_player = player
	# Wireframe draw needs the line indices generated as meshes are made: on from the start (meshes made before this
	# point show no wireframe)
	RenderingServer.set_debug_generate_wireframes(true)
	_label = Label.new()
	_label.anchor_left = 1.0
	_label.anchor_right = 1.0
	_label.offset_left = -420
	_label.offset_right = -16
	_label.offset_top = 12
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_label.add_theme_constant_override("outline_size", 6)
	add_child(_label)


## Flying one way or the other: the player moves with fly_step() instead of walking
func flying() -> bool:
	return fly or noclip


# Alt + wheel sets the flight speed while flying; the plain wheel keeps picking the slot / turning a piece. In
# _input, ahead of EdenMiner's and EdenBuilder's _unhandled_input, so an Alt notch doesn't reach them too.
func _input(event: InputEvent) -> void:
	if not flying() or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseButton and event.pressed and event.alt_pressed \
			and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var step := FLY_SPEED_STEP if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / FLY_SPEED_STEP
		fly_speed = clampf(fly_speed * step, FLY_SPEED_MIN, FLY_SPEED_MAX)
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.physical_keycode:
		KEY_F2:
			god = not god
		KEY_F3:
			set_creative(not creative)
		KEY_F4:
			fly = not fly
			if fly:
				set_noclip(false)
		KEY_F5:
			set_noclip(not noclip)
			if noclip:
				fly = false
		KEY_F6:
			get_tree().debug_collisions_hint = not get_tree().debug_collisions_hint
		KEY_F7:
			draw_mode = (draw_mode + 1) % DRAW_MODES.size()
			get_viewport().debug_draw = DRAW_MODES[draw_mode][1]
		KEY_F8:
			stats = not stats
		_:
			return
	get_viewport().set_input_as_handled()


func set_creative(on: bool) -> void:
	creative = on
	var miner := _player.miner
	if miner == null:
		return
	if on:
		_saved_counts = miner.counts.duplicate()
	elif not _saved_counts.is_empty():
		miner.counts = _saved_counts
		miner.refresh()


func set_noclip(on: bool) -> void:
	noclip = on
	_player.get_node("Collision").disabled = on


func _process(_delta: float) -> void:
	if creative and _player.miner:
		var changed := false
		for i in _player.miner.counts.size():
			if _player.miner.counts[i] < 999:
				_player.miner.counts[i] = 999
				changed = true
		if changed:
			_player.miner.refresh()
	var modes: Array[String] = []
	var speed := " %d m/s" % roundi(fly_speed)
	for m in [["GOD", god], ["CREATIVE", creative], ["FLY" + speed, fly], ["NOCLIP" + speed, noclip],
			["COLLISIONS", get_tree().debug_collisions_hint]]:
		if m[1]:
			modes.append(m[0])
	if draw_mode != 0:
		modes.append(DRAW_MODES[draw_mode][0].to_upper())
	var text := "  ".join(modes)
	if stats:
		text += "\n%d fps  %.1f ms\n%d draw calls  %.2f M primitives\nVRAM %d MB\nalt %.1f m" % [
			Engine.get_frames_per_second(), 1000.0 / maxf(Engine.get_frames_per_second(), 1.0),
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1.0e6,
			Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
			_player.altitude(),
		]
	_label.text = text
