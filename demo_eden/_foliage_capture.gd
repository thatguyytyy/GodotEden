extends SceneTree
## Ground-level captures of EdenFoliage per biome on the probe scene, with the sun moved over each spot.
##   godot --path demo_eden --resolution 1280x720 -s res://_foliage_capture.gd -- --biome=temperate --out=<png>
## Biomes: temperate, boreal, tropical, dry, tundra, cliff.

const QUIET_S := 4.0
const CRITERIA := {
	# temperature range, moisture range
	"temperate": [Vector2(0.45, 0.7), Vector2(0.5, 1.0)],
	"boreal": [Vector2(0.12, 0.35), Vector2(0.4, 1.0)],
	"tropical": [Vector2(0.78, 1.0), Vector2(0.55, 1.0)],
	"dry": [Vector2(0.6, 1.0), Vector2(0.0, 0.3)],
	"tundra": [Vector2(0.0, 0.1), Vector2(0.0, 1.0)],
}

var args := {}
var terrain: VoxelLodTerrain
var foliage: VoxelInstancer
var last_sig := ""
var stable_since := 0
var start := 0
var gpu_ms: Array[float] = []


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=")
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var scene: Node = load("res://_ocean_editor_probe.tscn").instantiate()
	root.add_child(scene)
	terrain = scene.get_node("VoxelLodTerrain")
	foliage = terrain.get_node("EdenFoliage")
	for k in args: # --f_<export>=value overrides EdenFoliage exports (before it builds on entering the tree)
		if k.begins_with("f_"):
			foliage.set(k.substr(2), str_to_var(args[k]))
	var amb := terrain.get_node_or_null("EdenAmbience")
	for k in args: # --amb_<export>=value overrides EdenAmbience exports
		if k.begins_with("amb_") and amb:
			amb.set(k.substr(4), str_to_var(args[k]))
		if k.begins_with("atmo_"): # --atmo_<export>=value overrides EdenPlanetAtmosphere exports
			terrain.get_node("EdenPlanetAtmosphere").set(k.substr(5), str_to_var(args[k]))
	var cal := scene.get_node_or_null("EdenCalendar")
	for k in args: # --cal_<export>=value overrides EdenCalendar exports (e.g. --cal_month=10 --cal_running=false)
		if k.begins_with("cal_") and cal:
			cal.set(k.substr(4), str_to_var(args[k]))
	if args.has("hide"): # --hide=<node path under the scene root>
		scene.get_node(args.hide).visible = false
	var gen: EdenPlanetGeneratorV4 = terrain.generator
	for k in args: # --gen_<export>=value overrides the planet generator (e.g. --gen_cliff_strength=0)
		if k.begins_with("gen_"):
			gen.set(k.substr(4), str_to_var(args[k]))
	var R: float = gen.planet_radius
	var biome: String = args.get("biome", "temperate")

	var golden := PI * (3.0 - sqrt(5.0))
	var best := Vector3.UP
	var best_score := -INF
	for i in 6000:
		var y := 1.0 - float(i) / 5999.0 * 2.0
		var r := sqrt(maxf(0.0, 1.0 - y * y))
		var d := Vector3(cos(golden * i) * r, y, sin(golden * i) * r)
		var s: Dictionary = gen.sample_surface(d)
		if float(s.height) < (1.0 if biome == "beach" else 20.0):
			continue
		var score := 0.0
		if biome == "forest":
			# Deep in a dense forest patch (EdenFoliage's forest mask), on gentle ground
			if float(s.temperature) < 0.4 or float(s.temperature) > 0.7 or float(s.moisture) < 0.5 or float(s.landform) > 0.35:
				continue
			score = foliage.get_forest_density(d * (R + float(s.height))) - _relief(gen, d, 30.0) * 0.01
			if score < 0.9:
				continue
		elif biome == "beach":
			# Warm low shore with sea within ~80 m
			if float(s.height) > 8.0 or float(s.temperature) < 0.5:
				continue
			var tb := d.cross(Vector3.UP if absf(d.y) < 0.99 else Vector3.RIGHT).normalized()
			var wet := false
			for k in 8:
				var o := d.rotated(tb.rotated(d, TAU * k / 8.0), 80.0 / R)
				wet = wet or float(gen.sample_surface(o).height) < -3.0
			if not wet:
				continue
			score = float(s.temperature)
		elif biome == "vista":
			# High ground with temperate, vegetated lowland ~3 km away
			var t0 := d.cross(Vector3.UP if absf(d.y) < 0.99 else Vector3.RIGHT).normalized()
			var low: Dictionary = gen.sample_surface(d.rotated(t0, 3000.0 / R))
			if float(s.height) < 400.0 or float(s.height) > 1000.0 or float(low.height) < 20.0 or float(low.moisture) < 0.45 \
					or float(low.temperature) < 0.3 or float(low.temperature) > 0.75:
				continue
			score = float(s.height) - float(low.height)
		elif biome == "cliff":
			if float(s.landform) < 0.8:
				continue
			score = _relief(gen, d, 60.0)
		else:
			var c: Array = CRITERIA[biome]
			if not _in(float(s.temperature), c[0]) or not _in(float(s.moisture), c[1]) or float(s.landform) > 0.35:
				continue
			score = -_relief(gen, d, 30.0)
		if score > best_score:
			best_score = score
			best = d
	var s0: Dictionary = gen.sample_surface(best)
	print("CAPTURE %s at %s: temp=%.2f moist=%.2f landform=%.2f material=%s score=%.1f" % [biome, best,
			s0.temperature, s0.moisture, s0.landform, s0.material, best_score])

	var up := best
	var t := up.cross(Vector3.UP if absf(up.y) < 0.99 else Vector3.RIGHT).normalized()
	var ground := R + float(s0.height)
	var cam_pos: Vector3
	var look: Vector3
	if biome == "vista":
		# Toward the lowland sampled during selection (d rotated about t), ~5 degrees down
		var toward := (up.rotated(t, 3000.0 / R) - up).normalized()
		cam_pos = up * (ground + 40.0)
		look = toward * 1000.0 - up * 90.0
	elif biome == "cliff":
		# Stand off along the downhill direction, look back at the face
		var down_dir := t
		var lowest := INF
		for k in 8:
			var dir := t.rotated(up, TAU * k / 8.0)
			var h := float(gen.sample_surface(up.rotated(up.cross(dir).normalized(), 80.0 / R)).height)
			if h < lowest:
				lowest = h
				down_dir = dir
		cam_pos = up * (ground + 40.0) + down_dir * 220.0
		look = up * ground - cam_pos
	else:
		cam_pos = up * (ground + float(args.get("alt", "2.5"))) + t * float(args.get("fwd", "0")) # --fwd=<m>: walk toward the view first
		look = t * 50.0 - up * 6.0
	var cam := Camera3D.new()
	cam.far = 30000.0
	cam.current = true
	root.add_child(cam)
	var viewer := VoxelViewer.new()
	viewer.view_distance = 30000
	cam.add_child(viewer)
	var cam_up := cam_pos.normalized()
	cam.transform = Transform3D(Basis.looking_at(look.normalized(), cam_up), cam_pos)
	if args.has("pitch"): # tilt the view up (+) or down (-), degrees
		cam.transform.basis = cam.transform.basis * Basis(Vector3.RIGHT, deg_to_rad(float(args.pitch)))

	# Sun ~55 degrees from overhead at the spot (see EdenPlanetAtmosphere::_update_sun_direction: axis +Y,
	# ea = (0,0,-1), eb = (-1,0,0))
	var atmo := terrain.get_node_or_null("EdenPlanetAtmosphere")
	if atmo:
		atmo.set("sun_declination_deg", rad_to_deg(asin(up.y)))
		atmo.set("sun_time_of_day", fposmod(atan2(-up.x, -up.z) / TAU + float(args.get("sun_offset", "0.15")), 1.0))
	# --storm=<intensity> parks a storm on the camera (--thunder for lightning)
	if args.has("storm") and terrain.has_node("EdenAmbience"):
		terrain.get_node("EdenAmbience").add_storm(cam_pos, 4000.0, float(args.storm), 1e6, args.has("thunder"), args.has("dust"))
	start = Time.get_ticks_msec()
	stable_since = start


