class_name EdenPlayer
extends CharacterBody3D
## Third-person character for a spherical planet: walks, runs, crouches and jumps on the terrain's collision, with
## "down" toward the planet's centre (the VoxelLodTerrain's origin). The camera orbits with the mouse.
##
## Drop it into a planet scene and set planet_path to the VoxelLodTerrain. When the game runs it sets the scene up
## for itself (see Scene Setup): terrain collision on, its own VoxelViewer, other viewers stopped, a HUD. Placed
## anywhere above the ground, it waits for collision to load under it and drops onto it.
##
## Controls (actions are created at runtime if the project doesn't define them, see ensure_input_actions()):
##   WASD move, Shift run (double-tap and hold: sprint), Ctrl/C crouch, Space jump, mouse look (click to capture),
##   Esc settings (EdenSettingsMenu);
##   N / B cycle the weather around you (EdenAmbience), L strikes lightning, F1 hides the help;
##   hold LMB dig, RMB place, 1-5 / wheel pick a material, Tab inventory (EdenMiner);
##   F2-F8 debug modes: god, creative, fly, no-clip, collision shapes, draw modes, stats (EdenDebug).
##
## The model is the Synty character (eden_character.tscn): its AnimationTree state machine (EdenCharacterAnim) blends
## idle/walk/run/sprint by ground speed, direction and slope, crouch, jump/fall/land. The body turns toward where it
## moves; while it turns (and when backing up) the feet step the actual direction with the strafe clips.
## Footsteps are synthesised per ground material (AudioStreamEdenAmbience.trigger_footstep).

signal landed

@export var planet_path: NodePath
@export_group("Scene Setup")
## Turn terrain collision on (for the nearest LODs) when the game runs. Never in the editor.
@export var enable_terrain_collision := true
@export var collision_lods := 1
## Stream terrain around the player with its own VoxelViewer
@export var stream_terrain := true
@export var view_distance := 80000
## Stop the scene's other VoxelViewers (fixed editor cameras) streaming terrain elsewhere while playing
@export var disable_other_viewers := true
## On-screen help and the weather keys
@export var show_hud := true
## Digging/building with an inventory (EdenMiner)
@export var enable_mining := true
@export var footstep_volume_db := -6.0
## Multiplayer through SpacetimeDB (EdenNet): see demo_eden/multiplayer/README.md. Also on with `-- --online`
@export var online := false
@export var server_url := "ws://127.0.0.1:3180"
@export var database := "eden"
@export var player_name := "Explorer"
@export_group("Movement")
@export var walk_speed := 1.6
## Shift: the Synty run's own pace
@export var run_speed := 2.6
## Double-tap Shift and hold the second press: a sprint for up to sprint_duration seconds, then back to the run
@export var sprint_speed := 7.0
@export var sprint_duration := 15.0
@export var crouch_speed := 1.0
@export var jump_speed := 5.0
@export var gravity := 9.8
## How quickly the ground speed reaches the target (m/s^2 per m/s of target)
@export var acceleration := 10.0
@export var air_control := 1.5
## How quickly the body turns to face where it moves
@export var turn_speed := 5.0
@export_group("Swimming")
@export var swim_speed := 1.8
@export var swim_sprint_speed := 3.2
## How deep the feet float below the surface at rest (buoyancy balances gravity there): head and shoulders out
@export var float_depth := 1.35
@export_group("Camera")
@export var mouse_sensitivity := 0.003
@export var camera_distance := 4.0
@export var camera_height := 1.55
## Over-the-shoulder: the camera sits this far right so the crosshair clears the body
@export var camera_shoulder := 0.55
@export var camera_min_pitch := -1.3
@export var camera_max_pitch := 0.7

const STAND_HEIGHT := 1.8
const CROUCH_HEIGHT := 1.2
const RADIUS := 0.3
const COYOTE_TIME := 0.15
## Seconds from letting go of Shift to pressing it again that start a sprint
const DOUBLE_TAP := 0.35
## Moving further than this from the camera's heading (cos ~110 deg) backs up instead of turning round
const BACKPEDAL_DOT := -0.34

var crouching := false
var running := false
var sprinting := false
var _sprint_time := 0.0
var _last_run_release := -10.0
var swimming := false
var _cam_height := 1.55
## True once terrain collision is under the spawn point (gravity is held off until then)
var ready_to_move := false

