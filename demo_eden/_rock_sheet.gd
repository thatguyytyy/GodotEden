extends SceneTree
## Every rock layer's meshes side by side (near mesh on top, far LOD under it), each scaled to the same size, lit
## from the side so facets read. For judging rock looks without walking the planet.
##   godot --path demo_eden --resolution 1600x900 -s res://_rock_sheet.gd -- --out=<png>

const ROCKS := [15, 16, 17, 18] # PEBBLES, BOULDER, ROCK_SLAB, ROCK_SPIRE


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var out := "user://rock_sheet.png"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.trim_prefix("--out=")
	var cfg: Resource = load("res://foliage/eden_foliage_default.tres")
	var layers := []
	for b in cfg.biomes:
		for l in b.layers:
			if l.kind in ROCKS and not layers.any(func(o): return o.name == l.name):
				layers.append(l)
	var light := DirectionalLight3D.new()
	root.add_child(light)
	light.rotation = Vector3(-0.6, 0.9, 0)
	light.shadow_enabled = true
	var we := WorldEnvironment.new()
	we.environment = Environment.new()
	we.environment.background_mode = Environment.BG_COLOR
	we.environment.background_color = Color(0.55, 0.62, 0.7)
	we.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	we.environment.ambient_light_color = Color(0.45, 0.47, 0.5)
	root.add_child(we)
	var x := 0.0
	for l in layers:
		for row in 2:
			var mesh: Mesh = EdenFoliageMeshes.build(l, 0)["mesh"] if row == 0 else EdenFoliageMeshes.build_far(l, 0)
			if mesh == null:
				continue
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			var size := mesh.get_aabb().size
			var s := 1.6 / maxf(maxf(size.x, size.y), size.z)
			mi.scale = Vector3.ONE * s
			mi.position = Vector3(x, -row * 2.2 - mesh.get_aabb().position.y * s, 0)
			root.add_child(mi)
		var label := Label3D.new()
		label.text = "%s\n%d tris" % [l.name, (EdenFoliageMeshes.build(l, 0)["mesh"] as Mesh).get_faces().size() / 3]
		label.pixel_size = 0.004
		label.position = Vector3(x, 2.1, 0)
		root.add_child(label)
		x += 2.2
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.position = Vector3((x - 2.2) * 0.5, 0.3, x * 0.42 + 1.0)
	cam.look_at(Vector3((x - 2.2) * 0.5, -0.2, 0))
	cam.current = true
	for i in 10:
		await process_frame
	root.get_texture().get_image().save_png(out)
	print("ROCK SHEET saved ", out, " layers ", layers.map(func(l): return l.name))
	quit()
