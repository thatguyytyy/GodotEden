extends SceneTree
## Renders a world's planet as an equirectangular map for the server's web viewer (Projects/eden-telemetry): a colour
## map (biomes, shaded relief), a height map (for bump relief) and a small JSON with the planet radius and height range.
## Longitude/latitude follow the game's axes: lat = asin(y/r), lon = atan2(z, x) (see _template_survey.gd). Headless:
##   godot --headless --path demo_eden -s res://menu/_render_world_map.gd -- --seed=424242 --out=C:/dir/eden-test
##       [--settings={"template":"eden","temperature":"temperate","rainfall":"normal"}] [--width=1024]
## Writes <out>_color.png, <out>_height.png and <out>.json.

const H_MIN := -5000.0
const H_MAX := 7000.0


func _initialize() -> void:
	var out := "user://world_map"
	var seed_v := 424242
	var settings: Dictionary = EdenWorldSettings.DEFAULTS.duplicate()
	var w := 1024
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			seed_v = int(a.trim_prefix("--seed="))
		elif a.begins_with("--out="):
			out = a.trim_prefix("--out=")
		elif a.begins_with("--width="):
			w = int(a.trim_prefix("--width="))
		elif a.begins_with("--settings="):
			var d = JSON.parse_string(a.trim_prefix("--settings="))
			if d is Dictionary:
				settings = d
	var h := w / 2
	var probe: Node = load("res://_ocean_editor_probe.tscn").instantiate()
	var gen: Resource = (probe.get_node("VoxelLodTerrain").generator as Resource).duplicate()
	gen.seed = seed_v
	EdenWorldSettings.apply(gen, settings)
	var height := PackedFloat32Array()
	height.resize(w * h)
	var color := Image.create(w, h, false, Image.FORMAT_RGB8)
	var hmap := Image.create(w, h, false, Image.FORMAT_L8)
	var temp := PackedFloat32Array()
	var moist := PackedFloat32Array()
	var rock := PackedFloat32Array()
	temp.resize(w * h)
	moist.resize(w * h)
	rock.resize(w * h)
	for y in h:
		var lat := PI * (0.5 - (y + 0.5) / h)
		for x in w:
			var lon := TAU * (x + 0.5) / w
			var d := Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))
			var s: Dictionary = gen.sample_surface(d)
			var i := y * w + x
			height[i] = float(s.height)
			temp[i] = float(s.temperature)
			moist[i] = float(s.moisture)
			rock[i] = float(s.landform)
	for y in h:
		for x in w:
			var i := y * w + x
			var e := height[i]
			# Hillshade: light from the north-west, from the height difference to the neighbours
			var dx := height[y * w + (x + 1) % w] - height[y * w + (x + w - 1) % w]
			var dy := height[mini(y + 1, h - 1) * w + x] - height[maxi(y - 1, 0) * w + x]
			var shade := clampf(1.0 + (-dx - dy) / 6000.0, 0.65, 1.3) if e > 0.0 else 1.0
			color.set_pixel(x, y, _biome(e, temp[i], moist[i], rock[i]) * shade)
			hmap.set_pixel(x, y, Color.from_hsv(0, 0, clampf((e - H_MIN) / (H_MAX - H_MIN), 0.0, 1.0)))
	color.save_png(out + "_color.png")
	hmap.save_png(out + "_height.png")
	var f := FileAccess.open(out + ".json", FileAccess.WRITE)
	f.store_string(JSON.stringify({"radius": float(gen.planet_radius), "h_min": H_MIN, "h_max": H_MAX, "seed": seed_v, "settings": settings, "width": w}))
	f.close()
	print("MAP written ", out, " radius ", gen.planet_radius)
	probe.free()
	quit(0)


## Surface colour from height (m), temperature and moisture (0..1) and how mountainous (landform)
static func _biome(e: float, t: float, m: float, rock: float) -> Color:
	if e <= 0.0:
		return Color(0.02, 0.12, 0.32).lerp(Color(0.12, 0.45, 0.7), clampf(1.0 + e / 1800.0, 0.0, 1.0))
	if e < 25.0:
		return Color(0.82, 0.77, 0.55) # beach
	var c: Color
	if t < 0.2:
		c = Color(0.92, 0.95, 0.98) # ice
	elif t < 0.3:
		c = Color(0.6, 0.65, 0.55) # tundra
	elif m < 0.25:
		c = Color(0.78, 0.66, 0.42) if t > 0.55 else Color(0.62, 0.6, 0.4) # desert / steppe
	elif m < 0.45:
		c = Color(0.55, 0.62, 0.3) # grassland
	elif t > 0.7 and m > 0.65:
		c = Color(0.08, 0.38, 0.12) # rainforest
	else:
		c = Color(0.16, 0.45, 0.2) # forest
	c = c.lerp(Color(0.5, 0.48, 0.45), clampf(rock * 0.9, 0.0, 0.9)) # rocky highlands
	return c.lerp(Color(0.97, 0.97, 1.0), clampf((e - 2800.0) / 1500.0, 0.0, 1.0)) # snow caps
