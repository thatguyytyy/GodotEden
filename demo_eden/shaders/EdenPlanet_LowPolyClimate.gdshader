shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx, ambient_light_disabled;

#define EDEN_WEATHER_MATERIAL_UNIFORMS
#include "res://shaders/eden_weather.gdshaderinc"
#include "res://shaders/eden_season.gdshaderinc"
// Seasons: set on this material by EdenAmbience from EdenCalendar (not globals: GPU-driven terrain can't use them)
uniform vec4 eden_calendar = vec4(0.0);
uniform vec4 eden_calendar_axis = vec4(0.0, 1.0, 0.0, 0.0);

/*
    Eden Planet — Low-Poly Faceted Climate Terrain
    ------------------------------------------------
    Designed for a spherical Voxel Plugin planet.

    Main visual goals:
      • Real geometric triangle/facet normals
      • No procedural bump/normal noise
      • Large, readable low-poly terrain facets
      • Latitude-driven planetary climate
      • Temperature + moisture + altitude + slope biome blending
      • Natural solid-color terrain palettes
      • Existing Voxel surface data compatibility

    Existing Voxel data expected:
      CUSTOM0      = Transvoxel position/transition data
      CUSTOM1.x    = packed material indices
      CUSTOM1.y    = packed material weights
      CUSTOM2.r    = erosion
      CUSTOM2.g    = ridge
      CUSTOM2.b    = moisture
      CUSTOM2.a    = temperature

    Material indices used by EdenPlanetGeneratorV4:
      0 = grass
      1 = rock
      2 = snow
      3 = sand
      4 = dirt
      5 = moss
      6 = ocean floor

    IMPORTANT:
      The faceted appearance comes from dFdx/dFdy on the actual rendered
      triangle. The shader deliberately does NOT perturb NORMAL with noise.
*/


// -----------------------------------------------------------------------------
// PLANET / LOD
// -----------------------------------------------------------------------------

uniform float u_planet_radius = 40000.0;
uniform vec3 u_planet_center_world = vec3(0.0);
uniform vec3 u_planet_north_world = vec3(0.0, 1.0, 0.0);

uniform int u_transition_mask;
uniform vec2 u_lod_fade = vec2(0.0, 0.0);


// -----------------------------------------------------------------------------
// DEBUG
// -----------------------------------------------------------------------------
//
// 0 = normal terrain
// 1 = erosion
// 2 = ridge
// 3 = moisture
// 4 = temperature
// 5 = latitude
// 6 = altitude
// 7 = facet normal
// 8 = slope
// 9 = climate zones
// 10 = biome temperature
//
uniform int u_debug_mode = 0;


// -----------------------------------------------------------------------------
// FACET / COLOR CONTROLS
// -----------------------------------------------------------------------------

// Overall palette saturation.
// 1 = unchanged.
// Values above 1 make the stylized colors stronger.
uniform float u_vibrance : hint_range(0.0, 2.0) = 1.08;

// Large-scale color variation. This is ALBEDO variation only.
// It does not alter normals.
uniform float u_color_variation : hint_range(0.0, 1.0) = 0.12;

// Controls how strongly altitude pushes terrain toward mountain rock.
uniform float u_highland_altitude : hint_range(1000.0, 20000.0) = 8000.0;

// Controls the slope at which exposed rock begins.
uniform float u_rock_slope_start : hint_range(0.0, 1.0) = 0.80;
uniform float u_rock_slope_end : hint_range(0.0, 1.0) = 0.78;

// Controls how strongly high terrain becomes exposed rock.
uniform float u_highland_rock_strength : hint_range(0.0, 1.0) = 1.0;

// Normalized altitude (fraction of u_highland_altitude) above which whole faces turn to rock.
uniform float u_highland_rock_start : hint_range(0.0, 1.0) = 0.47;

// Controls snow placement.
uniform float u_snow_temperature : hint_range(0.0, 1.0) = 0.22;
uniform float u_snow_temperature_blend : hint_range(0.001, 0.5) = 0.08;
uniform float u_snow_altitude_start : hint_range(0.0, 1.0) = 0.45;
uniform float u_snow_altitude_full : hint_range(0.0, 1.0) = 0.78;
uniform float u_snow_slope_start : hint_range(0.0, 1.0) = 0.28;


