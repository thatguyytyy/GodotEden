/*
=====================================================================
  UNIVERSAL PLANET SHADER  -  Billboard Edition       (Godot 4.x, 2D)
  - Jon Berg -- Recurrent Neural Nitwit
  License: CC0 1.0 - public domain. Use it, change it, sell it.
=====================================================================

  One shader, many worlds. Draws a fully shaded sphere on a flat quad
  (an "impostor"), so a planet costs one quad instead of a mesh.

  Planet types (planet_type / instance data .y):
     0 Terran            earthlike / rocky, oceans, biomes, life
     1 Gas Giant         sheared cloud bands, storm spots
     2 Ocean World       almost no land
     3 Ice / Plutoid     ice, tholin patches, bright plains, cracks
     4 Barren Rock       airless, cratered
     5 Runaway Greenhouse  thick opaque cloud, hot glow
     6 Lava World        crust, glowing cracks and lava seas
     7 Ice Giant         pale cyan banded giant
     8 Random            type picked from the seed

  Features: pixelation + "sensor level" clarity (features fade in as
  sensor_level rises), atmosphere rim + halo, moving clouds, hurricanes,
  lightning, city lights (with grid look at high tech), daytime city
  patches, wildfires, drifting "life" herds, moving water glints,
  auto level-of-detail from on-screen size.

---------------------------------------------------------------------
  QUICK START (single planet)
---------------------------------------------------------------------
  ColorRect (or Sprite2D) of any square size -> Material -> this shader.
  Leave use_instance_data OFF and tweak the uniforms.

---------------------------------------------------------------------
  MULTIMESH2D (thousands of planets, one draw call)
---------------------------------------------------------------------
  Turn use_instance_data ON. Per instance you send 8 numbers:

    instance COLOR   (r,g,b,a) = temperature, ocean, atmosphere, life
                                 each 0..1
    custom data      (r,g,b,a) = seed, planet_type, sensor_level,
                                 light_angle_degrees
                                 seed: whole number 0..2000
                                 type: 0..8 (8 = random from seed)
                                 sensor: 0..1
                                 light angle: 0..360, 0 = sunlight from
                                 the right, 90 = from above

    life: 0 = dead. 0..0.5 = biosphere. 0.5..1 = rising civilization.

  GDScript:

    var mm := MultiMesh.new()
    mm.transform_format = MultiMesh.TRANSFORM_2D
    mm.use_colors = true
    mm.use_custom_data = true
    var quad := QuadMesh.new()
    quad.size = Vector2(256, 256)
    mm.mesh = quad
    mm.instance_count = 200
    for i in mm.instance_count:
        mm.set_instance_transform_2d(i, Transform2D(0.0, pos[i]))
        mm.set_instance_color(i, Color(temp, ocean, atmo, life))
        mm.set_instance_custom_data(i, Color(seed, ptype, sensor, sun_deg))
    $MultiMeshInstance2D.multimesh = mm

  Notes:
   * QuadMesh is vertically flipped in 2D: turn flip_uv_y ON for it.
   * Keep the node's modulate white when using instance data.
   * Seeds above ~2000 lose precision (half-float storage).
   * With randomize_params ON, only the seed is needed: type (if 8),
     climate, atmosphere, life, tilt and spin all come from it.
   * align_light_to_world keeps sunlight fixed even if the instance
     (or node) is rotated.

  PERFORMANCE: cost scales with on-screen size. auto_lod cuts noise
  octaves and skips fine features for small planets. Hero planet at
  512px is fine; a galaxy map with hundreds of 30-60px planets is fine.
=====================================================================
*/
shader_type canvas_item;
render_mode unshaded;

// ---------------------------------------------------------------- UNIFORMS
group_uniforms Instance_Data;
uniform bool use_instance_data = false;
uniform bool flip_uv_y = false;
uniform bool align_light_to_world = true;

// Eden: paint the unlit surface (albedo, clouds, storms, fires) as an equirectangular map for the sky shader's
// moon / parent planet texture slots instead of a lit disc. The sky shader does the lighting and phase.
group_uniforms Eden;
uniform bool equirect_output = false;

group_uniforms Planet;
uniform int planet_type : hint_enum("Terran", "Gas Giant", "Ocean World", "Ice / Plutoid", "Barren Rock", "Runaway Greenhouse", "Lava World", "Ice Giant", "Random (from seed)") = 0;
uniform float planet_seed : hint_range(0.0, 2000.0, 1.0) = 7.0;
uniform bool randomize_params = false;
uniform bool enforce_type_rules = true;
uniform float temperature : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float ocean_coverage : hint_range(0.0, 1.0, 0.01) = 0.55;
uniform float atmosphere_density : hint_range(0.0, 1.0, 0.01) = 0.6;
uniform float life_level : hint_range(0.0, 1.0, 0.01) = 0.6;
uniform float planet_radius : hint_range(0.3, 1.0, 0.01) = 0.8;
uniform float hue_variation : hint_range(0.0, 1.0, 0.01) = 0.12;

group_uniforms Light;
uniform float sensor_level : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float light_angle_deg : hint_range(0.0, 360.0, 0.1) = 35.0;
uniform float light_facing : hint_range(-0.9, 0.95, 0.01) = 0.35;
uniform vec4 sun_color : source_color = vec4(1.0, 0.96, 0.88, 1.0);
uniform float ambient_light : hint_range(0.0, 0.3, 0.005) = 0.025;
uniform float exposure : hint_range(0.2, 2.5, 0.01) = 1.0;

group_uniforms Motion;
uniform float time_scale : hint_range(0.0, 8.0, 0.01) = 1.0;
uniform float rotation_speed : hint_range(-1.0, 1.0, 0.001) = 0.06;
uniform float axial_tilt_deg : hint_range(-60.0, 60.0, 0.5) = 12.0;
uniform float tilt_variation_deg : hint_range(0.0, 90.0, 0.5) = 30.0;
uniform float cloud_wind : hint_range(-0.5, 0.5, 0.001) = 0.02;
uniform float hurricane_spin : hint_range(-3.0, 3.0, 0.01) = 0.6;
uniform float gas_flow_speed : hint_range(0.0, 2.0, 0.01) = 0.6;