func _in(v: float, r: Vector2) -> bool:
	return v >= r.x and v <= r.y


# Max height difference to 8 neighbours at `dist` metres
func _relief(gen: EdenPlanetGeneratorV4, d: Vector3, dist: float) -> float:
	var h0 := float(gen.sample_surface(d).height)
	var t := d.cross(Vector3.UP if absf(d.y) < 0.99 else Vector3.RIGHT).normalized()
	var m := 0.0
	for k in 8:
		var o := d.rotated(t.rotated(d, TAU * k / 8.0), dist / gen.planet_radius)
		m = maxf(m, absf(float(gen.sample_surface(o).height) - h0))
	return m


func _process(_d: float) -> bool:
	if args.has("no_foliage_shadows") and foliage.library and not args.has("_done_shadows"):
		args["_done_shadows"] = true
		for id in foliage.library.get_all_item_ids():
			foliage.library.get_item(id).cast_shadow = RenderingServer.SHADOW_CASTING_SETTING_OFF
	if not args.has("_done_env") and root.get_viewport().world_3d.environment: # --env_<prop>=v overrides the Environment
		args["_done_env"] = true
		for k in args.keys():
			if k.begins_with("env_"):
				root.get_viewport().world_3d.environment.set(k.substr(4), str_to_var(args[k]))
	if args.has("face_sun") and not args.has("_done_face") and terrain.get_node("EdenPlanetAtmosphere").get_sun_direction() != Vector3.UP: # toward the sun azimuth, once the atmosphere has applied the time of day
		args["_done_face"] = true
		var cam := root.get_viewport().get_camera_3d()
		var up := cam.global_position.normalized()
		var sun: Vector3 = terrain.get_node("EdenPlanetAtmosphere").get_sun_direction()
		var flat := (sun - up * sun.dot(up)).normalized()
		cam.global_transform = Transform3D(Basis.looking_at(flat - up * 0.08, up), cam.global_position)
		print("CAPTURE face_sun: sun=", sun, " elev=", sun.dot(up), " fwd=", -cam.global_basis.z)
	var counts: Dictionary = foliage.debug_get_instance_counts()
	var total := 0
	for k in counts:
		total += counts[k]
	var sig := str(terrain.debug_get_mesh_block_count(), "/", total)
	var now := Time.get_ticks_msec()
	if sig != last_sig:
		last_sig = sig
		stable_since = now
	if (now - stable_since > QUIET_S * 1000 and now - start > 8000) or now - start > 120000:
		if args.has("lightning") and _lightning_frame():
			return false
		# Once settled: average GPU time and triangle count over 120 frames before saving
		var vp := root.get_viewport_rid()
		if gpu_ms.is_empty():
			RenderingServer.viewport_set_measure_render_time(vp, true)
		gpu_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(vp))
		if gpu_ms.size() < 120:
			return false
		var tris := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
		var calls := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		var sum := 0.0
		for ms in gpu_ms.slice(20):
			sum += ms
		var at := terrain.get_node("EdenPlanetAtmosphere")
		print("CAPTURE fog: density=", at.fog_density, " falloff=", at.fog_height_falloff, " base=", at.fog_base_altitude, " albedo=", at.fog_albedo, " sun=", at.fog_sun_intensity, " ambient_day=", at.fog_ambient_day)
		var cs := terrain.get_node_or_null("EdenCloudShell")
		if cs:
			print("CAPTURE clouds: storm_map=", cs.get_material().get_shader_parameter("storm_map"), " coverage=", cs.get("cloud_coverage"))
		if terrain.has_node("EdenAmbience"):
			print("CAPTURE ambience: ", terrain.get_node("EdenAmbience").get_debug_state())
		print("CAPTURE perf: gpu %.2f ms, %d primitives, %d draw calls" % [sum / (gpu_ms.size() - 20), tris, calls])
		root.get_viewport().get_texture().get_image().save_png(args.get("out", "res://_foliage_capture.png"))
		var gi = foliage.library.get_item(foliage.library.get_all_item_ids()[0])
		var gg: VoxelInstanceGenerator = gi.generator
		print("ITEM ", gi.name, " lod=", gi.lod_index, " density=", gg.density, " slope=", gg.min_slope_degrees, "-", gg.max_slope_degrees, " mats=", gg.voxel_texture_filter_array, " filt=", gg.voxel_texture_filter_enabled, " temp=", gg.temperature_range, " moist=", gg.moisture_range, " surf=", gg.surface_filter_enabled, " scale=", gg.min_scale, "-", gg.max_scale)
		var nonzero := {}
		var tiers := {}
		var tier_tris := {}
		for k in counts:
			if counts[k] > 0:
				var n: String = foliage.library.get_item(k).name
				nonzero[n] = counts[k]
				var tier := "far" + n.get_slice("_far", 1).get_slice("_", 0) if n.contains("_far") else "near"
				tiers[tier] = tiers.get(tier, 0) + counts[k]
				var it: VoxelInstanceLibraryMultiMeshItem = foliage.library.get_item(k)
				var m: Mesh = it.get_mesh(1) if tier != "near" else it.mesh
				var tri_key := tier + " " + n.get_slice("/", 0) + "/" + n.get_slice("/", 1).get_slice("_", 0)
				tier_tris[tri_key] = tier_tris.get(tri_key, 0) + counts[k] * _tris(m)
		print("CAPTURE instances by tier: ", tiers)
		var keys := tier_tris.keys()
		keys.sort_custom(func(a, b): return tier_tris[a] > tier_tris[b])
		for key in keys.slice(0, 15):
			print("CAPTURE tris %s: %d" % [key, tier_tris[key]])
		print("CAPTURE saved; library items=%d config=%s; instances by layer: " % [foliage.library.get_all_item_ids().size() if foliage.library else -1, foliage.get("config")], nonzero)
		return true
	return false