var _planet: Node3D
var _yaw := 0.0
var _pitch := -0.25
var _facing := Vector3.FORWARD
var animator: EdenCharacterAnim
var miner: EdenMiner
var net: EdenNet
## The chat box is taking keystrokes (EdenChat): no movement
var typing := false
var builder: EdenBuilder
var graphics: EdenGraphics
var calendar: EdenCalendar
var calendar_panel: EdenCalendarPanel
var settings_menu: EdenSettingsMenu
var debug: EdenDebug
var _model: Node3D
## Between the spring arm and the camera: lifts the camera clear of lying snow (the arm only sees solid ground)
var _cam_lift: Node3D
var _snow_lift := 0.0
var _cam_anchor := Vector3.ZERO
var _last_press: Variant = null
## Footprints in snow (world positions, 0.4 m apart) not yet sent by EdenNet
var snow_prints := PackedVector3Array()
var _steps: AudioStreamEdenAmbience
var _steps_player: AudioStreamPlayer
var _pivot: Node3D
var _arm: SpringArm3D
var _camera: Camera3D
var _shape: CapsuleShape3D
var _collision: CollisionShape3D
var _jump_time := -1.0
var _was_on_floor := true
var _air_time := 0.0
var _scene_ready := false
## Radius of the sea surface (the generator's planet_radius + sea_level); INF when the planet has no sea
var _sea_radius := -INF
var _hud: Label
## Facing to take once the ground is found after restore_position (NAN: face north as usual)
var _restore_yaw := NAN
var _ambience: Node


func _ready() -> void:
	# Only when part of the scene being played. Tools that load a scene holding a player just to render or
	# measure it (they have no current scene) keep their own camera and viewers; the player stays put.
	var main := get_tree().current_scene
	if main == null or not (main == self or main.is_ancestor_of(self)):
		set_physics_process(false)
		set_process(false)
		set_process_unhandled_input(false)
		return
	ensure_input_actions()
	_planet = get_node_or_null(planet_path) as Node3D
	_apply_session()
	_model = $Model
	animator = _model.get_node("EdenCharacter/AnimationTree")
	animator.run_speed = run_speed
	animator.step.connect(_on_step)
	_collision = $Collision
	_shape = _collision.shape
	# ~40 km from the origin a float resolves ~4 mm, coarser than the default 1 mm margin: the body couldn't
	# separate from the floor to slide along it and stood still with every move blocked
	safe_margin = 0.04
	collision_mask |= EdenFoliage.COLLISION_LAYER # walk into trunks and rocks (the camera arm doesn't see them)
	floor_snap_length = 0.4
	floor_max_angle = deg_to_rad(50.0)
	# Camera rig: a pivot above the character (planet-aligned, set every frame), a spring arm that pulls the
	# camera in when terrain is behind it, and the camera looking back along the arm
	_pivot = Node3D.new()
	_pivot.name = "CameraPivot"
	_pivot.top_level = true
	_pivot.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF # placed every frame, below
	add_child(_pivot)
	_arm = SpringArm3D.new()
	_arm.spring_length = camera_distance
	_arm.margin = 0.2
	_arm.add_excluded_object(get_rid())
	_pivot.add_child(_arm)
	_camera = Camera3D.new()
	_camera.far = 400000.0
	_camera.near = 0.1
	_cam_lift = Node3D.new()
	_arm.add_child(_cam_lift)
	_cam_lift.add_child(_camera)
	_camera.current = true
	# Footsteps: the ambience synth with its beds silent, used only for its one-shot steps
	_steps = AudioStreamEdenAmbience.new()
	for layer in AudioStreamEdenAmbience.LAYER_MAX:
		_steps.set_level(layer, 0.0)
	_steps_player = AudioStreamPlayer.new()
	_steps_player.stream = _steps
	_steps_player.volume_db = footstep_volume_db
	add_child(_steps_player)
	_steps_player.play()
	_setup_scene()