group_uniforms Terrain;
uniform float terrain_scale : hint_range(0.5, 8.0, 0.05) = 2.2;
uniform int terrain_octaves : hint_range(1, 8) = 5;
uniform float mountain_amount : hint_range(0.0, 1.0, 0.01) = 0.6;
uniform float relief : hint_range(0.0, 3.0, 0.01) = 1.0;
uniform float crater_amount : hint_range(0.0, 1.0, 0.01) = 0.6;
uniform float lat_gradient : hint_range(0.0, 1.5, 0.01) = 0.75;
uniform float water_glint : hint_range(0.0, 2.0, 0.01) = 0.8;

group_uniforms Gas_Giant;
uniform float gas_band_count : hint_range(2.0, 14.0, 0.1) = 6.0;
uniform float gas_turbulence : hint_range(0.0, 2.0, 0.01) = 1.0;

group_uniforms Clouds_And_Storms;
uniform float cloud_coverage : hint_range(0.0, 1.0, 0.01) = 0.55;
uniform float cloud_opacity : hint_range(0.0, 1.0, 0.01) = 0.9;
uniform float cloud_scale : hint_range(0.5, 8.0, 0.05) = 2.6;
uniform int cloud_octaves : hint_range(1, 8) = 5;
uniform float cloud_shadows : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float storm_activity : hint_range(0.0, 1.0, 0.01) = 0.45;
uniform float lightning_activity : hint_range(0.0, 1.0, 0.01) = 0.5;

group_uniforms Atmosphere;
uniform float atmo_halo_size : hint_range(0.0, 0.5, 0.005) = 0.12;
uniform float atmo_halo_strength : hint_range(0.0, 3.0, 0.01) = 1.0;
uniform float atmo_rim_strength : hint_range(0.0, 3.0, 0.01) = 1.0;
uniform float atmo_rim_power : hint_range(0.5, 8.0, 0.05) = 3.0;

group_uniforms Civilization;
uniform float city_density : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float tech_level : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float city_scale : hint_range(1.0, 10.0, 0.1) = 3.5;
uniform float city_detail : hint_range(10.0, 120.0, 1.0) = 48.0;
uniform float city_grid_lines : hint_range(20.0, 240.0, 1.0) = 90.0;
uniform float city_glow : hint_range(0.0, 4.0, 0.01) = 1.6;
uniform float city_outline : hint_range(0.0, 2.0, 0.01) = 0.6;
uniform float city_daytime_visibility : hint_range(0.0, 1.0, 0.01) = 0.35;

group_uniforms Wildfire_And_Life;
uniform float wildfire_activity : hint_range(0.0, 1.0, 0.01) = 0.25;
uniform float fire_scale : hint_range(1.0, 12.0, 0.1) = 5.0;
uniform float life_grid : hint_range(20.0, 160.0, 1.0) = 70.0;
uniform float life_dot_size : hint_range(0.05, 0.5, 0.01) = 0.22;
uniform float life_dot_opacity : hint_range(0.0, 1.0, 0.01) = 0.7;
uniform float life_speed : hint_range(0.0, 4.0, 0.01) = 0.8;
uniform float life_generation_rate : hint_range(0.0, 2.0, 0.01) = 0.25;

group_uniforms Sensor_And_Pixelation;
uniform bool sensor_gating = true;
uniform int pixelate_mode : hint_enum("Off", "Sensor driven", "Fixed") = 1;
uniform float pixels_min : hint_range(6.0, 64.0, 1.0) = 12.0;
uniform float pixels_max : hint_range(32.0, 512.0, 1.0) = 140.0;
uniform float sensor_curve : hint_range(0.3, 3.0, 0.05) = 1.0;
uniform float fixed_pixels : hint_range(8.0, 512.0, 1.0) = 64.0;
uniform bool sensor_posterize = true;
uniform float sensor_noise : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float sensor_scanlines : hint_range(0.0, 1.0, 0.01) = 0.4;
uniform vec4 unknown_color : source_color = vec4(0.35, 0.47, 0.6, 1.0);

group_uniforms Performance;
uniform bool auto_lod = true;
uniform float lod_min_pixels : hint_range(4.0, 64.0, 1.0) = 10.0;
uniform float lod_full_pixels : hint_range(64.0, 1024.0, 1.0) = 180.0;

group_uniforms Palette_Rocky;
uniform vec4 ocean_shallow : source_color = vec4(0.12, 0.45, 0.62, 1.0);
uniform vec4 ocean_deep : source_color = vec4(0.02, 0.10, 0.30, 1.0);
uniform vec4 land_low : source_color = vec4(0.36, 0.30, 0.22, 1.0);
uniform vec4 land_high : source_color = vec4(0.62, 0.56, 0.48, 1.0);
uniform vec4 desert_color : source_color = vec4(0.78, 0.62, 0.38, 1.0);
uniform vec4 vegetation_color : source_color = vec4(0.12, 0.38, 0.14, 1.0);
uniform vec4 ice_color : source_color = vec4(0.90, 0.95, 1.0, 1.0);
uniform vec4 lava_color : source_color = vec4(1.0, 0.35, 0.05, 1.0);

group_uniforms Palette_Gas;
uniform vec4 gas_color_a : source_color = vec4(0.86, 0.72, 0.52, 1.0);
uniform vec4 gas_color_b : source_color = vec4(0.62, 0.42, 0.28, 1.0);
uniform vec4 gas_color_c : source_color = vec4(0.94, 0.86, 0.72, 1.0);
uniform vec4 gas_spot_color : source_color = vec4(0.75, 0.32, 0.20, 1.0);
uniform vec4 greenhouse_light : source_color = vec4(0.95, 0.82, 0.55, 1.0);
uniform vec4 greenhouse_dark : source_color = vec4(0.65, 0.42, 0.22, 1.0);

group_uniforms Palette_Effects;
uniform vec4 atmosphere_color : source_color = vec4(0.45, 0.68, 1.0, 1.0);
uniform vec4 twilight_color : source_color = vec4(1.0, 0.5, 0.25, 1.0);
uniform vec4 cloud_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 city_color : source_color = vec4(1.0, 0.82, 0.5, 1.0);
uniform vec4 city_day_color : source_color = vec4(0.55, 0.55, 0.58, 1.0);
uniform vec4 fire_color : source_color = vec4(1.0, 0.4, 0.08, 1.0);
uniform vec4 lightning_color : source_color = vec4(0.75, 0.85, 1.0, 1.0);
uniform vec4 life_dot_color : source_color = vec4(0.12, 0.08, 0.05, 1.0);

group_uniforms;

