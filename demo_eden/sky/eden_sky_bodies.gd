class_name EdenSkyBodies
## A world's sky bodies from its seed: which painted, animated surface the parent planet and the two moons get (the
## sky shader draws them live; see planet_sky.gdshader's bs_* functions, in the look of the EDEN_Assets
## Moon_Planet_Textures maps), the rings' band pattern and which space panorama is behind it all.
##   Parent planet (EdenParentPlanet.parent_planet_style): 1 gas giant, 2 primordial, 3 ocean, 4 terrestrial,
##     5 tropical, 6 tundral, 7 wetlands
##   Moons (EdenPlanetAtmosphere.moon_style / moonb_style): 1 rock, 2 ice, 3 rust

const PLANET_STYLES := ["", "gas giant", "primordial", "ocean", "terrestrial", "tropical", "tundral", "wetlands",
		"ice giant", "greenhouse"]
const MOON_STYLES := ["", "rock", "ice", "rust"]
## Each style as universal planet shader settings (planet_type: 0 Terran, 1 Gas Giant, 2 Ocean World, 3 Ice / Plutoid,
## 4 Barren Rock, 5 Runaway Greenhouse, 6 Lava World, 7 Ice Giant). life_level stays at or under 0.5: no cities.
const PLANET_LOOKS := {
	1: {"planet_type": 1},
	2: {"planet_type": 6, "atmosphere_density": 0.35, "ocean_coverage": 0.12},
	3: {"planet_type": 2, "temperature": 0.55, "life_level": 0.3},
	4: {"planet_type": 0, "temperature": 0.62, "ocean_coverage": 0.5, "life_level": 0.5, "lat_gradient": 0.6},
	5: {"planet_type": 0, "temperature": 0.78, "ocean_coverage": 0.6, "life_level": 0.5, "cloud_coverage": 0.65},
	6: {"planet_type": 0, "temperature": 0.12, "ocean_coverage": 0.4, "life_level": 0.2, "cloud_coverage": 0.4},
	7: {"planet_type": 0, "temperature": 0.66, "ocean_coverage": 0.72, "life_level": 0.5, "cloud_coverage": 0.7,
		"lat_gradient": 0.6},
	8: {"planet_type": 7},
	9: {"planet_type": 5},
}
## Moons are airless and tidally locked (no spin, no polar ice from latitude)
const MOON_LOOKS := {
	1: {"planet_type": 4, "land_low": Color(0.28, 0.28, 0.28), "land_high": Color(0.62, 0.61, 0.6),
		"desert_color": Color(0.5, 0.5, 0.5), "crater_amount": 0.9},
	2: {"planet_type": 3},
	# (an airless, dry Terran: Barren Rock would desaturate the rust; airless Terran still gets craters)
	3: {"planet_type": 0, "ocean_coverage": 0.0, "atmosphere_density": 0.0, "life_level": 0.0,
		"land_low": Color(0.42, 0.13, 0.06), "land_high": Color(0.85, 0.42, 0.22), "desert_color": Color(0.78, 0.33, 0.14),
		"crater_amount": 0.7},
}
const MOON_COMMON := {"rotation_speed": 0.0, "temperature": 0.6, "lat_gradient": 0.0}
## The parent planet turns slowly
const PARENT_COMMON := {"rotation_speed": 0.01, "wildfire_activity": 0.1}
## Map widths (height is half). The parent planet fills a big piece of sky, so it needs the detail.
const PARENT_MAP := 2048
const MOON_MAP := 256
const PANORAMA_DIR := "res://Panoramics"


