#pragma once

// Particles live in a box that wraps around the emitter (placed at the camera every frame), so the
// field is always full wherever the camera goes and nothing respawns in view: a particle leaving one
// face re-enters at the opposite one, where the draw shader has faded it to nothing.
// mode: 0 motes (pollen / dust / ice crystals), 1 fireflies, 2 snow, 3 rain, 4 falling leaves, 5 blowing dust
static const char *EDEN_AMBIENCE_PROCESS_SHADER = R"(
shader_type particles;
render_mode disable_force, disable_velocity;

uniform int mode = 0;
uniform vec3 extent = vec3(12.0);
uniform vec3 planet_center;
uniform float ground_radius = 0.0;
uniform vec2 height_band = vec2(-1e9, 1e9);
uniform vec3 wind = vec3(0.0);
uniform float fall_speed = 0.0;

float hash(uint x) {
	x ^= x >> 16u; x *= 0x7feb352du; x ^= x >> 15u; x *= 0x846ca68bu; x ^= x >> 16u;
	return float(x) / 4294967295.0;
}

void start() {
	uint s = NUMBER * 747796405u + RANDOM_SEED;
	if (RESTART_POSITION) {
		vec3 r = vec3(hash(s), hash(s + 1u), hash(s + 2u)) * 2.0 - 1.0;
		TRANSFORM = mat4(1.0);
		TRANSFORM[3].xyz = EMISSION_TRANSFORM[3].xyz + r * extent;
	}
	VELOCITY = vec3(0.0);
	// x: phase, y: age 0..1, z: size / colour jitter, w: speed jitter
	CUSTOM = vec4(hash(s + 3u), 0.0, hash(s + 4u), hash(s + 5u));
}

void process() {
	vec3 cam = EMISSION_TRANSFORM[3].xyz;
	vec3 p = TRANSFORM[3].xyz;
	vec3 up = normalize(cam - planet_center);
	float ph = CUSTOM.x * 6.2831;
	vec3 turb = vec3(sin(TIME * 0.71 + ph + p.y * 0.21), sin(TIME * 0.53 + ph * 1.7 + p.z * 0.17), sin(TIME * 0.62 + ph * 2.3 + p.x * 0.19));
	vec3 vel;
	if (mode == 0) {
		vel = wind * 0.25 + turb * 0.12;
	} else if (mode == 1) {
		vel = turb * (0.15 + CUSTOM.w * 0.2); // a slow drift
	} else if (mode == 2) {
		vel = -up * fall_speed * (0.7 + 0.6 * CUSTOM.w) + wind * 0.8 + turb * 0.35;
	} else if (mode == 3) {
		vel = -up * fall_speed * (0.85 + 0.3 * CUSTOM.w) + wind;
	} else if (mode == 4) {
		// Leaves: slow, swinging descent carried by the wind
		vel = -up * fall_speed * (0.6 + 0.8 * CUSTOM.w) + wind * 1.1 + turb * 0.9;
	} else {
		// Dust: driven hard along the wind, rolling up and down near the ground
		vel = wind * (1.4 + 0.8 * CUSTOM.w) + turb * 0.7 + up * sin(TIME * 0.9 + ph) * 0.4;
	}
	p += vel * DELTA;
	vec3 d = p - cam;
	d = mod(d + extent, 2.0 * extent) - extent;
	p = cam + d;
	// Keep within a height band above the ground under the camera (fireflies and dust hug the ground)
	vec3 rel = p - planet_center;
	float rad = length(rel);
	float h = rad - ground_radius;
	if (h < height_band.x || h > height_band.y) {
		float hn = height_band.x + fract(h * 0.37 + CUSTOM.x) * (height_band.y - height_band.x);
		p = planet_center + rel / rad * (ground_radius + hn);
	}
	TRANSFORM[3].xyz = p;
	VELOCITY = vel;
	CUSTOM.y = fract(CUSTOM.y + DELTA / LIFETIME);
}
)";

static const char *EDEN_AMBIENCE_DRAW_SHADER = R"(
shader_type spatial;
render_mode skip_vertex_transform, unshaded, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled, BLEND;