# Runtime scene setup (Scene Setup exports): runs once the planet is known
func _setup_scene() -> void:
	if _scene_ready or _planet == null or Engine.is_editor_hint():
		return
	_scene_ready = true
	debug = EdenDebug.new()
	debug.name = "Debug"
	add_child(debug)
	debug.setup(self)
	for action in [["weather_next", KEY_N], ["weather_prev", KEY_B], ["lightning", KEY_L], ["toggle_help", KEY_F1], ["calendar", KEY_K]]:
		if not InputMap.has_action(action[0]):
			InputMap.add_action(action[0])
			var e := InputEventKey.new()
			e.physical_keycode = action[1]
			InputMap.action_add_event(action[0], e)
	if enable_terrain_collision and _planet is VoxelLodTerrain:
		_planet.generate_collisions = true
		_planet.collision_lod_count = collision_lods
	var own: VoxelViewer = null
	if stream_terrain:
		own = VoxelViewer.new()
		own.name = "PlayerViewer"
		own.view_distance = view_distance
		own.requires_collisions = true
		add_child(own)
	if disable_other_viewers:
		for v in get_tree().root.find_children("*", "VoxelViewer", true, false):
			if v != own and not is_ancestor_of(v):
				v.queue_free()
	for c in _planet.get_children():
		if c.is_class("EdenAmbience"):
			_ambience = c
	# Graphics quality: the scene's EdenGraphics (configured in the editor), or a default one; Esc opens the menu
	for g in get_tree().current_scene.find_children("*", "Node", true, false):
		if g is EdenGraphics:
			graphics = g
			break
	if graphics == null:
		graphics = EdenGraphics.new()
		graphics.name = "Graphics"
		add_child(graphics)
	# The calendar and seasons: the scene's EdenCalendar (set up in the editor), or a default one; K shows it
	for c in get_tree().current_scene.find_children("*", "Node", true, false):
		if c is EdenCalendar:
			calendar = c
			break
	if calendar == null:
		calendar = EdenCalendar.new()
		calendar.name = "Calendar"
		add_child(calendar)
	calendar_panel = EdenCalendarPanel.new()
	add_child(calendar_panel)
	calendar_panel.setup(calendar, self)
	settings_menu = EdenSettingsMenu.new()
	add_child(settings_menu)
	settings_menu.setup(graphics)
	if show_hud:
		var layer := CanvasLayer.new()
		add_child(layer)
		_hud = Label.new()
		_hud.position = Vector2(16, 12)
		_hud.add_theme_color_override("font_color", Color(1, 1, 1))
		_hud.add_theme_color_override("font_outline_color", Color(0, 0, 0))
		_hud.add_theme_constant_override("outline_size", 6)
		layer.add_child(_hud)
		_hud.visible = EdenOptions.show_help
	if enable_mining and _planet is VoxelLodTerrain:
		miner = EdenMiner.new()
		miner.name = "Miner"
		add_child(miner)
		miner.setup(self, _planet)
		builder = EdenBuilder.new()
		builder.name = "Builder"
		add_child(builder)
		builder.setup(self, miner, _planet)
	var args := OS.get_cmdline_user_args()
	if online or "--online" in args:
		net = EdenNet.new()
		net.name = "Net"
		net.server_url = server_url
		net.database = database
		net.player_name = player_name
		for a in args:
			if a.begins_with("--name="):
				net.player_name = a.trim_prefix("--name=")
			elif a.begins_with("--server="):
				net.server_url = a.trim_prefix("--server=")
			elif a.begins_with("--database="):
				net.database = a.trim_prefix("--database=")
		add_child(net)
		net.setup(self)


## The world the main menu picked (EdenSession): online or not and where, and the name others see (the planet's
## seed is set by the scene before the terrain streams: eden_play.gd). Run straight from the editor, the scene's own
## settings stay.
func _apply_session() -> void:
	EdenOptions.ensure_loaded()
	player_name = EdenOptions.player_name
	if not EdenSession.active:
		return
	online = not EdenSession.offline
	if online:
		server_url = EdenSession.ws_url()
		database = EdenSession.database


## Rejoining a saved world: the player goes back where the server last saw them (planet-relative) and waits for the
## ground to load there
func restore_position(planet_pos: Vector3, yaw: float) -> void:
	var up := planet_pos.normalized()
	global_position = _center() + planet_pos + up * 0.3
	velocity = Vector3.ZERO
	ready_to_move = false
	_restore_yaw = yaw
	reset_physics_interpolation()


func set_planet(planet: Node3D) -> void:
	_planet = planet
	planet_path = get_path_to(planet) if is_inside_tree() else NodePath()
	if is_inside_tree():
		_setup_scene()


func get_camera() -> Camera3D:
	return _camera


static func ensure_input_actions() -> void:
	var keys := {
		"move_forward": [KEY_W, KEY_UP], "move_back": [KEY_S, KEY_DOWN], "move_left": [KEY_A, KEY_LEFT],
		"move_right": [KEY_D, KEY_RIGHT], "sprint": [KEY_SHIFT], "crouch": [KEY_CTRL, KEY_C], "jump": [KEY_SPACE],
	}
	for action in keys:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for k in keys[action]:
			var e := InputEventKey.new()
			e.physical_keycode = k
			InputMap.action_add_event(action, e)


