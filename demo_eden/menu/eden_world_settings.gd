class_name EdenWorldSettings
## What kind of planet a world is, chosen when it is created (as in Civilization's map options): a template (the
## lay of land and sea), its temperature and its rainfall. Each choice is a set of EdenPlanetGeneratorV4 settings
## layered on the planet scene's own; the seed still decides the exact coastlines. A world's settings are a
## Dictionary {template, temperature, rainfall} of choice ids, kept as JSON in its world_meta and used by everyone
## joining. Measured with menu/_template_survey.gd.

## The option groups, in the form's order: key -> [label, choices]
const OPTIONS := {"template": ["Template", TEMPLATES], "temperature": ["Temperature", TEMPERATURES],
		"rainfall": ["Rainfall", RAINFALL]}
const DEFAULTS := {"template": "eden", "temperature": "temperate", "rainfall": "normal"}

## id -> {name, description, params}. Order is the menu's. Measured (average of 3-6 seeds): land % of the surface,
## landmasses, the largest's share of the land. Earth for scale: 29% land, the largest (Afro-Eurasia) 57% of it.
const TEMPLATES := {
	# 31% land, ~7 landmasses, largest 55% (was one continent, 92%). A bit larger than Continents, with less ocean
	"eden": {"name": "Eden", "description": "The classic world: a couple of great continents, smaller ones, and scattered islands.",
		"params": {"continent_scale": 36000.0, "island_bias": -0.02, "continent_blend": 1.0}},
	# 27% land, ~8 landmasses, largest 63%
	"earthlike": {"name": "Earthlike", "description": "Oceans and continents in Earth's proportions.",
		"params": {"continent_scale": 45000.0, "island_bias": -0.05, "continent_blend": 1.0}},
	# 26% land, ~9 landmasses, largest 39%: several of similar size
	"continents": {"name": "Continents", "description": "Several continents of similar size, split by open ocean.",
		"params": {"continent_scale": 35000.0, "island_bias": -0.05, "continent_blend": 1.0}},
	# 50% land, ~2.5 landmasses, largest 96%
	"pangaea": {"name": "Pangaea", "description": "One vast supercontinent wrapped by a world ocean.",
		"params": {"continent_scale": 100000.0, "island_bias": 0.1, "continent_blend": 1.0}},
	# 36% land, ~14 landmasses, largest 35%
	"small_continents": {"name": "Small Continents", "description": "Many modest landmasses and narrow seas.",
		"params": {"continent_scale": 18000.0, "island_bias": 0.0, "continent_blend": 0.9}},
	# 25% land, ~17 landmasses, largest 27%
	"archipelago": {"name": "Archipelago", "description": "Chains of islands across a shallow ocean.",
		"params": {"continent_scale": 22000.0, "island_bias": -0.12, "continent_blend": 0.7}},
	# 10% land, ~10 landmasses, largest 22% (was 5 with one holding half the land)
	"water_world": {"name": "Water World", "description": "Endless ocean and a handful of islands.",
		"params": {"continent_scale": 25000.0, "island_bias": -0.2, "continent_blend": 0.9}},
	# 51% land, mountains 66% of it (Eden: 27%)
	"highlands": {"name": "Highlands", "description": "Rugged land, mountain ranges everywhere.",
		"params": {"mountain_coverage": 0.65, "terrain_amplitude": 3400.0, "island_bias": 0.1}},
	# 51% land, mountains 11% of it
	"plains": {"name": "Great Plains", "description": "Broad flat lowlands, few mountains.",
		"params": {"mountain_coverage": 0.08, "lowland_relief": 0.12, "island_bias": 0.1}},
}

## Shift every point's temperature (0..1). Measured on Earthlike: land colder than 0.25 (snow, tundra) 17% -> cold 31%,
## hot 9%.
const TEMPERATURES := {
	"cold": {"name": "Cold", "description": "An ice-age world: wide tundra and ice caps, short summers.",
		"params": {"temperature_offset": -0.18}},
	"temperate": {"name": "Temperate", "description": "Earth-like warmth.",
		"params": {}},
	"hot": {"name": "Hot", "description": "A hothouse world: warm to the poles, little snow.",
		"params": {"temperature_offset": 0.15}},
}

## Shift every point's moisture (0..1). Measured on Earthlike: land drier than 0.3 (steppe, desert) 2% -> arid 25%;
## mean moisture 0.48 -> wet 0.63.
const RAINFALL := {
	"arid": {"name": "Arid", "description": "Dry land: steppe and desert spread, forests thin.",
		"params": {"moisture_offset": -0.12}},
	"normal": {"name": "Normal", "description": "Earth-like rainfall.",
		"params": {}},
	"wet": {"name": "Wet", "description": "Rain-soaked: dense forest, marsh and moss.",
		"params": {"moisture_offset": 0.15}},
}


## The settings with every option present and known (missing or unknown choices become the defaults)
static func normalized(settings: Dictionary) -> Dictionary:
	var out := DEFAULTS.duplicate()
	for key in OPTIONS:
		var choice = settings.get(key)
		if choice is String and OPTIONS[key][1].has(choice):
			out[key] = choice
	return out


## Puts the settings on a planet generator. Give it a copy: the scene's generator is a shared resource.
static func apply(gen: Object, settings: Dictionary) -> void:
	var s := normalized(settings)
	for key in OPTIONS:
		var params: Dictionary = OPTIONS[key][1][s[key]].params
		for k in params:
			gen.set(k, params[k])


## "Archipelago, Cold, Wet" (the defaults left out: "Eden")
static func describe(settings: Dictionary) -> String:
	var s := normalized(settings)
	var parts := []
	for key in OPTIONS:
		if key == "template" or s[key] != DEFAULTS[key]:
			parts.append(OPTIONS[key][1][s[key]].name)
	return ", ".join(parts)


## From world_meta's JSON (old worlds have none: the defaults)
static func from_json(text: String) -> Dictionary:
	var d = JSON.parse_string(text) if text != "" else null
	return normalized(d if d is Dictionary else {})
