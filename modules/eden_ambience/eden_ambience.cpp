#include "eden_ambience.h"
#include "eden_ambience_shaders.h"

#include "core/config/engine.h"
#include "core/os/os.h"
#include "core/config/project_settings.h"
#include "scene/3d/camera_3d.h"
#include "scene/3d/gpu_particles_3d.h"
#include "scene/3d/light_3d.h"
#include "scene/3d/mesh_instance_3d.h"
#include "scene/audio/audio_stream_player.h"
#include "scene/main/viewport.h"
#include "scene/resources/3d/primitive_meshes.h"
#include "scene/resources/3d/world_3d.h"
#include "scene/resources/environment.h"
#include "scene/resources/image_texture.h"
#include "scene/resources/material.h"
#include "servers/rendering/rendering_server.h"

#ifdef TOOLS_ENABLED
#include "editor/editor_interface.h"
#endif

static inline float _smoothstep(float a, float b, float x) {
	const float t = CLAMP((x - a) / (b - a), 0.0f, 1.0f);
	return t * t * (3.0f - 2.0f * t);
}

EdenAmbience::EdenAmbience() {
	soundscape.instantiate();
}

// ---------------------------------------------------------------------------------------------
// Scene lookup

Node3D *EdenAmbience::_get_planet() const {
	return Object::cast_to<Node3D>(get_node_or_null(planet_path));
}

static Node *_find_class(Node *p_node, const StringName &p_class, int p_depth) {
	if (p_node == nullptr) {
		return nullptr;
	}
	for (int i = 0; i < p_node->get_child_count(); i++) {
		Node *c = p_node->get_child(i);
		if (c->is_class(p_class)) {
			return c;
		}
	}
	if (p_depth > 0) {
		for (int i = 0; i < p_node->get_child_count(); i++) {
			Node *found = _find_class(p_node->get_child(i), p_class, p_depth - 1);
			if (found != nullptr) {
				return found;
			}
		}
	}
	return nullptr;
}

static bool _nearly(const Variant &p_a, const Variant &p_b) {
	if (p_a.get_type() != p_b.get_type()) {
		return false;
	}
	switch (p_a.get_type()) {
		case Variant::FLOAT: {
			const double a = p_a, b = p_b;
			return Math::abs(a - b) <= 0.002 * Math::abs(a) + 1e-7;
		}
		case Variant::VECTOR3: {
			const Vector3 a = p_a, b = p_b;
			return a.distance_to(b) <= 1e-4f * a.length() + 1e-5f;
		}
		case Variant::COLOR: {
			const Color a = p_a, b = p_b;
			return Math::abs(a.r - b.r) < 1e-3f && Math::abs(a.g - b.g) < 1e-3f && Math::abs(a.b - b.b) < 1e-3f && Math::abs(a.a - b.a) < 1e-3f;
		}
		default:
			return p_a == p_b;
	}
}

// Shader parameters are only pushed when they change: each set is a RenderingServer command
static void _push(const Ref<ShaderMaterial> &p_mat, const StringName &p_name, const Variant &p_value) {
	if (p_mat.is_valid() && !_nearly(p_mat->get_shader_parameter(p_name), p_value)) {
		p_mat->set_shader_parameter(p_name, p_value);
	}
}

static Node *_cached(ObjectID &r_id) {
	Node *n = Object::cast_to<Node>(ObjectDB::get_instance(r_id));
	return n != nullptr && n->is_inside_tree() ? n : nullptr;
}

Node *EdenAmbience::_get_clouds() const {
	Node *n = _cached(clouds_cache);
	if (n == nullptr) {
		n = _find_class(_get_planet(), "EdenCloudShell", 0);
		clouds_cache = n ? n->get_instance_id() : ObjectID();
	}
	return n;
}

Node *EdenAmbience::_get_foliage() const {
	Node *n = _cached(foliage_cache);
	if (n == nullptr) {
		Node *planet = _get_planet();
		for (int i = 0; planet && i < planet->get_child_count(); i++) {
			if (planet->get_child(i)->has_method("get_forest_density")) {
				n = planet->get_child(i);
				break;
			}
		}
		foliage_cache = n ? n->get_instance_id() : ObjectID();
	}
	return n;
}

void EdenAmbience::_atmo_set(Node *p_atmo, const StringName &p_name, const Variant &p_value) {
	const Variant *prev = atmo_pushed.getptr(p_name);
	if (prev != nullptr && _nearly(*prev, p_value)) {
		return;
	}
	atmo_pushed[p_name] = p_value;
	p_atmo->set(p_name, p_value);
}

// Looked up by class name so this module doesn't depend on eden_atmosphere
Node *EdenAmbience::_get_atmosphere() const {
	if (!atmosphere_path.is_empty()) {
		return get_node_or_null(atmosphere_path);
	}
	if (Node *cached = _cached(atmo_cache)) {
		return cached;
	}
	Node *planet = _get_planet();
	Node *found = _find_class(planet, "EdenPlanetAtmosphere", 0);
	if (found == nullptr && planet != nullptr) {
		found = _find_class(planet->get_parent(), "EdenPlanetAtmosphere", 1);
	}
	atmo_cache = found ? found->get_instance_id() : ObjectID();
	return found;
}

bool EdenAmbience::_get_camera(Vector3 &r_pos, Basis *r_basis) const {
#ifdef TOOLS_ENABLED
	// Not playing: follow the editor's own 3D view camera
	if (Engine::get_singleton()->is_editor_hint()) {
		EditorInterface *ei = EditorInterface::get_singleton();
		SubViewport *vp = ei ? ei->get_editor_viewport_3d(0) : nullptr;
		Camera3D *cam = vp ? vp->get_camera_3d() : nullptr;
		if (cam != nullptr) {
			r_pos = cam->get_global_position();
			if (r_basis) {
				*r_basis = cam->get_global_basis();
			}
			return true;
		}
	}
#endif
	Viewport *vp = get_viewport();
	Camera3D *cam = vp ? vp->get_camera_3d() : nullptr;
	if (cam == nullptr) {
		return false;
	}
	r_pos = cam->get_global_position();
	if (r_basis) {
		*r_basis = cam->get_global_basis();
	}
	return true;
}

DirectionalLight3D *EdenAmbience::_find_sun(Node *p_atmosphere) const {
	if (p_atmosphere == nullptr) {
		return nullptr;
	}
	const NodePath path = p_atmosphere->get("sun_light_path");
	if (!path.is_empty()) {
		return Object::cast_to<DirectionalLight3D>(p_atmosphere->get_node_or_null(path));
	}
	// The atmosphere's auto-created sun is an internal child
	for (int i = 0; i < p_atmosphere->get_child_count(true); i++) {
		Node *c = p_atmosphere->get_child(i, true);
		if (c->get_name() == StringName("Sun")) {
			return Object::cast_to<DirectionalLight3D>(c);
		}
	}
	return nullptr;
}

// ---------------------------------------------------------------------------------------------

void EdenAmbience::_build() {
	process_shader.instantiate();
	process_shader->set_code(EDEN_AMBIENCE_PROCESS_SHADER);
	const String draw_code = EDEN_AMBIENCE_DRAW_SHADER;
	Ref<Shader> draw_add, draw_mix;
	draw_add.instantiate();
	draw_add->set_code(draw_code.replace("BLEND", "blend_add"));
	draw_mix.instantiate();
	draw_mix->set_code(draw_code.replace("BLEND", "blend_mix"));

	Ref<QuadMesh> quad;
	quad.instantiate();
	quad->set_size(Size2(1, 1));

	struct Spec {
		const char *name;
		int amount;
		float extent, lifetime, size, brightness, fall;
		Color color;
		bool additive;
		Vector2 band;
	};
	const Spec specs[FX_MAX] = {
		{ "Motes", 900, 9.0f, 12.0f, 0.04f, 3.0f, 0.0f, Color(1.0f, 0.92f, 0.75f, 1.0f), true, Vector2(-1e9f, 1e9f) },
		{ "Fireflies", 45, 18.0f, 30.0f, 0.14f, 7.0f, 0.0f, Color(0.95f, 0.9f, 0.35f, 1.0f), true, Vector2(0.3f, 3.5f) },
		{ "Snow", 3000, 13.0f, 20.0f, 0.09f, 1.0f, 1.1f, Color(0.95f, 0.97f, 1.0f, 0.9f), false, Vector2(-1e9f, 1e9f) },
		{ "Rain", 3500, 13.0f, 4.0f, 0.14f, 1.4f, 9.0f, Color(0.78f, 0.82f, 0.9f, 0.55f), false, Vector2(-1e9f, 1e9f) },
		{ "Leaves", 900, 14.0f, 14.0f, 0.18f, 1.0f, 1.0f, Color(0.36f, 0.5f, 0.16f, 1.0f), false, Vector2(-1e9f, 1e9f) },
		{ "Dust", 700, 16.0f, 6.0f, 1.6f, 1.0f, 0.0f, Color(0.78f, 0.65f, 0.45f, 0.35f), false, Vector2(0.0f, 5.0f) },
	};

	for (int i = 0; i < FX_MAX; i++) {
		const Spec &s = specs[i];
		const Vector3 ext(s.extent, s.extent, s.extent);

		Ref<ShaderMaterial> pm;
		pm.instantiate();
		pm->set_shader(process_shader);
		pm->set_shader_parameter("mode", i);
		pm->set_shader_parameter("extent", ext);
		pm->set_shader_parameter("height_band", s.band);
		pm->set_shader_parameter("fall_speed", s.fall);
		fx_process[i] = pm;

		Ref<ShaderMaterial> dm;
		dm.instantiate();
		dm->set_shader(s.additive ? draw_add : draw_mix);
		dm->set_shader_parameter("mode", i);
		dm->set_shader_parameter("extent", ext);
		dm->set_shader_parameter("color", s.color);
		dm->set_shader_parameter("size", s.size);
		dm->set_shader_parameter("brightness", s.brightness);
		fx_draw[i] = dm;

		GPUParticles3D *p = memnew(GPUParticles3D);
		p->set_name(s.name);
		p->set_as_top_level(true);
		p->set_amount(s.amount);
		p->set_lifetime(s.lifetime);
		p->set_pre_process_time(s.lifetime * 0.5);
		p->set_fixed_fps(0);
		p->set_use_local_coordinates(false);
		p->set_visibility_aabb(AABB(-ext * 1.5f, ext * 3.0f));
		p->set_process_material(pm);
		p->set_draw_pass_mesh(0, quad);
		p->set_material_override(dm);
		p->set_cast_shadows_setting(GeometryInstance3D::SHADOW_CASTING_SETTING_OFF);
		p->set_emitting(false);
		add_child(p, false, INTERNAL_MODE_BACK);
		fx[i] = p;
	}

	player = memnew(AudioStreamPlayer);
	player->set_name("Soundscape");
	player->set_stream(soundscape);
	add_child(player, false, INTERNAL_MODE_BACK);

	for (int i = 0; i < SURF_EMITTERS + LEAF_EMITTERS; i++) {
		const bool surf = i < SURF_EMITTERS;
		Emitter &e = surf ? surf_emitters[i] : leaf_emitters[i - SURF_EMITTERS];
		e.layer = surf ? AudioStreamEdenAmbience::LAYER_SURF : AudioStreamEdenAmbience::LAYER_LEAVES;
		e.stream.instantiate();
		AudioStreamPlayer *p = memnew(AudioStreamPlayer);
		p->set_name(surf ? "Surf" : "Leaves");
		p->set_stream(e.stream);
		add_child(p, false, INTERNAL_MODE_BACK);
		e.player = p;
	}
}

