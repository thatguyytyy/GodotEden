extends SceneTree
## EdenDebug modes and build-mode camera look, in eden_play.tscn with simulated keys:
## creative refills and restores the inventory, fly rises and holds height, no-clip sinks through the ground and
## walking resumes after, F6/F7 switch the collision view and draw modes, and mouse motion turns the camera while
## EdenBuilder is active. Saves screenshots of the collision and wireframe views.
##   godot --audio-driver Dummy --path demo_eden --resolution 960x540 -s res://Character/_debug_modes_test.gd -- --out=<dir>
## (Needs a window: the planet scene doesn't run headless.)

var play: Node
var player: EdenPlayer
var out := "user://"
var ok := true


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.trim_prefix("--out=")
	play = load("res://eden_play.tscn").instantiate()
	root.add_child(play)
	current_scene = play
	_run()


func _run() -> void:
	while player == null or not player.ready_to_move:
		for n in play.find_children("*", "CharacterBody3D", true, false):
			if n is EdenPlayer:
				player = n
		await process_frame
	await _seconds(1.0)
	var dbg := player.debug
	_check(dbg != null, "EdenDebug added")

	# Creative: 999 of everything, the real counts back afterwards
	var before := player.miner.counts.duplicate()
	_key(KEY_F3)
	await _frames(2)
	_check(player.miner.counts.min() == 999, "creative fills the inventory (%s)" % [player.miner.counts])
	_key(KEY_F3)
	await _frames(2)
	_check(player.miner.counts == before, "creative off restores the inventory")

	# Fly: Space rises, nothing held keeps the height (no gravity)
	var alt0 := player.altitude()
	_key(KEY_F4)
	Input.action_press("jump")
	await _seconds(1.0)
	Input.action_release("jump")
	var alt1 := player.altitude()
	_check(alt1 > alt0 + 5.0, "fly rises (%.1f -> %.1f m)" % [alt0, alt1])
	await _seconds(1.0)
	_check(absf(player.altitude() - alt1) < 0.5, "flying holds its height (%.1f -> %.1f m)" % [alt1, player.altitude()])
	_shot("fly")

	# No-clip: down through the ground
	_key(KEY_F5)
	_check(dbg.noclip and not dbg.fly, "no-clip replaces fly")
	Input.action_press("crouch")
	await _seconds(2.0)
	Input.action_release("crouch")
	_check(player.altitude() < alt0 - 5.0, "no-clip sinks through the ground (%.1f m, ground was %.1f)" % [player.altitude(), alt0])
	Input.action_press("jump")
	while player.altitude() < alt0 + 3.0:
		await process_frame
	Input.action_release("jump")
	_key(KEY_F5)
	_check(not player.get_node("Collision").disabled, "no-clip off restores the collision shape")
	await _seconds(3.0)
	_check(absf(player.altitude() - alt0) < 2.0, "falls back onto the ground (%.1f m vs %.1f)" % [player.altitude(), alt0])

	# Collision shapes and draw modes
	_key(KEY_F6)
	await _seconds(0.5)
	_check(get_tree_hint(), "F6 turns the collision view on")
	_shot("collisions")
	_key(KEY_F6)
	_key(KEY_F7)
	await _frames(3)
	_check(root.get_viewport().debug_draw == Viewport.DEBUG_DRAW_WIREFRAME, "F7 -> wireframe")
	_shot("wireframe")
	for i in 4:
		_key(KEY_F7)
	_check(root.get_viewport().debug_draw == Viewport.DEBUG_DRAW_DISABLED, "F7 cycles back to normal")

	# Sprint: Shift held runs at run_speed; a quick second press held sprints, and the sprint ends after
	# sprint_duration (shortened here) back at the run
	player.sprint_duration = 2.0
	_face_clear_way()
	Input.action_press("move_forward")
	Input.action_press("sprint")
	await _seconds(1.5)
	_check(not player.sprinting and absf(_ground_speed() - player.run_speed) < 0.4, "Shift runs (%.1f m/s)" % _ground_speed())
	Input.action_release("sprint")
	await _frames(3)
	Input.action_press("sprint")
	await _seconds(1.2)
	_check(player.sprinting and _ground_speed() > player.run_speed + 2.0, "double-tap Shift sprints (%.1f m/s)" % _ground_speed())
	await _seconds(1.5)
	_check(not player.sprinting, "the sprint ends after sprint_duration")
	await _seconds(1.0)
	_check(absf(_ground_speed() - player.run_speed) < 0.6, "back to the run pace (%.1f m/s)" % _ground_speed())
	Input.action_release("sprint")
	Input.action_release("move_forward")
	# Backing up: the body keeps facing the camera's heading and the feet go backward
	var facing_before := -player.global_basis.z
	Input.action_press("move_back")
	await _seconds(1.5)
	Input.action_release("move_back")
	var heading := EdenPlayer._north(player.up_direction).rotated(player.up_direction, player._yaw)
	_check((-player.global_basis.z).dot(heading) > 0.8, "backing up doesn't turn round (facing . heading %.2f, was %.2f)" % [(-player.global_basis.z).dot(heading), facing_before.dot(heading)])
	_check(player.animator.move_direction.y < -0.8, "backward gait (direction %s)" % player.animator.move_direction)
	await _seconds(0.5)

	# Build mode: mouse motion still turns the camera
	player.builder.set_active(true)
	await _frames(2)
	var yaw0: float = player._yaw
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	var m := InputEventMouseMotion.new()
	m.relative = Vector2(200, 0)
	Input.parse_input_event(m)
	await _frames(3)
	_check(absf(player._yaw - yaw0) > 0.1, "mouse look works in build mode (yaw %.2f -> %.2f)" % [yaw0, player._yaw])
	player.builder.set_active(false)

	print("DEBUG_TEST ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


# Turns the player toward the heading with the longest clear path (as _play_test.gd does)
func _face_clear_way() -> void:
	var up := player.up_direction
	var space := player.get_world_3d().direct_space_state
	var best := -1.0
	var best_yaw := player._yaw
	for k in 16:
		var yaw := TAU * k / 16.0
		var dir := EdenPlayer._north(up).rotated(up, yaw)
		# A sphere as wide as the body at knee and chest height: a thin ray slipped past logs and rocks the capsule hits
		var free := 40.0
		var ball := SphereShape3D.new()
		ball.radius = 0.35
		for h in [0.5, 1.2]:
			var q := PhysicsShapeQueryParameters3D.new()
			q.shape = ball
			q.transform = Transform3D(Basis(), player.global_position + up * h)
			q.motion = dir * 40.0
			q.collision_mask = player.collision_mask
			q.exclude = [player.get_rid()]
			free = minf(free, 40.0 * space.cast_motion(q)[0])
		if free > best:
			best = free
			best_yaw = yaw
	player._yaw = best_yaw
	print("DEBUG_TEST info heading %.0f deg: %.1f m clear" % [rad_to_deg(best_yaw), best])


func _ground_speed() -> float:
	var up := player.up_direction
	return (player.velocity - up * player.velocity.dot(up)).length()


func get_tree_hint() -> bool:
	return debug_collisions_hint


func _key(k: Key) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.physical_keycode = k
		e.pressed = pressed
		Input.parse_input_event(e)
	Input.flush_buffered_events()


func _check(cond: bool, msg: String) -> void:
	print("DEBUG_TEST %s %s" % ["ok  " if cond else "FAIL", msg])
	ok = ok and cond


func _shot(name: String) -> void:
	root.get_viewport().get_texture().get_image().save_png(out.path_join("debug_%s.png" % name))


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _seconds(s: float) -> void:
	var end := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < end:
		await process_frame
