#pragma once

#include "eden_weather.h"
#include "scene/main/node.h"

// The world's roaming storms with nothing else: no planet, camera, particles or shaders. A dedicated server
// runs one of these (headless) and sends get_weather_state() to everyone, in the format EdenAmbience's
// set_weather_state() reads, so clients see the server's storms instead of simulating their own. Cells form
// anywhere (there is no climate map here) and drift the way EdenAmbience's natural cells do.
class EdenWeatherServer : public Node {
	GDCLASS(EdenWeatherServer, Node);

	EdenWeatherSim weather;
	int weather_seed = 1;
	int storm_count = 48;
	float storm_speed = 8.0f;
	float storm_min_radius = 1500.0f;
	float storm_max_radius = 6000.0f;
	float thunder_chance = 0.5f;
	float dust_storm_chance = 0.2f;
	float planet_radius = 40000.0f;
	float time_scale = 1.0f;

	void _apply_params();

protected:
	static void _bind_methods();
	void _notification(int p_what);

public:
#define EDEN_WS_PROP(m_type, m_name)                    \
	void set_##m_name(m_type p_value) { m_name = p_value; } \
	m_type get_##m_name() const { return m_name; }
	EDEN_WS_PROP(int, weather_seed)
	EDEN_WS_PROP(int, storm_count)
	EDEN_WS_PROP(float, storm_speed)
	EDEN_WS_PROP(float, storm_min_radius)
	EDEN_WS_PROP(float, storm_max_radius)
	EDEN_WS_PROP(float, thunder_chance)
	EDEN_WS_PROP(float, dust_storm_chance)
	EDEN_WS_PROP(float, planet_radius)
	EDEN_WS_PROP(float, time_scale)
#undef EDEN_WS_PROP

	// [weather_override (0 = Auto), then per natural cell: dir xyz, radius, intensity, age, life, drift, phase, flags]
	PackedFloat32Array get_weather_state();
	// Fast-forwards the storms by `p_seconds` of weather time (so a new world doesn't start with freshly formed cells)
	void warm_up(float p_seconds);
};