func _unhandled_input(event: InputEvent) -> void:
	if _ambience:
		if event.is_action_pressed("weather_next"):
			_ambience.call("cycle_weather", 1)
		elif event.is_action_pressed("weather_prev"):
			_ambience.call("cycle_weather", -1)
		elif event.is_action_pressed("lightning"):
			_ambience.call("strike_lightning")
	if calendar_panel and event.is_action_pressed("calendar"):
		calendar_panel.toggle()
	if _hud and event.is_action_pressed("toggle_help"):
		_hud.visible = not _hud.visible
	# (a click on a panel's empty space reaches here too: it mustn't hide the pointer while the panel is up)
	if event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not ui_open():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE and settings_menu and not settings_menu.visible:
		settings_menu.open()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE and settings_menu == null:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var sens := mouse_sensitivity * EdenOptions.mouse_sensitivity
		_yaw -= event.relative.x * sens
		_pitch = clampf(_pitch - event.relative.y * sens * (-1.0 if EdenOptions.invert_y else 1.0), camera_min_pitch, camera_max_pitch)


## Where and when you are, in plain terms: date, local time and season; the weather, temperature, wind and daylight
func readings() -> String:
	var up := up_direction
	var lines := []
	if calendar:
		var lat := calendar.latitude(up)
		lines.append("%s   %s   %s, %s hemisphere   %.0f° %s" % [calendar.date_string(), EdenCalendar.clock(calendar.local_hour(up)),
				calendar.season_at(up), "northern" if lat >= 0.0 else "southern", absf(lat), "N" if lat >= 0.0 else "S"])
	if _ambience:
		var st: Dictionary = _ambience.call("get_debug_state")
		var t: float = st.get("temperature", 0.5)
		# The day's warmth: cooler at night, warmer with the sun high (as the weather reckons it)
		var atmo := calendar._atmosphere if calendar else null
		var sun: Vector3 = atmo.call("get_sun_direction") if atmo else up
		t += -0.04 + 0.08 * maxf(sun.dot(up), 0.0)
		var wind_speed: float = st.get("wind_speed", 0.0)
		var wind_dir: Vector3 = st.get("wind_direction", Vector3.ZERO)
		var parts := [_weather_words(st), EdenCalendar.temp_text(t)]
		if wind_speed > 0.3 and wind_dir != Vector3.ZERO:
			parts.append("wind %d km/h from the %s" % [roundi(wind_speed * 3.6), EdenCalendar.compass(-wind_dir, up, _north(up))])
		else:
			parts.append("calm")
		parts.append("moisture %d %%" % roundi(100.0 * float(st.get("moisture", 0.5))))
		if calendar:
			var sun_t := calendar.sun_times(calendar.latitude(up))
			parts.append("polar day" if sun_t[2] >= 24.0 else ("polar night" if sun_t[2] <= 0.0 else "daylight %s-%s" % [EdenCalendar.clock(sun_t[0]), EdenCalendar.clock(sun_t[1])]))
		if st.get("weather", "Auto") != "Auto":
			parts.append("[weather set to %s]" % st.weather)
		lines.append("   ".join(parts))
	return "\n".join(lines)


static func _weather_words(st: Dictionary) -> String:
	var p: float = st.get("precipitation", 0.0)
	var cloud: float = st.get("cloud", 0.0)
	if float(st.get("dust_storm", 0.0)) > 0.3:
		return "Dust storm"
	if p > 0.08:
		var kind := "snow" if float(st.get("freezing", 0.0)) > 0.5 else "rain"
		var s := ("Heavy " if p > 0.6 else ("Light " if p < 0.3 else "")) + kind
		s = s.capitalize() if s == kind else s
		return s + (" and thunder" if st.get("thunder", false) else "")
	if cloud > 0.65:
		return "Overcast"
	if cloud > 0.3:
		return "Partly cloudy"
	var snow: float = st.get("snow_cover", 0.0)
	return "Clear" + (", snow on the ground" if snow > 0.3 else "")


func _center() -> Vector3:
	return _planet.global_position if _planet else Vector3.ZERO


## Metres above sea level (above the planet's centre when it has no sea)
func altitude() -> float:
	return global_position.distance_to(_center()) - (_sea_radius if is_finite(_sea_radius) else 0.0)


## Planet north projected onto the ground here: the reference the camera heading is measured from
static func _north(up: Vector3) -> Vector3:
	var n := Vector3.UP - up * up.y
	return n.normalized() if n.length_squared() > 1e-6 else up.cross(Vector3.RIGHT).normalized()


