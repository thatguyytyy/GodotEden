extends SceneTree
## Showcase clips of the cloud styles and weather, from the ground and from orbit, as JPEG frames per clip (encode with
## ffmpeg). Run with --fixed-fps 30 so every frame is 1/30 s of game time however slow the recording is.
##   godot --path demo_eden --resolution 960x540 --fixed-fps 30 -s res://_cloud_showcase.gd -- --out=dir [--only=a,b]
## Drift and flow run sped up (a time-lapse), so the motion shows within a few seconds.

const PROBE := "res://_ocean_editor_probe.tscn"
const FRAMES := 180

var out := "user://cloud_showcase"
var only := []
var world: Node
var terrain: Node3D
var clouds: Node
var ambience: Node
var atmo: Node
var cam: Camera3D
var R := 40000.0
var up := Vector3.UP
var ground_h := 0.0
var spots := []


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.trim_prefix("--out=")
		elif a.begins_with("--only="):
			only = Array(a.trim_prefix("--only=").split(","))
	_run.call_deferred()


func _run() -> void:
	world = load(PROBE).instantiate()
	for n in world.find_children("*", "", true, false):
		if is_instance_valid(n) and (n is EdenPlayer or n is Camera3D):
			n.get_parent().remove_child(n)
			n.free()
	terrain = world.get_node("VoxelLodTerrain")
	R = terrain.generator.planet_radius
	root.add_child(world)
	clouds = world.find_children("*", "EdenCloudShell", true, false)[0]
	ambience = terrain.get_node_or_null("EdenAmbience")
	atmo = world.find_children("*", "EdenPlanetAtmosphere", true, false)[0]
	# A spot on land a little above the sea (the seed of the stills)
	for spot_seed in [11, 23]: # (the stills' spots: a warm coast, a snowy upland)
		var rng := RandomNumberGenerator.new()
		rng.seed = spot_seed
		for i in 400:
			var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
			var s: Dictionary = terrain.generator.sample_surface(d)
			if float(s.height) > 40.0 and float(s.height) < 300.0:
				spots.append([d, float(s.height)])
				break
	up = spots[0][0]
	ground_h = spots[0][1]
	cam = Camera3D.new()
	cam.near = 1.0
	cam.far = R * 8.0
	cam.fov = 70.0
	root.add_child(cam)
	cam.make_current()
	var viewer := VoxelViewer.new()
	viewer.view_distance = int(R * 3.0)
	cam.add_child(viewer)
	# Time-lapse
	clouds.set("cloud_drift_speed", 0.012)
	clouds.set("flow_speed", 0.02)
	clouds.set("vol_flow_period", 1.0)
	# Towering cumulus need room: a 1.4 km deck (the scene has 700 m)
	clouds.set("cloud_top", 3600.0)

	var clips := [
		# [name, view, sun_time_of_day (here: 0.2 is 56 degrees up, 0.47 setting, 0.1 lights the side seen from orbit), cloud settings]
		["ground_stylised", "ground", 0.2, {"volumetric": false}],
		["ground_smooth", "ground", 0.2, {"volumetric": true, "vol_facet_mix": 0.0}],
		["ground_lowpoly", "ground", 0.2, {"volumetric": true, "vol_facet_mix": 1.0}],
		["upland_lowpoly", "ground2", 0.2, {"volumetric": true, "vol_facet_mix": 1.0}],
		["sunset_lowpoly", "ground", 0.47, {"volumetric": true, "vol_facet_mix": 1.0}],
		["orbit_stylised", "orbit", 0.1, {"volumetric": false}],
		["orbit_lowpoly", "orbit", 0.1, {"volumetric": true, "vol_facet_mix": 1.0}],
		["orbit_flow", "flow", 0.1, {"volumetric": true, "vol_facet_mix": 1.0, "flow_speed": 0.06}],
		["storm_lowpoly", "storm", 0.2, {"volumetric": true, "vol_facet_mix": 1.0}],
	]
	var last_view := ""
	for c in clips:
		if not only.is_empty() and not only.has(c[0]):
			continue
		var spot: Array = spots[1] if c[1] == "ground2" else spots[0]
		up = spot[0]
		ground_h = spot[1]
		atmo.set("sun_declination_deg", rad_to_deg(asin(up.y)))
		# (the upland spot: the stills' formula, sun ~55 degrees up there)
		atmo.set("sun_time_of_day", fposmod(atan2(-up.x, -up.z) / TAU + 0.15, 1.0) if c[1] == "ground2" else float(c[2]))
		for k in c[3]:
			clouds.set(k, c[3][k])
		# The terrain needs longer to stream in at first and back on the ground after orbit
		var settle := 25.0 if last_view == "" or c[1] == "ground2" or last_view == "ground2" or ((c[1] == "ground" or c[1] == "storm") and (last_view == "orbit" or last_view == "flow")) else 9.0
		last_view = c[1]
		await _record(c[0], c[1], settle)
		clouds.set("flow_speed", 0.02)
	quit(0)


func _pose(kind: String, f: float) -> void:
	var t := up.cross(Vector3.UP if absf(up.y) < 0.99 else Vector3.RIGHT).normalized()
	match kind:
		"ground", "storm", "ground2":
			# On the ground, panning slowly along the horizon, looking a little up at the deck
			var fwd := t.rotated(up, deg_to_rad(-15.0 + 30.0 * f))
			cam.global_transform = Transform3D(Basis.looking_at(fwd, up), up * (R + ground_h + 30.0))
			cam.global_transform.basis = cam.global_transform.basis * Basis(Vector3.RIGHT, deg_to_rad(16.0))
		"orbit", "flow":
			# The planet from orbit, the camera sweeping slowly round it
			var d := up.rotated(Vector3.UP, deg_to_rad(-12.0 + 24.0 * f))
			var dist := R * (2.6 if kind == "orbit" else 1.9)
			cam.global_transform = Transform3D(Basis.looking_at(-d, t), d * dist)


func _record(name: String, kind: String, settle: float) -> void:
	var dir := out.path_join(name)
	DirAccess.make_dir_recursive_absolute(dir)
	_pose(kind, 0.0)
	if kind == "storm" and ambience:
		ambience.call("add_storm", cam.global_position, 5000.0, 1.0, 1e6, true, false)
	# Let the terrain stream in and the clouds rebake before the first frame
	var end := Time.get_ticks_msec() + int(settle * 1000.0)
	while Time.get_ticks_msec() < end:
		await process_frame
	for i in FRAMES:
		_pose(kind, float(i) / FRAMES)
		await process_frame
		root.get_viewport().get_texture().get_image().save_jpg(dir.path_join("%04d.jpg" % i), 0.9)
	if kind == "storm" and ambience and ambience.has_method("clear_storms"):
		ambience.call("clear_storms")
	print("CLIP %s done" % name)
