extends Node
## Renders the launcher's BackgroundVideo: a low orbit over the planet, the camera drifting slowly back and forth along
## its track, as lossless PNG frames (launcher/render_launcher_background.ps1 runs this and encodes the .ogv).
## The motion is one sine period, so frame N would equal frame 0 and the loop closes; nothing else may move
## (the sun is fixed, the clouds don't drift). The drift is small so the terrain around the camera stays streamed in.
##   godot --path demo_eden res://launcher/launcher_background_movie.tscn --fixed-fps 30 -- --out=<dir>
##       [--seconds=24] [--fps=30] [--settle=45] [--wait=2]
##       [--stills] (4 frames to check the framing, then quit) [--max=N] (stop after N frames)

const SIZE := Vector2i(1920, 1200) # 16:10, as the launcher window
const PROBE := "res://_ocean_editor_probe.tscn"
const PLANET_RADIUS := 40000.0
## Orbit radius in planet radii and vertical fov
## Where the planet's centre sits in the frame (fraction of the width from the left): one third in from the right
const PLANET_SCREEN_X := 2.0 / 3.0
const DISTANCE := 1.8
const FOV := 65.0
## Supersampling on top of the 4x MSAA (the 3D render size relative to the output)
const SUPERSAMPLE := 1.5
## Terrain LOD0 and LOD1 distances (m; the scene has 128 and 256): full detail much further out, memory and time be damned
const LOD_DISTANCE := 6000.0
const SECONDARY_LOD_DISTANCE := 12000.0
## Where the sun sits in the frame at the start (fraction of the width from the left, of the height from the top)
const SUN_SCREEN := Vector2(1.0 / 3.0, 0.45)
## The ring plane contains the camera's radial line: rolled about it from the orbit normal toward the direction of
## travel (sweeps the rings down to the bottom left), and the camera sits this far above the plane
const RING_ROLL_DEG := -45.0
const RING_ELEVATION_DEG := 8.0
## Energy of the fill light on the planet's near side
const FILL_ENERGY := 1.0
## Along-track drift (deg of arc, each way) and the sway of the view direction (deg)
const DRIFT_DEG := 6.0
const SWAY_DEG := 2.0

@onready var viewport: SubViewport = $SubViewport

var out := "user://launcher_background"
var seconds := 24.0
var fps := 30
var settle_s := 45.0
var stills := false
var one := false
var fast := false # (a quick preview: no supersampling, the scene's own terrain LOD)
## Extra rendered frames before each saved one; --max stops early (tests)
var wait_frames := 2
var max_frames := 0
var cam: Camera3D
var atmo: Node
var rings: Node3D
var centre := Vector3.ZERO
## Orbit frame (along track, orbit normal, away from the planet) over the region with the most land
var orbit := Basis()


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.trim_prefix("--out=")
		elif a.begins_with("--seconds="):
			seconds = float(a.trim_prefix("--seconds="))
		elif a.begins_with("--fps="):
			fps = int(a.trim_prefix("--fps="))
		elif a.begins_with("--settle="):
			settle_s = float(a.trim_prefix("--settle="))
		elif a.begins_with("--wait="):
			wait_frames = int(a.trim_prefix("--wait="))
		elif a.begins_with("--max="):
			max_frames = int(a.trim_prefix("--max="))
		elif a == "--fast":
			fast = true
		elif a == "--one":
			stills = true
			one = true
		elif a == "--stills":
			stills = true
	viewport.size = SIZE
	_run.call_deferred()