// Samples the terrain on rings around the camera: surf goes where the ground crosses sea level (the nearest
// shoreline along each bearing), rustling where EdenFoliage reports dense forest. Each kind keeps its nearest
// sources, spread over different bearings. Spread over frames (SWEEP_BEARINGS_PER_FRAME bearings each) so it
// never costs a frame spike: done in one go it took ~12 ms in a forest, once a second.
void EdenAmbience::_find_sound_sources(const Vector3 &p_cam) {
	SourceSweep &sw = sweep;
	if (!sw.active) {
		Node3D *planet = _get_planet();
		Object *gen = planet ? (Object *)planet->get("generator") : nullptr;
		if (gen == nullptr || !gen->has_method("sample_surface") || !state.valid) {
			return;
		}
		sw.active = true;
		sw.bearing = 0;
		sw.R = state.planet_radius;
		sw.center = state.center;
		sw.up = (p_cam - state.center).normalized();
		sw.t = sw.up.cross(Math::abs(sw.up.y) < 0.99f ? Vector3(0, 1, 0) : Vector3(1, 0, 0)).normalized();
		sw.b = sw.up.cross(sw.t);
		sw.cam_water = state.ground_height < 0.0f;
		sw.shore.clear();
		sw.forest.clear();
		Node *foliage = _get_foliage();
		sw.forest_here = -1.0f;
		if (foliage != nullptr) {
			sw.forest_here = foliage->call("get_forest_density", sw.center + sw.up * (sw.R + MAX(state.ground_height, 0.0f)));
		}
		return;
	}
	Node3D *planet = _get_planet();
	Object *gen = planet ? (Object *)planet->get("generator") : nullptr;
	if (gen == nullptr) {
		sw.active = false;
		return;
	}
	Node *foliage = _get_foliage();
	static const float radii[] = { 10.0f, 25.0f, 50.0f, 90.0f, 150.0f, 240.0f, 350.0f, 550.0f, 800.0f };
	for (int step = 0; step < SWEEP_BEARINGS_PER_FRAME && sw.bearing < SWEEP_BEARINGS; step++, sw.bearing++) {
		const float az = Math::TAU * sw.bearing / SWEEP_BEARINGS;
		const Vector3 tangent = sw.t * Math::cos(az) + sw.b * Math::sin(az);
		bool prev_water = sw.cam_water;
		float prev_r = 0.0f;
		bool shore_found = false;
		for (float r : radii) {
			const bool want_shore = !shore_found && r <= surf_range * 1.6f;
			const bool want_forest = foliage != nullptr && r <= forest_sound_range;
			if (!want_shore && !want_forest) {
				break;
			}
			const Vector3 dir = (sw.up + tangent * (r / sw.R)).normalized();
			const Dictionary s = gen->call("sample_surface", dir);
			const float h = s.get("height", 0.0f);
			const bool water = h < 0.0f;
			if (want_shore && water != prev_water) {
				const float mid = (prev_r + r) * 0.5f;
				if (mid <= surf_range) {
					const Vector3 sdir = (sw.up + tangent * (mid / sw.R)).normalized();
					sw.shore.push_back({ sw.center + sdir * (sw.R + 0.5f), mid, az, 1.0f });
				}
				shore_found = true;
			}
			prev_water = water;
			prev_r = r;
			if (want_forest && !water) {
				const float f = foliage->call("get_forest_density", sw.center + dir * (sw.R + h));
				if (f > 0.15f) {
					sw.forest.push_back({ sw.center + dir * (sw.R + h + 6.0f), r, az, f }); // in the canopy
					if (r <= 25.0f) {
						sw.forest_here = MAX(sw.forest_here, f);
					}
				}
			}
		}
	}
	if (sw.bearing < SWEEP_BEARINGS) {
		return;
	}
	sw.active = false;
	forest_here = sw.forest_here;
	// Nearest first, spread over bearings, then fill the emitters (unused ones fade out where they are)
	auto pick = [](LocalVector<SoundCandidate> &p_cands, Emitter *p_emitters, int p_count, float p_min_sep) {
		// Selection sort by distance with a bearing-separation check (candidate lists are small)
		LocalVector<SoundCandidate> chosen;
		LocalVector<bool> taken;
		taken.resize(p_cands.size());
		for (uint32_t i = 0; i < taken.size(); i++) {
			taken[i] = false;
		}
		while ((int)chosen.size() < p_count) {
			int best = -1;
			for (uint32_t i = 0; i < p_cands.size(); i++) {
				if (taken[i] || (best >= 0 && p_cands[i].dist >= p_cands[best].dist)) {
					continue;
				}
				bool clash = false;
				for (const SoundCandidate &c : chosen) {
					clash = clash || Math::abs(Math::angle_difference(p_cands[i].az, c.az)) < p_min_sep;
				}
				if (!clash) {
					best = i;
				}
			}
			if (best < 0) {
				break;
			}
			taken[best] = true;
			chosen.push_back(p_cands[best]);
		}
		// Keep each emitter on the chosen source nearest to where it already is, so they don't jump around
		LocalVector<bool> done;
		done.resize(chosen.size());
		for (uint32_t i = 0; i < done.size(); i++) {
			done[i] = false;
		}
		for (int k = 0; k < p_count; k++) {
			Emitter &e = p_emitters[k];
			int best = -1;
			for (uint32_t i = 0; i < chosen.size(); i++) {
				if (!done[i] && (best < 0 || chosen[i].pos.distance_squared_to(e.target) < chosen[best].pos.distance_squared_to(e.target))) {
					best = i;
				}
			}
			if (best < 0) {
				e.target_level = 0.0f;
				continue;
			}
			done[best] = true;
			e.target = chosen[best].pos;
			e.target_level = chosen[best].strength;
		}
	};
	pick(sw.shore, surf_emitters, SURF_EMITTERS, Math::deg_to_rad(60.0f));
	pick(sw.forest, leaf_emitters, LEAF_EMITTERS, Math::deg_to_rad(50.0f));
}

void EdenAmbience::_update_emitters(double p_delta, bool p_play, float p_wind, const Vector3 &p_cam, const Basis &p_cam_basis) {
	const float ease_level = 1.0f - Math::exp(-(float)p_delta / 1.5f);
	const float ease_pos = 1.0f - Math::exp(-(float)p_delta / 1.0f);
	for (int i = 0; i < SURF_EMITTERS + LEAF_EMITTERS; i++) {
		const bool surf = i < SURF_EMITTERS;
		Emitter &e = surf ? surf_emitters[i] : leaf_emitters[i - SURF_EMITTERS];
		if (e.player == nullptr) {
			continue;
		}
		const float target = spatial_audio ? e.target_level : 0.0f;
		// A silent emitter jumps straight to its new source; an audible one glides there
		e.pos = e.level < 0.02f ? e.target : e.pos.lerp(e.target, ease_pos);
		e.level = Math::lerp(e.level, target, ease_level);
		// Inverse-distance falloff from unit_size (as AudioStreamPlayer3D's default model), a little quieter
		// behind the camera, and balance toward the side the source is on
		const Vector3 rel = e.pos - p_cam;
		const float d = rel.length();
		const float unit = surf ? surf_unit_size : leaves_unit_size;
		const float max_d = surf ? surf_range * 3.0f : forest_sound_range * 3.0f;
		const Vector3 in_view = p_cam_basis.xform_inv(rel); // +x right, -z ahead
		const float behind = d > 1e-3f ? MAX(in_view.z / d, 0.0f) : 0.0f;
		const float att = unit / MAX(unit, d) * (1.0f - _smoothstep(max_d * 0.7f, max_d, d)) * (1.0f - 0.25f * behind);
		e.stream->out_gain.store(att);
		e.stream->out_pan.store(d > 0.5f ? CLAMP(in_view.x / d, -1.0f, 1.0f) * 0.85f : 0.0f);
		if (e.player->get_volume_db() != volume_db) {
			e.player->set_volume_db(volume_db);
		}
		const float gain = surf ? surf_volume : leaves_volume * CLAMP(p_wind / 4.0f, 0.2f, 1.0f);
		e.stream->set_level(e.layer, e.level * gain);
		e.stream->gustiness.store(gustiness);
		const bool play = p_play && e.level > 0.002f;
		if (play && !e.player->is_playing()) {
			e.player->play();
		} else if (!play && e.player->is_playing()) {
			e.player->stop();
		}
	}
}

// Sizes, ranges and fixed colours from the exports (the per-frame, biome-driven ones are set in _update)
void EdenAmbience::_apply_fx_params() {
	fx_dirty = false;
	static const float base_extent[FX_MAX] = { 9.0f, 18.0f, 13.0f, 13.0f, 14.0f, 16.0f };
	const float sizes[FX_MAX] = { motes_size, 0.14f, snowflake_size, rain_streak_size, leaves_size, dust_size };
	for (int i = 0; i < FX_MAX; i++) {
		if (fx[i] == nullptr) {
			continue;
		}
		const float e = base_extent[i] * MAX(particle_range, 0.1f);
		const Vector3 ext(e, e, e);
		fx_process[i]->set_shader_parameter("extent", ext);
		fx_draw[i]->set_shader_parameter("extent", ext);
		fx_draw[i]->set_shader_parameter("size", sizes[i]);
		fx[i]->set_visibility_aabb(AABB(-ext * 1.5f, ext * 3.0f));
	}
	fx_draw[FX_MOTES]->set_shader_parameter("brightness", 3.0f * motes_brightness);
	fx_draw[FX_MOTES]->set_shader_parameter("max_brightness", motes_brightness);
	fx_draw[FX_FIREFLIES]->set_shader_parameter("brightness", fireflies_brightness);
	fx_draw[FX_RAIN]->set_shader_parameter("color", Color(0.78f, 0.82f, 0.9f, rain_opacity));
	fx_draw[FX_DUST]->set_shader_parameter("color", Color(dust_color.r, dust_color.g, dust_color.b, 0.35f));
}

void EdenAmbience::_survey(const Vector3 &p_cam) {
	Node3D *planet = _get_planet();
	Node *atmo = _get_atmosphere();
	if (planet == nullptr) {
		state.valid = false;
		return;
	}
	Object *gen = planet->get("generator");
	state.center = planet->get_global_position();
	float radius = 0.0f;
	if (gen != nullptr) {
		radius = gen->get("planet_radius");
	}
	if (radius <= 0.0f && atmo != nullptr) {
		radius = atmo->get("planet_radius");
	}
	if (radius <= 0.0f) {
		state.valid = false;
		return;
	}
	state.planet_radius = radius;

	const Vector3 rel = p_cam - state.center;
	const float r = rel.length();
	const Vector3 up = r > 1e-3f ? rel / r : Vector3(0, 1, 0);
	state.ground_height = 0.0f;
	state.water = 0.0f;
	if (gen != nullptr && gen->has_method("sample_surface")) {
		const Dictionary s = gen->call("sample_surface", up);
		state.ground_height = s.get("height", 0.0f);
		temperature_mean = s.get("temperature", 0.5f);
		moisture_mean = s.get("moisture", 0.5f);
		// Sea nearby: sample two rings around the camera
		const Vector3 t = up.cross(Math::abs(up.y) < 0.99f ? Vector3(0, 1, 0) : Vector3(1, 0, 0)).normalized();
		const Vector3 b = up.cross(t);
		int wet = state.ground_height < 0.0f ? 2 : 0;
		const int n = 8;
		for (int ring = 0; ring < 2; ring++) {
			const float d = (ring == 0 ? 150.0f : 450.0f) / radius;
			for (int k = 0; k < n; k++) {
				const float a = Math::TAU * (k + 0.5f * ring) / n;
				const Vector3 dir = (up + (t * Math::cos(a) + b * Math::sin(a)) * d).normalized();
				const Dictionary sk = gen->call("sample_surface", dir);
				wet += (float)sk.get("height", 1.0f) < 0.0f ? 1 : 0;
			}
		}
		state.water = MIN(1.0f, wet / (float)n);
	}
	state.altitude = r - (radius + MAX(state.ground_height, 0.0f));

	state.day = 1.0f;
	state.night = 0.0f;
	if (atmo != nullptr && atmo->has_method("get_sun_direction")) {
		const Vector3 sun = atmo->call("get_sun_direction");
		const float elev = sun.dot(up);
		state.sun_elevation = elev;
		state.day = _smoothstep(-0.03f, 0.12f, elev);
		state.night = 1.0f - _smoothstep(-0.12f, 0.0f, elev);
	}
	state.valid = true;

	// Sun shadows: the atmosphere may create its light after us, so checked on every survey
	DirectionalLight3D *sun = _find_sun(atmo);
	if (sun != nullptr && look_enabled) {
		if (sun->has_shadow() != sun_shadows) {
			sun->set_shadow(sun_shadows);
		}
		const DirectionalLight3D::ShadowMode mode = DirectionalLight3D::ShadowMode(CLAMP(shadow_cascades, 0, 2));
		if (sun_shadows && (sun->get_param(Light3D::PARAM_SHADOW_MAX_DISTANCE) != shadow_distance || sun->get_shadow_mode() != mode)) {
			sun->set_param(Light3D::PARAM_SHADOW_MAX_DISTANCE, shadow_distance);
			sun->set_shadow_mode(mode);
			sun->set_blend_splits(mode != DirectionalLight3D::SHADOW_ORTHOGONAL);
			sun->set_param(Light3D::PARAM_SHADOW_FADE_START, 0.85f);
		}
		const float opacity = 1.0f - storm_shadow_fade * (weather_enabled ? MAX(local.cloud, local.dust) : 0.0f);
		if (Math::abs(sun->get_param(Light3D::PARAM_SHADOW_OPACITY) - opacity) > 0.01f) {
			sun->set_param(Light3D::PARAM_SHADOW_OPACITY, opacity);
		}
	}
}

