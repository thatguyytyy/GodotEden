extends SceneTree
## Far tier: hull proxy vs the old voxelized copy, triangles per kind, plus a render of both beside the near mesh.
##   godot --path demo_eden --resolution 1600x900 -s res://foliage/_far_compare.gd -- --out=<png>

const _Tris := preload("res://foliage/_mesh_tris.gd")

var frames := 0
var out := ""


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	var cfg: EdenFoliageConfig = load("res://foliage/eden_foliage_default.tres")
	var seen := {}
	var row := 0
	for b in cfg.biomes:
		for l in b.layers:
			var kind: String = EdenFoliageLayer.kind_name(l.kind)
			if seen.has(kind) or l.is_grass() or l.is_rock():
				continue
			seen[kind] = true
			var near: Mesh = EdenFoliageMeshes.build(l, 0).mesh
			var vox := EdenFoliageMeshes.voxelize(near, l.far_resolution)
			var hull := EdenFoliageMeshes.build_far(l, 0)
			print("FAR %-12s near %5d  voxel %4d  hull %4d" % [kind, _Tris.tris(near), _Tris.tris(vox), _Tris.tris(hull)])
			if row < 6:
				var w := near.get_aabb().size.x + 2.0
				for i in 3:
					var mi := MeshInstance3D.new()
					mi.mesh = [near, vox, hull][i]
					mi.position = Vector3((i - 1) * w, 0, -row * 14.0)
					root.add_child(mi)
				row += 1
	if out == "":
		quit()
		return
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.62, 0.74, 0.8)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.65, 0.7)
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -30, 0)
	root.add_child(sun)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.look_at_from_position(Vector3(0, 12, 16), Vector3(0, 4, -8))


func _process(_delta: float) -> bool:
	frames += 1
	if out != "" and frames == 30:
		root.get_texture().get_image().save_png(out)
		quit()
	return false
