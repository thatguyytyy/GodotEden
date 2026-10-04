extends SceneTree
## Stylised vs volumetric clouds (EdenCloudShell.volumetric) on the real planet: screenshots and GPU time from the
## ground, above the deck and from orbit, sun ~55 degrees from overhead.
##   godot --path demo_eden --resolution 1920x1080 -s res://_volumetric_clouds_capture.gd -- [--out=dir]
##       [--views=ground,above,orbit] [--modes=stylised,volumetric] [--wait=8] [--sun_offset=0.15] [--seed=3]
##       [--set=prop=value ...] (on the EdenCloudShell, for tuning)

const PROBE := "res://_ocean_editor_probe.tscn"

var args := {}
var sets := {}


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--set="):
			var kv := a.trim_prefix("--set=").split("=")
			sets[kv[0]] = str_to_var(kv[1])
		elif a.begins_with("--"):
			var kv := a.trim_prefix("--").split("=")
			args[kv[0]] = kv[1] if kv.size() > 1 else ""
	_run.call_deferred()


func _run() -> void:
	var out: String = args.get("out", "user://volumetric_clouds")
	DirAccess.make_dir_recursive_absolute(out)
	var world: Node = load(PROBE).instantiate()
	for n in world.find_children("*", "", true, false):
		if is_instance_valid(n) and (n is EdenPlayer or n is Camera3D):
			n.get_parent().remove_child(n)
			n.free()
	# The calendar drives the sun each frame: stopped, so the sun stays where this sets it
	var calendar_script := load("res://settings/eden_calendar.gd")
	for n in world.find_children("*", "", true, false):
		if n.get_script() == calendar_script:
			n.process_mode = Node.PROCESS_MODE_DISABLED
	var terrain: Node3D = world.get_node("VoxelLodTerrain")
	var gen = terrain.generator
	var R: float = gen.planet_radius
	root.add_child(world)
	var clouds: Node = world.find_children("*", "EdenCloudShell", true, false)[0]
	for k in sets:
		clouds.set(k, sets[k])
		print("SET %s = %s" % [k, clouds.get(k)])
	var atmo: Node = world.find_children("*", "EdenPlanetAtmosphere", true, false)[0]

	# A spot on land, a little above sea level
	var rng := RandomNumberGenerator.new()
	rng.seed = int(args.get("seed", "3"))
	var up := Vector3.UP
	var h := 0.0
	for i in 400:
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
		var s: Dictionary = gen.sample_surface(d)
		if float(s.height) > 40.0 and float(s.height) < 300.0:
			up = d
			h = float(s.height)
			break
	atmo.set("sun_declination_deg", rad_to_deg(asin(up.y)))
	atmo.set("sun_time_of_day", fposmod(atan2(-up.x, -up.z) / TAU + float(args.get("sun_offset", "0.15")), 1.0))

	var cam := Camera3D.new()
	cam.near = 1.0
	cam.far = R * 8.0
	cam.fov = 70.0
	root.add_child(cam)
	cam.make_current()
	var viewer := VoxelViewer.new()
	viewer.view_distance = int(R * 3.0)
	cam.add_child(viewer)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)

	var t := up.cross(Vector3.UP if absf(up.y) < 0.99 else Vector3.RIGHT).normalized()
	var top: float = clouds.get("cloud_top")
	var views := {
		# On the ground, looking along the land and a little up at the deck
		"ground": [up * (R + h + 30.0), t, float(args.get("pitch", "14"))],
		# Above the deck, looking across its top
		"above": [up * (R + top + 500.0), t, -8.0],
		# The whole planet
		"orbit": [up * (R * 2.6), -up, 0.0],
	}
	var wait := float(args.get("wait", "8"))
	for v in String(args.get("views", "ground,above,orbit")).split(","):
		var cfg: Array = views[v]
		var pos: Vector3 = cfg[0]
		var fwd: Vector3 = cfg[1]
		var cam_up := pos.normalized() if absf(fwd.dot(pos.normalized())) < 0.99 else t
		cam.global_transform = Transform3D(Basis.looking_at(fwd, cam_up), pos)
		cam.global_transform.basis = cam.global_transform.basis * Basis(Vector3.RIGHT, deg_to_rad(cfg[2]))
		if args.has("storm") and v == "ground": # --storm=<intensity>: a storm parked on the ground view
			var amb := terrain.get_node_or_null("EdenAmbience")
			if amb:
				amb.call("add_storm", pos, 5000.0, float(args.storm), 1e6, false, false)
		await _seconds(wait)
		for m in String(args.get("modes", "stylised,volumetric")).split(","):
			clouds.set("volumetric", m == "volumetric")
			await _seconds(1.5)
			var gpu := 0.0
			var frames := 0
			var end := Time.get_ticks_msec() + 2000
			while Time.get_ticks_msec() < end:
				await process_frame
				gpu += RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
				frames += 1
			print("CLOUDS %s %s: gpu %.2f ms/frame (%d frames)" % [v, m, gpu / frames, frames])
			root.get_viewport().get_texture().get_image().save_png(out.path_join("%s_%s.png" % [v, m]))
			if args.has("flow_check") and m == "volumetric": # the flow snapshots cycling: the blend should ramp 0..1 and wrap
				var mat: ShaderMaterial = clouds.call("get_material")
				for i in 12:
					await _seconds(1.0)
					print("FLOW +%ds mix %.2f" % [i + 1, mat.get_shader_parameter("vol_flow_mix")])
				root.get_viewport().get_texture().get_image().save_png(out.path_join("%s_%s_later.png" % [v, m]))
	quit(0)


func _seconds(s: float) -> void:
	var end := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < end:
		await process_frame