// ---------------------------------------------------------------- VARYINGS
varying flat vec4 v_custom;
varying flat vec4 v_inst_color;
varying flat float v_rot;

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	v_inst_color = COLOR;
	v_rot = atan(MODEL_MATRIX[0].y, MODEL_MATRIX[0].x);
}

// ---------------------------------------------------------------- HASH / NOISE
float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

float hash13(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

vec3 hash31(float p) {
	vec3 p3 = fract(vec3(p) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xxy + p3.yzz) * p3.zyx);
}

vec3 hash33(vec3 p3) {
	p3 = fract(p3 * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yxz + 33.33);
	return fract((p3.xxy + p3.yxx) * p3.zyx);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float a = hash13(i);
	float b = hash13(i + vec3(1.0, 0.0, 0.0));
	float c = hash13(i + vec3(0.0, 1.0, 0.0));
	float d = hash13(i + vec3(1.0, 1.0, 0.0));
	float e = hash13(i + vec3(0.0, 0.0, 1.0));
	float g = hash13(i + vec3(1.0, 0.0, 1.0));
	float h = hash13(i + vec3(0.0, 1.0, 1.0));
	float k = hash13(i + vec3(1.0, 1.0, 1.0));
	return mix(mix(mix(a, b, f.x), mix(c, d, f.x), f.y),
			mix(mix(e, g, f.x), mix(h, k, f.x), f.y), f.z);
}

const mat3 OCT_ROT = mat3(vec3(0.00, 0.80, 0.60), vec3(-0.80, 0.36, -0.48), vec3(-0.60, -0.48, 0.64));

float fbm(vec3 p, int oct) {
	float a = 0.5;
	float s = 0.0;
	float n = 0.0;
	for (int i = 0; i < 8; i++) {
		if (i >= oct) {
			break;
		}
		s += a * vnoise(p);
		n += a;
		p = OCT_ROT * p * 2.03 + vec3(1.7, 9.2, 4.1);
		a *= 0.5;
	}
	return s / max(n, 0.0001);
}

float ridged(vec3 p, int oct) {
	float a = 0.5;
	float s = 0.0;
	float n = 0.0;
	for (int i = 0; i < 8; i++) {
		if (i >= oct) {
			break;
		}
		float v = 1.0 - abs(2.0 * vnoise(p) - 1.0);
		s += a * v * v;
		n += a;
		p = OCT_ROT * p * 2.03 + vec3(5.3, 1.1, 7.7);
		a *= 0.5;
	}
	return s / max(n, 0.0001);
}

// ---------------------------------------------------------------- MISC MATH
vec3 rotY(vec3 v, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec3(c * v.x + s * v.z, v.y, -s * v.x + c * v.z);
}

vec3 rotZ(vec3 v, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec3(c * v.x - s * v.y, s * v.x + c * v.y, v.z);
}

vec3 hue_rot(vec3 c, float a) {
	vec3 k = vec3(0.57735026);
	float ca = cos(a);
	return c * ca + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - ca);
}

float gate(float s, float a, float b) {
	return sensor_gating ? smoothstep(a, b, s) : 1.0;
}

// ---------------------------------------------------------------- TYPE LOGIC
int pick_type(float seed) {
	float r = hash11(seed * 0.731 + 5.17);
	if (r < 0.16) { return 1; }
	if (r < 0.24) { return 7; }
	if (r < 0.46) { return 0; }
	if (r < 0.56) { return 2; }
	if (r < 0.68) { return 3; }
	if (r < 0.82) { return 4; }
	if (r < 0.90) { return 5; }
	return 6;
}

// returns (temperature, ocean, atmosphere, life)
vec4 random_env(int ty, float seed) {
	vec3 h = hash31(seed * 1.37 + 0.5);
	float w = hash11(seed * 2.91 + 7.0);
	float temp = mix(0.3, 0.75, h.x);
	float water = mix(0.15, 0.85, h.y);
	float atmo = mix(0.4, 0.85, h.z);
	float life = (w < 0.45) ? 0.0 : mix(0.1, 1.0, fract(w * 7.7));
	if (ty == 1) {
		temp = h.x * 0.7; water = 0.0; atmo = mix(0.7, 1.0, h.z); life = 0.0;
	} else if (ty == 7) {
		temp = h.x * 0.3; water = 0.0; atmo = mix(0.8, 1.0, h.z); life = 0.0;
	} else if (ty == 2) {
		water = mix(0.92, 1.0, h.y);
		life = (w < 0.6) ? 0.0 : mix(0.1, 0.5, fract(w * 7.7));
	} else if (ty == 3) {
		temp = h.x * 0.18; water = h.y * 0.4; atmo = h.z * 0.3; life = 0.0;
	} else if (ty == 4) {
		temp = h.x; water = 0.0; atmo = h.z * 0.03; life = 0.0;
	} else if (ty == 5) {
		temp = 1.0; water = 0.0; atmo = 1.0; life = 0.0;
	} else if (ty == 6) {
		temp = 1.0; water = h.y * 0.6; atmo = h.z * 0.4; life = 0.0;
	}
	return vec4(temp, water, atmo, life);
}

vec4 apply_rules(int ty, vec4 e) {
	vec4 r = e;
	if (ty == 1 || ty == 7) {
		r.y = 0.0; r.w = 0.0; r.z = max(r.z, 0.5);
	} else if (ty == 2) {
		r.y = max(r.y, 0.93);
	} else if (ty == 3) {
		r.x = min(r.x, 0.2); r.z = min(r.z, 0.35); r.w = 0.0;
	} else if (ty == 4) {
		r.y = 0.0; r.z = min(r.z, 0.04); r.w = 0.0;
	} else if (ty == 5) {
		r.x = max(r.x, 0.9); r.y = 0.0; r.z = max(r.z, 0.9); r.w = 0.0;
	} else if (ty == 6) {
		r.x = max(r.x, 0.95); r.z = min(r.z, 0.5); r.w = 0.0;
	}
	return r;
}

// ---------------------------------------------------------------- TERRAIN
// Bowl + rim craters from two jittered 3D cell grids (cheap, no neighbor search).
float craters(vec3 sp, float seed) {
	float total = 0.0;
	vec3 so = hash31(seed + 41.0) * 30.0;
	for (int k = 0; k < 2; k++) {
		float freq = (k == 0) ? 5.0 : 13.0;
		float amp = (k == 0) ? 1.0 : 0.5;
		vec3 p = sp * freq + so + float(k) * 11.0;
		vec3 cell = floor(p);
		vec3 h = hash33(cell);
		float present = step(0.35, h.x);
		vec3 c = cell + 0.3 + 0.4 * h;
		float rad = 0.16 + 0.16 * h.y;
		float d = length(p - c) / rad;
		float bowl = -max(1.0 - d * d, 0.0) * 0.6;
		float rd = (d - 1.0) * 3.5;
		float rim = exp(-rd * rd) * 0.3;
		total += present * amp * (bowl + rim);
	}
	return total;
}