void EdenAmbience::_apply_look() {
	if (!look_enabled || !is_inside_tree()) {
		return;
	}
	Ref<World3D> world = get_world_3d();
	if (world.is_null()) {
		return;
	}
	Ref<Environment> env = world->get_environment();
	if (env.is_null()) {
		return;
	}
	if (env->get_instance_id() != look_env) {
		look_env = env->get_instance_id();
		look_dirty = true;
	}
	if (look_dirty) {
		look_dirty = false;
		applied_exposure = -1.0f;
		if (tonemapper > 0) {
			env->set_tonemapper(Environment::ToneMapper(tonemapper - 1));
		}
		env->set_tonemap_white(white);
		env->set_adjustment_contrast(contrast);
		env->set_ssao_enabled(ssao_enabled);
		env->set_ssao_intensity(ssao_intensity);
		env->set_ssao_radius(ssao_radius);
		Node *atmo = _get_atmosphere();
		if (atmo == nullptr || !(bool)atmo->get("manage_glow")) {
			env->set_glow_enabled(glow_enabled);
			env->set_glow_intensity(glow_intensity);
			env->set_glow_hdr_bleed_threshold(glow_threshold);
			env->set_glow_blend_mode(Environment::GLOW_BLEND_MODE_ADDITIVE);
		}
	}
	// How much of the sky's light fills the shadows: at full strength it lifts every face equally and flattens the
	// sun-lit vs shaded facets of the low-poly terrain (the atmosphere sets it back to 1 when it configures)
	if (Math::abs(env->get_ambient_light_sky_contribution() - ambient_strength) > 1e-3f) {
		env->set_ambient_light_sky_contribution(ambient_strength);
	}
	// Night light: the dark sky itself lights nothing, so starlight (always) and moonlight (by the moon's phase
	// and height) fill the ambient's colour half instead -- enough to make out the ground -- dimmed by cloud
	const float overcast = weather_enabled ? local.cloud : 0.0f;
	{
		float moon = 0.0f;
		Vector3 cam;
		Node *atmo = _get_atmosphere();
		if (atmo != nullptr && state.valid && _get_camera(cam)) {
			const Vector3 up = (cam - state.center).normalized();
			const Vector3 md = atmo->get("moon_direction");
			const float illum = atmo->call("get_moon_illumination");
			const float opacity = atmo->get("moon_opacity"); // 0 = no moon (SkySystem hides absent moons)
			moon = Math::pow(CLAMP(illum, 0.0f, 1.0f), 1.5f) * _smoothstep(-0.05f, 0.2f, md.normalized().dot(up)) * CLAMP(opacity, 0.0f, 1.0f);
		}
		const float night_energy = state.night * (starlight + moonlight * moon) * (1.0f - 0.85f * overcast);
		if (Math::abs(env->get_ambient_light_energy() - night_energy) > 1e-3f || env->get_ambient_light_color() != night_ambient_color) {
			env->set_ambient_light_color(night_ambient_color);
			env->set_ambient_light_energy(night_energy);
		}
	}
	// Overcast skies are darker and greyer; lightning flashes the whole frame
	const float exp_now = exposure * (1.0f - storm_exposure_drop * overcast) * (1.0f + lightning_brightness * flash);
	const float sat_now = saturation * (1.0f - storm_desaturation * overcast);
	if (Math::abs(exp_now - applied_exposure) > 1e-3f || Math::abs(sat_now - applied_saturation) > 1e-3f) {
		applied_exposure = exp_now;
		applied_saturation = sat_now;
		env->set_tonemap_exposure(exp_now);
		env->set_adjustment_enabled(contrast != 1.0f || sat_now != 1.0f);
		env->set_adjustment_saturation(sat_now);
	}
}

void EdenAmbience::_update_weather(double p_delta, const Vector3 &p_cam, const Vector3 &p_sun) {
	RenderingServer *rs = RenderingServer::get_singleton();
	if (!weather_enabled || !state.valid) {
		local = EdenWeatherSim::Sample();
		local_snow = local_wet = local_freezing = 0.0f;
		rs->global_shader_parameter_set("eden_weather_planet", Vector4(0, 0, 0, 0));
		return;
	}
	EdenWeatherSim::Params &wp = weather.params;
	if ((uint32_t)weather_seed != wp.seed) {
		wp.seed = weather_seed;
		weather.natural = -1; // reseed
	}
	wp.cell_count = weather_external ? 0 : storm_count;
	wp.wind_speed = storm_speed;
	wp.min_radius = storm_min_radius;
	wp.max_radius = MAX(storm_max_radius, storm_min_radius);
	wp.freeze_temperature = freeze_temperature;
	wp.year_phase = year_phase;
	wp.season_strength = season_strength;
	wp.wet_season_strength = wet_season_strength;
	wp.snow_rate = snow_rate;
	wp.melt_rate = melt_rate;
	wp.wet_rate = wet_rate;
	wp.dry_rate = dry_rate;
	wp.humidity_bias = storm_humidity_bias;
	wp.thunder_chance = thunder_chance;
	wp.dust_chance = dust_storm_chance;
	weather.planet_radius = state.planet_radius;
	if (!weather_started) {
		weather_started = true;
		Node3D *planet = _get_planet();
		weather.start_climate(planet ? (Object *)planet->get("generator") : nullptr);
	}

	const Vector3 up = (p_cam - state.center).normalized();
	_update_override((float)p_delta, up);
	const float wdt = (float)p_delta * weather_time_scale;
	weather.step(wdt);
	weather_accum += wdt;
	weather_timer -= (float)p_delta;
	// The map is rebuilt on a worker (every 0.5 s: storms move ~4 m in that time, a texel is ~550 m)
	if (weather_timer <= 0.0f && !weather.is_integrating()) {
		weather_timer = 0.5f;
		weather.integrate_async(weather_accum, p_sun);
		weather_accum = 0.0f;
	}
	if (weather.poll_integrate()) {
		const bool first = weather_texture.is_null();
		if (first) {
			weather_texture = ImageTexture::create_from_image(weather.image);
			rs->global_shader_parameter_set("eden_weather_map", weather_texture->get_rid());
		} else {
			weather_texture->update(weather.image);
		}
		// Shaders skip weather entirely while there is nothing to show: z = snow or wet ground within ~2 km
		// (grass, plants), w = anywhere on the map (terrain)
		float near = MAX(weather.snow_at(up), weather.wetness_at(up));
		const Vector3 t = up.get_any_perpendicular();
		for (int k = 0; k < 8; k++) {
			const Vector3 d = (up + t.rotated(up, Math::TAU * k / 8.0f) * (2000.0f / MAX(state.planet_radius, 1.0f))).normalized();
			near = MAX(near, MAX(weather.snow_at(d), weather.wetness_at(d)));
		}
		const Vector4 planet_v(state.center.x, state.center.y, state.center.z, state.planet_radius);
		const Vector4 params_v(snow_max_depth, wet_darkening, near > 0.01f ? 1.0f : 0.0f, weather.map_activity > 0.01f ? 1.0f : 0.0f);
		const Vector4 snow_v(snow_color.r, snow_color.g, snow_color.b, 1.0f);
		if (first || planet_v != weather_planet_pushed || params_v != weather_params_pushed) {
			weather_planet_pushed = planet_v;
			weather_params_pushed = params_v;
			rs->global_shader_parameter_set("eden_weather_planet", planet_v);
			rs->global_shader_parameter_set("eden_weather_params", params_v);
			rs->global_shader_parameter_set("eden_weather_snow", snow_v);
		}
		Node3D *planet_node = _get_planet();
		Ref<ShaderMaterial> terrain_mat = planet_node ? Ref<ShaderMaterial>(planet_node->get("material")) : Ref<ShaderMaterial>();
		if (terrain_mat.is_valid()) {
			if (terrain_mat->get_shader_parameter("eden_weather_map") != Variant(weather_texture)) {
				terrain_mat->set_shader_parameter("eden_weather_map", weather_texture);
			}
			if (terrain_mat->get_shader_parameter("eden_weather_planet") != Variant(planet_v)) {
				terrain_mat->set_shader_parameter("eden_weather_planet", planet_v);
			}
			if (terrain_mat->get_shader_parameter("eden_weather_params") != Variant(params_v)) {
				terrain_mat->set_shader_parameter("eden_weather_params", params_v);
			}
			if (terrain_mat->get_shader_parameter("eden_weather_snow") != Variant(snow_v)) {
				terrain_mat->set_shader_parameter("eden_weather_snow", snow_v);
			}
		}
		// Storm clouds over the storms (EdenCloudShell's shader reads storm_map; looked up by class name)
		Node *clouds = _get_clouds();
		if (clouds != nullptr) {
			Ref<ShaderMaterial> m = clouds->call("get_material");
			if (m.is_valid() && m->get_shader_parameter("storm_map") != Variant(weather_texture)) {
				m->set_shader_parameter("storm_map", weather_texture);
			}
		}
	}

	local = weather.sample(up);
	if (weather_external) {
		// The zone's cloud cover as asked (a lone cell's own cloud falls short of it)
		local.cloud = MAX(local.cloud, ext_cloud_now);
	}
	local_snow = weather.snow_at(up);
	local_wet = weather.wetness_at(up);
	const float t = state.temperature - 0.04f + 0.08f * MAX(p_sun.dot(up), 0.0f);
	local_freezing = 1.0f - _smoothstep(freeze_temperature - 0.03f, freeze_temperature + 0.03f, t);
	// Forced snow freezes, forced rain thaws, around the camera
	if (ov_mode == WEATHER_SNOW || (weather_external && ext_snow)) {
		local_freezing = Math::lerp(local_freezing, 1.0f, ov_strength);
	} else if (ov_mode == WEATHER_RAIN || ov_mode == WEATHER_THUNDERSTORM) {
		local_freezing = Math::lerp(local_freezing, 0.0f, ov_strength);
	}

	// Clouds: storm cover on the map, plus the local overcast over the camera
	Node *clouds = _get_clouds();
	if (clouds != nullptr) {
		Ref<ShaderMaterial> m = clouds->call("get_material");
		if (m.is_valid()) {
			_push(m, "storm_local", local.cloud);
			_push(m, "storm_local_radius", overcast_radius);
			_push(m, "storm_coverage", storm_cloud_coverage);
			_push(m, "storm_darkening", storm_cloud_darkening);
		}
	}

	// Lightning in thunder cells: strikes around the camera (see _strike: bolt, light, cloud glow, thunder)
	if (lightning_enabled && local.thunder) {
		strike_timer -= (float)p_delta * weather_time_scale * lightning_frequency * (0.5f + local.precipitation);
		if (strike_timer <= 0.0f) {
			strike_timer = Math::random(3.0f, 14.0f);
			Vector3 ground;
			if (_pick_strike_point(ground)) {
				_strike(ground, Math::randf() < intra_cloud_chance);
			}
		}
	}
}