// -----------------------------------------------------------------------------
// CLIMATE CONTROLS
// -----------------------------------------------------------------------------

// Latitude at which climate bands begin/end.
// Latitude is normalized:
//   0 = equator
//   1 = north/south pole
uniform float u_tropical_end : hint_range(0.0, 1.0) = 0.25;
uniform float u_temperate_start : hint_range(0.0, 1.0) = 0.20;
uniform float u_temperate_end : hint_range(0.0, 1.0) = 0.58;
uniform float u_boreal_start : hint_range(0.0, 1.0) = 0.48;
uniform float u_boreal_end : hint_range(0.0, 1.0) = 0.78;
uniform float u_polar_start : hint_range(0.0, 1.0) = 0.68;

// Moisture response.
uniform float u_moisture_dry : hint_range(0.0, 1.0) = 0.25;
uniform float u_moisture_wet : hint_range(0.0, 1.0) = 0.72;

// How much latitude contributes to temperature.
// This is useful when CUSTOM2.a already contains generated temperature.
uniform float u_latitude_temperature_strength : hint_range(0.0, 1.0) = 0.35;

// How much altitude cools the climate.
uniform float u_altitude_temperature_strength : hint_range(0.0, 1.0) = 0.25;

// Amount of cold-color desaturation.
uniform float u_cold_desaturation : hint_range(0.0, 1.0) = 0.18;


// -----------------------------------------------------------------------------
// TERRAIN PALETTE
// -----------------------------------------------------------------------------

// Tropical
uniform vec3 u_tropical_dry_grass = vec3(0.42, 0.40, 0.18);
uniform vec3 u_tropical_wet_grass = vec3(0.20, 0.42, 0.14);
uniform vec3 u_tropical_dark_grass = vec3(0.11, 0.30, 0.10);

// Temperate
uniform vec3 u_temperate_dry_grass = vec3(0.38, 0.38, 0.16);
uniform vec3 u_temperate_wet_grass = vec3(0.22, 0.42, 0.16);
uniform vec3 u_temperate_dark_grass = vec3(0.14, 0.31, 0.11);

// Boreal
uniform vec3 u_boreal_dry_grass = vec3(0.31, 0.35, 0.19);
uniform vec3 u_boreal_wet_grass = vec3(0.20, 0.36, 0.18);
uniform vec3 u_boreal_dark_grass = vec3(0.10, 0.25, 0.15);

// Polar / tundra
uniform vec3 u_polar_dry_grass = vec3(0.38, 0.40, 0.27);
uniform vec3 u_polar_wet_grass = vec3(0.32, 0.40, 0.27);
uniform vec3 u_polar_dark_grass = vec3(0.22, 0.30, 0.22);

// Rock
uniform vec3 u_rock_dark = vec3(0.40, 0.40, 0.38);
uniform vec3 u_rock_mid = vec3(0.49, 0.48, 0.44);
uniform vec3 u_rock_light = vec3(0.63, 0.61, 0.54);

// Snow
uniform vec3 u_snow_color = vec3(0.84, 0.85, 0.82);

// Sand
uniform vec3 u_sand_color = vec3(0.67, 0.56, 0.34);

// Dirt
uniform vec3 u_dirt_color = vec3(0.34, 0.24, 0.13);

// Moss
uniform vec3 u_moss_color = vec3(0.15, 0.31, 0.14);

// Ocean floor
uniform vec3 u_ocean_floor_color = vec3(0.18, 0.28, 0.33);


// -----------------------------------------------------------------------------
// VARYINGS
// -----------------------------------------------------------------------------

varying flat vec4 v_indices;
varying vec4 v_weights;
varying vec4 v_surface;
// 0 where the mesh had no surface data (far sectors): the climate is estimated there instead
varying float v_has_surface;
varying vec3 v_pos_world;
// Provoking-vertex altitude: one value per triangle, so highland rock cuts along facet edges.
varying flat float v_face_altitude01;
varying vec2 v_weather; // snow cover, wetness (EdenAmbience)


// -----------------------------------------------------------------------------
// UTILITY
// -----------------------------------------------------------------------------


