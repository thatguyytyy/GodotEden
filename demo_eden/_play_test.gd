extends SceneTree
## Drives eden_play.tscn with simulated input and checks the character: spawns onto terrain collision, walks,
## runs, jumps and lands, crouch-walks, with the matching animations; also cycles the weather. Saves screenshots.
##   godot --audio-driver Dummy --path demo_eden --resolution 960x540 -s res://_play_test.gd -- --out=<dir>
##       [--scene=res://_ocean_editor_probe.tscn]  (any scene with an EdenPlayer; default eden_play.tscn)
## (Needs a window: the planet scene doesn't run headless.)

var play: Node
var player: EdenPlayer
var ambience: Node
var out := "user://"
var t0 := 0
var step := 0
var ok := true
var start_pos: Vector3
var anims_seen := {}
var min_height := INF
var max_height := -INF
var _ready_at := -1.0
var steps_heard := 0
var dig_hit := 0.0
var dig_at := Vector3.ZERO
var dug_item := -1


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.trim_prefix("--out=")
	var scene_path := "res://eden_play.tscn"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--scene="):
			scene_path = a.trim_prefix("--scene=")
	play = load(scene_path).instantiate()
	root.add_child(play)
	current_scene = play # the player only takes over in the scene being played
	t0 = Time.get_ticks_msec()


func _check(cond: bool, msg: String) -> void:
	print("PLAY_TEST %s %s" % ["ok  " if cond else "FAIL", msg])
	ok = ok and cond


func _el() -> float:
	return (Time.get_ticks_msec() - t0) / 1000.0


func _next() -> void:
	step += 1
	t0 = Time.get_ticks_msec()


func _shot(name: String) -> void:
	root.get_viewport().get_texture().get_image().save_png(out.path_join("play_%s.png" % name))


func _release_all() -> void:
	for a in ["move_forward", "sprint", "crouch", "jump"]:
		Input.action_release(a)


