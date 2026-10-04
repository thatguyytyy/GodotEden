extends SceneTree
## GPU cost of the parent planet: the sky shader's own painted surface (bs_*) against the universal planet shader's
## map (EdenBodyPainter), with the camera filled by the parent planet. Also times one repaint of each painter map.
##   godot --path demo_eden --resolution 1920x1080 -s res://perf/sky_bodies_perf.gd

const WARM := 90
const FRAMES := 300

var _scene: Node
var _parent: Node
var _atmo: Node


func _initialize() -> void:
	_run()


func _run() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_scene = load("res://_ocean_editor_probe.tscn").instantiate()
	for n in _scene.find_children("*", "", true, false):
		if is_instance_valid(n) and (n is EdenPlayer or n is VoxelViewer):
			n.get_parent().remove_child(n)
			n.free()
	root.add_child(_scene)
	await process_frame # (the tree isn't running yet in _initialize)
	_parent = _scene.find_children("*", "EdenParentPlanet", true, false)[0]
	_atmo = _scene.find_children("*", "EdenPlanetAtmosphere", true, false)[0]
	for c in _scene.find_children("*", "EdenCloudShell", true, false):
		c.visible = false
	# Out past the planet on the parent planet's side, looking at it: the planet itself is behind the camera
	var d: Vector3 = (_parent.get("parent_planet_direction") as Vector3).normalized()
	var cam: Camera3D = _scene.get_node("Camera3D")
	cam.far = 1000000.0
	cam.global_position = d * 40000.0 * 3.0
	cam.look_at(cam.global_position + d, Vector3.UP if absf(d.y) < 0.99 else Vector3.RIGHT)
	cam.make_current()
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	await _frames(240) # (settle)
	_old(4)
	await _frames(30)
	root.get_viewport().get_texture().get_image().save_png("user://sky_bodies_perf_view.png")
	print("SKYPERF view saved to ", ProjectSettings.globalize_path("user://sky_bodies_perf_view.png"))

	var results := []
	for round in 2:
		_off()
		results.append(["none (no parent planet)", await _measure()])
		for st in [4, 1]:
			_old(st)
			results.append(["old procedural, %s" % EdenSkyBodies.PLANET_STYLES[st], await _measure()])
			_new(st, 0.0)
			results.append(["new map, %s, no repaint" % EdenSkyBodies.PLANET_STYLES[st], await _measure()])
			_new(st, 0.25)
			results.append(["new map, %s, repaint 4/s" % EdenSkyBodies.PLANET_STYLES[st], await _measure()])
	print("SKYPERF frame GPU ms (median / mean / 99th percentile / worst), round 1 then round 2:")
	for r in results:
		print("SKYPERF  %-40s %6.2f / %6.2f / %6.2f / %6.2f" % [r[0], r[1][0], r[1][1], r[1][2], r[1][3]])

	# One repaint of each map on its own (the painter's viewport, repainted every frame while measured)
	for spec in [["parent terrestrial", 4, EdenSkyBodies.PARENT_MAP, true], ["parent gas giant", 1, EdenSkyBodies.PARENT_MAP, true],
			["parent 1024 terrestrial", 4, 1024, true], ["moon rock", 1, EdenSkyBodies.MOON_MAP, false]]:
		var look: Dictionary
		if spec[3]:
			look = EdenSkyBodies.PLANET_LOOKS[spec[1]].merged(EdenSkyBodies.PARENT_COMMON)
		else:
			look = EdenSkyBodies.MOON_LOOKS[spec[1]].merged(EdenSkyBodies.MOON_COMMON)
		var p := EdenBodyPainter.create(spec[2], look)
		p.refresh_interval = 0.0
		p.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(p)
		RenderingServer.viewport_set_measure_render_time(p.get_viewport_rid(), true)
		await _frames(WARM)
		var t := []
		for i in FRAMES:
			await process_frame
			t.append(RenderingServer.viewport_get_measured_render_time_gpu(p.get_viewport_rid()))
		t.sort()
		print("SKYPERF repaint %-26s %dx%d  %6.2f ms" % [spec[0], spec[2], spec[2] / 2, t[t.size() / 2]])
		p.free()
	quit(0)


func _off() -> void:
	_parent.set("parent_planet_enabled", false)


func _old(style: int) -> void:
	_parent.set("parent_planet_enabled", true)
	_parent.set("parent_planet_texture", null)
	_parent.set("parent_planet_style", style)
	_parent.set("parent_planet_shade_bands", 5)


func _new(style: int, refresh: float) -> void:
	var look: Dictionary = EdenSkyBodies.PLANET_LOOKS[style].merged(EdenSkyBodies.PARENT_COMMON)
	look.planet_seed = 123.0
	var p := EdenSkyBodies._painter(_scene, "parent", EdenSkyBodies.PARENT_MAP, look)
	p.refresh_interval = refresh
	_parent.set("parent_planet_enabled", true)
	_parent.set("parent_planet_style", 0)
	_parent.set("parent_planet_shade_bands", 1)
	_parent.set("parent_planet_texture", p.get_texture())


## GPU ms of the main view per frame: [median, mean, 99th percentile, worst]
func _measure() -> Array:
	await _frames(WARM)
	var t := []
	for i in FRAMES:
		await process_frame
		t.append(RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()))
	var sum := 0.0
	for v in t:
		sum += v
	t.sort()
	return [t[t.size() / 2], sum / t.size(), t[int(t.size() * 0.99)], t[-1]]


func _frames(n: int) -> void:
	for i in n:
		await process_frame