vec4 decode_8bit_vec4(float v) {
	uint i = floatBitsToUint(v);

	return vec4(
		float(i & 0xffu),
		float((i >> 8u) & 0xffu),
		float((i >> 16u) & 0xffu),
		float((i >> 24u) & 0xffu)
	);
}


float luma(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}


vec3 saturate_color(vec3 c, float amount) {
	return clamp(
		mix(vec3(luma(c)), c, amount),
		vec3(0.0),
		vec3(1.0)
	);
}


float hash13(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;

	return fract(
		p.x * p.y * p.z *
		(p.x + p.y + p.z)
	);
}


float value_noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);

	f = f * f * (3.0 - 2.0 * f);

	float n00 = mix(
		hash13(i),
		hash13(i + vec3(1.0, 0.0, 0.0)),
		f.x
	);

	float n10 = mix(
		hash13(i + vec3(0.0, 1.0, 0.0)),
		hash13(i + vec3(1.0, 1.0, 0.0)),
		f.x
	);

	float n01 = mix(
		hash13(i + vec3(0.0, 0.0, 1.0)),
		hash13(i + vec3(1.0, 0.0, 1.0)),
		f.x
	);

	float n11 = mix(
		hash13(i + vec3(0.0, 1.0, 1.0)),
		hash13(i + vec3(1.0, 1.0, 1.0)),
		f.x
	);

	return mix(
		mix(n00, n10, f.y),
		mix(n01, n11, f.y),
		f.z
	);
}


float get_hash(vec2 c) {
	return fract(
		sin(dot(c.xy, vec2(12.9898, 78.233)))
		* 43758.5453
	);
}


// -----------------------------------------------------------------------------
// TRANSVOXEL
// -----------------------------------------------------------------------------

float get_transvoxel_secondary_factor(int idata) {
	int transition_mask = u_transition_mask & 0xff;
	int cell_border_mask = idata & 63;
	int vertex_border_mask = (idata >> 8) & 63;

	int m = transition_mask & cell_border_mask;

	float t = float(m != 0);
	t *= float((vertex_border_mask & ~transition_mask) == 0);

	return t;
}


vec3 get_transvoxel_position(
	vec3 vertex_pos,
	vec4 fdata
) {
	int idata = floatBitsToInt(fdata.a);

	float secondary_factor =
		get_transvoxel_secondary_factor(idata);

	vec3 pos = mix(
		vertex_pos,
		fdata.xyz,
		secondary_factor
	);

	int itransition = (idata >> 16) & 0xff;

	float transition_cull =
		float(
			itransition == 0 ||
			(itransition & u_transition_mask) != 0
		);

	return pos * transition_cull;
}


// -----------------------------------------------------------------------------
// MATERIAL DATA
// -----------------------------------------------------------------------------

vec3 material_base_color(int i) {

	if (i == 0) {
		return vec3(0.24, 0.42, 0.16); // grass
	}

	if (i == 1) {
		return u_rock_mid; // rock
	}

	if (i == 2) {
		return u_snow_color; // snow
	}

	if (i == 3) {
		return u_sand_color; // sand
	}

	if (i == 4) {
		return u_dirt_color; // dirt
	}

	if (i == 5) {
		return u_moss_color; // moss
	}

	if (i == 6) {
		return u_ocean_floor_color; // ocean floor
	}

	return vec3(1.0, 0.0, 1.0);
}


float material_roughness(int i) {

	if (i == 2) {
		return 0.82;
	}

	if (i == 1) {
		return 0.88;
	}

	if (i == 3) {
		return 0.90;
	}

	if (i == 6) {
		return 0.78;
	}

	return 0.92;
}


bool is_vegetation(int i) {
	return i == 0 || i == 5;
}


bool is_rock(int i) {
	return i == 1;
}


bool is_sand(int i) {
	return i == 3;
}


bool is_dirt(int i) {
	return i == 4;
}


bool is_snow(int i) {
	return i == 2;
}


bool is_ocean_floor(int i) {
	return i == 6;
}


// -----------------------------------------------------------------------------
// CLIMATE / BIOME HELPERS
// -----------------------------------------------------------------------------

// Smooth tropical / temperate / boreal / polar climate bands.
// The returned weights are intentionally overlapping so transitions remain
// natural rather than looking like hard latitude stripes.

