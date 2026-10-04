extends SceneTree
## Measures each world template (EdenWorldSettings) over a few seeds: land %, landmasses (connected land over a
## lat-long grid, bigger than 0.2% of the planet), the largest's share of the land, mountain %, and the land's
## climate: mean temperature and moisture (0..1), cold % (temperature < 0.25: snow and tundra) and dry %
## (moisture < 0.3). Saves a height map per template. Headless:
##   godot --headless --path demo_eden -s res://menu/_template_survey.gd -- [--out=dir] [--seeds=3] [--only=id]
##       [--temperature=cold|temperate|hot] [--rainfall=arid|normal|wet] [--set=prop=value ...]

const W := 160
const H := 80


func _initialize() -> void:
	var out := "user://template_survey"
	var seeds := 3
	var only := ""
	var extra := {}
	var climate := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--set="): # --set=prop=value, on top of the settings (for tuning)
			var kv := a.trim_prefix("--set=").split("=")
			extra[kv[0]] = float(kv[1])
		elif a.begins_with("--out="):
			out = a.trim_prefix("--out=")
		elif a.begins_with("--seeds="):
			seeds = int(a.trim_prefix("--seeds="))
		elif a.begins_with("--only="):
			only = a.trim_prefix("--only=")
		elif a.begins_with("--temperature=") or a.begins_with("--rainfall="):
			var kv := a.trim_prefix("--").split("=")
			climate[kv[0]] = kv[1]
	DirAccess.make_dir_recursive_absolute(out)
	var probe: Node = load("res://_ocean_editor_probe.tscn").instantiate()
	var base: Resource = probe.get_node("VoxelLodTerrain").generator
	for id in EdenWorldSettings.TEMPLATES:
		if only != "" and id != only:
			continue
		var sums := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
		for s in seeds:
			var gen: Resource = base.duplicate()
			gen.seed = 1000 + s * 7717
			EdenWorldSettings.apply(gen, climate.merged({"template": id}))
			for k in extra:
				gen.set(k, extra[k])
			var r := _survey(gen, out.path_join("%s_%d.png" % [id, s]) if s == 0 else "")
			for k in sums.size():
				sums[k] += float(r[k]) / seeds
		print(("TEMPLATE %-17s land %5.1f%%  landmasses %4.1f  largest %5.1f%% of land  mountains %5.1f%% of land" +
				"  | temp %.2f  moist %.2f  cold %5.1f%%  dry %5.1f%%") % ([id] + sums))
	probe.free()
	quit(0)


## [land %, landmasses, largest % of land, mountain % of land, mean temperature, mean moisture, cold % of land,
## dry % of land]
func _survey(gen: Resource, png: String) -> Array:
	var land := PackedByteArray()
	land.resize(W * H)
	var area := PackedFloat32Array()
	area.resize(W * H)
	var img := Image.create(W, H, false, Image.FORMAT_RGB8) if png != "" else null
	var total := 0.0
	var land_area := 0.0
	var mountain_area := 0.0
	var climate := [0.0, 0.0, 0.0, 0.0] # over land, area-weighted: temperature, moisture, cold area, dry area
	for y in H:
		var lat := PI * (0.5 - (y + 0.5) / H)
		var a := cos(lat)
		for x in W:
			var lon := TAU * (x + 0.5) / W
			var d := Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))
			var s: Dictionary = gen.sample_surface(d)
			var h := float(s.height)
			var i := y * W + x
			area[i] = a
			total += a
			if h > 0.0:
				land[i] = 1
				land_area += a
				if float(s.landform) > 0.5:
					mountain_area += a
				var t := float(s.temperature)
				var m := float(s.moisture)
				climate[0] += t * a
				climate[1] += m * a
				climate[2] += a if t < 0.25 else 0.0
				climate[3] += a if m < 0.3 else 0.0
			if img:
				var c := Color(0.1, 0.25, 0.55).lerp(Color(0.3, 0.6, 0.85), clampf(1.0 + h / 2000.0, 0.0, 1.0)) if h <= 0.0 \
						else Color(0.3, 0.6, 0.25).lerp(Color(0.95, 0.95, 0.95), clampf(h / 2500.0, 0.0, 1.0))
				img.set_pixel(x, y, c)
	if img:
		img.resize(W * 4, H * 4, Image.INTERPOLATE_NEAREST)
		img.save_png(png)
	# Landmasses: 4-connected, wrapping in longitude
	var seen := PackedByteArray()
	seen.resize(W * H)
	var masses := 0
	var largest := 0.0
	for start in W * H:
		if land[start] == 0 or seen[start] == 1:
			continue
		var stack := [start]
		seen[start] = 1
		var mass := 0.0
		while not stack.is_empty():
			var i: int = stack.pop_back()
			mass += area[i]
			var x := i % W
			var y := i / W
			for n in [y * W + (x + 1) % W, y * W + (x + W - 1) % W, (y + 1) * W + x if y + 1 < H else -1, (y - 1) * W + x if y > 0 else -1]:
				if n >= 0 and land[n] == 1 and seen[n] == 0:
					seen[n] = 1
					stack.append(n)
		if mass > total * 0.002:
			masses += 1
		largest = maxf(largest, mass)
	var la := maxf(land_area, 1e-6)
	return [land_area / total * 100.0, masses, largest / la * 100.0, mountain_area / la * 100.0,
			climate[0] / la, climate[1] / la, climate[2] / la * 100.0, climate[3] / la * 100.0]