// weather_override: a storm (or a clear zone) that follows the camera. Switching fades the old one out
// before the new one fades in over override_fade.
void EdenAmbience::_update_override(float p_delta, const Vector3 &p_up) {
	if (weather_external) {
		// The game's weather: one storm cell (or a clear zone) riding with the camera. Strength follows the cloud
		// cover, the cell's intensity the precipitation; both ease toward their targets.
		// Linear, so a change is complete (to exactly 0 when the rain stops) after override_fade
		const float k = p_delta / MAX(override_fade, 0.01f);
		const bool any = ext_intensity > 0.0f || ext_cloud > 0.0f;
		const float strength = any ? MAX(ext_cloud, ext_intensity > 0.0f ? 1.0f : 0.0f) : 1.0f;
		ov_strength = Math::move_toward(ov_strength, strength, k);
		ext_intensity_now = Math::move_toward(ext_intensity_now, ext_intensity, k);
		ext_fog_now = Math::move_toward(ext_fog_now, ext_fog, k);
		ext_cloud_now = Math::move_toward(ext_cloud_now, ext_cloud, k);
		ov_mode = WEATHER_AUTO;
		EdenWeatherSim::Override &o = weather.override_zone;
		o.dir = p_up;
		o.radius = override_radius / MAX(state.planet_radius, 1.0f);
		o.strength = ov_strength;
		o.mode = any ? EdenWeatherSim::Override::STORM : EdenWeatherSim::Override::CLEAR;
		o.temperature = ext_intensity > 0.0f && ext_snow ? -1 : 0; // else the climate decides rain or snow
		EdenWeatherSim::Cell &c = o.cell;
		c.dir = p_up;
		c.radius = o.radius;
		c.life = 1e9f;
		c.age = 0.5e9f;
		c.drift = 0.0f;
		c.dust = false;
		c.thunder = ext_thunder;
		c.intensity = ext_intensity_now;
		return;
	}
	ext_fog_now = 0.0f;
	const int target = CLAMP(weather_override, 0, WEATHER_MAX - 1);
	if (target != ov_mode) {
		ov_strength -= p_delta / 0.75f;
		if (ov_strength <= 0.0f) {
			ov_strength = 0.0f;
			ov_mode = target;
		}
	} else if (ov_mode != WEATHER_AUTO) {
		ov_strength = MIN(1.0f, ov_strength + p_delta / MAX(override_fade, 0.01f));
	}
	EdenWeatherSim::Override &o = weather.override_zone;
	o.dir = p_up;
	o.radius = override_radius / MAX(state.planet_radius, 1.0f);
	o.strength = ov_strength;
	o.temperature = 0;
	EdenWeatherSim::Cell &c = o.cell;
	c.dir = p_up;
	c.radius = o.radius;
	c.life = 1e9f;
	c.age = 0.5e9f; // mid-life: full strength
	c.drift = 0.0f;
	c.thunder = false;
	c.dust = false;
	c.intensity = 0.85f;
	switch (ov_mode) {
		case WEATHER_CLEAR:
			o.mode = EdenWeatherSim::Override::CLEAR;
			break;
		case WEATHER_RAIN:
			o.mode = EdenWeatherSim::Override::STORM;
			o.temperature = 1;
			break;
		case WEATHER_THUNDERSTORM:
			o.mode = EdenWeatherSim::Override::STORM;
			o.temperature = 1;
			c.thunder = true;
			c.intensity = 1.0f;
			break;
		case WEATHER_SNOW:
			o.mode = EdenWeatherSim::Override::STORM;
			o.temperature = -1;
			break;
		case WEATHER_DUST_STORM:
			o.mode = EdenWeatherSim::Override::STORM;
			c.dust = true;
			c.intensity = 0.95f;
			break;
		default:
			o.mode = EdenWeatherSim::Override::NONE;
			break;
	}
}

void EdenAmbience::set_external_weather(float p_intensity, float p_cloud, bool p_snow, bool p_thunder, float p_fog) {
	ext_intensity = CLAMP(p_intensity, 0.0f, 1.0f);
	ext_cloud = CLAMP(p_cloud, 0.0f, 1.0f);
	ext_snow = p_snow;
	ext_thunder = p_thunder;
	ext_fog = CLAMP(p_fog, 0.0f, 1.0f);
}

String EdenAmbience::get_weather_name() const {
	static const char *names[WEATHER_MAX] = { "Auto", "Clear", "Rain", "Thunderstorm", "Snow", "Dust Storm" };
	return names[CLAMP(weather_override, 0, WEATHER_MAX - 1)];
}

static constexpr int WEATHER_STATE_STRIDE = 10;

PackedFloat32Array EdenAmbience::get_weather_state() {
	if (weather.natural < 0) {
		weather.step(0.0f); // (seeds the natural cells)
	}
	PackedFloat32Array out;
	out.push_back(weather_override);
	for (int i = 0; i < weather.natural && i < (int)weather.cells.size(); i++) {
		const EdenWeatherSim::Cell &c = weather.cells[i];
		const float v[WEATHER_STATE_STRIDE] = { c.dir.x, c.dir.y, c.dir.z, c.radius, c.intensity, c.age, c.life, c.drift,
			c.phase, float((c.thunder ? 1 : 0) | (c.dust ? 2 : 0)) };
		for (float f : v) {
			out.push_back(f);
		}
	}
	return out;
}

void EdenAmbience::set_weather_state(const PackedFloat32Array &p_state) {
	if (p_state.is_empty() || (p_state.size() - 1) % WEATHER_STATE_STRIDE != 0) {
		return;
	}
	if ((int)p_state[0] != weather_override) {
		set_weather_override((int)p_state[0]);
	}
	if (weather.natural < 0) {
		weather.step(0.0f);
	}
	// Cell counts can differ (a setting): the ones both have
	const int n = MIN((p_state.size() - 1) / WEATHER_STATE_STRIDE, MIN(weather.natural, (int)weather.cells.size()));
	const float *v = p_state.ptr() + 1;
	for (int i = 0; i < n; i++, v += WEATHER_STATE_STRIDE) {
		EdenWeatherSim::Cell &c = weather.cells[i];
		c.dir = Vector3(v[0], v[1], v[2]).normalized();
		c.radius = v[3];
		c.intensity = v[4];
		c.age = v[5];
		c.life = MAX(v[6], 1.0f);
		c.drift = v[7];
		c.phase = v[8];
		c.thunder = (int)v[9] & 1;
		c.dust = (int)v[9] & 2;
	}
}

String EdenAmbience::cycle_weather(int p_step) {
	set_weather_override(((weather_override + p_step) % WEATHER_MAX + WEATHER_MAX) % WEATHER_MAX);
	return get_weather_name();
}

// Somewhere within the lightning distance range, biased into the camera's view so strikes get seen
bool EdenAmbience::_pick_strike_point(Vector3 &r_ground) const {
	Node3D *planet = _get_planet();
	Object *gen = planet ? (Object *)planet->get("generator") : nullptr;
	Vector3 cam;
	if (!state.valid || !_get_camera(cam)) {
		return false;
	}
	const float R = state.planet_radius;
	const Vector3 up = (cam - state.center).normalized();
	Vector3 fwd = cam_forward - up * cam_forward.dot(up);
	fwd = fwd.length_squared() > 1e-6f ? fwd.normalized() : up.get_any_perpendicular();
	float bearing = (Math::randf() * 2.0f - 1.0f) * Math::deg_to_rad(Math::randf() < lightning_view_bias ? 55.0f : 180.0f);
	const Vector3 tangent = fwd.rotated(up, bearing);
	const float dist = Math::lerp(lightning_min_distance, MAX(lightning_max_distance, lightning_min_distance), Math::pow(Math::randf(), 1.3f));
	const Vector3 dir = (up + tangent * (dist / R)).normalized();
	float h = 0.0f;
	if (gen != nullptr && gen->has_method("sample_surface")) {
		h = (float)((Dictionary)gen->call("sample_surface", dir)).get("height", 0.0f);
	}
	r_ground = state.center + dir * (R + MAX(h, 0.0f));
	return true;
}

void EdenAmbience::strike_lightning(const Vector3 &p_world_position, bool p_cloud_only) {
	Vector3 ground = p_world_position;
	if (ground == Vector3() && !_pick_strike_point(ground)) {
		return;
	}
	_strike(ground, p_cloud_only);
}

void EdenAmbience::_strike(const Vector3 &p_ground, bool p_cloud_only) {
	Node3D *planet = _get_planet();
	if (planet == nullptr || state.planet_radius <= 0.0f) {
		return;
	}
	if (bolt_shader.is_null()) {
		bolt_shader.instantiate();
		bolt_shader->set_code(EDEN_LIGHTNING_SHADER);
		bolt_rng.seed(Math::rand());
	}
	const float R = state.planet_radius;
	const Vector3 up = (p_ground - state.center).normalized();
	// From the cloud base (EdenCloudShell's, when there is one) straight-ish down to the strike point
	float cloud_base = 1500.0f;
	Node *clouds = _get_clouds();
	if (clouds != nullptr) {
		cloud_base = clouds->get("cloud_bottom");
	}
	const float ground_alt = (p_ground - state.center).length() - R;
	const Vector3 side = up.get_any_perpendicular().rotated(up, bolt_rng.randf() * Math::TAU);
	const Vector3 top = state.center + up * (R + MAX(cloud_base, ground_alt + 400.0f)) + side * (bolt_rng.randf() * 300.0f);

	// A free slot, else the one furthest through its strike
	Strike *s = &bolts[0];
	for (Strike &b : bolts) {
		if (b.t < 0.0f || b.t > s->t) {
			s = &b;
			if (b.t < 0.0f) {
				break;
			}
		}
	}
	if (s->mesh == nullptr) {
		s->material.instantiate();
		s->material->set_shader(bolt_shader);
		s->mesh = memnew(MeshInstance3D);
		s->mesh->set_name("Lightning");
		s->mesh->set_as_top_level(true);
		s->mesh->set_cast_shadows_setting(GeometryInstance3D::SHADOW_CASTING_SETTING_OFF);
		s->mesh->set_material_override(s->material);
		add_child(s->mesh, false, INTERNAL_MODE_BACK);
		s->light = memnew(OmniLight3D);
		s->light->set_name("LightningLight");
		s->light->set_as_top_level(true);
		s->light->set_shadow(false);
		// No distance falloff inside its range: a flash that lights the whole area, not a bulb 150 m up
		s->light->set_param(Light3D::PARAM_ATTENUATION, 0.0f);
		add_child(s->light, false, INTERNAL_MODE_BACK);
	}
	s->bolt.plan_strokes(bolt_rng);
	s->top = top;
	s->ground = p_ground;
	s->cloud_only = p_cloud_only;
	s->t = 0.0f;
	Vector3 cam;
	s->distance = _get_camera(cam) ? cam.distance_to(p_ground) : lightning_max_distance;
	if (!p_cloud_only) {
		s->mesh->set_mesh(EdenLightningBolt::build_mesh(top, p_ground, up, bolt_width, bolt_rng));
		s->mesh->set_global_position(top);
	}
	s->mesh->set_visible(!p_cloud_only);
	// Lights the land around the strike (or the cloud from inside)
	const float height = top.distance_to(p_ground);
	s->light->set_global_position(p_cloud_only ? top : p_ground + up * MIN(150.0f, height * 0.2f));
	// Each strike its own colour from the palette (bolt_color when it is empty)
	s->color = bolt_colors.is_empty() ? bolt_color : bolt_colors[bolt_rng.rand() % bolt_colors.size()];
	s->light->set_color(s->color);
	s->light->set_param(Light3D::PARAM_RANGE, lightning_light_range);
	s->light->set_visible(false);
	lightning_strikes++;
	// Thunder: after the sound's travel time, darker and softer with distance (and muffled inside cloud)
	const float thunder_dist = CLAMP(s->distance / MAX(lightning_max_distance, 1.0f) + (p_cloud_only ? 0.25f : 0.0f), 0.0f, 1.0f);
	soundscape->trigger_thunder(s->distance / 340.0f, thunder_dist);
}

