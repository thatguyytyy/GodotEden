extends SceneTree
## Looks up from the play scene at the parent planet and the moons (the sky shader's painted surfaces, EdenSkyBodies) and saves a
## screenshot of each. -- --seed=N plays that world's sky (as if joined from the menu).
##   godot --path demo_eden --resolution 1280x720 -s res://sky/_sky_capture.gd -- --out=<dir> [--seed=N]

var out := "user://sky_capture"
var play: Node
var player: EdenPlayer


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.trim_prefix("--out=")
		elif a.begins_with("--seed="):
			EdenSession.play_offline("Sky capture", int(a.trim_prefix("--seed=")))
	DirAccess.make_dir_recursive_absolute(out)
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
	await _seconds(4.0)
	var parent: Node = play.find_children("*", "EdenParentPlanet", true, false)[0]
	var atmo: Node = play.find_children("*", "EdenPlanetAtmosphere", true, false)[0]
	print("SKY bodies ", EdenSkyBodies.world_bodies(int(player._planet.generator.seed)))
	print("SKY styles parent ", parent.get("parent_planet_style"), " moon ", atmo.get("moon_style"), " moonb ", atmo.get("moonb_style"))
	# A camera above the trees with a long lens, aimed straight at each body
	var cam := Camera3D.new()
	cam.fov = 45.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--fov="): # wider, to see the bodies against the sky
			cam.fov = float(a.trim_prefix("--fov="))
	cam.far = 100000.0
	play.add_child(cam)
	var up := player.up_direction
	cam.global_position = player.global_position + up * 150.0
	cam.make_current()
	for a in OS.get_cmdline_user_args(): # --cloud_<prop>=value on the EdenCloudShell (e.g. --cloud_cloud_facet_mix=0)
		if a.begins_with("--cloud_"):
			var kv := a.trim_prefix("--cloud_").split("=")
			for c in play.find_children("*", "EdenCloudShell", true, false):
				c.set(kv[0], str_to_var(kv[1]))
	if "--clear" in OS.get_cmdline_user_args():
		# No clouds in the way, and the hour when the sun lights the parent planet's near side
		for c in play.find_children("*", "EdenCloudShell", true, false):
			c.visible = false
		var cal := player.calendar
		cal.running = false
		var pdir: Vector3 = (parent.get("parent_planet_direction") as Vector3).normalized()
		var best_days := cal.days
		var best := INF
		for k in 48:
			cal.days = floor(cal.days) + k / 48.0
			cal.call("_apply")
			await process_frame
			var s: Vector3 = atmo.get_sun_direction()
			if s.dot(pdir) < best:
				best = s.dot(pdir)
				best_days = cal.days
		cal.days = best_days
		cal.call("_apply")
		print("SKY sun . parent = %.2f" % best)
		await _seconds(1.0)
	if "--motion" in OS.get_cmdline_user_args():
		# The painted surfaces move: two frames of the gas giant 2 s apart, with the clock sped up
		var d: Vector3 = (parent.get("parent_planet_direction") as Vector3).normalized()
		cam.look_at(cam.global_position + d, up)
		parent.set("parent_planet_style", 1)
		parent.set("parent_planet_band_speed", 0.3)
		await _seconds(0.5)
		var a := root.get_viewport().get_texture().get_image()
		await _seconds(2.0)
		var b := root.get_viewport().get_texture().get_image()
		var diff := 0.0
		for y in range(200, 520, 4):
			for x in range(440, 840, 4):
				var ca := a.get_pixel(x, y)
				var cb := b.get_pixel(x, y)
				diff += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
		print("SKY motion: mean change %.4f per pixel over 2 s" % (diff / (80.0 * 100.0)))
		b.save_png(out.path_join("motion_b.png"))
		a.save_png(out.path_join("motion_a.png"))
		quit(0)
		return
	if "--all-styles" in OS.get_cmdline_user_args():
		var d: Vector3 = (parent.get("parent_planet_direction") as Vector3).normalized()
		cam.look_at(cam.global_position + d, up)
		parent.set("parent_planet_enabled", true)
		parent.set("parent_planet_style", 0)
		parent.set("parent_planet_shade_bands", 1)
		for st in range(1, EdenSkyBodies.PLANET_STYLES.size()):
			var look: Dictionary = EdenSkyBodies.PLANET_LOOKS[st].merged(EdenSkyBodies.PARENT_COMMON)
			look.planet_seed = 123.0
			var painter := EdenSkyBodies._painter(play.get_child(0), "parent", EdenSkyBodies.PARENT_MAP, look)
			parent.set("parent_planet_texture", painter.get_texture())
			await _seconds(0.8)
			root.get_viewport().get_texture().get_image().save_png(out.path_join("parent_style_%d.png" % st))
			painter.get_texture().get_image().save_png(out.path_join("parent_map_%d.png" % st))
			print("SKY shot parent style ", st, " ", EdenSkyBodies.PLANET_STYLES[st])
		for st in range(1, EdenSkyBodies.MOON_STYLES.size()):
			var look: Dictionary = EdenSkyBodies.MOON_LOOKS[st].merged(EdenSkyBodies.MOON_COMMON)
			look.planet_seed = 321.0
			var painter := EdenSkyBodies._painter(play.get_child(0), "moon", EdenSkyBodies.MOON_MAP, look)
			await _seconds(0.3)
			painter.get_texture().get_image().save_png(out.path_join("moon_map_%d.png" % st))
			print("SKY moon map ", st, " ", EdenSkyBodies.MOON_STYLES[st])
		quit(0)
		return
	for target in [["parent", parent.get("parent_planet_direction")], ["moon", atmo.get("moon_direction")], ["moonb", atmo.get("moonb_direction")]]:
		var d: Vector3 = (target[1] as Vector3).normalized()
		cam.look_at(cam.global_position + d, up if absf(d.dot(up)) < 0.99 else up.cross(Vector3.RIGHT))
		await _seconds(1.0)
		root.get_viewport().get_texture().get_image().save_png(out.path_join("sky_%s.png" % target[0]))
		print("SKY shot ", target[0], " dir ", target[1])
	quit(0)


# Turns the player's camera toward a sky direction (planet-relative, as the sky nodes give them)
func _look_at(dir: Vector3) -> void:
	var up := player.up_direction
	var d := (dir as Vector3).normalized()
	var flat := (d - up * d.dot(up)).normalized()
	player._yaw = EdenPlayer._north(up).signed_angle_to(flat, up)
	player._pitch = clampf(asin(clampf(d.dot(up), -1.0, 1.0)) - 0.25, player.camera_min_pitch, player.camera_max_pitch)


func _seconds(s: float) -> void:
	var end := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < end:
		await process_frame