float terrain_height(vec3 sp, float seed, int ptype, float atmo, int oct) {
	vec3 so = hash31(seed) * 90.0;
	vec3 pp = sp * terrain_scale + so;
	float h = fbm(pp, oct);
	if (mountain_amount > 0.001) {
		float m = ridged(pp * 1.7 + 3.1, max(oct - 1, 1));
		h = mix(h, m * 0.85, mountain_amount * smoothstep(0.5, 0.75, h));
	}
	if (crater_amount > 0.001 && (ptype == 4 || ptype == 3 || ptype == 6 || (ptype == 0 && atmo < 0.12))) {
		h += craters(sp, seed) * 0.22 * crater_amount * (1.0 - atmo * 0.8);
	}
	return h;
}

void rocky_surface(vec3 sp, vec3 Lo, float seed, int ptype, vec4 env, int oct, float relief_gate, float t,
		out vec3 albedo, out vec3 emis, out float ocean, out float veg, out float ice, out float hab, out float bump) {
	float temp = env.x;
	float water = env.y;
	float atmo = env.z;
	float life = env.w;
	vec3 so = hash31(seed) * 90.0;
	vec3 pp = sp * terrain_scale + so;

	float h = terrain_height(sp, seed, ptype, atmo, oct);
	float sea = (water <= 0.001) ? -1.0 : mix(0.32, 0.70, water);
	float sref = (sea < 0.0) ? 0.32 : sea;

	// Relief: one extra height sample a step toward the sun -> cheap directional bump shading.
	bump = 0.0;
	if (relief_gate > 0.01 && relief > 0.001) {
		vec3 tl = Lo - sp * dot(Lo, sp);
		float tlen = length(tl);
		if (tlen > 0.0001) {
			vec3 sp2 = normalize(sp + (tl / tlen) * 0.02);
			float h2 = terrain_height(sp2, seed, ptype, atmo, oct);
			bump = clamp((max(h, sref) - max(h2, sref)) / 0.02, -4.0, 4.0) * relief * relief_gate;
		}
	}

	float lat = abs(sp.y);
	float moist = fbm(pp * 0.8 + vec3(7.7, 1.3, 3.9), min(oct, 4));
	float alt = clamp((h - sref) / max(1.0 - sref, 0.05), 0.0, 1.0);
	float local_t = temp + 0.25 - lat_gradient * lat * lat;
	float local_ta = local_t - alt * 0.3;
	ice = 1.0 - smoothstep(0.14, 0.24, local_ta + (moist - 0.5) * 0.18);

	vec3 rock = mix(land_low.rgb, land_high.rgb, smoothstep(0.05, 0.9, alt + (h - 0.5) * 0.4));
	float desert = smoothstep(0.55, 0.85, local_t) * (1.0 - smoothstep(0.30, 0.55, moist));
	rock = mix(rock, desert_color.rgb, desert * 0.75);

	float vp = smoothstep(0.22, 0.42, local_ta) * (1.0 - smoothstep(0.85, 1.05, local_t))
			* smoothstep(0.34, 0.58, moist) * (1.0 - smoothstep(0.5, 0.9, alt));
	float vthr = (1.0 - life) * 0.8;
	veg = (life > 0.001) ? smoothstep(vthr, vthr + 0.2, vp) : 0.0;
	vec3 vcol = mix(desert_color.rgb * 0.7 + vegetation_color.rgb * 0.5, vegetation_color.rgb, smoothstep(0.4, 0.75, moist));

	vec3 land = mix(rock, vcol * (0.85 + 0.3 * h), veg);
	land = mix(land, ice_color.rgb, ice);

	ocean = (sea < 0.0) ? 0.0 : 1.0 - smoothstep(sea - 0.008, sea + 0.008, h);
	float depth = clamp((sea - h) / max(sea, 0.05), 0.0, 1.0);
	vec3 ocean_col = mix(ocean_shallow.rgb, ocean_deep.rgb, sqrt(depth));
	ocean_col = mix(ocean_col, ice_color.rgb, ice * 0.95);

	albedo = mix(land, ocean_col, ocean);
	hab = (1.0 - ocean) * (1.0 - ice) * (1.0 - smoothstep(0.45, 0.85, alt));
	emis = vec3(0.0);

	if (ptype == 4) { // barren: desaturated regolith
		float g = dot(albedo, vec3(0.333));
		albedo = mix(vec3(g), albedo, 0.45) * (0.75 + 0.5 * h);
	} else if (ptype == 3) { // plutoid: tholin, bright plain, cracks
		float tho = smoothstep(0.52, 0.72, fbm(pp * 0.7 + vec3(3.3, 8.8, 1.1), min(oct, 4)));
		vec3 base = mix(ice_color.rgb * 0.85, vec3(0.42, 0.24, 0.17), tho * 0.85);
		vec3 hp = normalize(hash31(seed * 3.17 + 1.0) * 2.0 - 1.0 + vec3(0.001));
		float heart = 1.0 - smoothstep(0.35, 0.85, distance(sp, hp));
		base = mix(base, ice_color.rgb * 1.15, heart);
		float cr = ridged(pp * 1.3 + 9.0, min(oct, 4));
		base *= 1.0 - 0.3 * smoothstep(0.80, 0.95, cr);
		albedo = base * (0.85 + 0.3 * h);
		ocean = 0.0; hab = 0.0; veg = 0.0; ice = 1.0;
	} else if (ptype == 6) { // lava world
		float crack = smoothstep(0.62, 0.90, ridged(pp * 2.2 + 5.0, min(oct, 4)));
		float pool = (sea < 0.0) ? 0.0 : 1.0 - smoothstep(sea - 0.13, sea - 0.10, h);
		vec3 crust = mix(vec3(0.05, 0.04, 0.04), vec3(0.16, 0.12, 0.10), smoothstep(0.3, 0.8, h));
		float glow = clamp(max(crack * 0.9, pool), 0.0, 1.0);
		albedo = mix(crust, lava_color.rgb * 0.5, glow * 0.6);
		emis = lava_color.rgb * glow * (0.9 + 0.3 * sin(t * 1.3 + h * 20.0));
		ocean = 0.0; hab = 0.0; veg = 0.0; ice = 0.0;
	}
}

