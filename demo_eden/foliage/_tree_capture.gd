extends SceneTree
## Side-by-side render of procedural tree species, to eyeball silhouettes after generator changes.
##   godot --path demo_eden --resolution 1600x900 -s res://foliage/_tree_capture.gd -- --types=1,2,3 --season=1 --out=<png>
## types are EdenTreeInstance.tree_type (1 Oak, 2 Pine, 3 Birch, 4 Willow, 5 Palm, 6 Dead, 7 Fruit); season 3 = Winter (bare).
## Close-up of one tree: --types=1 --variants=1 [--seed=N] [--dist=8] [--look_y=2.5] [--cam_y=3] [--yaw=30 orbit degrees]

var args := {}
var frames := 0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=")
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var types: PackedStringArray = args.get("types", "1,2,3").split(",")
	var variants := int(args.get("variants", "3"))
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.62, 0.74, 0.8)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.65, 0.7)
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -30, 0)
	sun.shadow_enabled = true
	root.add_child(sun)
	var ground := MeshInstance3D.new()
	ground.mesh = PlaneMesh.new()
	ground.mesh.size = Vector2(200, 200)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.55, 0.66, 0.72)
	ground.material_override = gm
	root.add_child(ground)
	var spacing := 6.0
	var n := types.size() * variants
	for ti in types.size():
		for v in variants:
			var t := _tree(int(types[ti]) - 1, int(args.get("season", "1")), int(args.get("seed", "1000")) + v * 77)
			t.position = Vector3((ti * variants + v - (n - 1) * 0.5) * spacing, 0, 0)
			root.add_child(t)
	var dist := float(args.get("dist", str(max(n * spacing * 0.36, 7.0))))
	var yaw := deg_to_rad(float(args.get("yaw", "0")))
	var look := Vector3(0, float(args.get("look_y", "3.0")), 0)
	var cam := Camera3D.new()
	cam.position = Vector3(sin(yaw) * dist, float(args.get("cam_y", "4.0")), cos(yaw) * dist)
	cam.fov = 50
	root.add_child(cam)
	cam.transform = Transform3D(Basis(), cam.position).looking_at(look)


## Same meshes/colors EdenTreeInstance builds, but any --shape_<EdenTreeShape property>=value overrides the species
## defaults (e.g. --shape_branch_depth=1 to see primaries alone).
func _tree(type: int, season: int, seed: int) -> Node3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var shape := EdenTreeGenerator.species_shape(type, rng)
	shape.season = season
	for k in args:
		if k.begins_with("shape_"):
			shape.set(k.substr(6), str_to_var(args[k]))
	var built := EdenTreeGenerator.build(rng, shape)
	var node := Node3D.new()
	for part in [["trunk_mesh", "trunk_color"], ["foliage_mesh", "leaf_color"], ["fruit_mesh", "fruit_color"]]:
		var m: Mesh = built[part[0]]
		if m == null or m.get_surface_count() == 0:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = m
		var mat := StandardMaterial3D.new()
		mat.albedo_color = built[part[1]]
		mat.roughness = 0.9
		mi.material_override = mat
		node.add_child(mi)
	return node


func _process(_d: float) -> bool:
	frames += 1
	if frames == 10:
		root.get_viewport().get_texture().get_image().save_png(args.get("out", "user://trees.png"))
		quit()
	return false