func _physics_process(delta: float) -> void:
	var up := (global_position - _center()).normalized()
	up_direction = up
	if not ready_to_move:
		_wait_for_ground(up)
		return
	var heading := _north(up).rotated(up, _yaw)
	var right := heading.cross(up)

	var input := Input.get_vector("move_left", "move_right", "move_back", "move_forward")
	if typing or (settings_menu and settings_menu.visible):
		input = Vector2.ZERO
	if debug and debug.flying():
		_fly_step(delta, input, heading, right, up)
		return
	var wish := heading * input.y + right * input.x
	if wish.length_squared() > 1.0:
		wish = wish.normalized()

	# "Grounded" forgives a few frames off the floor (bumps, tree roots, the flicker of a contact while wedged
	# between trunks): jumping, crouching and the animations use it, gravity uses the real floor contact
	var on_floor := is_on_floor()
	var grounded := on_floor or (_air_time < COYOTE_TIME and _jump_time < 0.0)
	_set_crouching(_held("crouch") and grounded)
	var backpedal := wish.dot(heading) < BACKPEDAL_DOT * wish.length()
	running = _held("sprint") and not crouching and input.length() > 0.1
	_update_sprint(delta, running and not backpedal)
	var speed := crouch_speed if crouching else (sprint_speed if sprinting else (run_speed if running else walk_speed))
	speed *= _snow_slowdown(global_position + wish * 0.4)

	var vertical := velocity.dot(up)
	var horizontal := velocity - up * vertical
	# Water: in once the feet are deeper than a wade, out when they are shallow again or standing in the shallows
	var depth := water_depth()
	if swimming:
		swimming = depth > 0.9 and not (on_floor and depth < float_depth - 0.2)
	else:
		swimming = depth > float_depth + 0.25 or (depth > float_depth - 0.1 and not on_floor and velocity.dot(up) < 0.0)
	if swimming:
		_swim_step(delta, wish, input, depth, up, horizontal, vertical)
		move_and_slide()
		_rescue_if_buried(up)
		_air_time = 0.0
		_jump_time = -1.0
		_was_on_floor = true
		_update_animation(velocity - up * velocity.dot(up), delta)
		return
	var rate := (acceleration if grounded else air_control) * maxf(speed, 1.0) * delta
	horizontal = horizontal.move_toward(wish * speed, rate)
	if on_floor:
		vertical = minf(vertical, 0.0)
	else:
		vertical -= gravity * delta
	if grounded and not typing and Input.is_action_just_pressed("jump") and not crouching:
		vertical = jump_speed
		_jump_time = 0.0
		_air_time = COYOTE_TIME # no second jump from the grace window
	velocity = horizontal + up * vertical
	var fall_speed := -vertical

	# Face where we move (smoothly), always upright on the planet; backing up (away from the camera's heading) keeps
	# facing ahead and walks backward instead of turning round
	if wish.length_squared() > 0.01:
		var target := -wish.normalized() if backpedal else wish.normalized()
		_facing = _facing.slerp(target, minf(1.0, turn_speed * delta))
	_facing = (_facing - up * _facing.dot(up))
	_facing = _facing.normalized() if _facing.length_squared() > 1e-6 else heading
	global_basis = Basis.looking_at(_facing, up)

	move_and_slide()
	_rescue_if_buried(up)
	var air_before := _air_time
	# Hung up on an edge (the capsule's round bottom resting on a trunk or log: a wall contact, not floor,
	# and not falling): ease off it, away from what we touch, so gravity takes over again
	if is_on_floor():
		_air_time = 0.0
	else:
		_air_time += delta
		if _air_time > 0.25 and velocity.dot(up) > -1.0:
			# Away from everything touched; wedged between two trunks the pushes cancel, so slip along the gap
			var push := Vector3.ZERO
			var side := Vector3.ZERO
			for i in get_slide_collision_count():
				var n := get_slide_collision(i).get_normal()
				n -= up * n.dot(up)
				if n.length_squared() > 0.01:
					push += n.normalized()
					side = n.normalized().cross(up)
			if push.length_squared() < 0.25 and side != Vector3.ZERO:
				push = side if side.dot(_facing) >= 0.0 else -side
			if push != Vector3.ZERO:
				global_position += push.normalized() * 0.05
	if is_on_floor() and not _was_on_floor and air_before > COYOTE_TIME:
		landed.emit()
		animator.land(fall_speed)
		_on_step(0, clampf(fall_speed / 6.0, 0.4, 1.3))
	_was_on_floor = is_on_floor()
	_update_animation(horizontal, delta)
	# Walking through lying snow presses a path into it
	_last_press = press_snow_stroke(_ambience, _last_press, global_position, _air_time < 0.3)
	# ...and keeps a footprint every 0.4 m of it for EdenNet to share (the world's record of who walked where)
	if net and _ambience and _air_time < 0.3 and float(_ambience.get_snow_depth_at(global_position)) > 0.0 \
			and (snow_prints.is_empty() or snow_prints[-1].distance_to(global_position) >= 0.4):
		snow_prints.append(global_position)


## How far below the sea surface the feet are (negative above it)
func water_depth() -> float:
	if _sea_radius == -INF:
		_sea_radius = INF
		var gen: Object = _planet.get("generator") if _planet else null
		if gen and "planet_radius" in gen and "sea_level" in gen:
			_sea_radius = float(gen.planet_radius) + float(gen.sea_level)
	return _sea_radius - (global_position - _center()).length() if _sea_radius != INF else -INF