// ---------------------------------------------------------------- GAS GIANTS
// mode 0 = gas giant, 1 = runaway greenhouse, 2 = ice giant
void gas_surface(vec3 sp, float seed, int mode, float storm, int oct, float t,
		out vec3 albedo, out float density) {
	vec3 so = hash31(seed + 5.0) * 60.0;
	vec3 cA;
	vec3 cB;
	vec3 cC;
	float bfreq;
	float contrast;
	float stretch;
	if (mode == 0) {
		cA = gas_color_a.rgb; cB = gas_color_b.rgb; cC = gas_color_c.rgb;
		bfreq = gas_band_count * (0.75 + 0.5 * hash11(seed + 1.7));
		contrast = 1.0; stretch = 5.0;
	} else if (mode == 1) {
		cA = greenhouse_light.rgb; cB = greenhouse_dark.rgb;
		cC = mix(greenhouse_light.rgb, greenhouse_dark.rgb, 0.5) * 1.1;
		bfreq = 2.5; contrast = 0.7; stretch = 3.0;
	} else {
		cA = vec3(0.55, 0.82, 0.90); cB = vec3(0.35, 0.62, 0.85); cC = vec3(0.62, 0.88, 0.92);
		bfreq = 3.0; contrast = 0.45; stretch = 3.5;
	}

	// Differential rotation: each latitude drifts at its own speed. Two phases,
	// cross-faded, so the shear resets invisibly instead of stretching forever.
	float flow_t = t * gas_flow_speed;
	float f1 = fract(flow_t / 20.0);
	float f2 = fract(flow_t / 20.0 + 0.5);
	float wA = 1.0 - abs(2.0 * f1 - 1.0);
	float jet = sin(sp.y * bfreq * PI) + 0.4 * sin(sp.y * bfreq * 2.3 * PI + 1.3);
	float turb = 0.0;
	for (int k = 0; k < 2; k++) {
		float fk = (k == 0) ? f1 : f2;
		float wk = (k == 0) ? wA : (1.0 - wA);
		vec3 r = rotY(sp, jet * fk * 0.6);
		float tn = fbm(vec3(r.x, r.y * stretch, r.z) * 2.2 + so, oct);
		turb += wk * tn;
	}

	float lat_w = sp.y + (turb - 0.5) * 0.30 * gas_turbulence;
	float bv = 0.5 + 0.5 * sin(lat_w * bfreq * PI + hash11(seed) * 6.0);
	bv = clamp(mix(0.5, bv, contrast) + (turb - 0.5) * 0.35 * gas_turbulence, 0.0, 1.0);
	albedo = mix(mix(cA, cB, smoothstep(0.0, 0.5, bv)), cC, smoothstep(0.5, 1.0, bv));
	density = turb;

	if (mode != 1 && storm > 0.03) {
		vec3 spot_col = (mode == 2) ? vec3(0.08, 0.18, 0.4) : gas_spot_color.rgb;
		for (int i = 0; i < 2; i++) {
			vec3 h = hash31(seed * 1.7 + float(i) * 13.0 + 2.0);
			float lat0 = ((i == 0) ? -1.0 : 1.0) * (0.18 + 0.32 * h.x);
			float lon0 = h.y * TAU;
			vec3 c = vec3(cos(lat0) * cos(lon0), sin(lat0), cos(lat0) * sin(lon0));
			vec3 te = normalize(cross(vec3(0.0, 1.0, 0.0), c));
			vec3 tn2 = cross(c, te);
			float x = dot(sp, te);
			float y = dot(sp, tn2);
			float sz = (i == 0) ? (0.10 + 0.20 * storm) : (0.05 + 0.06 * storm);
			float e = length(vec2(x / (sz * 1.9), y / sz));
			float front = step(0.0, dot(sp, c));
			float m = (1.0 - smoothstep(0.75, 1.0, e)) * front;
			float collar = ((1.0 - smoothstep(1.0, 1.5, e)) - (1.0 - smoothstep(0.75, 1.0, e))) * front;
			float dirn = (i == 0) ? 1.0 : -1.0;
			float sw = 0.5 + 0.5 * sin(atan(y, x) * 2.0 - e * 10.0 + t * 0.6 * dirn);
			vec3 sc = mix(spot_col * 0.7, spot_col * 1.15, sw);
			albedo = mix(albedo, sc, m * 0.9);
			albedo *= 1.0 - collar * 0.25;
			density = mix(density, 0.9, m);
		}
	}
}

// ---------------------------------------------------------------- CLOUDS
// Returns cloud density 0..1. 'stormy' (0..1) marks hurricane / storm areas.
float cloud_density(vec3 spc, float seed, float cover, float storm, int oct, float t, out float stormy) {
	vec3 so = hash31(seed + 11.0) * 70.0;
	vec3 w = vec3(spc.x, spc.y * 1.6, spc.z) * cloud_scale + so;
	float warp = fbm(w * 0.5 + vec3(5.0, 2.0, 8.0), 2);
	float n = fbm(w + warp * 1.3, oct);
	float weather = 0.85 + 0.3 * sin(abs(spc.y) * 9.0 + seed);
	float cv = clamp(cover * weather, 0.0, 1.0);
	float d = smoothstep(1.0 - cv - 0.02, 1.0 - cv + 0.28, n);
	stormy = 0.0;
	if (storm > 0.02) {
		for (int i = 0; i < 3; i++) {
			vec3 h = hash31(seed * 1.31 + float(i) * 7.7 + 0.3);
			float on = step(h.z, storm * 1.3 - float(i) * 0.25);
			if (on > 0.5) {
				float sgn = (h.y > 0.5) ? 1.0 : -1.0;
				float lat0 = sgn * (0.2 + 0.4 * h.x);
				float lon0 = fract(h.y * 13.7) * TAU;
				vec3 c = vec3(cos(lat0) * cos(lon0), sin(lat0), cos(lat0) * sin(lon0));
				float rad = 0.16 + 0.12 * fract(h.x * 7.3) + 0.08 * storm;
				float dd = length(spc - c) / rad;
				if (dd < 1.6) {
					vec3 t1 = normalize(cross(c, vec3(0.0, 1.0, 0.0)));
					vec3 t2 = cross(c, t1);
					float ang = atan(dot(spc, t2), dot(spc, t1));
					float arm = 0.5 + 0.5 * sin(ang * 2.0 * sgn + dd * 8.0 - t * hurricane_spin);
					float eye = smoothstep(0.07, 0.16, dd);
					float spiral = clamp(arm * 0.85 + 0.25 * n + 0.2, 0.0, 1.0) * eye;
					float m = 1.0 - smoothstep(0.55, 1.5, dd);
					d = mix(d, max(spiral, d * 0.5), m);
					stormy = max(stormy, m * eye);
				}
			}
		}
	}
	stormy = max(stormy, d * storm * 0.6);
	return d;
}