uniform int mode = 0;
uniform vec4 color : source_color = vec4(1.0);
uniform vec4 color2 : source_color = vec4(1.0); // per-particle colour variation (leaves)
uniform float size = 0.05;
uniform float brightness = 1.0;
// Additive effects are capped below the glow threshold, so they never bloom into blobs
uniform float max_brightness = 1.0;
uniform float forward_scatter = 1.0; // motes: 1 = only visible against the sun, 0 = evenly lit
uniform float twinkle = 0.0; // motes: ice crystals glinting
uniform vec3 extent = vec3(12.0);
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform vec3 planet_center;
uniform float intensity = 1.0;

varying float v_alpha;
varying vec3 v_to_particle;
varying float v_phase;
varying float v_jitter;

void vertex() {
	vec3 center = MODEL_MATRIX[3].xyz;
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 d = center - cam;
	// Fade at the wrap box's faces and right at the lens
	vec3 e = abs(d) / extent;
	float edge = 1.0 - smoothstep(0.7, 1.0, max(e.x, max(e.y, e.z)));
	float near = smoothstep(0.3, 1.2, length(d));
	float life = sin(3.14159 * INSTANCE_CUSTOM.y);
	v_alpha = edge * near * life * intensity;
	v_to_particle = d;
	v_phase = INSTANCE_CUSTOM.x;
	v_jitter = INSTANCE_CUSTOM.z;
	float s = size * (0.6 + 0.8 * INSTANCE_CUSTOM.z);
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 upv = INV_VIEW_MATRIX[1].xyz;
	if (mode == 3) {
		// Rain: a streak along the fall direction, facing the camera
		vec3 fall = normalize(planet_center - center);
		upv = fall;
		right = normalize(cross(fall, normalize(d)));
		VERTEX = center + right * VERTEX.x * s * 0.15 + upv * VERTEX.y * s * 6.0;
	} else if (mode == 4) {
		// Leaves: tumbling, so they flash edge-on and face-on as they fall
		vec3 fwd = INV_VIEW_MATRIX[2].xyz;
		float a = TIME * (1.5 + 2.0 * INSTANCE_CUSTOM.w) + INSTANCE_CUSTOM.x * 6.2831;
		vec3 r2 = right * cos(a) + fwd * sin(a);
		vec3 u2 = upv * cos(a * 0.7) + fwd * sin(a * 0.7);
		VERTEX = center + (r2 * VERTEX.x + u2 * VERTEX.y * 0.6) * s;
	} else {
		VERTEX = center + (right * VERTEX.x + upv * VERTEX.y) * s;
	}
	// VERTEX is now world space
	VERTEX = (VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float r = length(UV - 0.5) * 2.0;
	float a = clamp(1.0 - r, 0.0, 1.0);
	a *= a;
	vec3 c = color.rgb * brightness;
	if (mode == 0) {
		float cos_t = dot(normalize(v_to_particle), sun_direction);
		c *= mix(1.0, 0.1 + 2.0 * pow(max(cos_t, 0.0), 6.0), forward_scatter);
		float glint = pow(0.5 + 0.5 * sin(TIME * 6.0 + v_phase * 60.0), 16.0);
		c *= mix(1.0, 0.15 + 3.0 * glint, twinkle);
		c = min(c, vec3(max_brightness));
	} else if (mode == 1) {
		// Each firefly on its own slow cycle (5-9 s): a ~1.6 s glow that swells and fades, then dark. The phase is the
		// particle's own, so moving or turning the camera doesn't re-time them
		float period = 5.0 + 4.0 * v_jitter;
		float t = fract(TIME / period + v_phase) * period;
		float glow = t < 1.6 ? sin(3.14159 * t / 1.6) : 0.0;
		c *= glow * glow;
		a = pow(clamp(1.0 - r, 0.0, 1.0), 3.0);
	} else if (mode == 3) {
		a = 1.0 - abs(UV.x - 0.5) * 2.0;
		a *= a;
	} else if (mode == 4) {
		// A leaf: hard-edged ellipse with a slight point, colour varying per leaf
		vec2 q = (UV - 0.5) * vec2(2.0, 2.0);
		a = step(length(q * vec2(1.0, 0.8 + 0.4 * abs(q.x))), 0.95);
		c = mix(color.rgb, color2.rgb, v_jitter) * brightness * (0.8 + 0.2 * UV.y);
	} else if (mode == 5) {
		// Dust: soft puffs
		a = pow(clamp(1.0 - r, 0.0, 1.0), 2.5);
	}
	ALBEDO = c;
	ALPHA = a * v_alpha * color.a;
}
)";