# Swimming: buoyancy grows with how deep the body is (capped once under), drag in every direction; Space kicks
# up, Crouch dives. Movement follows the camera heading, slower than on land.
func _swim_step(delta: float, wish: Vector3, input: Vector2, depth: float, up: Vector3, horizontal: Vector3, vertical: float) -> void:
	_set_crouching(false)
	running = _held("sprint") and input.length() > 0.1
	var speed := swim_sprint_speed if running else swim_speed
	horizontal = horizontal.move_toward(wish * speed, 3.0 * speed * delta)
	var a := gravity * (clampf(depth / float_depth, 0.0, 1.6) - 1.0) - 2.2 * vertical
	if _held("jump"):
		a += 5.0
	if _held("crouch"):
		a -= 9.0
	vertical += a * delta
	velocity = horizontal + up * vertical
	if wish.length_squared() > 0.01:
		_facing = _facing.slerp(wish.normalized(), minf(1.0, turn_speed * 0.5 * delta))
	_facing = (_facing - up * _facing.dot(up))
	_facing = _facing.normalized() if _facing.length_squared() > 1e-6 else _north(up)
	global_basis = Basis.looking_at(_facing, up)


# Holds the character in place until terrain collision exists below it, then drops it onto the ground
func _wait_for_ground(up: Vector3) -> void:
	velocity = Vector3.ZERO
	var from := global_position + up * 50.0
	var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, global_position - up * 400.0, collision_mask, [get_rid()]))
	if hit.is_empty() and water_depth() <= 0.0:
		return
	if not hit.is_empty():
		global_position = hit.position + up * 0.05
		reset_physics_interpolation()
	if water_depth() > float_depth: # the ground is the sea floor, or not loaded under the sea: float at the surface
		global_position = _center() + up * (_sea_radius - float_depth)
		reset_physics_interpolation()
	ready_to_move = true
	_facing = _north(up) if is_nan(_restore_yaw) else _north(up).rotated(up, _restore_yaw)
	_restore_yaw = NAN
	global_basis = Basis.looking_at(_facing, up)


# Fell through the ground (collision missing for a moment as terrain loads or changes LOD, say): falling a while,
# or "swimming", with terrain overhead. Put the player back on the surface to find the ground again. A tunnel
# dug by the player doesn't count: there you stand on its floor.
func _rescue_if_buried(up: Vector3) -> void:
	if Engine.get_physics_frames() % 20 != 0 or not (_air_time > 1.0 or swimming):
		return
	# Only when the body is really inside solid ground: a dug pit or a cave has terrain overhead too, and the
	# generator's surface knows nothing of digging (putting the player there dropped them back into their pit)
	var vt: VoxelTool = _planet.get_voxel_tool() if _planet is VoxelLodTerrain else null
	if vt == null:
		return
	vt.channel = VoxelBuffer.CHANNEL_SDF
	var local := _planet.to_local(global_position + up * 0.9)
	var local_up := (_planet.global_basis.inverse() * up).normalized()
	var sdf := vt.get_voxel_f(Vector3i(local.round()))
	if sdf > -0.3:
		return
	# Up through the solid to the (edited) surface: the SDF says how far it is at least. (Rays don't work from in
	# here: the terrain's collision faces aren't hit from inside)
	var climbed := 0.0
	while sdf <= 0.0 and climbed < 400.0:
		var stride := maxf(absf(sdf), 0.5)
		local += local_up * stride
		climbed += stride
		sdf = vt.get_voxel_f(Vector3i(local.round()))
	if sdf <= 0.0:
		return
	global_position = _planet.to_global(local) + up * 0.5
	reset_physics_interpolation()
	velocity = Vector3.ZERO
	swimming = false
	ready_to_move = false
	push_warning("EdenPlayer: fell under the terrain, put back on the surface")


func _set_crouching(want: bool) -> void:
	if want == crouching:
		return
	if not want:
		# Stand up only with room overhead
		var up := up_direction
		var q := PhysicsShapeQueryParameters3D.new()
		var standing := CapsuleShape3D.new()
		standing.radius = RADIUS
		standing.height = STAND_HEIGHT
		q.shape = standing
		q.transform = Transform3D(global_basis, global_position + up * (STAND_HEIGHT * 0.5 + 0.05))
		q.exclude = [get_rid()]
		q.collision_mask = collision_mask
		if not get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty():
			return
	crouching = want
	var h := CROUCH_HEIGHT if crouching else STAND_HEIGHT
	_shape.height = h
	_collision.position = Vector3(0, h * 0.5, 0)