func _run() -> void:
	var world: Node = load(PROBE).instantiate()
	world.get_node("Camera3D2/VoxelViewer").free()
	var placed := world.get_node_or_null("EdenPlayer")
	if placed:
		placed.free()
	for n in world.find_children("*", "Node", true, false):
		if n is EdenGraphics:
			n.remember_player_choice = false # (don't overwrite the player's user://graphics.cfg)
			n.custom = EdenGraphicsPreset.make("Max", {upscaler = 0, antialiasing = 3, grass_density = 1.3,
					grass_distance = 85.0, foliage_far_visibility = 650.0, ssao = true, glow = true, light_ray_samples = 256,
					ocean_reflection_steps = 64, volumetric_clouds = true, cloud_style = 0, cloud_steps = 128})
			n.quality = EdenGraphics.Quality.CUSTOM
	viewport.add_child(world)
	cam = world.get_node("Camera3D")
	cam.current = true
	cam.far = 500000.0
	cam.near = 20.0
	cam.fov = FOV
	centre = world.get_node("VoxelLodTerrain").global_position
	if not fast:
		world.get_node("VoxelLodTerrain").lod_distance = LOD_DISTANCE
		world.get_node("VoxelLodTerrain").secondary_lod_distance = SECONDARY_LOD_DISTANCE
	orbit = _land_orbit(world.get_node("VoxelLodTerrain").generator)
	for n in world.find_children("*", "Node", true, false):
		if n is EdenCalendar:
			n.running = false
			n.set_date(1, 5, 2, 12.0)
		elif n.is_class("EdenPlanetAtmosphere"):
			atmo = n
		elif n.is_class("EdenCloudShell"):
			n.set("cloud_drift_speed", 0.0)
			n.set("flow_speed", 0.0)
			n.set("volumetric", true)
			n.set("vol_facet_mix", 1.0) # low-poly
			n.set("vol_steps", 128)
			n.set("vol_light_steps", 8)
			n.set("vol_ambient_gain", 5.0) # (shadowed faces went black)
			n.set("vol_surface_light", 1.2)
			n.set("cloud_ambient", 0.6)
			n.set("cloud_night_ambient", 0.6)
			n.set("cloud_sky_ambient_gain", 5.0)
			n.set("vol_surface_shadow", 0.25)
			n.set("vol_facet_size", 200.0) # (the lattice texture is 6 faces wide: 200 m is the finest a 2048 px limit allows)
			if not fast:
				n.set("volume_resolution", 336) # (likewise: 6 faces x 336 fits 2048)
				n.set("volume_layers", 24)
		elif n.is_class("EdenParentPlanet"):
			n.set("parent_planet_enabled", false)
		elif n.is_class("EdenPlanetRings"):
			rings = n
	atmo.set("external_directions", true) # (the day cycle would move the sun)

	_pose(0.0)
	_place_sun_and_rings()
	# (EdenGraphics applies its render scale on the first frames; supersample after that)
	for k in 5:
		await get_tree().process_frame
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	viewport.scaling_3d_scale = 1.0 if fast else SUPERSAMPLE
	await _wait_s(settle_s)
	if not stills:
		# One lap of the drift unrecorded, so the terrain along the whole track is streamed in
		for k in 24:
			_pose(float(k) / 24.0)
			await _wait_s(2.0)
		_pose(0.0)
		await _wait_s(10.0)

	var frames := int(round(seconds * fps))
	DirAccess.make_dir_recursive_absolute(out)
	var indices: Array = [0] if one else [0, frames / 4, frames / 2, frames * 3 / 4] if stills else range(frames)
	for i in indices:
		if max_frames > 0 and i >= max_frames:
			break
		_pose(float(i) / frames)
		for k in (60 if stills else wait_frames):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		viewport.get_texture().get_image().save_png(out.path_join("%05d.png" % i))
		if i % 30 == 0:
			print("LAUNCHER_BG frame %d/%d" % [i, frames])
	print("LAUNCHER_BG done %d frames at %d fps" % [indices.size(), fps])
	get_tree().quit()


func _wait_s(s: float) -> void:
	var end := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < end:
		await get_tree().process_frame