void EdenAmbience::_update_bolts(double p_delta, const Vector3 &p_cam) {
	float sky = 0.0f;
	float cloud = 0.0f;
	Vector3 cloud_pos;
	for (Strike &s : bolts) {
		if (s.t < 0.0f || s.mesh == nullptr) {
			continue;
		}
		s.t += (float)p_delta;
		if (s.t > s.bolt.end_time) {
			s.t = -1.0f;
			s.mesh->set_visible(false);
			s.light->set_visible(false);
			continue;
		}
		const float f = s.bolt.flash_at(s.t);
		s.material->set_shader_parameter("flash", f);
		s.material->set_shader_parameter("reveal", s.bolt.reveal_at(s.t));
		s.material->set_shader_parameter("bolt_color", s.color);
		s.material->set_shader_parameter("intensity", bolt_brightness);
		const float d = p_cam.distance_to(s.ground);
		const bool lit = f > 0.02f && d < lightning_light_range * 2.0f;
		if (s.light->is_visible() != lit) {
			s.light->set_visible(lit);
		}
		s.light->set_param(Light3D::PARAM_ENERGY, f * lightning_light_energy);
		// The sky flash fades with distance; flashes inside cloud are softer
		const float near = 1.0f - _smoothstep(0.2f, 1.0f, d / MAX(lightning_max_distance, 1.0f)) * 0.75f;
		const float strength = f * near * (s.cloud_only ? 0.6f : 1.0f);
		sky = MAX(sky, strength);
		if (f * cloud_flash_brightness > cloud) {
			cloud = f * cloud_flash_brightness;
			cloud_pos = s.top - state.center;
			cloud_flash_color = s.color;
		}
	}
	flash = sky;
	// Clouds glow around the strike
	if (cloud > 0.0f || cloud_flash > 0.0f) {
		cloud_flash = cloud;
		Node *clouds = _get_clouds();
		Ref<ShaderMaterial> m = clouds ? Ref<ShaderMaterial>(clouds->call("get_material")) : Ref<ShaderMaterial>();
		if (m.is_valid()) {
			m->set_shader_parameter("lightning_flash", cloud);
			if (cloud > 0.0f) {
				m->set_shader_parameter("lightning_pos", cloud_pos);
				m->set_shader_parameter("lightning_color", cloud_flash_color);
			}
		}
	}
}