## Sprint: Shift pressed again right after letting go of it (a double tap, or a quick re-press while running) starts
## it, held; it ends on release, after sprint_duration seconds (back to the run while Shift stays down), or when it
## can't go on (crouched, stopped, backing up)
func _update_sprint(delta: float, can: bool) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if Input.is_action_just_released("sprint"):
		_last_run_release = now
	if not typing and Input.is_action_just_pressed("sprint") and now - _last_run_release < DOUBLE_TAP:
		sprinting = true
		_sprint_time = 0.0
	if sprinting:
		_sprint_time += delta
		if not _held("sprint") or not can or _sprint_time > sprint_duration:
			sprinting = false


func _update_animation(horizontal: Vector3, delta: float) -> void:
	if _jump_time >= 0.0:
		_jump_time += delta
	if is_on_floor():
		_jump_time = -1.0
	var up := up_direction
	animator.ground_speed = horizontal.length()
	# Direction of travel in the model's frame (it faces the body's -Z: x its left, y ahead)
	var travel := Vector2(horizontal.dot(-global_basis.x), horizontal.dot(-global_basis.z))
	if travel.length() > 0.05:
		animator.move_direction = travel.normalized()
	# In the air only after a jump or a real drop: a moment off the ground (a bump) keeps the gait going
	animator.airborne = not is_on_floor() and (_jump_time >= 0.0 or _air_time >= COYOTE_TIME)
	animator.crouching = crouching
	animator.swimming = swimming
	animator.vertical_speed = velocity.dot(up)
	# Slope along the direction of travel, for the uphill/downhill gaits (their clips are 25 degrees)
	var n := get_floor_normal() if is_on_floor() else up
	var along := horizontal.normalized() if horizontal.length() > 0.05 else _facing
	animator.incline = clampf(asin(clampf(-n.dot(along), -1.0, 1.0)) / deg_to_rad(25.0), -1.0, 1.0)


# A foot came down: the synth's step for the ground here (snowed-on or rain-soaked ground sounds so)
func _on_step(foot: int, strength: float) -> void:
	if swimming:
		_steps.trigger_footstep(AudioStreamEdenAmbience.SURFACE_WET, strength, -0.15 if foot == 0 else 0.15) # stroke splash
		return
	var surface := AudioStreamEdenAmbience.SURFACE_GRASS
	var mat := miner.material_at(global_position - up_direction * 0.3) if miner else -1
	if mat < 0 and _planet and _planet.get("generator") and _planet.generator.has_method("sample_surface"):
		mat = int(_planet.generator.sample_surface(global_position - _center()).material)
	# V4 materials line up with the synth's surfaces (grass rock snow sand dirt moss); the ocean floor is sand
	surface = mat if mat >= 0 and mat <= AudioStreamEdenAmbience.SURFACE_MOSS else AudioStreamEdenAmbience.SURFACE_SAND
	if _ambience:
		var w: Dictionary = _ambience.call("get_weather_at", global_position)
		if float(w.get("snow", 0.0)) > 0.35:
			surface = AudioStreamEdenAmbience.SURFACE_SNOW
		elif float(w.get("wetness", 0.0)) > 0.5 and surface != AudioStreamEdenAmbience.SURFACE_ROCK:
			surface = AudioStreamEdenAmbience.SURFACE_WET
	_steps.trigger_footstep(surface, strength, -0.15 if foot == 0 else 0.15)


func _held(action: String) -> bool:
	return not typing and Input.is_action_pressed(action)


## A panel that needs the pointer is open (settings, calendar, the build menu)
func ui_open() -> bool:
	return typing or (settings_menu != null and settings_menu.visible) or (calendar_panel != null and calendar_panel.visible) \
			or (builder != null and builder._menu != null and builder._menu.visible)


