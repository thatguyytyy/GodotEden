extends SceneTree
## EdenCharacterAnim check: drives eden_character.tscn through each state and asserts the state machine, the
## footsteps and the pose follow. With a window (no --headless) it also saves a contact sheet of the states to
## user://synty_states.png.
##   godot --path demo_eden -s Character/_synty_anim_test.gd [--headless]

var ch: Node3D
var anim: EdenCharacterAnim
var skel: Skeleton3D
var steps := 0
var fails := 0
var shots: Array[Image] = []


func _initialize() -> void:
	_run()


func _run() -> void:
	var headless := DisplayServer.get_name() == "headless"
	if not headless:
		var cam := Camera3D.new()
		root.add_child(cam)
		cam.look_at_from_position(Vector3(2.2, 1.3, 2.2), Vector3(0, 0.9, 0))
		var sun := DirectionalLight3D.new()
		root.add_child(sun)
		sun.rotation = Vector3(-0.8, 0.6, 0)
		var env := WorldEnvironment.new()
		env.environment = Environment.new()
		env.environment.background_mode = Environment.BG_COLOR
		env.environment.background_color = Color(0.25, 0.28, 0.32)
		env.environment.ambient_light_color = Color(0.6, 0.6, 0.6)
		env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		root.add_child(env)
	ch = load("res://Character/eden_character.tscn").instantiate()
	root.add_child(ch)
	anim = ch.get_node("AnimationTree")
	skel = ch.get_node("Model/Skeleton3D")
	anim.step.connect(func(_f, _s): steps += 1)
	var pb: AnimationNodeStateMachinePlayback = anim.get("parameters/playback")

	await _frames(10)
	_expect(pb.get_current_node() == &"Grounded", "starts Grounded, got %s" % pb.get_current_node())
	var idle_hips := _hips()
	await _shot("idle")

	anim.ground_speed = 1.45
	steps = 0
	await _seconds(2.06) # two walk cycles
	_expect(anim.state == "walk", "walk state, got %s" % anim.state)
	_expect(steps >= 3 and steps <= 5, "~4 steps in two walk cycles, got %d" % steps)
	_expect(_hips().distance_to(idle_hips) > 0.005, "the pose moves when walking")
	await _shot("walk")
	anim.ground_speed = 2.6
	await _seconds(1.0)
	_expect(anim.state == "run", "run state, got %s" % anim.state)
	await _shot("run")
	# Backing up plays the backward clips: the left ankle ends up behind the right at a different phase than ahead
	var ahead: float = await _ankles_over(0.7)
	anim.move_direction = Vector2(0, -1)
	await _seconds(0.3)
	var back: float = await _ankles_over(0.7)
	_expect(absf(ahead - back) > 0.05, "backward gait differs from forward (%.2f vs %.2f)" % [ahead, back])
	await _shot("run backward")
	anim.move_direction = Vector2(1, 0)
	await _seconds(0.3)
	await _shot("run left")
	anim.move_direction = Vector2(0, 1)
	anim.ground_speed = 7.0
	await _seconds(1.0)
	_expect(anim.state == "sprint", "sprint state, got %s" % anim.state)
	await _shot("sprint")
	anim.incline = 1.0
	await _seconds(1.0)
	await _shot("run uphill")
	anim.incline = 0.0
	anim.ground_speed = 1.0
	anim.crouching = true
	await _seconds(1.0)
	_expect(anim.state == "crouch_walk", "crouch_walk state, got %s" % anim.state)
	_expect(_hips().y < idle_hips.y - 0.15, "hips drop crouching (%.2f vs %.2f)" % [_hips().y, idle_hips.y])
	await _shot("crouch walk")
	anim.crouching = false
	anim.ground_speed = 0.0
	await _seconds(0.5)

	anim.airborne = true
	anim.vertical_speed = 5.0
	await _seconds(0.3)
	_expect(pb.get_current_node() == &"Jump", "jump -> Jump, got %s" % pb.get_current_node())
	await _shot("jump")
	anim.vertical_speed = -6.0
	await _seconds(0.5)
	_expect(pb.get_current_node() == &"Fall", "descending -> Fall, got %s" % pb.get_current_node())
	await _shot("fall")
	anim.land(9.0)
	anim.airborne = false
	anim.vertical_speed = 0.0
	await _seconds(0.2)
	_expect(pb.get_current_node() == &"Land", "hard landing -> Land, got %s" % pb.get_current_node())
	await _shot("land")
	await _seconds(1.6)
	_expect(pb.get_current_node() == &"Grounded", "Land ends -> Grounded, got %s" % pb.get_current_node())

	# Running landing skips the Land clip
	anim.ground_speed = 4.0
	anim.airborne = true
	anim.vertical_speed = -4.0
	await _seconds(0.5)
	anim.land(4.0)
	anim.airborne = false
	await _seconds(0.3)
	_expect(pb.get_current_node() == &"Grounded", "running landing -> Grounded, got %s" % pb.get_current_node())

	# Cycle rate matches the clips between the blend points
	_expect(is_equal_approx(EdenCharacterAnim.cycle_rate(1.45, anim.STAND_SPEEDS, anim.STAND_CYCLES), 1.0 / 1.03), "walk rate")
	_expect(is_equal_approx(EdenCharacterAnim.cycle_rate(14.48, anim.STAND_SPEEDS, anim.STAND_CYCLES), 2.0 / 0.60), "past sprint scales up")

	if not shots.is_empty():
		var w := shots[0].get_width()
		var h := shots[0].get_height()
		var sheet := Image.create(w * 4, h * ceili(shots.size() / 4.0), false, shots[0].get_format())
		for i in shots.size():
			sheet.blit_rect(shots[i], Rect2i(0, 0, w, h), Vector2i((i % 4) * w, (i / 4) * h))
		sheet.save_png("user://synty_states.png")
		print("contact sheet: ", ProjectSettings.globalize_path("user://synty_states.png"))
	print("PASS" if fails == 0 else "FAIL (%d)" % fails)
	quit(1 if fails else 0)


## Mean forward (z) offset of the left ankle from the right over `s` seconds of play
func _ankles_over(s: float) -> float:
	var total := 0.0
	var n := 0
	var end := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < end:
		await process_frame
		total += skel.get_bone_global_pose(skel.find_bone("Ankle_L")).origin.z - skel.get_bone_global_pose(skel.find_bone("Ankle_R")).origin.z
		n += 1
	return total / maxf(n, 1)


func _hips() -> Vector3:
	return skel.get_bone_global_pose(skel.find_bone("Hips")).origin


func _expect(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok:
		fails += 1


func _shot(label: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await _frames(2)
	var img := root.get_texture().get_image()
	img.resize(480, 360)
	print("shot: ", label)
	shots.append(img)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _seconds(s: float) -> void:
	var end := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < end:
		await process_frame