float climate_tropical(float lat) {
	return 1.0 - smoothstep(
		u_tropical_end * 0.55,
		u_tropical_end,
		lat
	);
}


float climate_temperate(float lat) {

	float rising =
		smoothstep(
			u_temperate_start,
			u_temperate_start + 0.10,
			lat
		);

	float falling =
		1.0 - smoothstep(
			u_temperate_end - 0.10,
			u_temperate_end,
			lat
		);

	return rising * falling;
}


float climate_boreal(float lat) {

	float rising =
		smoothstep(
			u_boreal_start,
			u_boreal_start + 0.10,
			lat
		);

	float falling =
		1.0 - smoothstep(
			u_boreal_end - 0.10,
			u_boreal_end,
			lat
		);

	return rising * falling;
}


float climate_polar(float lat) {
	return smoothstep(
		u_polar_start,
		1.0,
		lat
	);
}


vec3 climate_grass_color(
	float lat,
	float moisture
) {

	float tropical =
		climate_tropical(lat);

	float temperate =
		climate_temperate(lat);

	float boreal =
		climate_boreal(lat);

	float polar =
		climate_polar(lat);

	float total =
		tropical +
		temperate +
		boreal +
		polar;

	// Prevent gaps if parameters are changed into unusual ranges.
	if (total < 0.0001) {
		return u_temperate_wet_grass;
	}

	tropical /= total;
	temperate /= total;
	boreal /= total;
	polar /= total;

	float wet =
		smoothstep(
			u_moisture_dry,
			u_moisture_wet,
			moisture
		);

	vec3 tropical_color =
		mix(
			u_tropical_dry_grass,
			u_tropical_wet_grass,
			wet
		);

	vec3 temperate_color =
		mix(
			u_temperate_dry_grass,
			u_temperate_wet_grass,
			wet
		);

	vec3 boreal_color =
		mix(
			u_boreal_dry_grass,
			u_boreal_wet_grass,
			wet
		);

	vec3 polar_color =
		mix(
			u_polar_dry_grass,
			u_polar_wet_grass,
			wet
		);

	return
		tropical_color * tropical +
		temperate_color * temperate +
		boreal_color * boreal +
		polar_color * polar;
}


vec3 climate_dark_grass_color(
	float lat
) {

	float tropical =
		climate_tropical(lat);

	float temperate =
		climate_temperate(lat);

	float boreal =
		climate_boreal(lat);

	float polar =
		climate_polar(lat);

	float total =
		tropical +
		temperate +
		boreal +
		polar;

	total = max(total, 0.0001);

	tropical /= total;
	temperate /= total;
	boreal /= total;
	polar /= total;

	return
		u_tropical_dark_grass * tropical +
		u_temperate_dark_grass * temperate +
		u_boreal_dark_grass * boreal +
		u_polar_dark_grass * polar;
}


// -----------------------------------------------------------------------------
// VERTEX
// -----------------------------------------------------------------------------