void EdenAmbience::_update(double p_delta) {
	time += p_delta;
	// Seasons: the camera's temperature is the climate's mean plus the season there; shaders (foliage through
	// globals, the terrain through its material) get the year's phase and the spin axis
	{
		const Vector4 cal(year_phase < 0.0f ? 0.0f : year_phase, season_strength, wet_season_strength, year_phase < 0.0f ? 0.0f : 1.0f);
		if (cal != calendar_pushed) {
			calendar_pushed = cal;
			RenderingServer::get_singleton()->global_shader_parameter_set("eden_calendar", cal);
			const Vector3 axis = weather.params.spin_axis;
			RenderingServer::get_singleton()->global_shader_parameter_set("eden_calendar_axis", Vector4(axis.x, axis.y, axis.z, 0.0f));
			Node3D *planet_node = _get_planet();
			Ref<ShaderMaterial> terrain_mat = planet_node ? Ref<ShaderMaterial>(planet_node->get("material")) : Ref<ShaderMaterial>();
			if (terrain_mat.is_valid()) {
				terrain_mat->set_shader_parameter("eden_calendar", cal);
				terrain_mat->set_shader_parameter("eden_calendar_axis", Vector4(axis.x, axis.y, axis.z, 0.0f));
			}
		}
	}
	// Floating origin: the planet's frame in world space, followed on the frame it moves (the survey and the weather
	// map only refresh every fraction of a second). Shaders key their planet-relative maths off it.
	{
		Node3D *planet_node = _get_planet();
		if (planet_node != nullptr && planet_node->is_inside_tree()) {
			const Transform3D xf = planet_node->get_global_transform();
			if (xf.origin != planet_frame_pushed.origin || xf.basis != planet_frame_pushed.basis) {
				planet_frame_pushed = xf;
				state.center = xf.origin;
				Ref<ShaderMaterial> terrain_mat = planet_node->get("material");
				if (weather_planet_pushed.w > 0.0f) {
					weather_planet_pushed = Vector4(xf.origin.x, xf.origin.y, xf.origin.z, weather_planet_pushed.w);
					RenderingServer::get_singleton()->global_shader_parameter_set("eden_weather_planet", weather_planet_pushed);
					if (terrain_mat.is_valid()) {
						terrain_mat->set_shader_parameter("eden_weather_planet", weather_planet_pushed);
					}
				}
				if (terrain_mat.is_valid()) {
					terrain_mat->set_shader_parameter("u_planet_center_world", xf.origin);
					terrain_mat->set_shader_parameter("u_planet_north_world", xf.basis.get_column(1).normalized());
				}
			}
		}
	}
	Vector3 cam;
	Basis cam_basis;
	const bool have_cam = _get_camera(cam, &cam_basis);
	if (have_cam) {
		cam_forward = -cam_basis.get_column(2);
	}
	if (have_cam && state.valid) {
		state.temperature = temperature_mean + weather.season_offset((cam - state.center).normalized());
		state.moisture = CLAMP(moisture_mean + weather.wet_season_offset((cam - state.center).normalized()), 0.0f, 1.0f);
	}
	survey_timer -= (float)p_delta;
	if (have_cam && survey_timer <= 0.0f) {
		survey_timer = 0.3f;
		_survey(cam);
	}
	source_timer -= (float)p_delta;
	if (have_cam && (spatial_audio || biome_effects_enabled) && (sweep.active || source_timer <= 0.0f)) {
		if (!sweep.active) {
			source_timer = 1.0f;
		}
		_find_sound_sources(cam);
	}

	const bool on = have_cam && state.valid;
	const Vector3 up = on ? (cam - state.center).normalized() : Vector3(0, 1, 0);
	Vector3 sun_dir = up;
	Node *atmo = _get_atmosphere();
	if (atmo != nullptr && atmo->has_method("get_sun_direction")) {
		sun_dir = atmo->call("get_sun_direction");
	}
	_update_weather(p_delta, cam, sun_dir);
	_update_trail((float)p_delta);
	_update_bolts(p_delta, cam);
	_apply_look();

	if (fx_dirty) {
		_apply_fx_params();
	}
	const float near_ground = 1.0f - _smoothstep(15.0f, 120.0f, state.altitude);
	const bool land = state.ground_height > 0.0f;
	const float vegetation = land ? _smoothstep(0.25f, 0.55f, state.moisture) * _smoothstep(0.1f, 0.3f, state.temperature) : 0.0f;
	const float cold = 1.0f - _smoothstep(0.08f, 0.16f, state.temperature);
	const float warm = _smoothstep(0.35f, 0.6f, state.temperature);
	const float precip = local.precipitation;
	const float dust_storm = local.dust;
	const float storm = MAX(MAX(precip, local.cloud * 0.5f), dust_storm);

	// Biome at the camera, as soft weights from the climate
	const bool biomes = biome_effects_enabled;
	const float b_desert = land ? _smoothstep(0.45f, 0.6f, state.temperature) * (1.0f - _smoothstep(0.2f, 0.35f, state.moisture)) : 0.0f;
	const float b_tropical = land ? _smoothstep(0.6f, 0.75f, state.temperature) * _smoothstep(0.45f, 0.6f, state.moisture) : 0.0f;
	const float b_cold = 1.0f - _smoothstep(0.12f, 0.25f, state.temperature);
	const float b_coast = state.water;
	const float b_forest = vegetation * (1.0f - b_desert);
	biome_weights = Vector4(b_desert, b_tropical, b_cold, b_coast);

	// Wind: a heading in the local tangent plane, measured from planet north; storms blow harder
	Vector3 north = Vector3(0, 1, 0) - up * up.y;
	north = north.length_squared() > 1e-6f ? north.normalized() : up.cross(Vector3(1, 0, 0)).normalized();
	const Vector3 east = north.cross(up);
	// The heading wanders slowly around wind_heading (two incommensurate periods of ~5 and ~14 minutes)
	const float wander = wind_wander * (0.7f * Math::sin((float)time * 0.021f) + 0.3f * Math::sin((float)time * 0.0073f + 2.0f));
	const float heading = Math::deg_to_rad(wind_heading + wander);
	const float gusts = MIN(gustiness + 0.4f * storm, 1.0f);
	const float gust = 0.75f + 0.25f * Math::sin((float)time * 0.37f) * Math::sin((float)time * 0.13f + 1.0f) * (1.0f + gusts);
	const float wind_now = wind_speed * (1.0f + storm_wind_boost * storm);
	const Vector3 wind_dir = north * Math::cos(heading) + east * Math::sin(heading);
	const Vector3 wind = wind_dir * wind_now * gust;
	// For shaders (grass, trees): eden_wind = direction (world, at the camera) and speed in m/s; eden_wind_flow.x = how
	// far the gust pattern has moved, wrapped at 4800 m (a multiple of the shaders' gust wavelengths), y = gustiness
	wind_flow = Math::fmod(wind_flow + (double)(wind_now * gust) * p_delta, 4800.0);
	{
		const Vector4 w(wind_dir.x, wind_dir.y, wind_dir.z, wind_now * gust);
		RenderingServer *rs = RenderingServer::get_singleton();
		if (!w.is_equal_approx(wind_pushed)) {
			wind_pushed = w;
			rs->global_shader_parameter_set("eden_wind", w);
		}
		rs->global_shader_parameter_set("eden_wind_flow", Vector4((float)wind_flow, gusts, 0.0f, 0.0f));
	}

	// Particles
	float ratio[FX_MAX] = {};
	// Motes by biome: pollen in green country (seen against the sun), dust in dry country (lit all
	// round), glinting ice crystals in clear, cold air
	const float m_ice = biomes ? b_cold * (1.0f - local.cloud) : 0.0f;
	const float m_dust = biomes ? b_desert * (1.0f - m_ice) : 0.0f;
	const float m_pollen = MAX(1.0f - m_ice - m_dust, 0.0f);
	// The daylight the particles catch, less what an eclipse takes: in the parent planet's shadow the sky goes dark
	// but sunlit motes kept glinting as at noon, white specks that read as stars across the planet's disc
	float sun_vis = 1.0f;
	if (Node *atmo_n = _get_atmosphere()) {
		sun_vis = CLAMP(float(atmo_n->call("get_sun_visible")), 0.0f, 1.0f);
	}
	if (on && particles_enabled) {
		ratio[FX_MOTES] = motes_amount * state.day * sun_vis * near_ground * (land || m_ice > 0.0f ? 1.0f : 0.0f) * (1.0f - local.cloud) * (1.0f - dust_storm) *
				(biomes ? 1.0f : 1.0f - cold);
		// Fireflies are a summer thing: in this hemisphere's summer where seasons are felt, all year in the tropics
		float summer = 1.0f;
		if (year_phase >= 0.0f) {
			const float sl = up.dot(weather.params.spin_axis);
			const float w = Math::fposmod(year_phase + (sl < 0.0f ? 0.5f : 0.0f), 1.0f); // 0 = local spring equinox
			const float felt = _smoothstep(0.05f, 0.5f, Math::abs(sl));
			const float in_summer = _smoothstep(0.17f, 0.25f, w) * (1.0f - _smoothstep(0.47f, 0.55f, w));
			summer = Math::lerp(1.0f, in_summer, felt);
		}
		ratio[FX_FIREFLIES] = fireflies_amount * summer * state.night * warm * vegetation * near_ground * (1.0f - precip);
		ratio[FX_SNOW] = snow_amount * (precip * local_freezing + 0.25f * cold * local.cloud) * (1.0f - _smoothstep(800.0f, 3000.0f, state.altitude));
		// (above the clouds, and out in space, nothing falls)
		ratio[FX_RAIN] = (rain_amount * (1.0f - cold) + precip * (1.0f - local_freezing)) * (1.0f - _smoothstep(800.0f, 3000.0f, state.altitude));
		if (biomes) {
			ratio[FX_LEAVES] = leaves_amount * (forest_here >= 0.0f ? forest_here : b_forest) * (1.0f - cold) * (1.0f - 0.8f * b_coast) * near_ground * _smoothstep(0.5f, 4.0f, wind_now) * (1.0f - precip * 0.5f);
			ratio[FX_DUST] = dust_amount * near_ground * MAX(b_desert * _smoothstep(dust_wind_threshold, dust_wind_threshold * 2.5f, wind_now), dust_storm);
		}
	}
	const float ground_radius = state.planet_radius + MAX(state.ground_height, 0.0f);
	const float ambient = (0.12f + 0.88f * state.day * sun_vis) * (1.0f - 0.35f * MAX(local.cloud, dust_storm));
	{
		const float wsum = MAX(m_ice + m_dust + m_pollen, 1e-3f);
		const Color mc = (ice_crystal_color * m_ice + dust_mote_color * m_dust + pollen_color * m_pollen) / wsum;
		_push(fx_draw[FX_MOTES], "color", Color(mc.r, mc.g, mc.b, 1.0f));
		_push(fx_draw[FX_MOTES], "forward_scatter", 1.0f - 0.7f * m_dust / wsum - 0.5f * m_ice / wsum);
		_push(fx_draw[FX_MOTES], "twinkle", m_ice / wsum);
		// Leaves turn with the season (autumn in this hemisphere, where seasons are felt) and in cool country
		float autumn = 1.0f - _smoothstep(0.3f, 0.5f, state.temperature);
		if (year_phase >= 0.0f) {
			const float sl = up.dot(weather.params.spin_axis);
			const float w = Math::fposmod(year_phase + (sl < 0.0f ? 0.5f : 0.0f), 1.0f);
			const float felt = _smoothstep(0.05f, 0.5f, Math::abs(sl));
			autumn = MAX(autumn * 0.5f, _smoothstep(0.5f, 0.6f, w) * (1.0f - _smoothstep(0.78f, 0.86f, w)) * felt);
		}
		const Color lc = leaf_color_summer.lerp(leaf_color_autumn, autumn);
		_push(fx_draw[FX_LEAVES], "color", Color(lc.r, lc.g, lc.b, 1.0f));
		_push(fx_draw[FX_LEAVES], "color2", Color(lc.r * 0.8f, lc.g * 0.7f, lc.b * 0.6f, 1.0f).lerp(leaf_color_autumn, autumn * 0.5f));
	}

	// Fog: light haze by day, thicker in humid country and on the coast, thinner in cold air and tinted
	// by the biome; around dawn, dusk and night in humid air a dense mist whose top sits a little
	// below the ground under the camera, so it pools in the valleys around you; thick in rain and
	// snow, and tan in dust storms. Owns the atmosphere's fog density/height/base/albedo while
	// enabled (its lighting is left alone).
	const bool drive_atmo = (fog_enabled || weather_enabled) && on && atmo != nullptr;
	if (!drive_atmo || atmo->get_instance_id() != fog_atmo) {
		_restore_fog();
	}
	if (drive_atmo) {
		if (fog_atmo.is_null()) { // remember the atmosphere's own values, put back by _restore_fog()
			fog_atmo = atmo->get_instance_id();
			fog_saved = Vector3(atmo->get("fog_density"), atmo->get("fog_height_falloff"), atmo->get("fog_base_altitude"));
			sun_energy_saved = atmo->get("sun_light_energy");
			moon_energy_saved = atmo->get("moon_light_energy");
			fog_albedo_saved = atmo->get("fog_albedo");
			fog_sun_saved = atmo->get("fog_sun_intensity");
		}
		// Storm cover dims the direct sun (the sky and ambient already darken through the grade)
		_atmo_set(atmo, "sun_light_energy", sun_energy_saved * (1.0f - storm_sun_dimming * (weather_enabled ? MAX(local.cloud, dust_storm) : 0.0f)));
		// Cloud hides the moon too (more than the sun: moonlight has no diffuse sky glow to carry it through)
		_atmo_set(atmo, "moon_light_energy", moon_energy_saved * (1.0f - 0.9f * (weather_enabled ? MAX(local.cloud, dust_storm) : 0.0f)));
	}
	if (drive_atmo && fog_enabled) {
		const float humid = _smoothstep(0.3f, 0.8f, state.moisture) * (1.0f - cold * 0.5f);
		const float low_sun = 1.0f - _smoothstep(0.05f, 0.4f, state.sun_elevation);
		const float target = MAX(MAX(humid * (0.15f + 0.85f * low_sun), ext_fog_now * 2.5f), MAX(rain_amount * 0.6f, MAX(precip * storm_fog + local.cloud * 0.15f, dust_storm * dust_fog)));
		const float k = mist < 0.0f ? 1.0f : 1.0f - Math::exp(-(float)p_delta / 4.0f);
		mist = mist < 0.0f ? target : Math::lerp(mist, target, k);
		mist_ground = Math::lerp(mist_ground, MAX(state.ground_height, 0.0f), k);
		float haze = haze_density;
		Color tint = fog_albedo_saved;
		if (biome_fog_enabled) {
			const float w_humid = b_tropical, w_dry = MIN(b_desert + dust_storm, 1.0f), w_cold = b_cold, w_coast = b_coast * (1.0f - b_cold);
			haze *= MAX(1.0f + (humid_haze - 1.0f) * w_humid + (dry_haze - 1.0f) * w_dry + (cold_haze - 1.0f) * w_cold + (coast_haze - 1.0f) * w_coast, 0.05f);
			const float wsum = 1.0f + w_humid + w_dry * 2.0f + w_cold + w_coast;
			tint = (fog_albedo_saved + humid_haze_color * w_humid + dry_haze_color * (w_dry * 2.0f) + cold_haze_color * w_cold + coast_haze_color * w_coast) / wsum;
		}
		fog_tint = fog_tint.a < 0.0f ? tint : fog_tint.lerp(tint, k);
		_atmo_set(atmo, "fog_density", haze + mist_density * mist);
		// mist can exceed 1 (thick storms add density), but the layer's shape stops at the mist's
		const float shape = CLAMP(mist, 0.0f, 1.0f);
		_atmo_set(atmo, "fog_height_falloff", Math::lerp(haze_height, mist_height, shape));
		// The atmosphere measures fog altitude from its own planet_radius, which needn't be the terrain's
		// sea level (the probe scene's sits 100 m lower)
		const float atmo_radius = atmo->get("planet_radius");
		const float sea_offset = atmo_radius > 0.0f ? state.planet_radius - atmo_radius : 0.0f;
		_atmo_set(atmo, "fog_base_altitude", Math::lerp(fog_saved.z, sea_offset + mist_ground - mist_depth, shape));
		_atmo_set(atmo, "fog_albedo", Color(fog_tint.r, fog_tint.g, fog_tint.b));
		// Dust is lit by the sun (a sunless scene fog would turn a tan dust storm grey-blue)
		_atmo_set(atmo, "fog_sun_intensity", Math::lerp(fog_sun_saved, MAX(fog_sun_saved, 0.9f), dust_storm));
	}
	for (int i = 0; i < FX_MAX; i++) {
		GPUParticles3D *p = fx[i];
		if (p == nullptr) {
			continue;
		}
		const float r = CLAMP(ratio[i], 0.0f, 1.0f);
		if (r < 0.01f || fx_draw[i].is_null()) {
			if (p->is_emitting()) {
				p->set_emitting(false);
			}
			if (p->is_visible() && r <= 0.0f) {
				p->set_visible(false);
			}
			continue;
		}
		if (!p->is_visible()) {
			p->set_visible(true);
		}
		if (!p->is_emitting()) {
			p->set_emitting(true);
		}
		if (Math::abs(p->get_amount_ratio() - r) > 0.002f) {
			p->set_amount_ratio(r);
		}
		if (p->get_global_position() != cam) {
			p->set_global_transform(Transform3D(Basis(), cam));
		}
		_push(fx_process[i], "planet_center", state.center);
		_push(fx_process[i], "ground_radius", ground_radius);
		_push(fx_process[i], "wind", wind);
		if (i == FX_RAIN) {
			_push(fx_process[i], "fall_speed", 7.0f + 4.0f * r);
		}
		_push(fx_draw[i], "planet_center", state.center);
		_push(fx_draw[i], "sun_direction", sun_dir);
		const bool lit = i == FX_SNOW || i == FX_RAIN || i == FX_LEAVES || i == FX_DUST;
		_push(fx_draw[i], "intensity", lit ? ambient * (1.0f + 3.0f * flash) : 1.0f);
	}

	// Soundscape
	if (player != nullptr) {
		bool want = audio_enabled && on;
#ifdef TOOLS_ENABLED
		want = want && (audio_in_editor || !Engine::get_singleton()->is_editor_hint());
#endif
		const float sea_alt = on ? (cam - state.center).length() - state.planet_radius : 1e9f;
		soundscape->set_level(AudioStreamEdenAmbience::LAYER_WIND, wind_volume * (0.3f + 0.45f * _smoothstep(0.0f, 1500.0f, state.altitude) + 0.25f * CLAMP(wind_now / 10.0f, 0.0f, 1.0f) + 0.5f * dust_storm));
		// With spatial audio, surf and leaves come from 3D emitters at their sources instead
		const float flat = spatial_audio ? 0.0f : 1.0f;
		soundscape->set_level(AudioStreamEdenAmbience::LAYER_LEAVES, flat * leaves_volume * vegetation * near_ground * CLAMP(wind_now / 4.0f, 0.2f, 1.0f));
		soundscape->set_level(AudioStreamEdenAmbience::LAYER_SURF, flat * surf_volume * state.water * (1.0f - _smoothstep(20.0f, 250.0f, sea_alt)));
		soundscape->set_level(AudioStreamEdenAmbience::LAYER_BIRDS, birds_volume * state.day * vegetation * near_ground * (1.0f - precip));
		soundscape->set_level(AudioStreamEdenAmbience::LAYER_CRICKETS, crickets_volume * state.night * warm * near_ground * (0.3f + 0.7f * vegetation) * (1.0f - 0.8f * precip));
		soundscape->set_level(AudioStreamEdenAmbience::LAYER_RAIN, rain_volume * CLAMP(ratio[FX_RAIN], 0.0f, 1.0f) * (1.0f - _smoothstep(200.0f, 1500.0f, state.altitude)));
		soundscape->gustiness.store(gusts);
		soundscape->thunder_gain.store(thunder_volume);
		if (player->get_volume_db() != volume_db) {
			player->set_volume_db(volume_db);
		}
		if (want && !player->is_playing()) {
			player->play();
		} else if (!want && player->is_playing()) {
			player->stop();
		}
		_update_emitters(p_delta, want, wind_now, cam, cam_basis);
	}
}