float lightning_flash(vec3 p, float seed, float t, float amount) {
	vec3 g = p * 14.0;
	vec3 c = floor(g);
	vec3 h = hash33(c + seed * 0.37);
	vec3 f = fract(g);
	float d = length(f - (0.25 + 0.5 * h));
	float period = 2.5 + 7.0 * h.z;
	float ph = fract((t + h.x * 40.0) / period);
	float flash = exp(-ph * 22.0) * (0.55 + 0.45 * sin(ph * 140.0));
	float on = step(h.y, amount);
	return clamp(flash, 0.0, 1.0) * on * (1.0 - smoothstep(0.05, 0.38, d));
}

// ---------------------------------------------------------------- CIVILIZATION / LIFE
void city_masks(vec3 sp, float seed, float civ, out float fill, out float outline, out float lights) {
	vec3 co = hash31(seed + 21.0) * 80.0;
	float f = fbm(sp * city_scale + co, 3);
	float amt = clamp(civ * (0.4 + 1.2 * city_density), 0.0, 1.0);
	float thr = mix(0.86, 0.42, amt);
	fill = smoothstep(thr, thr + 0.05, f);
	outline = smoothstep(thr - 0.005, thr + 0.02, f) * (1.0 - smoothstep(thr + 0.03, thr + 0.07, f));

	float dots = smoothstep(0.55, 0.78, vnoise(sp * city_detail + co.yzx));
	dots = max(dots, smoothstep(0.60, 0.85, vnoise(sp * city_detail * 2.3 + co.zxy)) * 0.7);

	float nl = max(floor(city_grid_lines + 0.5), 1.0);
	float u = atan(sp.z, sp.x) / TAU * nl;
	float v = asin(clamp(sp.y, -1.0, 1.0)) / PI * nl;
	float gl = max(smoothstep(0.82, 1.0, abs(fract(u) * 2.0 - 1.0)), smoothstep(0.82, 1.0, abs(fract(v) * 2.0 - 1.0)));
	gl *= 1.0 - smoothstep(0.7, 0.95, abs(sp.y));
	lights = mix(dots, max(dots * 0.4, gl * 0.9), tech_level);
}

// Drifting herds + Conway-ish generations of little moving specks.
float life_dots(vec3 sp, float seed, float presence, float t) {
	vec3 hs = hash31(seed + 31.0) * 40.0;
	vec3 wander = vec3(sin(t * 0.07), cos(t * 0.05), sin(t * 0.031 + 1.0)) * 0.9;
	float herd = fbm(sp * 3.0 + hs + wander, 2);
	float pres = presence * smoothstep(0.50, 0.68, herd);
	vec3 g = sp * life_grid;
	vec3 cell = floor(g);
	vec3 f = fract(g);
	vec3 h3 = hash33(cell);
	float st = t * life_speed;
	vec3 mv = 0.5 + 0.27 * vec3(
			sin(st * (0.6 + h3.x) + h3.y * 6.283),
			sin(st * (0.6 + h3.y) + h3.z * 6.283),
			sin(st * (0.6 + h3.z) + h3.x * 6.283));
	float d = length(f - mv);
	float gt = t * life_generation_rate;
	float g0 = floor(gt);
	float a0 = step(hash13(cell + g0 * 1.37), pres);
	float a1 = step(hash13(cell + (g0 + 1.0) * 1.37), pres);
	float alive = mix(a0, a1, smoothstep(0.75, 1.0, fract(gt)));
	return alive * (1.0 - smoothstep(life_dot_size * 0.5, life_dot_size, d));
}

