extends SceneTree
## Shoreline look: finds the nearest coast from the spawn (V4 sample_surface crossing sea level), no-clips the player
## 40 m out to sea, 10 m up, at local noon, and saves views toward the coast and out to sea, once per
## floor_reject_band value given (default: the material's own). --debug-depth adds the same views colour-coded by
## what the ocean's depth read hits.
##   godot --audio-driver Dummy --path demo_eden --resolution 960x540 -s res://_shore_capture.gd -- --out=<dir> [--bands=3.5,0.3] [--debug-depth]

var play: Node
var player: EdenPlayer
var out := "user://"
var bands: Array = []


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.trim_prefix("--out=")
		elif a.begins_with("--bands="):
			bands = Array(a.trim_prefix("--bands=").split(",")).map(func(s): return float(s))
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
	var planet: Node3D = player._planet
	var gen = planet.generator
	var sea: float = gen.sea_level
	var center := planet.global_position
	var up0 := (player.global_position - center).normalized()
	# Walk out along 16 headings until the ground crosses sea level
	var best := {}
	for i in 16:
		var dir := EdenPlayer._north(up0).rotated(up0, TAU * i / 16.0)
		var axis := up0.cross(dir).normalized()
		var prev_land := float(gen.sample_surface(up0).height) > sea
		for s in range(1, 400):
			var d := up0.rotated(axis, -s * 15.0 / player._sea_radius) # (toward dir)
			var land := float(gen.sample_surface(d).height) > sea
			if land != prev_land:
				if best.is_empty() or s < best.s:
					best = {"s": s, "dir": d, "land_first": prev_land, "axis": axis}
				break
	if best.is_empty():
		print("SHORE no coast within 6 km")
		quit(1)
		return
	print("SHORE coast %.0f m away" % (best.s * 15.0))
	# Hover 40 m out to sea, 10 m above the water, looking back at the coast
	var out_to_sea: float = (40.0 if best.land_first else -40.0) / player._sea_radius
	var at: Vector3 = (best.dir as Vector3).rotated(best.axis, -out_to_sea)
	player.debug.set_noclip(true)
	player.global_position = center + at * (player._sea_radius + 10.0)
	var up := at
	var to_land: Vector3 = best.dir as Vector3 - at
	to_land = (to_land - up * to_land.dot(up)).normalized()
	player._yaw = EdenPlayer._north(up).signed_angle_to(to_land, up)
	# Local noon, clock stopped
	var cal := player.calendar
	cal.running = false
	cal.days += fposmod(12.0 - cal.local_hour(up), 24.0) / 24.0
	cal.call("_apply")
	await _seconds(12.0) # terrain and collision stream in around the new spot
	var ocean: EdenPlanetOcean = planet.find_children("*", "EdenPlanetOcean", true, false)[0]
	var mat: ShaderMaterial = ocean.material
	if bands.is_empty():
		bands = [mat.get_shader_parameter("floor_reject_band")]
	for b in bands:
		mat.set_shader_parameter("floor_reject_band", b)
		await _views("band_%s" % str(b))
	if "--debug-depth" in OS.get_cmdline_user_args():
		# What the depth read hits: R metres behind the surface (0..6), G its height vs sea level (-4..4 m),
		# B lit where it is (within 5 cm) the water pixel itself
		var sh := Shader.new()
		var code: String = mat.shader.code
		code = code.replace("void fragment() {", "void fragment() {\n\tfloat dbg_z = -1.0; float dbg_h = 0.0;")
		var probe := "z_behind = depth_from_water_to_object(SCREEN_UV, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX, VERTEX);"
		code = code.replace(probe, probe + """
			{ float dr = textureLod(depth_texture, SCREEN_UV, 0.0).r;
			  vec4 vv = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, dr, 1.0); vv.xyz /= vv.w;
			  vec3 ww = (INV_VIEW_MATRIX * vec4(vv.xyz, 1.0)).xyz;
			  dbg_h = length(ww - planet_center) - planet_radius; dbg_z = -vv.z + VERTEX.z; }""")
		var last := code.rfind("}")
		code = code.substr(0, last) + "\tALBEDO = vec3(clamp(dbg_z / 6.0, 0.0, 1.0), clamp(dbg_h / 8.0 + 0.5, 0.0, 1.0), abs(dbg_z) < 0.05 ? 1.0 : 0.0);\n\tEMISSION = vec3(0.0);\n}\n"
		sh.code = code
		mat.shader = sh
		await _views("depth")
	print("SHORE done")
	quit(0)


## Screenshots toward the coast (steep and low) and out to sea (low and grazing)
func _views(tag: String) -> void:
	for view in [["shore", -0.35, 0.0], ["shore_low", -0.08, 0.0], ["sea", -0.1, PI], ["sea_grazing", -0.02, PI]]:
		player._pitch = view[1]
		player._yaw += view[2]
		await _seconds(1.0)
		root.get_viewport().get_texture().get_image().save_png(out.path_join("%s_%s.png" % [tag, view[0]]))
		player._yaw -= view[2]
	print("SHORE shots ", tag)


func _seconds(s: float) -> void:
	var end := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < end:
		await process_frame