void EdenAmbience::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_ENTER_TREE: {
			if (player == nullptr) {
				_build();
			}
			look_dirty = true;
			survey_timer = 0.0f;
			set_process_internal(true);
			// Shaders read the weather through these; a project declares them in [shader_globals] so the
			// editor can compile shaders that use them, otherwise they are created here at runtime
			RenderingServer *rs = RenderingServer::get_singleton();
			const char *names[] = { "eden_weather_map", "eden_weather_planet", "eden_weather_params", "eden_weather_snow", "eden_wind", "eden_wind_flow",
				"eden_calendar", "eden_calendar_axis", "eden_snow_trail_map", "eden_snow_trail_frame", "eden_snow_trail_u", "eden_snow_trail_v" };
			const RS::GlobalShaderParameterType types[] = { RS::GLOBAL_VAR_TYPE_SAMPLER2D, RS::GLOBAL_VAR_TYPE_VEC4, RS::GLOBAL_VAR_TYPE_VEC4, RS::GLOBAL_VAR_TYPE_VEC4,
				RS::GLOBAL_VAR_TYPE_VEC4, RS::GLOBAL_VAR_TYPE_VEC4, RS::GLOBAL_VAR_TYPE_VEC4, RS::GLOBAL_VAR_TYPE_VEC4,
				RS::GLOBAL_VAR_TYPE_SAMPLER2D, RS::GLOBAL_VAR_TYPE_VEC4, RS::GLOBAL_VAR_TYPE_VEC4, RS::GLOBAL_VAR_TYPE_VEC4 };
			const Variant values[] = { RID(), Vector4(), Vector4(), Vector4(), Vector4(), Vector4(), Vector4(), Vector4(), RID(), Vector4(), Vector4(), Vector4() };
			for (int i = 0; i < 12; i++) {
				if (!globals_added && !ProjectSettings::get_singleton()->has_setting(String("shader_globals/") + names[i])) {
					rs->global_shader_parameter_add(names[i], types[i], values[i]);
				}
			}
			globals_added = true;
		} break;
		case NOTIFICATION_INTERNAL_PROCESS: {
			const uint64_t t0 = OS::get_singleton()->get_ticks_usec();
			_update(get_process_delta_time());
			// CPU cost, averaged and peaked over the last second (get_debug_state)
			const uint64_t us = OS::get_singleton()->get_ticks_usec() - t0;
			cost_sum += us;
			cost_peak_acc = MAX(cost_peak_acc, us);
			cost_frames++;
			if (OS::get_singleton()->get_ticks_usec() - cost_window_start > 1000000) {
				cost_avg_us = cost_frames > 0 ? float(cost_sum) / cost_frames : 0.0f;
				cost_peak_us = float(cost_peak_acc);
				cost_sum = cost_peak_acc = 0;
				cost_frames = 0;
				cost_window_start = OS::get_singleton()->get_ticks_usec();
			}
		} break;
		// The driven fog values must not end up saved into the scene's atmosphere
		case NOTIFICATION_EDITOR_PRE_SAVE:
		case NOTIFICATION_EXIT_TREE: {
			_restore_fog();
			if (p_what == NOTIFICATION_EXIT_TREE) {
				RenderingServer::get_singleton()->global_shader_parameter_set("eden_weather_planet", Vector4());
			}
			// Nor the weather map in the terrain's (saved) material; set again on the next map update
			Node3D *planet = _get_planet();
			Ref<ShaderMaterial> terrain_mat = planet ? Ref<ShaderMaterial>(planet->get("material")) : Ref<ShaderMaterial>();
			if (terrain_mat.is_valid()) {
				terrain_mat->set_shader_parameter("eden_weather_map", Variant());
				terrain_mat->set_shader_parameter("eden_weather_planet", Variant());
				terrain_mat->set_shader_parameter("eden_calendar", Variant());
				terrain_mat->set_shader_parameter("eden_calendar_axis", Variant());
				calendar_pushed = Vector4(-9, -9, -9, -9); // set again next update
				terrain_mat->set_shader_parameter("eden_weather_params", Variant());
				terrain_mat->set_shader_parameter("eden_weather_snow", Variant());
				terrain_mat->set_shader_parameter("eden_snow_trail_map", Variant());
				terrain_mat->set_shader_parameter("eden_snow_trail_frame", Variant());
				terrain_mat->set_shader_parameter("eden_snow_trail_u", Variant());
				terrain_mat->set_shader_parameter("eden_snow_trail_v", Variant());
				trail_texture.unref(); // (re-set on the material with the next upload)
				trail_dirty = trail_active;
				weather_timer = 0.0f;
			}
		} break;
	}
}

void EdenAmbience::_restore_fog() {
	// Not when the atmosphere itself is already out of the tree (the whole scene closing): its setters
	// then resolve node paths and error, and nothing is left to show the values anyway
	Node *atmo = Object::cast_to<Node>(ObjectDB::get_instance(fog_atmo));
	if (atmo != nullptr && atmo->is_inside_tree()) {
		_atmo_set(atmo, "fog_density", fog_saved.x);
		_atmo_set(atmo, "fog_height_falloff", fog_saved.y);
		_atmo_set(atmo, "fog_base_altitude", fog_saved.z);
		_atmo_set(atmo, "sun_light_energy", sun_energy_saved);
		_atmo_set(atmo, "moon_light_energy", moon_energy_saved);
		_atmo_set(atmo, "fog_albedo", fog_albedo_saved);
		_atmo_set(atmo, "fog_sun_intensity", fog_sun_saved);
	}
	fog_atmo = ObjectID();
	fog_tint = Color(0, 0, 0, -1);
	atmo_pushed.clear();
}

// ---------------------------------------------------------------------------------------------
// Properties

#define EDEN_AMB_DEFINE(m_type, m_name, m_default, m_hint, m_hint_string, m_group) \
	void EdenAmbience::set_##m_name(m_type p_value) {                               \
		m_name = p_value;                                                           \
		look_dirty = true;                                                          \
		fx_dirty = true;                                                            \
		survey_timer = 0.0f;                                                        \
	}                                                                               \
	m_type EdenAmbience::get_##m_name() const {                                     \
		return m_name;                                                              \
	}
EDEN_AMBIENCE_PROPS(EDEN_AMB_DEFINE)
#undef EDEN_AMB_DEFINE

void EdenAmbience::set_planet_path(const NodePath &p_path) {
	planet_path = p_path;
	survey_timer = 0.0f;
}

NodePath EdenAmbience::get_planet_path() const {
	return planet_path;
}

void EdenAmbience::set_atmosphere_path(const NodePath &p_path) {
	atmosphere_path = p_path;
	survey_timer = 0.0f;
}

NodePath EdenAmbience::get_atmosphere_path() const {
	return atmosphere_path;
}

Ref<AudioStreamEdenAmbience> EdenAmbience::get_soundscape() const {
	return soundscape;
}

GPUParticles3D *EdenAmbience::get_effect(Effect p_effect) const {
	ERR_FAIL_INDEX_V(p_effect, FX_MAX, nullptr);
	return fx[p_effect];
}

Dictionary EdenAmbience::get_weather_at(const Vector3 &p_world_position) const {
	const Vector3 dir = (p_world_position - state.center).normalized();
	const EdenWeatherSim::Sample s = weather.sample(dir);
	Dictionary d;
	d["precipitation"] = s.precipitation;
	d["cloud"] = s.cloud;
	d["thunder"] = s.thunder;
	d["dust"] = s.dust;
	d["snow"] = weather.snow_at(dir);
	d["wetness"] = weather.wetness_at(dir);
	d["temperature"] = weather.temperature_at(dir);
	return d;
}

// ===========================================================================================
// Snow trail
// ===========================================================================================

float EdenAmbience::get_snow_depth_at(const Vector3 &p_world_position) const {
	if (!weather_enabled || !state.valid) {
		return 0.0f;
	}
	const float cover = weather.snow_at(p_world_position - state.center);
	return cover * snow_max_depth * (1.0f - TRAIL_PRESS * _trail_sample(p_world_position));
}

// The tangent frame at a world point: axes kept stable by building them off the planet's Y (Z near the poles)
void EdenAmbience::_trail_frame(const Vector3 &p_center) {
	const Vector3 up = (p_center - state.center).normalized();
	Vector3 ref = Math::abs(up.y) < 0.9f ? Vector3(0, 1, 0) : Vector3(0, 0, 1);
	trail_u = ref.cross(up).normalized();
	trail_v = up.cross(trail_u).normalized();
	trail_center = p_center;
}

float EdenAmbience::_trail_sample(const Vector3 &p_world) const {
	if (!trail_active) {
		return 0.0f;
	}
	const Vector3 d = p_world - trail_center;
	const float fx = (d.dot(trail_u) / TRAIL_SIZE + 0.5f) * TRAIL_RES - 0.5f;
	const float fy = (d.dot(trail_v) / TRAIL_SIZE + 0.5f) * TRAIL_RES - 0.5f;
	const int x0 = (int)Math::floor(fx), y0 = (int)Math::floor(fy);
	if (x0 < 0 || y0 < 0 || x0 >= TRAIL_RES - 1 || y0 >= TRAIL_RES - 1) {
		return 0.0f;
	}
	const float tx = fx - x0, ty = fy - y0;
	const float *t = trail.ptr() + y0 * TRAIL_RES + x0;
	return Math::lerp(Math::lerp(t[0], t[1], tx), Math::lerp(t[TRAIL_RES], t[TRAIL_RES + 1], tx), ty);
}

// Moves the map's centre, carrying the trail already there across (a path stays where it was walked)
void EdenAmbience::_trail_recentre(const Vector3 &p_center) {
	if (!trail_active) {
		trail.resize(TRAIL_RES * TRAIL_RES);
		for (float &v : trail) {
			v = 0.0f;
		}
		_trail_frame(p_center);
		trail_active = true;
		trail_dirty = true;
		return;
	}
	LocalVector<float> old = trail;
	const Vector3 oc = trail_center, ou = trail_u, ov = trail_v;
	_trail_frame(p_center);
	for (int y = 0; y < TRAIL_RES; y++) {
		for (int x = 0; x < TRAIL_RES; x++) {
			const Vector3 w = trail_center + trail_u * (((x + 0.5f) / TRAIL_RES - 0.5f) * TRAIL_SIZE) +
					trail_v * (((y + 0.5f) / TRAIL_RES - 0.5f) * TRAIL_SIZE);
			const Vector3 d = w - oc;
			const int ox = (int)Math::floor((d.dot(ou) / TRAIL_SIZE + 0.5f) * TRAIL_RES);
			const int oy = (int)Math::floor((d.dot(ov) / TRAIL_SIZE + 0.5f) * TRAIL_RES);
			trail[y * TRAIL_RES + x] = (ox >= 0 && oy >= 0 && ox < TRAIL_RES && oy < TRAIL_RES) ? old[oy * TRAIL_RES + ox] : 0.0f;
		}
	}
	trail_dirty = true;
}

void EdenAmbience::press_snow(const Vector3 &p_world_position, float p_radius, float p_amount) {
	if (!state.valid || p_radius <= 0.0f || p_amount <= 0.0f) {
		return;
	}
	// The map follows the camera (_update_trail), not the presses: a press 20 m off (another player, an old trail
	// from the server) recentred it there and dropped the path behind us. Presses off the map are lost.
	if (!trail_active) {
		_trail_recentre(p_world_position);
	}
	const Vector3 d = p_world_position - trail_center;
	const float texel = TRAIL_SIZE / TRAIL_RES;
	const float cx = (d.dot(trail_u) / TRAIL_SIZE + 0.5f) * TRAIL_RES;
	const float cy = (d.dot(trail_v) / TRAIL_SIZE + 0.5f) * TRAIL_RES;
	const float r = p_radius / texel;
	const int x0 = MAX(0, (int)Math::floor(cx - r)), x1 = MIN(TRAIL_RES - 1, (int)Math::ceil(cx + r));
	const int y0 = MAX(0, (int)Math::floor(cy - r)), y1 = MIN(TRAIL_RES - 1, (int)Math::ceil(cy + r));
	for (int y = y0; y <= y1; y++) {
		for (int x = x0; x <= x1; x++) {
			const float dist = Vector2(x + 0.5f - cx, y + 0.5f - cy).length() / r;
			if (dist >= 1.0f) {
				continue;
			}
			const float f = 1.0f - dist * dist; // soft rim
			float &v = trail[y * TRAIL_RES + x];
			v = MAX(v, MIN(1.0f, p_amount * f * 1.6f));
		}
	}
	trail_dirty = true;
}