## {planet, moon, moonb} styles, and a seed for each (the palette, the land, the craters); the rings' seed and a
## panorama pick
static func world_bodies(world_seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(world_seed * 7919 + 17)
	return {
		"planet": rng.randi_range(1, PLANET_STYLES.size() - 1), "planet_seed": float(rng.randi() % 1000),
		"moon": rng.randi_range(1, 3), "moon_seed": float(rng.randi() % 1000),
		"moonb": rng.randi_range(1, 3), "moonb_seed": float(rng.randi() % 1000),
		"ring_seed": float(rng.randi() % 1000), "panorama": rng.randi(),
	}


## Gives a world scene (the probe scene's root) its look from the seed: moons, parent planet, rings and space
## panorama. A texture assigned in the scene would override a painted surface, so it is cleared. With show_parent
## false the parent planet is hidden (the main menu shows only the planet itself).
static func apply_world(world: Node, world_seed: int, show_parent := true) -> void:
	var b := world_bodies(world_seed)
	var atmosphere := _first(world, "EdenPlanetAtmosphere")
	var parent_planet := _first(world, "EdenParentPlanet")
	var rings := _first(world, "EdenPlanetRings")
	var space := _first(world, "EdenSpaceEnvironment")
	# Surfaces painted by the universal planet shader (EdenBodyPainter) into maps the sky wraps on each body
	if atmosphere:
		for m in ["moon", "moonb"]:
			var look: Dictionary = MOON_LOOKS[b[m]].merged(MOON_COMMON)
			look.planet_seed = b[m + "_seed"]
			atmosphere.set(m + "_style", 0)
			atmosphere.set(m + "_texture_equirect", true)
			atmosphere.set(m + "_texture", _painter(world, m, MOON_MAP, look).get_texture())
	if parent_planet:
		parent_planet.set("parent_planet_enabled", show_parent)
		if show_parent: # (not painted when hidden)
			var look: Dictionary = PLANET_LOOKS[b.planet].merged(PARENT_COMMON)
			look.planet_seed = b.planet_seed
			parent_planet.set("parent_planet_style", 0)
			parent_planet.set("parent_planet_shade_bands", 1) # (the posterised light is for the old pixel-art surface)
			parent_planet.set("parent_planet_texture", _painter(world, "parent", PARENT_MAP, look).get_texture())
	if rings:
		rings.set("ring_seed", b.ring_seed)
	if space:
		var files := _panoramas()
		if not files.is_empty():
			# No folder scan (it would load the first panorama just to replace it): pick one and load only that. The
			# node rescans its (now empty) folder when it enters the tree and would clear a panorama set before, so
			# it goes on after that.
			var path := files[b.panorama % files.size()]
			space.set("space_texture_dir", "")
			space.set("use_placeholder_panorama", false)
			var put := func():
				space.call("rescan_panoramas")
				_load_panorama(space, path)
			if space.is_node_ready():
				put.call()
			else:
				space.ready.connect(put, CONNECT_ONE_SHOT)


## Loads one panorama on a thread (no hitch) and hands it to the space node; the previous one is released as it
## is replaced, so only one is ever resident. Call again with another path to swap.
static func _load_panorama(space: Node, path: String) -> void:
	ResourceLoader.load_threaded_request(path)
	var tree := Engine.get_main_loop() as SceneTree
	while ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await tree.process_frame
	if is_instance_valid(space):
		space.set("space_panorama", ResourceLoader.load_threaded_get(path))


## A body's painter under the world with this look (the one from an earlier apply_world, repainted)
static func _painter(world: Node, body: String, width: int, look: Dictionary) -> EdenBodyPainter:
	var node_name := "Painter_" + body
	var p := world.get_node_or_null(node_name) as EdenBodyPainter
	if p:
		p.set_look(look)
		return p
	p = EdenBodyPainter.create(width, look)
	if body != "parent":
		p.refresh_interval = 0.0 # (airless, tidally locked: nothing on a moon moves)
	p.name = node_name
	world.add_child(p)
	return p


static func _first(world: Node, type: String) -> Node:
	var n := world.find_children("*", type, true, false)
	return n[0] if n else null


## res://Panoramics images, sorted (an exported build lists them with a .import suffix)
static func _panoramas() -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(PANORAMA_DIR):
		f = f.trim_suffix(".import")
		if f.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp", "exr", "hdr"] and not out.has(f):
			out.append(PANORAMA_DIR.path_join(f))
	out.sort()
	return out