# The sun is fixed in the world where it shows at SUN_SCREEN from the start pose; two ring sets share one plane
func _place_sun_and_rings() -> void:
	var ndc := Vector2(SUN_SCREEN.x * 2.0 - 1.0, 1.0 - SUN_SCREEN.y * 2.0)
	var th := tan(deg_to_rad(FOV) * 0.5)
	var dir_c := Vector3(ndc.x * th * float(SIZE.x) / SIZE.y, ndc.y * th, -1.0)
	var sun: Vector3 = (cam.global_transform.basis * dir_c).normalized()
	atmo.call("set_sun_direction", sun)

	# With the sun ahead of the camera the near side is in twilight: a soft warm fill from the camera's side lights it
	var to_fill: Vector3 = (sun * 0.6 + (cam.global_position - centre).normalized() * 0.9).normalized()
	var fill := DirectionalLight3D.new()
	fill.light_color = Color(1.0, 0.82, 0.65)
	fill.light_energy = FILL_ENERGY
	viewport.add_child(fill)
	fill.global_transform = Transform3D(Basis.looking_at(-to_fill, Vector3.UP), centre)

	var t0: Vector3 = orbit * Vector3.RIGHT
	var n0: Vector3 = orbit * Vector3.UP
	var d0: Vector3 = orbit * Vector3.BACK
	var roll := deg_to_rad(RING_ROLL_DEG)
	var lift := deg_to_rad(RING_ELEVATION_DEG)
	var normal := ((n0 * cos(roll) + t0 * sin(roll)) * cos(lift) + d0 * sin(lift)).normalized()
	# (the ring mesh is built from ring_normal when the node enters the tree: so two fresh duplicates of the scene's)
	var parent := rings.get_parent()
	for set in [[1.9, 2.5, Color(1.0, 0.45, 0.4)], [2.55, 3.4, Color(0.5, 1.0, 0.55)]]:
		var r: Node3D = rings.duplicate()
		r.set("ring_normal", normal)
		r.set("ring_inner_radius", set[0])
		r.set("ring_outer_radius", set[1])
		r.set("ring_tint", set[2])
		r.set("ring_opacity", 1.0)
		r.set("ring_band_scale", 200.0)
		r.set("ring_band_contrast", 0.7)
		r.set("ring_band_variation", 0.7)
		r.set("ring_translucency", 1.0)
		r.set("ring_self_shadow", 0.2)
		parent.add_child(r)
	rings.free()


# The orbit over the spot whose surroundings (the part of the planet in view) are the most land
func _land_orbit(gen: Object) -> Basis:
	var sea: float = gen.sea_level
	var best := -1.0
	var best_d := Vector3.RIGHT
	var n := 600
	for i in n:
		var y := 1.0 - 2.0 * (i + 0.5) / n
		if y < 0.05 or y > 0.7:
			continue # (the date is northern summer: the south is in snow, the poles are white)
		var a := i * 2.399963
		var d := Vector3(cos(a) * sqrt(1.0 - y * y), y, sin(a) * sqrt(1.0 - y * y))
		var side := d.cross(Vector3.UP).normalized()
		var land := 0
		var total := 0
		for ring in [0.12, 0.3, 0.5, 0.65]:
			for k in 10:
				var p := d.rotated(side, ring).rotated(d, TAU * k / 10.0 + ring)
				total += 1
				if float(gen.sample_surface(p).height) > sea + 5.0:
					land += 1
		var score := float(land) / total
		if score > best:
			best = score
			best_d = d
	print("LAUNCHER_BG land fraction %.2f toward %s" % [best, best_d])
	var t := Vector3.UP.cross(best_d).normalized()
	return Basis(t, best_d.cross(t), best_d)


# f in [0, 1): the fraction of the loop
func _pose(f: float) -> void:
	var s := sin(TAU * f)
	var phi := deg_to_rad(DRIFT_DEG) * s
	var d: Vector3 = orbit * Vector3(sin(phi), 0.0, cos(phi))
	var t: Vector3 = orbit * Vector3(cos(phi), 0.0, -sin(phi))
	# Right is toward the planet, up along the orbit's normal
	var z := -t
	var x := -d
	var off := atan((PLANET_SCREEN_X * 2.0 - 1.0) * tan(deg_to_rad(FOV) * 0.5) * float(SIZE.x) / SIZE.y)
	var yaw := 90.0 - rad_to_deg(off) # (the planet's centre is 90 deg from the direction of travel)
	var basis := Basis(x, z.cross(x), z) * Basis(Vector3.UP, deg_to_rad(-yaw + SWAY_DEG * cos(TAU * f)))
	cam.global_transform = Transform3D(basis, centre + d * PLANET_RADIUS * DISTANCE)