func _process(_d: float) -> bool:
	if player == null:
		for n in play.find_children("*", "CharacterBody3D", true, false):
			if n is EdenPlayer:
				player = n
		if player and player._planet:
			ambience = player._planet.get_node_or_null("EdenAmbience")
		if player:
			player.animator.step.connect(func(_f, _s): steps_heard += 1)
		return false
	var cur: String = player.animator.state
	anims_seen[cur] = true

	var h: float = player.global_position.length()
	match step:
		0: # wait for terrain collision under the spawn
			if player.ready_to_move and _ready_at < 0:
				_ready_at = _el()
			if _ready_at >= 0 and _el() > _ready_at + 1.5: # settled onto the ground
				_check(true, "spawned onto terrain collision after %.1f s" % _el())
				_face_clear_way()
				start_pos = player.global_position
				_shot("idle")
				_check(cur == "idle", "idle animation at rest (%s)" % cur)
				Input.action_press("move_forward")
				_next()
			elif _el() > 90.0:
				_check(false, "terrain collision under the spawn within 90 s")
				return _finish()
		1: # walk 4 s
			if _el() > 4.0:
				var d := player.global_position.distance_to(start_pos)
				_check(d > 3.5 and d < 9.0, "walked %.1f m in 4 s" % d)
				_check(cur == "walk", "walk animation (%s)" % cur)
				_check(player._air_time < EdenPlayer.COYOTE_TIME, "still on the ground")
				_check(steps_heard >= 8, "%d footsteps in 4 s of walking" % steps_heard)
				_shot("walk")
				start_pos = player.global_position
				Input.action_press("sprint")
				_next()
		2: # run 3 s
			if _el() > 3.0:
				var d := player.global_position.distance_to(start_pos)
				_check(d > 6.0, "ran %.1f m in 3 s" % d)
				_check(cur == "run", "run animation (%s)" % cur)
				_shot("run")
				Input.action_release("sprint")
				Input.action_press("jump")
				min_height = h
				max_height = h
				_next()
		3: # jump and land
			Input.action_release("jump")
			max_height = maxf(max_height, h)
			if _el() > 0.25 and _el() < 0.35:
				_shot("jump")
			if _el() > 2.0:
				var cols := []
				for i in player.get_slide_collision_count():
					var c := player.get_slide_collision(i)
					cols.append([c.get_collider().name if c.get_collider() else null, rad_to_deg(c.get_angle(0, player.up_direction))])
				print("PLAY_TEST info after jump: floor=%s vel=%s touching=%s" % [player.is_on_floor(), player.velocity, cols])
				_check(max_height - min_height > 0.5, "jumped %.2f m up" % (max_height - min_height))
				_check(anims_seen.has("jump") and anims_seen.has("fall"), "jump and fall animations played")
				# (grounded as the player counts it: pressed against a trunk, floor contact flickers frame to frame)
				_check(player._air_time < EdenPlayer.COYOTE_TIME, "landed back on the ground")
				start_pos = player.global_position
				# Back along the way we came, which is known to be clear (straight on there may be a tree)
				player._yaw += PI
				Input.action_press("crouch")
				_next()
		4: # crouch-walk 3 s
			if _el() > 3.0:
				var d := player.global_position.distance_to(start_pos)
				_check(player.crouching and cur == "crouch_walk", "crouch-walking (%s)" % cur)
				_check(d > 1.5 and d < 5.0, "crouch-walked %.1f m in 3 s" % d)
				_shot("crouch")
				_release_all()
				player._pitch = -0.7 # look down at the ground ahead
				_next()
		5: # mining: dig three times into the ground, the hit moves away; place one back
			if _el() > 1.0 and dig_at == Vector3.ZERO:
				_check(player.miner.has_target, "crosshair on the ground within reach")
				if not player.miner.has_target:
					return _finish()
				dig_at = player.miner.target_position
				dig_hit = _ground_below(dig_at)
				print("PLAY_TEST info voxel material at target: %d" % player.miner.material_at(player.miner.target_position - player.miner.target_normal * 0.3))
				_shot("before_dig")
				for i in 3:
					dug_item = player.miner.dig()
				_shot("dig")
			elif _el() > 3.0:
				var after := _ground_below(dig_at)
				_check(after < dig_hit - 0.3, "digging lowered the ground %.2f m" % (dig_hit - after))
				_check(dug_item >= 0 and player.miner.counts[dug_item] == 3, "collected 3 %s" % (EdenMiner.ITEMS[dug_item][0] if dug_item >= 0 else "?"))
				_shot("hole")
				player.miner.select(dug_item)
				_check(player.miner.place() and player.miner.counts[dug_item] == 2, "placed one back (%d left)" % player.miner.counts[dug_item])
				_shot("placed")
				player._pitch = -0.25
				_next()
		6: # weather keys: step through to Snow
			if _el() > 1.0:
				for i in 4:
					ambience.cycle_weather(1)
				_check(ambience.get_weather_name() == "Snow", "weather cycles (now %s)" % ambience.get_weather_name())
				_next()
		7:
			if _el() > 8.0:
				_shot("snow")
				_check(ambience.get_debug_state().effects[EdenAmbience.FX_SNOW] > 0.2, "snowing around the player")
				return _finish()
	return false


# Height (along up) of the ground under p, from a vertical ray: the dig check doesn't depend on the view angle
func _ground_below(p: Vector3) -> float:
	var up := player.up_direction
	var q := PhysicsRayQueryParameters3D.create(p + up * 3.0, p - up * 3.0, player.collision_mask, [player.get_rid()])
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	return (hit.position - p).dot(up) if not hit.is_empty() else -3.0


# Turns the player toward the heading with the longest clear path (trees and rocks stand anywhere around a spawn)
func _face_clear_way() -> void:
	var up := player.up_direction
	var space := player.get_world_3d().direct_space_state
	var best := -1.0
	var best_yaw := player._yaw
	for k in 12:
		var yaw := TAU * k / 12.0
		var dir := EdenPlayer._north(up).rotated(up, yaw)
		# A sphere as wide as the body at knee and chest height: a thin ray slipped past logs and rocks the capsule hits
		var free := 30.0
		var ball := SphereShape3D.new()
		ball.radius = 0.35
		for h in [0.5, 1.2]:
			var q := PhysicsShapeQueryParameters3D.new()
			q.shape = ball
			q.transform = Transform3D(Basis(), player.global_position + up * h)
			q.motion = dir * 30.0
			q.collision_mask = player.collision_mask
			q.exclude = [player.get_rid()]
			var frac := space.cast_motion(q)
			free = minf(free, 30.0 * frac[0])
		if free > best:
			best = free
			best_yaw = yaw
	player._yaw = best_yaw
	print("PLAY_TEST info heading %.0f°: %.1f m clear" % [rad_to_deg(best_yaw), best])


func _finish() -> bool:
	_release_all()
	print("PLAY_TEST ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
	return true