void vertex() {

	VERTEX =
		get_transvoxel_position(
			VERTEX,
			CUSTOM0
		);

	v_pos_world =
		(MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// Weather: snow piles up by lifting the ground along the planet's up. A function of position
	// only, so vertices shared between LOD blocks move together and no cracks open.
	vec4 weather = eden_weather(v_pos_world);
	v_weather = weather.gb;
	if (weather.g > 0.0) {
		// (less where feet have pressed a path into it)
		vec3 snow_lift = eden_weather_up(v_pos_world) * weather.g * eden_weather_params.x * eden_snow_left_soft(v_pos_world);
		v_pos_world += snow_lift;
		VERTEX += snow_lift * mat3(MODEL_MATRIX); // inverse of a rigid transform's rotation
	}

	v_face_altitude01 =
		clamp(
			(length(v_pos_world - u_planet_center_world) - u_planet_radius) /
			max(u_highland_altitude, 1.0),
			0.0,
			1.0
		);

	v_indices =
		decode_8bit_vec4(
			CUSTOM1.x
		);

	v_weights =
		decode_8bit_vec4(
			CUSTOM1.y
		) / 255.0;

	// Meshes without surface data can return zero.
	// Fall back to neutral climate values.
	v_surface =
		dot(CUSTOM2, CUSTOM2) == 0.0
		? vec4(0.5)
		: CUSTOM2;
	v_has_surface = dot(CUSTOM2, CUSTOM2) == 0.0 ? 0.0 : 1.0;
}


// -----------------------------------------------------------------------------
// FRAGMENT
// -----------------------------------------------------------------------------

void fragment() {

	// -------------------------------------------------------------------------
	// Surface data
	// -------------------------------------------------------------------------

	float erosion =
		clamp(v_surface.r, 0.0, 1.0);

	float ridge =
		v_surface.g * 2.0 - 1.0;

	float moisture =
		clamp(v_surface.b, 0.0, 1.0);

	float generator_temperature =
		clamp(v_surface.a, 0.0, 1.0);


	// -------------------------------------------------------------------------
	// Planet coordinates
	// -------------------------------------------------------------------------

	vec3 radial =
		normalize(
			v_pos_world -
			u_planet_center_world
		);

	vec3 planet_north =
		normalize(
			u_planet_north_world
		);

	float altitude =
		length(
			v_pos_world -
			u_planet_center_world
		)
		-
		u_planet_radius;

	float altitude01 =
		clamp(
			altitude /
			max(u_highland_altitude, 1.0),
			0.0,
			1.0
		);


	// Latitude:
	//   0 = equator
	//   1 = either pole
	float signed_latitude =
		asin(
			clamp(
				dot(radial, planet_north),
				-1.0,
				1.0
			)
		) /
		(PI * 0.5);

	float abs_latitude =
		abs(signed_latitude);


	// -------------------------------------------------------------------------
	// True geometric triangle normal
	// -------------------------------------------------------------------------
	//
	// This is the heart of the low-poly look.
	//
	// dFdx/dFdy operate on the actual rendered triangle, so every triangle
	// receives a single geometric face normal instead of a smooth interpolated
	// normal.
	//
	// DO NOT add procedural bump normals here.
	//
	// Derivatives come from view-space VERTEX, not v_pos_world: world coords
	// sit ~40 km out where float steps are ~4 mm, so up close the world-space
	// derivatives are rounding noise and the normal jitters per pixel.

	vec3 n_world =
		normalize(
			(INV_VIEW_MATRIX * vec4(
				cross(
					dFdx(VERTEX),
					dFdy(VERTEX)
				),
				0.0
			)).xyz
		);

	// Ensure the normal points away from the planet.
	if (dot(n_world, radial) < 0.0) {
		n_world = -n_world;
	}


	// -------------------------------------------------------------------------
	// Slope
	// -------------------------------------------------------------------------

	float slope_up =
		clamp(
			dot(n_world, radial),
			0.0,
			1.0
		);

	float steep =
		1.0 -
		smoothstep(
			u_rock_slope_end,
			u_rock_slope_start,
			slope_up
		);


	// -------------------------------------------------------------------------
	// Climate temperature
	// -------------------------------------------------------------------------
	//
	// CUSTOM2.a remains the generator's primary temperature.
	// Latitude and altitude gently modify it rather than replacing it.

	float latitude_cold =
		smoothstep(
			0.0,
			1.0,
			abs_latitude
		);

	float climate_temperature =
		generator_temperature;

	climate_temperature =
		climate_temperature
		-
		latitude_cold *
		u_latitude_temperature_strength;

	climate_temperature =
		climate_temperature
		-
		altitude01 *
		u_altitude_temperature_strength;

	climate_temperature =
		clamp(
			climate_temperature,
			0.0,
			1.0
		);


	// -------------------------------------------------------------------------
	// Climate zones
	// -------------------------------------------------------------------------

	float tropical =
		climate_tropical(abs_latitude);

	float temperate =
		climate_temperate(abs_latitude);

	float boreal =
		climate_boreal(abs_latitude);

	float polar =
		climate_polar(abs_latitude);


	// -------------------------------------------------------------------------
	// Base material weights
	// -------------------------------------------------------------------------

	vec4 w =
		v_weights /
		(
			v_weights.x +
			v_weights.y +
			v_weights.z +
			v_weights.w +
			0.00001
		);

	float vegetation_weight = 0.0;
	float rock_weight = 0.0;
	float sand_weight = 0.0;
	float dirt_weight = 0.0;
	float snow_weight = 0.0;
	float ocean_floor_weight = 0.0;

	vec3 material_color = vec3(0.0);
	float roughness = 0.0;

	for (int k = 0; k < 4; ++k) {

		int material_id =
			int(v_indices[k]);

		float weight =
			w[k];

		material_color +=
			material_base_color(material_id)
			*
			weight;

		roughness +=
			material_roughness(material_id)
			*
			weight;

		if (is_vegetation(material_id)) {
			vegetation_weight += weight;
		}

		if (is_rock(material_id)) {
			rock_weight += weight;
		}

		if (is_sand(material_id)) {
			sand_weight += weight;
		}

		if (is_dirt(material_id)) {
			dirt_weight += weight;
		}

		if (is_snow(material_id)) {
			snow_weight += weight;
		}

		if (is_ocean_floor(material_id)) {
			ocean_floor_weight += weight;
		}
	}


	// -------------------------------------------------------------------------
	// Vegetation climate color
	// -------------------------------------------------------------------------

	vec3 grass_color =
		climate_grass_color(
			abs_latitude,
			moisture
		);

	vec3 dark_grass_color =
		climate_dark_grass_color(
			abs_latitude
		);

	// Wet areas get deeper greens.
	float wetness =
		smoothstep(
			0.30,
			0.78,
			moisture
		);

	vec3 vegetation_color =
		mix(
			grass_color,
			dark_grass_color,
			wetness * 0.32
		);

	// Cold vegetation becomes slightly less saturated.
	float cold_factor =
		1.0 -
		smoothstep(
			0.10,
			0.45,
			climate_temperature
		);

	vegetation_color =
		saturate_color(
			vegetation_color,
			1.0 -
			cold_factor *
			u_cold_desaturation
		);

	// The seasons here (this hemisphere's, felt more toward the poles): the ground's plants flush in spring,
	// brown in autumn and go dormant in winter, like the grass tufts
	vegetation_color =
		eden_seasonal_green(
			vegetation_color,
			eden_grass_state_tropical(
				eden_grass_state(eden_season(radial, eden_calendar, eden_calendar_axis.xyz)),
				eden_tropical_season(radial, eden_calendar, eden_calendar_axis.xyz)
			)
		);


	// -------------------------------------------------------------------------
	// Grass / vegetation
	// -------------------------------------------------------------------------

	vec3 albedo =
		material_color;

	albedo =
		mix(
			albedo,
			vegetation_color,
			vegetation_weight
		);


	// -------------------------------------------------------------------------
	// High altitude / mountain rock
	// -------------------------------------------------------------------------

	float highland =
		step(
			u_highland_rock_start,
			v_face_altitude01
		);

	float mountain_rock =
		max(
			steep,
			highland *
			u_highland_rock_strength
		);

	// Ridge tops expose additional rock.
	mountain_rock =
		max(
			mountain_rock,
			max(ridge, 0.0) * 0.35
		);

	mountain_rock =
		clamp(
			mountain_rock,
			0.0,
			1.0
		);


	// -------------------------------------------------------------------------
	// Large-scale rock palette variation
	// -------------------------------------------------------------------------
	//
	// This changes COLOR only. It does not affect the facet normal.
	//
	// The variation is deliberately broad so mountains retain the solid-color
	// low-poly appearance rather than looking like textured noise.

	float rock_noise =
		value_noise(
			v_pos_world * 0.00022
		);

	vec3 rock_color =
		mix(
			u_rock_dark,
			u_rock_mid,
			smoothstep(
				0.20,
				0.52,
				rock_noise
			)
		);

	rock_color =
		mix(
			rock_color,
			u_rock_light,
			smoothstep(
				0.58,
				0.88,
				rock_noise
			)
		);

	// Slightly brighten exposed high ridges.
	rock_color *=
		1.0 +
		max(ridge, 0.0) *
		0.08;

	albedo =
		mix(
			albedo,
			rock_color,
			mountain_rock
		);


	// -------------------------------------------------------------------------
	// Dirt / sediment
	// -------------------------------------------------------------------------

	float dirt_amount =
		dirt_weight *
		(1.0 - mountain_rock) *
		(1.0 - wetness * 0.25);

	albedo =
		mix(
			albedo,
			u_dirt_color,
			dirt_amount
		);


	// -------------------------------------------------------------------------
	// Sand
	// -------------------------------------------------------------------------

	// Sand stays mostly controlled by the generator's material assignment,
	// while allowing dry regions to read a little more strongly.
	float sand_amount =
		sand_weight *
		(1.0 + (1.0 - moisture) * 0.20);

	sand_amount =
		clamp(
			sand_amount,
			0.0,
			1.0
		);

	albedo =
		mix(
			albedo,
			u_sand_color,
			sand_amount
		);


	// -------------------------------------------------------------------------
	// Ocean floor
	// -------------------------------------------------------------------------

	albedo =
		mix(
			albedo,
			u_ocean_floor_color,
			ocean_floor_weight
		);


	// -------------------------------------------------------------------------
	// Snow / alpine snow
	// -------------------------------------------------------------------------

	float temperature_snow =
		1.0 -
		smoothstep(
			u_snow_temperature -
			u_snow_temperature_blend,

			u_snow_temperature +
			u_snow_temperature_blend,

			climate_temperature
		);

	float altitude_snow =
		smoothstep(
			u_snow_altitude_start,
			u_snow_altitude_full,
			altitude01
		);

	float snow_slope =
		smoothstep(
			u_snow_slope_start,
			0.85,
			slope_up
		);

	float generated_snow =
		snow_weight;

	float alpine_snow =
		temperature_snow *
		altitude_snow *
		snow_slope;

	float snow_amount =
		max(
			generated_snow,
			alpine_snow
		);

	snow_amount =
		clamp(
			snow_amount,
			0.0,
			1.0
		);

	// Seasonal snow cover and frost, from today's temperature here (the climate plus this hemisphere's season,
	// as the weather reckons it): lying snow below about -3 °C, settling on flatter ground first; a hoar-frost
	// paling just above; both come and go with the seasons, opposite in the two hemispheres
	// (far sectors have no surface data: their climate comes from the latitude/height estimate)
	float annual_temperature =
		mix(
			eden_estimated_temperature(radial, eden_calendar_axis.xyz, altitude),
			generator_temperature,
			v_has_surface
		);
	float season_temperature =
		annual_temperature +
		eden_season_offset(radial, eden_calendar, eden_calendar_axis.xyz);
	float land = 1.0 - ocean_floor_weight;
	// Lying winter snow comes through the weather map (below) with the storms' snow, so the ground agrees with the
	// grass and trees; far sectors, which have no weather lookup of their own, reckon it here
	float winter_snow =
		(1.0 - v_has_surface) *
		eden_winter_snow(season_temperature) *
		smoothstep(0.3, 0.75, slope_up) *
		land;
	float frost =
		(1.0 - smoothstep(0.26, 0.33, season_temperature)) *
		(1.0 - winter_snow) *
		land;
	albedo = mix(albedo, mix(albedo, vec3(0.78, 0.8, 0.82), 0.55), frost * 0.6);
	snow_amount = max(snow_amount, winter_snow);

	albedo =
		mix(
			albedo,
			u_snow_color,
			snow_amount
		);

	// Weather: fresh snow settles on flatter ground first; rain darkens and glosses the ground
	float fresh_snow = smoothstep(0.0, 0.35, v_weather.x * 1.3 - (1.0 - slope_up) * 1.5);
	albedo = mix(albedo, eden_snow_color(), fresh_snow);
	if (fresh_snow > 0.0) {
		// Packed snow in a footpath: per pixel, so the path has crisp edges (the dip itself is per vertex)
		// (trodden snow in shade: bluish, dark enough to read against sunlit snow, which is near white)
		albedo = mix(albedo, albedo * vec3(0.52, 0.58, 0.68), eden_snow_trail(v_pos_world) * fresh_snow);
	}
	snow_amount = max(snow_amount, fresh_snow);
	float wet_amount = v_weather.y * (1.0 - snow_amount);
	albedo *= 1.0 - eden_weather_params.y * wet_amount;


	// -------------------------------------------------------------------------
	// Moss
	// -------------------------------------------------------------------------

	// Moss is represented by material index 5 through the vegetation group.
	// Wet/cool areas remain darker and richer.
	float moss_factor =
		clamp(
			moisture *
			(1.0 - climate_temperature * 0.35),
			0.0,
			1.0
		);

	// Only apply a modest moss influence so existing material weights remain
	// meaningful.
	float moss_amount =
		moss_factor *
		0.18;

	albedo =
		mix(
			albedo,
			u_moss_color,
			moss_amount *
			vegetation_weight
		);


	// -------------------------------------------------------------------------
	// Subtle low-poly palette variation
	// -------------------------------------------------------------------------
	//
	// This is intentionally low-frequency and low-contrast.
	// Lighting remains responsible for the major triangle-to-triangle changes.

	float color_noise =
		value_noise(
			v_pos_world * 0.00045
		);

	float color_variation =
		mix(
			1.0 - u_color_variation,
			1.0 + u_color_variation,
			color_noise
		);

	// Reduce color variation in snow so it remains clean.
	color_variation =
		mix(
			color_variation,
			1.0,
			snow_amount * 0.75
		);

	albedo *= color_variation;


	// -------------------------------------------------------------------------
	// Final palette saturation
	// -------------------------------------------------------------------------

	albedo =
		saturate_color(
			albedo,
			u_vibrance
		);

	albedo =
		clamp(
			albedo,
			vec3(0.0),
			vec3(1.0)
		);


	// -------------------------------------------------------------------------
	// Material output
	// -------------------------------------------------------------------------

	ALBEDO = albedo;

	ROUGHNESS =
		mix(
			roughness,
			0.88,
			mountain_rock * 0.35
		);

	ROUGHNESS =
		mix(
			ROUGHNESS,
			0.86,
			snow_amount * 0.60
		);

	ROUGHNESS = mix(ROUGHNESS, 0.3, wet_amount);

	METALLIC = 0.0;

	// Keep the terrain matte. The low-poly facet lighting should be the star (a sky sheen at grazing angles washes
	// distant ground toward white).
	SPECULAR = 0.01;


	// -------------------------------------------------------------------------
	// TRUE FACET NORMAL OUTPUT
	// -------------------------------------------------------------------------

	NORMAL =
		normalize(
			(VIEW_MATRIX * vec4(n_world, 0.0)).xyz
		);


	// -------------------------------------------------------------------------
	// DEBUG MODES
	// -------------------------------------------------------------------------

	if (u_debug_mode > 0) {

		vec3 debug_color = vec3(0.0);

		if (u_debug_mode == 1) {
			debug_color = vec3(erosion);
		}
		else if (u_debug_mode == 2) {
			debug_color = vec3(v_surface.g);
		}
		else if (u_debug_mode == 3) {
			debug_color = vec3(moisture);
		}
		else if (u_debug_mode == 4) {
			debug_color = vec3(generator_temperature);
		}
		else if (u_debug_mode == 5) {
			debug_color = vec3(
				signed_latitude * 0.5 + 0.5
			);
		}
		else if (u_debug_mode == 6) {
			debug_color = vec3(altitude01);
		}
		else if (u_debug_mode == 7) {
			debug_color =
				n_world * 0.5 +
				0.5;
		}
		else if (u_debug_mode == 8) {
			debug_color = vec3(slope_up);
		}
		else if (u_debug_mode == 9) {
			debug_color = vec3(
				tropical,
				temperate,
				boreal
			);

			if (polar > 0.5) {
				debug_color = vec3(
					0.75,
					0.75,
					0.75
				);
			}
		}
		else if (u_debug_mode == 10) {
			debug_color =
				vec3(climate_temperature);
		}

		ALBEDO = vec3(0.0);
		EMISSION = debug_color;
	}


	// -------------------------------------------------------------------------
	// Transvoxel LOD fade
	// -------------------------------------------------------------------------

	if (
		u_lod_fade.x > 0.0 ||
		u_lod_fade.y > 0.0
	) {

		float fade_hash =
			get_hash(SCREEN_UV);

		if (u_lod_fade.y > 0.5) {

			if (u_lod_fade.x < fade_hash) {
				discard;
			}

		} else {

			if (u_lod_fade.x > fade_hash) {
				discard;
			}
		}
	}
}
