extends SceneTree
## Brings res://foliage/eden_foliage_default.tres up to date with EdenFoliageConfig.make_default() without throwing
## away edits made to it: layers the defaults have and the config lacks (matched by biome and layer name) are added,
## and --densities=<Layer name,...> takes those layers' density from the defaults; everything else is left as it is.
##   godot --headless --path demo_eden -s res://foliage/_merge_default_layers.gd -- [--densities=Forest oak,Pine] [--dry]

const PATH := "res://foliage/eden_foliage_default.tres"


func _initialize() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=")
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var take_density: PackedStringArray = args.get("densities", "").split(",", false)
	var cfg: EdenFoliageConfig = load(PATH)
	var defaults := EdenFoliageConfig.make_default()
	var added := 0
	var changed := 0
	for db in defaults.biomes:
		var biome: EdenFoliageBiome = null
		for b in cfg.biomes:
			if b.name == db.name:
				biome = b
		if biome == null:
			print("MERGE no biome '%s' in the config: skipped" % db.name)
			continue
		var by_name := {}
		for l in biome.layers:
			by_name[l.name] = l
		var layers := biome.layers.duplicate()
		for dl in db.layers:
			if not by_name.has(dl.name):
				layers.append(dl)
				added += 1
				print("MERGE + %s / %s (%s, density %s)" % [db.name, dl.name, EdenFoliageLayer.kind_name(dl.kind), dl.density])
			elif dl.name in take_density and not is_equal_approx(by_name[dl.name].density, dl.density):
				print("MERGE ~ %s / %s density %s -> %s" % [db.name, dl.name, by_name[dl.name].density, dl.density])
				by_name[dl.name].density = dl.density
				changed += 1
		biome.layers = layers
	if args.has("dry"):
		print("MERGE dry run: %d to add, %d densities to change" % [added, changed])
	else:
		print("MERGE saved err=%d: %d added, %d densities changed" % [ResourceSaver.save(cfg, PATH), added, changed])
	quit()