void EdenAmbience::_update_trail(float p_delta) {
	if (!trail_active) {
		return;
	}
	// Kept within 6 m of the camera, so everything up to ~20 m round the player is always on the 64 m map
	Vector3 cam;
	if (_get_camera(cam) && (cam - trail_center).length() > 6.0f) {
		_trail_recentre(cam);
	}
	// Falling snow fills paths back in (about as fast as fresh cover builds up)
	// and every path fades over snow_trail_lifetime, linearly: a print pressed at 1 - age / lifetime (one walked before
	// we came near, from the server) then fades in step with everyone else's copy of it
	// (gathered into whole 8-bit steps of the map, ~2.4 s apart at 10 min, not re-uploaded every frame)
	float refill = local.precipitation * local_freezing * snow_rate / 60.0f * 3.0f * p_delta;
	if (snow_trail_lifetime > 0.0f) {
		trail_fade_acc += p_delta / snow_trail_lifetime;
		if (trail_fade_acc >= 1.0f / 255.0f) {
			refill += trail_fade_acc;
			trail_fade_acc = 0.0f;
		}
	}
	if (refill > 0.0f) {
		for (float &v : trail) {
			v = MAX(0.0f, v - refill);
		}
		trail_dirty = true;
	}
	trail_upload_timer -= p_delta;
	if (!trail_dirty || trail_upload_timer > 0.0f) {
		return;
	}
	trail_upload_timer = 1.0f / 20.0f;
	trail_dirty = false;
	PackedByteArray bytes;
	bytes.resize(TRAIL_RES * TRAIL_RES);
	uint8_t *w = bytes.ptrw();
	for (int i = 0; i < TRAIL_RES * TRAIL_RES; i++) {
		w[i] = (uint8_t)CLAMP((int)(trail[i] * 255.0f + 0.5f), 0, 255);
	}
	trail_image = Image::create_from_data(TRAIL_RES, TRAIL_RES, false, Image::FORMAT_R8, bytes);
	RenderingServer *rs = RenderingServer::get_singleton();
	const bool first = trail_texture.is_null();
	if (first) {
		trail_texture = ImageTexture::create_from_image(trail_image);
		rs->global_shader_parameter_set("eden_snow_trail_map", trail_texture->get_rid());
	} else {
		trail_texture->update(trail_image);
	}
	const Vector4 frame(trail_center.x, trail_center.y, trail_center.z, TRAIL_SIZE * 0.5f);
	const Vector4 axis_u(trail_u.x, trail_u.y, trail_u.z, 1.0f);
	const Vector4 axis_v(trail_v.x, trail_v.y, trail_v.z, TRAIL_PRESS);
	rs->global_shader_parameter_set("eden_snow_trail_frame", frame);
	rs->global_shader_parameter_set("eden_snow_trail_u", axis_u);
	rs->global_shader_parameter_set("eden_snow_trail_v", axis_v);
	// GPU-driven terrain can't bind global textures: the same on its material (see eden_weather.gdshaderinc)
	Node3D *planet_node = _get_planet();
	Ref<ShaderMaterial> terrain_mat = planet_node ? Ref<ShaderMaterial>(planet_node->get("material")) : Ref<ShaderMaterial>();
	if (terrain_mat.is_valid()) {
		if (first) {
			terrain_mat->set_shader_parameter("eden_snow_trail_map", trail_texture);
		}
		terrain_mat->set_shader_parameter("eden_snow_trail_frame", frame);
		terrain_mat->set_shader_parameter("eden_snow_trail_u", axis_u);
		terrain_mat->set_shader_parameter("eden_snow_trail_v", axis_v);
	}
}

void EdenAmbience::add_storm(const Vector3 &p_world_position, float p_radius, float p_intensity, float p_duration, bool p_thunder, bool p_dust) {
	// May run before the first survey: resolve the planet directly
	Vector3 center = state.center;
	float radius = state.planet_radius;
	Node3D *planet = _get_planet();
	if (planet != nullptr) {
		center = planet->is_inside_tree() ? planet->get_global_position() : planet->get_position();
		Object *gen = planet->get("generator");
		if (radius <= 0.0f && gen != nullptr) {
			radius = gen->get("planet_radius");
		}
	}
	ERR_FAIL_COND_MSG(radius <= 0.0f, "EdenAmbience: no planet radius yet (planet_path must point at a terrain with a generator).");
	weather.planet_radius = radius;
	weather.add_cell(p_world_position - center, p_radius, p_intensity, p_duration, p_thunder, p_dust);
}

void EdenAmbience::clear_snow_and_wetness() {
	weather.clear_cover();
	for (float &v : trail) {
		v = 0.0f;
	}
	trail_dirty = trail_active;
}

Ref<ImageTexture> EdenAmbience::get_weather_texture() const {
	return weather_texture;
}

Dictionary EdenAmbience::get_debug_state() const {
	Dictionary d;
	d["valid"] = state.valid;
	d["ground_height"] = state.ground_height;
	d["altitude"] = state.altitude;
	d["temperature"] = state.temperature;
	d["moisture"] = state.moisture;
	d["water"] = state.water;
	d["day"] = state.day;
	d["night"] = state.night;
	Array fx_ratio;
	for (int i = 0; i < FX_MAX; i++) {
		fx_ratio.push_back(fx[i] && fx[i]->is_emitting() ? fx[i]->get_amount_ratio() : 0.0f);
	}
	d["effects"] = fx_ratio;
	Array levels;
	for (int i = 0; i < AudioStreamEdenAmbience::LAYER_MAX; i++) {
		levels.push_back(soundscape->get_level(AudioStreamEdenAmbience::Layer(i)));
	}
	d["audio_levels"] = levels;
	d["precipitation"] = local.precipitation;
	d["cloud"] = local.cloud;
	d["thunder"] = local.thunder;
	d["snow_cover"] = local_snow;
	d["wetness"] = local_wet;
	d["freezing"] = local_freezing;
	d["climate_ready"] = weather.is_climate_ready();
	d["forest_here"] = forest_here;
	Array sources;
	for (int i = 0; i < SURF_EMITTERS + LEAF_EMITTERS; i++) {
		const Emitter &e = i < SURF_EMITTERS ? surf_emitters[i] : leaf_emitters[i - SURF_EMITTERS];
		Dictionary src;
		src["kind"] = i < SURF_EMITTERS ? "surf" : "leaves";
		src["level"] = e.level;
		src["target_level"] = e.target_level;
		src["position"] = e.target;
		sources.push_back(src);
	}
	d["sound_sources"] = sources;
	d["dust_storm"] = local.dust;
	Dictionary b;
	b["desert"] = biome_weights.x;
	b["tropical"] = biome_weights.y;
	b["cold"] = biome_weights.z;
	b["coast"] = biome_weights.w;
	d["biome"] = b;
	d["lightning_strikes"] = lightning_strikes;
	int active = 0;
	for (const Strike &s : bolts) {
		active += s.t >= 0.0f ? 1 : 0;
	}
	d["active_bolts"] = active;
	d["flash"] = flash;
	d["cpu_avg_us"] = cost_avg_us;
	d["weather"] = get_weather_name();
	// Wind at the camera (world direction it blows toward, m/s with gusts) and the season's temperature change there
	d["wind_direction"] = Vector3(wind_pushed.x, wind_pushed.y, wind_pushed.z);
	d["wind_speed"] = wind_pushed.w;
	d["temperature_mean"] = temperature_mean;
	d["moisture_mean"] = moisture_mean;
	d["override_strength"] = ov_strength;
	d["cpu_peak_us"] = cost_peak_us;
	return d;
}

void EdenAmbience::_bind_methods() {
#define EDEN_AMB_BIND(m_type, m_name, m_default, m_hint, m_hint_string, m_group)                  \
	ClassDB::bind_method(D_METHOD("set_" #m_name, "value"), &EdenAmbience::set_##m_name); \
	ClassDB::bind_method(D_METHOD("get_" #m_name), &EdenAmbience::get_##m_name);
	EDEN_AMBIENCE_PROPS(EDEN_AMB_BIND)
#undef EDEN_AMB_BIND
	ClassDB::bind_method(D_METHOD("set_planet_path", "path"), &EdenAmbience::set_planet_path);
	ClassDB::bind_method(D_METHOD("get_planet_path"), &EdenAmbience::get_planet_path);
	ClassDB::bind_method(D_METHOD("set_atmosphere_path", "path"), &EdenAmbience::set_atmosphere_path);
	ClassDB::bind_method(D_METHOD("get_atmosphere_path"), &EdenAmbience::get_atmosphere_path);
	ClassDB::bind_method(D_METHOD("get_soundscape"), &EdenAmbience::get_soundscape);
	ClassDB::bind_method(D_METHOD("get_effect", "effect"), &EdenAmbience::get_effect);
	ClassDB::bind_method(D_METHOD("get_debug_state"), &EdenAmbience::get_debug_state);
	ClassDB::bind_method(D_METHOD("get_weather_at", "world_position"), &EdenAmbience::get_weather_at);
	ClassDB::bind_method(D_METHOD("get_snow_depth_at", "world_position"), &EdenAmbience::get_snow_depth_at);
	ClassDB::bind_method(D_METHOD("get_snow_trail_at", "world_position"), &EdenAmbience::get_snow_trail_at);
	ClassDB::bind_method(D_METHOD("press_snow", "world_position", "radius", "amount"), &EdenAmbience::press_snow);
	ClassDB::bind_method(D_METHOD("add_storm", "world_position", "radius", "intensity", "duration", "thunder", "dust"), &EdenAmbience::add_storm, DEFVAL(false), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("clear_snow_and_wetness"), &EdenAmbience::clear_snow_and_wetness);
	ClassDB::bind_method(D_METHOD("strike_lightning", "world_position", "cloud_only"), &EdenAmbience::strike_lightning, DEFVAL(Vector3()), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("cycle_weather", "step"), &EdenAmbience::cycle_weather, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("set_external_weather", "intensity", "cloud", "snow", "thunder", "fog"), &EdenAmbience::set_external_weather);
	ClassDB::bind_method(D_METHOD("get_weather_name"), &EdenAmbience::get_weather_name);
	ClassDB::bind_method(D_METHOD("get_weather_state"), &EdenAmbience::get_weather_state);
	ClassDB::bind_method(D_METHOD("set_weather_state", "state"), &EdenAmbience::set_weather_state);
	ClassDB::bind_method(D_METHOD("get_weather_texture"), &EdenAmbience::get_weather_texture);

	ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH, "planet_path", PROPERTY_HINT_NODE_PATH_VALID_TYPES, "Node3D"), "set_planet_path", "get_planet_path");
	ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH, "atmosphere_path"), "set_atmosphere_path", "get_atmosphere_path");

	String group;
#define EDEN_AMB_PROP(m_type, m_name, m_default, m_hint, m_hint_string, m_group)                                          \
	if (group != m_group) {                                                                                               \
		group = m_group;                                                                                                  \
		ADD_GROUP(group, "");                                                                                             \
	}                                                                                                                     \
	ADD_PROPERTY(PropertyInfo(Variant(m_type()).get_type(), #m_name, m_hint, m_hint_string), "set_" #m_name, "get_" #m_name);
	EDEN_AMBIENCE_PROPS(EDEN_AMB_PROP)
#undef EDEN_AMB_PROP

	BIND_ENUM_CONSTANT(FX_MOTES);
	BIND_ENUM_CONSTANT(FX_FIREFLIES);
	BIND_ENUM_CONSTANT(FX_SNOW);
	BIND_ENUM_CONSTANT(FX_RAIN);
	BIND_ENUM_CONSTANT(FX_LEAVES);
	BIND_ENUM_CONSTANT(FX_DUST);
	BIND_ENUM_CONSTANT(FX_MAX);
	BIND_ENUM_CONSTANT(WEATHER_AUTO);
	BIND_ENUM_CONSTANT(WEATHER_CLEAR);
	BIND_ENUM_CONSTANT(WEATHER_RAIN);
	BIND_ENUM_CONSTANT(WEATHER_THUNDERSTORM);
	BIND_ENUM_CONSTANT(WEATHER_SNOW);
	BIND_ENUM_CONSTANT(WEATHER_DUST_STORM);
	BIND_ENUM_CONSTANT(WEATHER_MAX);
}
