extends SceneTree
## Close-up low-poly check: camera a few metres above the water looking down, so a 1 m facet is
## large on screen. A 1 m cube floats at the aim point for scale.
##   godot --path demo_eden --resolution 1280x720 --script res://_ocean_closeup.gd -- <out_dir> [relief] [alt] [pitch]

const R := 20000.0

var _out := "user://ocean_closeup"
var _ocean: EdenPlanetOcean
var _cam: Camera3D


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	_run.call_deferred()


func _frames(n: int) -> void:
	for _i in n:
		await RenderingServer.frame_post_draw


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var relief := float(args[1]) if args.size() > 1 else -1.0
	var alt := float(args[2]) if args.size() > 2 else 3.0
	var pitch := float(args[3]) if args.size() > 3 else -25.0
	DirAccess.make_dir_recursive_absolute(_out)

	var scene := Node3D.new()
	root.add_child(scene)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.2
	scene.add_child(sun)

	_ocean = EdenPlanetOcean.new()
	_ocean.planet_radius = R
	scene.add_child(_ocean)
	if args.size() > 4:
		_ocean.lod0_triangle_size = float(args[4])
	printerr("CLOSEUP: asked lod0_triangle_size %s -> snapped %.3f m, grid_resolution %d"
			% [args[4] if args.size() > 4 else "(default)",
			_ocean.lod0_triangle_size, _ocean.grid_resolution])
	if OS.get_environment("CLOSEUP_SCENE_MATERIAL") != "": # the probe scene's ocean material (its wave set) instead of the default
		var probe: Node = load("res://_ocean_editor_probe.tscn").instantiate()
		_ocean.material = probe.find_children("*", "EdenPlanetOcean", true, false)[0].material
		probe.free()
	var mat: ShaderMaterial = _ocean.material
	mat.set_shader_parameter("low_poly_normals", true)
	if relief > 0.0:
		mat.set_shader_parameter("low_poly_relief", relief)

	# Local frame at the site: up, and a horizontal forward.
	var up := Vector3(0.2, 0.95, 0.24).normalized()
	var east := up.cross(Vector3.UP).normalized()
	var fwd := up.cross(east).normalized()

	var eye := up * (R + alt)
	_cam = Camera3D.new()
	_cam.near = 0.05
	_cam.far = R * 4.0
	_cam.fov = 60.0
	scene.add_child(_cam)
	_cam.current = true
	_cam.look_at_from_position(eye, eye + fwd * cos(deg_to_rad(pitch)) + up * sin(deg_to_rad(pitch)), up)

	# Sun from behind-left, fairly high, so facets shade by angle rather than by glare.
	sun.look_at_from_position(eye + up * 50.0, eye + fwd * 20.0, up)

	# A ruler of 1 m cubes marching away from the camera: facet size can be read off directly
	# against them at every distance, which is the only way to see the LOD doubling.
	for dist in [4.0, 8.0, 16.0, 32.0, 64.0, 128.0]:
		var cube := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3.ONE
		cube.mesh = bm
		scene.add_child(cube)
		cube.global_position = up * (R + 0.5) + fwd * dist

	await _frames(4)
	_ocean.update_lod()
	await _frames(40)
	_measure_triangles(eye)
	var img := root.get_texture().get_image()
	img.save_png(_out.path_join("closeup.png"))
	printerr("CLOSEUP: saved (leaves %d, relief %s, alt %s, pitch %s)"
			% [_ocean.get_leaf_count(), relief, alt, pitch])
	quit()


## Reads the real mesh of the leaf nearest the camera and reports its edge lengths, so "is a facet
## a metre across?" is a measurement rather than an impression.
func _measure_triangles(eye: Vector3) -> void:
	var best: MeshInstance3D = null
	var best_d := INF
	for c in _ocean.get_children(true):
		var mi := c as MeshInstance3D
		if mi == null:
			continue
		var d: float = mi.global_position.distance_to(eye)
		if d < best_d:
			best_d = d
			best = mi
	if best == null:
		printerr("CLOSEUP: no leaf found")
		return
	var arrays: Array = (best.mesh as ArrayMesh).surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var lens: Array[float] = []
	for t in range(0, mini(idx.size(), 600), 3):
		lens.append(verts[idx[t]].distance_to(verts[idx[t + 1]]))
		lens.append(verts[idx[t + 1]].distance_to(verts[idx[t + 2]]))
	lens.sort()
	var aabb: AABB = best.mesh.get_aabb()
	printerr("CLOSEUP: nearest leaf %.1f m away, patch aabb %.2f m, %d verts, edge min %.3f median %.3f max %.3f m"
			% [best_d, maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z)), verts.size(),
			lens[0], lens[lens.size() / 2], lens[lens.size() - 1]])

	# Patch size against camera distance, measured off the tree rather than derived: this is the
	# LOD doubling that makes facets grow with distance.
	var by_dist := {}
	for c in _ocean.get_children(true):
		var mi := c as MeshInstance3D
		if mi == null:
			continue
		var d: float = mi.global_position.distance_to(eye)
		var size: float = mi.mesh.get_aabb().size.x
		var bucket: int = int(log(maxf(d, 1.0)) / log(2.0))
		if not by_dist.has(bucket) or by_dist[bucket] > size:
			by_dist[bucket] = size
	var keys: Array = by_dist.keys()
	keys.sort()
	for k in keys:
		printerr("CLOSEUP:   beyond %5.0f m -> patch %6.2f m, triangle %.2f m"
				% [pow(2.0, k), by_dist[k], by_dist[k] / float(_ocean.grid_resolution)])