func _process(_delta: float) -> void:
	# Each panel captures the mouse when it closes, though another may still be open (it vanished over the calendar
	# after closing settings): while any is open the pointer shows
	if ui_open() and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# Camera height eases between standing, crouched and swimming (lifted clear of the water)
	var cam_target := camera_height - 0.5 if crouching else (camera_height + 0.8 if swimming else camera_height)
	_cam_height = lerpf(_cam_height, cam_target, 1.0 - exp(-_delta * 6.0))
	if _camera:
		_camera.fov = EdenOptions.fov
	# Camera: above the character, turned to the camera heading and pitched, aligned with the planet
	# The camera follows where the body is drawn (interpolated between physics steps), not the physics position,
	# which moves in 60 Hz steps: on a faster display the whole world shuddered against the character
	var up := (get_global_transform_interpolated().origin - _center()).normalized()
	_cam_anchor = ease_anchor(_cam_anchor, get_global_transform_interpolated().origin, up, _delta)
	var body := _cam_anchor
	var heading := _north(up).rotated(up, _yaw)
	_pivot.global_transform = Transform3D(Basis.looking_at(heading, up) * Basis(Vector3.RIGHT, _pitch),
			body + up * _cam_height + heading.cross(up) * camera_shoulder)
	_arm.spring_length = camera_distance
	_keep_camera_above_snow(up, _delta)
	if _hud and _hud.visible:
		var status := "" if ready_to_move else "\nWaiting for terrain collision under the player..."
		var mine := "\nHold LMB dig / chop trees, RMB place, T brush, 1-6 / wheel select, Tab inventory   G hammer (build)" if miner else ""
		if net:
			mine += "\nMultiplayer: %s, %d online" % [net.status, net.online_count()]
		_hud.text = "%s\nWASD move, Shift run (2x hold: sprint), Ctrl/C crouch, Space jump, mouse look (click)   N / B weather, L lightning, K calendar   Esc settings   F1 hide   F2-F8 debug%s%s" % [
				readings(), mine, status]


## EdenDebug fly / no-clip: along the view (pitch included), Space up, Ctrl/C down, Shift faster. No-clip moves the
## body straight through everything (its collision shape is off); fly slides along what it hits.
func _fly_step(delta: float, input: Vector2, heading: Vector3, right: Vector3, up: Vector3) -> void:
	var dir := heading.rotated(right, _pitch) * input.y + right * input.x
	dir += up * (float(_held("jump")) - float(_held("crouch")))
	var speed := debug.fly_speed * (8.0 if _held("sprint") else 1.0)
	velocity = dir.limit_length(1.0) * speed
	if debug.noclip:
		global_position += velocity * delta
	else:
		move_and_slide()
	swimming = false
	_set_crouching(false)
	_air_time = 0.0
	_jump_time = -1.0
	_was_on_floor = true
	_facing = heading
	global_basis = Basis.looking_at(_facing, up)
	_update_animation(Vector3.ZERO, delta)


## Speed multiplier in lying snow at a spot: wading through its full depth (0.35 m) takes nearly half the speed
func _snow_slowdown(at: Vector3) -> float:
	if not _ambience:
		return 1.0
	var depth: float = _ambience.call("get_snow_depth_at", at)
	return 1.0 - 0.55 * clampf(depth / 0.35, 0.0, 1.0)


## The spring arm stops at solid ground, but lying snow is drawn above it: raise the camera (eased) to stay over
## the snow's surface where it sits
func _keep_camera_above_snow(up: Vector3, delta: float) -> void:
	var need := 0.0
	if _ambience:
		var cam := _cam_lift.global_position   # where the arm put the camera, before the lift
		var q := PhysicsRayQueryParameters3D.create(cam + up * 2.0, cam - up * 3.0, 1, [get_rid()])
		var hit := get_world_3d().direct_space_state.intersect_ray(q)
		if not hit.is_empty():
			var snow: float = _ambience.call("get_snow_depth_at", hit.position)
			need = maxf(0.0, (snow + 0.3) - (cam - hit.position).dot(up))
	_snow_lift = lerpf(_snow_lift, need, 1.0 - exp(-delta * 10.0))
	_camera.position = _cam_lift.global_basis.inverse() * (up * _snow_lift)


## Presses a path into lying snow from where the last press was to `at`: a continuous stroke, so no gaps open at speed
## or over a bump (`grounded` false, e.g. mid-jump, lifts the pen)
static func press_snow_stroke(ambience: Node, last: Variant, at: Vector3, grounded: bool) -> Variant:
	if ambience == null or not grounded or float(ambience.get_snow_depth_at(at)) <= 0.005:
		return at if grounded else null
	var from: Vector3 = last if last is Vector3 and (last as Vector3).distance_to(at) < 3.0 else at
	var n := ceili(from.distance_to(at) / 0.15)
	for i in range(1, n + 1):
		ambience.press_snow(from.lerp(at, float(i) / n), 0.4, 1.0)
	if n == 0:
		ambience.press_snow(at, 0.4, 1.0)
	return at


## Where the camera anchors to the body: exactly along the ground, eased along up. Physics contacts (the capsule
## settling against terrain, rocks and trunks) shiver the body a few centimetres up and down every few steps; copied
## straight into the camera that shook the whole view. A jump of more than 2 m (teleport, respawn) snaps.
static func ease_anchor(anchor: Vector3, body: Vector3, up: Vector3, delta: float) -> Vector3:
	var d := body - anchor
	if d.length() > 2.0:
		return body
	var vertical := d.dot(up)
	return anchor + (d - up * vertical) + up * vertical * (1.0 - exp(-delta * 12.0))
