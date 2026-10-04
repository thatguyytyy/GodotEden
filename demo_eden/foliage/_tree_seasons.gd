extends SceneTree
## Every tree species in a row, drawn with the in-game tree shader (EdenFoliageMeshes.tree + the shared tree
## material, u_deciduous as EdenFoliage sets it) at one point of the year: the shader globals EdenAmbience normally
## pushes are set by hand -- a planet below with its spin axis tilted so the row stands at 45° N, the calendar at
## --phase (0 spring equinox, 0.25 midsummer, 0.5 autumn equinox, 0.75 midwinter) and, with --snow=<0..1>, a weather
## map of lying snow everywhere.
##   godot --path demo_eden --resolution 1800x600 -s res://foliage/_tree_seasons.gd -- --phase=0.3 [--snow=0.9] --out=<png>

const R := 40000.0
## EdenTreeShape types left to right, and whether EdenFoliage marks them deciduous
const TYPES := [[0, "Oak", true], [2, "Birch", true], [1, "Pine", false], [3, "Willow", true], [6, "Fruit", true], [4, "Palm", false],
		[5, "Dead", false], [7, "Mahogany", false], [8, "Teak", false], [9, "Ebony", false], [10, "Rosewood", false], [11, "Maple", true],
		[12, "Walnut", true], [13, "Cherry", true], [14, "Cedar", false], [15, "Spruce", false], [16, "Fir", false]]

var args := {}
var frames := 0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=")
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var snow := float(args.get("snow", "0"))
	RenderingServer.global_shader_parameter_set("eden_calendar", Vector4(float(args.get("phase", "0.3")), 0.25, 0.25, 1.0))
	RenderingServer.global_shader_parameter_set("eden_calendar_axis", Vector4(1, 1, 0, 0).normalized())
	RenderingServer.global_shader_parameter_set("eden_weather_planet", Vector4(0, -R, 0, R))
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, snow, 0, 0))
	RenderingServer.global_shader_parameter_set("eden_weather_map", ImageTexture.create_from_image(img))
	RenderingServer.global_shader_parameter_set("eden_weather_params", Vector4(0.35, 0.4, 1.0 if snow > 0.0 else 0.0, 1.0 if snow > 0.0 else 0.0))

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
	gm.albedo_color = Color(0.85, 0.87, 0.9) if snow > 0.0 else Color(0.55, 0.66, 0.72)
	ground.material_override = gm
	root.add_child(ground)

	# --only=Oak[,Pine..]: just those species (a close-up); camera: --dist, --cam_y, --look_x/y/z, --yaw (degrees)
	var types := TYPES.filter(func(t: Array) -> bool: return not args.has("only") or t[1] in args.only.split(","))
	var spacing := float(args.get("spacing", "6.5"))
	for i in types.size():
		var t: Array = types[i]
		var mi := MeshInstance3D.new()
		mi.mesh = EdenFoliageMeshes.tree(t[0], 1, int(args.get("variant", "0")))["mesh"]
		var mat: ShaderMaterial = EdenFoliageMeshes.get_material(true).duplicate()
		mat.set_shader_parameter("u_deciduous", t[2])
		var autumn := EdenTreeGenerator.autumn_color(t[0])
		var blossom := EdenTreeGenerator.blossom_color(t[0])
		mat.set_shader_parameter("u_autumn", Vector4(autumn.r, autumn.g, autumn.b, autumn.a))
		mat.set_shader_parameter("u_blossom", Vector4(blossom.r, blossom.g, blossom.b, blossom.a))
		mat.set_shader_parameter("u_wind_strength", 0.0)
		mi.material_override = mat
		mi.position = Vector3((i - (types.size() - 1) * 0.5) * spacing, 0, 0)
		root.add_child(mi)
	var cam := Camera3D.new()
	cam.fov = float(args.get("fov", "22"))
	var yaw := deg_to_rad(float(args.get("yaw", "0")))
	var dist := float(args.get("dist", "52"))
	var look := Vector3(float(args.get("look_x", "0")), float(args.get("look_y", "3.4")), float(args.get("look_z", "0")))
	cam.position = Vector3(look.x + sin(yaw) * dist, float(args.get("cam_y", "4.0")), look.z + cos(yaw) * dist)
	root.add_child(cam)
	cam.transform = Transform3D(Basis(), cam.position).looking_at(look)


func _process(_d: float) -> bool:
	frames += 1
	if frames == 10:
		root.get_viewport().get_texture().get_image().save_png(args.get("out", "user://tree_seasons.png"))
		quit()
	return false