// ---------------------------------------------------------------- FRAGMENT
void fragment() {
	// Derivatives first (must run in uniform control flow).
	vec2 uv = flip_uv_y ? vec2(UV.x, 1.0 - UV.y) : UV;
	float fw_uv = max(fwidth(UV.x), 0.00001);
	vec2 praw = (uv - 0.5) * 2.0;
	float rraw = length(praw) / planet_radius;
	float fw_r = max(fwidth(rraw), 0.00001);
	float t = TIME * time_scale;

	// ---- 1. planet descriptor
	int ptype;
	float seed;
	float sensor;
	float lang;
	vec4 env;
	if (use_instance_data) {
		seed = v_custom.x;
		ptype = int(floor(v_custom.y + 0.5));
		sensor = clamp(v_custom.z, 0.0, 1.0);
		lang = v_custom.w;
		env = clamp(v_inst_color, vec4(0.0), vec4(1.0));
	} else {
		seed = planet_seed;
		ptype = planet_type;
		sensor = sensor_level;
		lang = light_angle_deg;
		env = vec4(temperature, ocean_coverage, atmosphere_density, life_level);
	}
	if (align_light_to_world) {
		lang += degrees(v_rot);
	}
	if (ptype > 7) {
		ptype = pick_type(seed);
	}
	if (randomize_params) {
		env = random_env(ptype, seed);
	}
	if (enforce_type_rules) {
		env = apply_rules(ptype, env);
	}
	float temp = env.x;
	float water = env.y;
	float atmo = env.z;
	float life = env.w;
	bool is_gas = (ptype == 1 || ptype == 5 || ptype == 7);

	// ---- 2. per-planet variation
	vec3 hv = hash31(seed * 0.913 + 3.3);
	float hue = (hv.x - 0.5) * TAU * hue_variation;
	float tilt = equirect_output ? 0.0 : radians(axial_tilt_deg + (hv.y - 0.5) * tilt_variation_deg);
	float spin = t * rotation_speed * (0.6 + 0.8 * hv.z) + hash11(seed * 4.7 + 1.9) * TAU;
	float storm = storm_activity * smoothstep(0.05, 0.5, atmo) * mix(1.0, 0.4 + 1.2 * hash11(seed * 1.9 + 0.7), float(randomize_params));

	// ---- 3. quad -> sphere (with optional pixelation)
	float pix = 0.0;
	if (pixelate_mode == 1) {
		float k = pow(sensor, sensor_curve);
		if (k < 0.995) {
			pix = mix(pixels_min, pixels_max, k);
		}
	} else if (pixelate_mode == 2) {
		pix = fixed_pixels;
	}
	vec2 puv = uv;
	if (pix > 0.0) {
		float g = pix / planet_radius;
		puv = (floor(uv * g) + 0.5) / g;
	}
	vec2 q = ((puv - 0.5) * 2.0) / planet_radius;
	float r = length(q);
	float halo_reach = max(min(atmo_halo_size, 1.0 / planet_radius - 1.0), 0.0);
	float edge = 1.0;
	vec3 n;
	if (equirect_output) {
		// The sky shader's equirect convention: u = 0.5 + atan(x, z) / TAU, v = acos(y) / PI (x right, y up, z out)
		halo_reach = 0.0;
		float lon = (uv.x - 0.5) * TAU;
		float colat = uv.y * PI;
		n = vec3(sin(colat) * sin(lon), cos(colat), sin(colat) * cos(lon));
	} else {
		if (r > 1.0 + halo_reach + 0.05) {
			discard;
		}
		edge = (pix > 0.0) ? step(r, 1.0) : clamp((1.0 - rraw) / fw_r + 0.5, 0.0, 1.0);
		vec2 qd = (r > 1.0) ? q / r : q;
		n = vec3(qd.x, -qd.y, sqrt(max(1.0 - dot(qd, qd), 0.0)));
	}

	float la = radians(lang);
	float lxy = sqrt(max(1.0 - light_facing * light_facing, 0.0));
	vec3 L = equirect_output ? n : vec3(cos(la) * lxy, sin(la) * lxy, light_facing); // (lit everywhere: an albedo map)
	float ndl = dot(n, L);
	vec3 sp = rotY(rotZ(n, -tilt), -spin);
	vec3 Lo = rotY(rotZ(L, -tilt), -spin);

	// ---- 4. level of detail
	float planet_px = planet_radius / fw_uv;
	float detail = auto_lod ? clamp((log2(planet_px) - log2(lod_min_pixels)) / max(log2(lod_full_pixels) - log2(lod_min_pixels), 0.01), 0.0, 1.0) : 1.0;
	float qf = detail * (sensor_gating ? mix(0.35, 1.0, sensor) : 1.0);
	int oct_t = int(mix(2.0, float(terrain_octaves), qf) + 0.5);
	int oct_c = int(mix(2.0, float(cloud_octaves), qf) + 0.5);
	float g_relief = gate(sensor, 0.35, 0.60);
	float g_city = gate(sensor, 0.60, 0.80);
	float g_fire = gate(sensor, 0.75, 0.90);
	float g_life = gate(sensor, 0.85, 1.00) * smoothstep(0.5, 0.9, detail);
	float g_storm = gate(sensor, 0.50, 0.75);
	float g_light = gate(sensor, 0.65, 0.85);
	float g_cloud = gate(sensor, 0.30, 0.50);
	storm *= g_storm;

	// ---- atmosphere colour + halo
	vec3 atmo_col = atmosphere_color.rgb;
	if (ptype == 1) {
		atmo_col = mix(atmo_col, mix(gas_color_a.rgb, gas_color_b.rgb, 0.5), 0.5);
	} else if (ptype == 5) {
		atmo_col = greenhouse_light.rgb;
	} else if (ptype == 7) {
		atmo_col = vec3(0.45, 0.75, 0.95);
	}
	atmo_col = hue_rot(atmo_col, hue);

	float halo_a = 0.0;
	if (halo_reach > 0.001 && atmo > 0.02) {
		float hr = max(r - 1.0, 0.0);
		vec2 dirq = normalize(vec2(q.x, -q.y) + vec2(0.00001));
		float limb_lit = clamp(dot(dirq, L.xy) + 0.30 + 0.45 * max(L.z, 0.0), 0.0, 1.0);
		float prof = exp(-hr / (halo_reach * 0.28)) * (1.0 - smoothstep(0.0, halo_reach, hr));
		halo_a = prof * atmo * atmo_halo_strength * limb_lit * gate(sensor, 0.15, 0.40);
	}

	vec3 disc = vec3(0.0);
	if (edge > 0.0) {
		// ---- 5. surface
		vec3 albedo = vec3(0.5);
		vec3 emis = vec3(0.0);
		float ocean = 0.0;
		float veg = 0.0;
		float ice = 0.0;
		float hab = 0.0;
		float bump = 0.0;
		float gas_density = 0.0;
		if (is_gas) {
			int mode = (ptype == 1) ? 0 : ((ptype == 5) ? 1 : 2);
			gas_surface(sp, seed, mode, storm, oct_t, t, albedo, gas_density);
		} else {
			rocky_surface(sp, Lo, seed, ptype, env, oct_t, g_relief, t, albedo, emis, ocean, veg, ice, hab, bump);
		}
		albedo = hue_rot(albedo, hue);

		// ---- 6. clouds (density first: they also veil city lights and fires)
		float cloud_a = 0.0;
		float stormy = 0.0;
		float cang = t * cloud_wind;
		vec3 spc = rotY(sp, cang);
		float cover = clamp(cloud_coverage * (0.35 + 0.9 * atmo) * (0.6 + 0.6 * water), 0.0, 1.0);
		if (!is_gas && atmo > 0.03 && cloud_opacity > 0.001 && g_cloud > 0.001) {
			cloud_a = cloud_density(spc, seed, cover, storm, oct_c, t, stormy) * cloud_opacity * g_cloud;
		}

		// ---- 7. civilization, fire, life (modify albedo / collect emission)
		float civ = smoothstep(0.55, 1.0, life);
		float c_fill = 0.0;
		float c_outline = 0.0;
		float c_lights = 0.0;
		if (!is_gas && civ > 0.01 && hab > 0.02 && g_city > 0.001) {
			city_masks(sp, seed, civ, c_fill, c_outline, c_lights);
			c_fill *= hab;
			c_outline *= hab;
			albedo = mix(albedo, city_day_color.rgb, c_fill * city_daytime_visibility * g_city);
		}

		float fire = 0.0;
		if (!is_gas && wildfire_activity > 0.01 && veg > 0.05 && g_fire > 0.001) {
			vec3 fo = hash31(seed + 51.0) * 60.0;
			float fn = fbm(sp * fire_scale + fo + vec3(0.0, t * 0.01, t * 0.008), 3);
			float ft = 0.80 - 0.22 * wildfire_activity;
			fire = smoothstep(ft, ft + 0.05, fn) * veg * g_fire;
			float scar = smoothstep(ft - 0.06, ft, fn) * veg * g_fire;
			albedo *= 1.0 - 0.45 * scar;
			fire *= 0.6 + 0.4 * vnoise(sp * 140.0 + vec3(t * 2.0, 0.0, 0.0));
		}

		if (!is_gas && life > 0.05 && veg > 0.3 && g_life > 0.001) {
			float ld = life_dots(sp, seed, veg * clamp(life * 1.6, 0.0, 1.0) * (1.0 - civ * 0.5), t);
			albedo = mix(albedo, life_dot_color.rgb, ld * life_dot_opacity * g_life);
		}

		// ---- 8. lighting
		float wrap = 0.04 + 0.22 * atmo;
		float diff = clamp((ndl + bump * 0.05 + wrap) / (1.0 + wrap), 0.0, 1.0);
		float night = 1.0 - smoothstep(-0.10, 0.20, ndl);
		vec3 col = albedo * (sun_color.rgb * diff + vec3(ambient_light));

		// ocean glint with moving ripples
		if (!equirect_output && ocean > 0.01 && water_glint > 0.001 && ndl > 0.0) {
			vec3 wp = sp * 28.0;
			vec3 nw = normalize(n + (vec3(
					vnoise(wp + vec3(0.0, t * 0.4, t * 0.3)),
					vnoise(wp + vec3(t * 0.35, 5.2, 1.3)),
					0.5) - 0.5) * 0.12 * detail);
			vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));
			float spec = pow(max(dot(nw, H), 0.0), 70.0) * 0.8;
			col += sun_color.rgb * spec * ocean * (1.0 - ice) * water_glint * (1.0 - cloud_a);
		}

		// cloud shadows on the ground
		if (cloud_a > 0.01 && cloud_shadows > 0.001 && ndl > 0.0 && !is_gas) {
			vec3 Lc = rotY(Lo, cang);
			vec3 tl = Lc - spc * dot(Lc, spc);
			float tlen = length(tl);
			if (tlen > 0.0001) {
				float dummy;
				float sh = cloud_density(normalize(spc + tl / tlen * 0.05), seed, cover, 0.0, 3, t, dummy);
				col *= 1.0 - sh * cloud_shadows * 0.55 * g_cloud;
			}
		}

		// ---- 9. emissives (lava, greenhouse glow, cities, fires)
		float veil = 1.0 - cloud_a * 0.85;
		col += emis * veil;
		if (ptype == 5) {
			col += lava_color.rgb * 0.30 * (1.0 - smoothstep(0.35, 0.65, gas_density)) * (1.0 - diff);
		}
		if (c_fill > 0.001 || c_outline > 0.001) {
			float lit = c_fill * c_lights * city_glow + c_outline * city_outline;
			col += city_color.rgb * lit * night * g_city * veil;
		}
		if (fire > 0.001) {
			col += fire_color.rgb * fire * 1.8 * (0.35 + 0.65 * night) * veil;
		}

		// ---- 10. cloud composite + lightning
		if (cloud_a > 0.001) {
			vec3 ccol = (ptype == 6) ? vec3(0.28, 0.22, 0.20) : cloud_color.rgb;
			float cdiff = clamp((ndl + wrap) / (1.0 + wrap), 0.0, 1.0);
			vec3 cloud_lit = ccol * (sun_color.rgb * cdiff + vec3(ambient_light)) * (1.0 - stormy * 0.35 - cloud_a * 0.08);
			col = mix(col, cloud_lit, cloud_a);
			if (lightning_activity > 0.01 && stormy > 0.05 && g_light > 0.001) {
				float lf = lightning_flash(spc, seed, t, stormy * lightning_activity);
				col += lightning_color.rgb * lf * cloud_a * (0.25 + 0.75 * night) * g_light * 2.0;
			}
		}
		if (ptype == 1 && lightning_activity > 0.01 && g_light > 0.001) {
			float gs = smoothstep(0.55, 0.75, gas_density) * storm;
			if (gs > 0.02) {
				col += lightning_color.rgb * lightning_flash(sp, seed, t, gs * lightning_activity) * night * g_light * 1.5;
			}
		}

		// ---- 11. atmosphere rim + twilight
		float rim = pow(1.0 - n.z, atmo_rim_power);
		float sunf = smoothstep(-0.30, 0.55, ndl);
		float ag = equirect_output ? 0.0 : gate(sensor, 0.15, 0.40);
		col += atmo_col * rim * atmo * atmo_rim_strength * (0.15 + 0.85 * sunf) * ag;
		float tw = exp(-abs(ndl) * 9.0) * pow(1.0 - n.z, 1.5);
		col += twilight_color.rgb * tw * atmo * 0.6 * ag;

		// ---- 12. sensor look
		if (sensor_gating) {
			float unk = 1.0 - smoothstep(0.0, 0.22, sensor);
			col = mix(col, unknown_color.rgb * (0.12 + 0.88 * diff), unk);
			float lum = dot(col, vec3(0.299, 0.587, 0.114));
			col = mix(vec3(lum), col, mix(0.4, 1.0, smoothstep(0.1, 0.6, sensor)));
		}
		float lo = 1.0 - sensor;
		if (sensor_posterize && sensor < 0.98) {
			float lv = mix(4.0, 48.0, sensor);
			col = floor(col * lv + 0.5) / lv;
		}
		if (sensor_noise > 0.001 && lo > 0.001) {
			float nz = hash13(vec3(floor(uv * 140.0), floor(TIME * 12.0))) - 0.5;
			col += nz * sensor_noise * lo * lo * 0.35;
		}
		if (sensor_scanlines > 0.001 && lo > 0.001) {
			col *= 1.0 - sensor_scanlines * lo * 0.4 * (0.5 + 0.5 * sin(praw.y * 160.0 + TIME * 3.0));
		}
		disc = col;
	}

	// ---- 13. composite disc + halo
	float a = edge + halo_a * (1.0 - edge);
	vec3 rgb = (disc * edge + atmo_col * halo_a * (1.0 - edge)) / max(a, 0.0001);
	COLOR = vec4(rgb * exposure, a);
}
