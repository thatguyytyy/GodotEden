extends SceneTree
## Eclipses: from the ground, the moon slides across the sun (partial -> total), then the parent planet with a moon in
## front of it. Screenshots and the sun's visible share (EdenPlanetAtmosphere.get_sun_visible) at each step.
##   godot --path demo_eden --resolution 1280x720 -s res://sky/_eclipse_test.gd -- [--out=dir]

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var out := "user://eclipse_test"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(out)
	var world: Node = load("res://_ocean_editor_probe.tscn").instantiate()
	for n in world.find_children("*", "", true, false):
		if is_instance_valid(n) and (n is EdenPlayer or n is Camera3D):
			n.get_parent().remove_child(n)
			n.free()
	var calendar_script := load("res://settings/eden_calendar.gd")
	for n in world.find_children("*", "", true, false):
		if n.get_script() == calendar_script:
			n.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(world)
	var terrain: Node3D = world.get_node("VoxelLodTerrain")
	var R: float = terrain.generator.planet_radius
	var atmo: Node = world.find_children("*", "EdenPlanetAtmosphere", true, false)[0]
	var parent: Node = world.find_children("*", "EdenParentPlanet", true, false)[0]
	var light: DirectionalLight3D = null
	for l in world.find_children("*", "DirectionalLight3D", true, false):
		light = l
		break
	for c in world.find_children("*", "EdenCloudShell", true, false):
		c.visible = false # (a clear sky, so the discs show)

	# A camera on the planet's +Y side looking up toward the sun, 40 degrees up toward +Z
	var up := Vector3.UP
	var sun := (up * sin(deg_to_rad(40.0)) + Vector3(0, 0, -1) * cos(deg_to_rad(40.0))).normalized()
	var cam := Camera3D.new()
	cam.fov = 40.0
	cam.far = R * 10.0
	root.add_child(cam)
	cam.make_current()
	cam.global_transform = Transform3D(Basis.looking_at(sun, up), up * (R + float(terrain.generator.sample_surface(up).height) + 200.0))
	var viewer := VoxelViewer.new()
	viewer.view_distance = 20000
	cam.add_child(viewer)

	atmo.set("external_directions", true)
	atmo.call("set_sun_direction", sun)
	atmo.set("moon_angular_radius", atmo.get("sun_angular_radius") * 1.15)
	var side := sun.cross(up).normalized()
	await _seconds(6.0)
	var step := 0
	# The moon from beside the sun to dead centre
	for off in [3.0, 1.5, 0.8, 0.0]:
		var d := sun.rotated(up.cross(sun).normalized(), 0.0).rotated(side, 0.0)
		d = (sun + side * (off * float(atmo.get("sun_angular_radius")))).normalized()
		atmo.set("moon_direction", d)
		await _seconds(1.0)
		_report(out, "moon_%d" % step, atmo, light)
		step += 1
	# At dusk (the sun just below the horizon off to the side), the parent planet where the sun was, a moon in front
	atmo.call("set_sun_direction", (side - up * 0.06).normalized())
	atmo.set("moon_direction", (sun + side * 0.08).normalized())
	parent.set("parent_planet_enabled", true)
	parent.set("parent_planet_direction", sun)
	parent.set("parent_planet_angular_radius", 0.12)
	await _seconds(1.5)
	_report(out, "parent_moon_in_front", atmo, light)
	# The parent planet over the sun
	atmo.call("set_sun_direction", sun)
	parent.set("parent_planet_direction", sun)
	atmo.set("moon_direction", (sun - side * 0.4).normalized())
	await _seconds(1.5)
	_report(out, "parent_over_sun", atmo, light)
	# Lunar eclipse: the sun behind the planet (below the horizon), the moon crossing this planet's shadow
	parent.set("parent_planet_enabled", false)
	atmo.call("set_sun_direction", -sun)
	for i in 4:
		var off: float = [0.4, 0.15, 0.1, 0.0][i]
		atmo.set("moon_direction", (sun + side * off).normalized())
		await _seconds(1.0)
		_report(out, "lunar_%d" % i, atmo, light)
	# The parent planet lit from behind the camera and to the side, the moon in front of it: its shadow lands beside it
	parent.set("parent_planet_enabled", true)
	parent.set("parent_planet_direction", sun)
	parent.set("parent_planet_angular_radius", 0.12)
	parent.set("parent_planet_distance", 30.0)
	atmo.call("set_sun_direction", (-sun + side * 0.10 + up * 0.03).normalized())
	atmo.set("moon_direction", (sun + side * 0.07).normalized())
	await _seconds(1.5)
	_report(out, "parent_moon_shadow", atmo, light)
	# This planet's shadow on the parent planet (the sun straight behind us, a little off): a lunar eclipse of it
	atmo.call("set_sun_direction", (-sun + side * 0.05).normalized())
	atmo.set("moon_direction", (sun + side * 0.6).normalized())
	await _seconds(1.5)
	_report(out, "parent_planet_shadow", atmo, light)
	quit(0)


func _report(out: String, name: String, atmo: Node, light: DirectionalLight3D) -> void:
	print("ECLIPSE %s sun_visible %.3f moon_lit %.3f" % [name, atmo.call("get_sun_visible"), atmo.call("get_moon_eclipse")])
	root.get_viewport().get_texture().get_image().save_png(out.path_join(name + ".png"))


func _seconds(s: float) -> void:
	var end := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < end:
		await process_frame
