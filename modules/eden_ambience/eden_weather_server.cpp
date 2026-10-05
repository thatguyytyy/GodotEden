#include "eden_weather_server.h"

static constexpr int WEATHER_STATE_STRIDE = 10; // must match eden_ambience.cpp

void EdenWeatherServer::_apply_params() {
	EdenWeatherSim::Params &wp = weather.params;
	if ((uint32_t)weather_seed != wp.seed) {
		wp.seed = weather_seed;
		weather.natural = -1; // reseed
	}
	wp.cell_count = storm_count;
	wp.wind_speed = storm_speed;
	wp.min_radius = storm_min_radius;
	wp.max_radius = MAX(storm_max_radius, storm_min_radius);
	wp.thunder_chance = thunder_chance;
	wp.dust_chance = dust_storm_chance;
	weather.planet_radius = planet_radius;
}

void EdenWeatherServer::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_READY: {
			set_process(true);
		} break;
		case NOTIFICATION_PROCESS: {
			_apply_params();
			weather.step((float)get_process_delta_time() * time_scale);
		} break;
	}
}

PackedFloat32Array EdenWeatherServer::get_weather_state() {
	_apply_params();
	if (weather.natural < 0) {
		weather.step(0.0f); // (seeds the natural cells)
	}
	PackedFloat32Array out;
	out.push_back(0); // weather_override: Auto
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

void EdenWeatherServer::warm_up(float p_seconds) {
	_apply_params();
	float left = MAX(p_seconds, 0.0f);
	while (left > 0.0f) {
		const float dt = MIN(left, 5.0f);
		weather.step(dt);
		left -= dt;
	}
}

void EdenWeatherServer::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_weather_state"), &EdenWeatherServer::get_weather_state);
	ClassDB::bind_method(D_METHOD("warm_up", "seconds"), &EdenWeatherServer::warm_up);
#define EDEN_WS_BIND(m_type, m_name, m_variant, m_hint)                                                            \
	ClassDB::bind_method(D_METHOD("set_" #m_name, "value"), &EdenWeatherServer::set_##m_name);                     \
	ClassDB::bind_method(D_METHOD("get_" #m_name), &EdenWeatherServer::get_##m_name);                              \
	ADD_PROPERTY(PropertyInfo(m_variant, #m_name, PROPERTY_HINT_RANGE, m_hint), "set_" #m_name, "get_" #m_name);
	EDEN_WS_BIND(int, weather_seed, Variant::INT, "0,100000,1")
	EDEN_WS_BIND(int, storm_count, Variant::INT, "0,256,1")
	EDEN_WS_BIND(float, storm_speed, Variant::FLOAT, "0.0,60.0,0.1")
	EDEN_WS_BIND(float, storm_min_radius, Variant::FLOAT, "100,50000,10")
	EDEN_WS_BIND(float, storm_max_radius, Variant::FLOAT, "100,50000,10")
	EDEN_WS_BIND(float, thunder_chance, Variant::FLOAT, "0.0,1.0,0.01")
	EDEN_WS_BIND(float, dust_storm_chance, Variant::FLOAT, "0.0,1.0,0.01")
	EDEN_WS_BIND(float, planet_radius, Variant::FLOAT, "1000,1000000,1,or_greater")
	EDEN_WS_BIND(float, time_scale, Variant::FLOAT, "0.0,100.0,0.01,or_greater")
#undef EDEN_WS_BIND
}