func _tris(m: Mesh) -> int:
	var n := 0
	for s in m.get_surface_count():
		var a := m.surface_get_arrays(s)
		var idx = a[Mesh.ARRAY_INDEX]
		n += (idx.size() if idx is PackedInt32Array and idx.size() > 0 else a[Mesh.ARRAY_VERTEX].size()) / 3
	return n


# --lightning[=distance m]: once settled, strike ahead of the camera and hold the capture for the brightest
# frame of the flash. Returns true while still waiting.
var _strike_frames := -1
var _best_flash := 0.0
func _lightning_frame() -> bool:
	var amb := terrain.get_node("EdenAmbience")
	if _strike_frames < 0:
		var cam := root.get_viewport().get_camera_3d()
		var up := cam.global_position.normalized()
		var fwd := -cam.global_basis.z
		fwd = (fwd - up * fwd.dot(up)).normalized()
		var dist := float(args.lightning) if args.lightning != "1" else 900.0
		var R: float = terrain.generator.planet_radius
		var dir := (up + fwd * (dist / R)).normalized()
		var ground := dir * (R + maxf(float(terrain.generator.sample_surface(dir).height), 0.0))
		amb.strike_lightning(ground, false)
		_strike_frames = 0
		return true
	_strike_frames += 1
	var f: float = amb.get_debug_state().flash
	# Save on the first frame of a return stroke (the leader alone is dim), or give up after a second
	if f < 0.5 and _strike_frames < 60:
		return true
	print("CAPTURE lightning: flash=%.2f after %d frames" % [f, _strike_frames])
	root.get_viewport().get_texture().get_image().save_png(args.get("out", "res://_foliage_capture.png"))
	quit()
	return true
