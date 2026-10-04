#ifndef EDEN_PLANET_GENERATOR_V4_H
#define EDEN_PLANET_GENERATOR_V4_H

#include "modules/voxel/generators/voxel_generator.h"
#include "modules/voxel/util/thread/rw_lock.h"

// Fourth-generation planet generator, rebuilt on modules/voxel's batched terrain kernels (ISPC when
// VOXEL_ISPC_ENABLED, scalar otherwise):
//   shaped continental fBm with mountain bands (terrain_height_3d_series) -> advanced erosion filter
//   (planet_erosion_series) -> climate (terrain_climate_3d_series) -> biome masks (terrain_material_blend_series)
//   -> MIXEL4 materials + surface data.
// Every stage is continuous, so there are no cliffs from cell-based data. PlanetTectonics is deliberately not used:
// its per-point fields jump between Voronoi cells (see eden_planet_generator_v4.cpp).
//
// Channels written:
//   SDF, INDICES + WEIGHTS (MIXEL4, same MAT_* ids as V1-V3),
//   DATA5 baked ocean water (VoxelWaterSimulator::WATER_CHANNEL), if bake_ocean_water,
//   DATA6 surface data, 4 packed unorm bytes: R erosion (0.5 untouched, lower = carved),
//     G ridge (0 crease/gully .. 1 ridge), B moisture, A temperature. Needs CHANNEL_DATA6 at 32-bit in the
//     terrain's VoxelFormat; VoxelMesherTransvoxel.surface_data_enabled forwards it to shaders as CUSTOM2.
//
// Properties are table-driven (see eden_planet_generator_v4.cpp), all settable from GDScript/the inspector.
class EdenPlanetGeneratorV4 : public zylann::voxel::VoxelGenerator {
	GDCLASS(EdenPlanetGeneratorV4, zylann::voxel::VoxelGenerator);

public:
	static const int MAT_GRASS = 0;
	static const int MAT_ROCK = 1;
	static const int MAT_SNOW = 2;
	static const int MAT_SAND = 3;
	static const int MAT_DIRT = 4;
	static const int MAT_MOSS = 5;
	static const int MAT_OCEAN_FLOOR = 6;
	static const int MAT_COUNT = 7;

	struct Parameters {
		// Planet
		float planet_radius = 40000.0f;
		int seed = 12345;
		float sea_level = 0.0f; // meters, relative to planet_radius
		bool bake_ocean_water = true;
		// Terrain (continental fBm + shaping)
		// Shaped continents are centered on 0 m, this lifts them (and ocean floors) to set land coverage
		float terrain_base_height = 200.0f;
		float terrain_amplitude = 2600.0f;
		float terrain_feature_scale = 5200.0f;
		int terrain_octaves = 6;
		float terrain_lacunarity = 2.0f;
		float terrain_gain = 0.5f;
		float terrain_aesthetic_bias = 0.55f;
		float warp_strength = 900.0f;
		float warp_scale = 7000.0f;
		float mountain_blend = 0.0f;
		float mountain_scale = 14000.0f;
		float continent_blend = 0.85f;
		float continent_scale = 26000.0f;
		float island_bias = 0.05f;
		float canyon_blend = 0.0f;
		float canyon_scale = 6000.0f;
		float terrace_strength = 0.0f;
		float terrace_count = 8.0f;
		// Landforms: a low-frequency region mask (0 lowland .. 1 mountain range). Lowlands get their land relief and
		// erosion scaled down (hills, fields, plains) and shallow valley channels carved in; mountain regions keep
		// the full relief. The ridged fBm + erosion alone made ~2/3 of all land steeper than 35 degrees.
		bool landforms_enabled = true;
		float mountain_coverage = 0.3f; // approx. fraction of land that is mountain regions
		float landform_scale = 9000.0f; // size of lowland / mountain regions, m
		float lowland_relief = 0.2f; // land height multiplier in lowlands
		float lowland_erosion = 0.1f; // eroded relief multiplier in lowlands
		float valley_depth = 45.0f; // m
		float valley_width = 0.07f; // 0..1, fraction of the valley noise range
		float valley_scale = 4500.0f; // spacing of the valley network, m
		// Rugged: crags (ridged noise: sharp crests, creased gullies) on dry ground, full in mountain regions, a touch in
		// lowlands. Without them every slope was one smooth ramp.
		float rugged_strength = 1.0f; // 0 smooth .. 1 (2 = twice as craggy)
		float rugged_lowland = 0.15f; // strength multiplier in lowlands
		float rugged_height = 26.0f; // m, crest to gully at full strength (about +-)
		float rugged_scale = 140.0f; // m, size of the biggest crags (finer ones nest inside)
		// Erosion
		bool use_erosion = true;
		float erosion_height_scale = 1.5f;
		float erosion_tile_size = 16000.0f;
		float erosion_strength = 0.22f;
		float erosion_detail = 1.5f;
		int erosion_octaves = 5;
		// Climate & materials
		float climate_scale = 9000.0f;
		float elevation_cooling = 0.7f;
		float temperature_variation = 0.6f;
		float biome_contrast = 0.6f;
		float ridge_rock_strength = 0.8f;
		float gully_sediment_strength = 0.6f;
		// Whole-world climate, added to every point's temperature / moisture (0..1): colder or hotter, drier or wetter
		// worlds (the game's world settings). Everything reading climate from the generator follows: biomes,
		// materials, snow, foliage, weather.
		float temperature_offset = 0.0f;
		float moisture_offset = 0.0f;
	};

	Result generate_block(VoxelQueryData input) override;
	int get_used_channels_mask() const override;

	// Sampling at arbitrary points, not just over an axis-aligned block.
	//
	// Needed by anything that follows a surface rather than a grid: the far
	// field's radial columns (modules/voxel/far), detail normalmaps, and
	// instancing on slopes. The generator is already built on batched `_series`
	// kernels that take point arrays, so this is the same work generate_block
	// does minus the grid.
	//
	// CHANNEL_SDF only; see the implementation for why.
	bool supports_series_generation() const override {
		return true;
	}

	// NOTE: `Span` and `Vector3f` must be qualified. Godot core has a `Span` of
	// its own, and this class sits in the global namespace where the unqualified
	// names do not resolve to the ones the base class declares.
	void generate_series(
			zylann::Span<const float> positions_x,
			zylann::Span<const float> positions_y,
			zylann::Span<const float> positions_z,
			unsigned int channel,
			zylann::Span<float> out_values,
			zylann::Vector3f min_pos,
			zylann::Vector3f max_pos
	) override;

	// Surface values along a direction from the planet center: height (m, relative to planet_radius),
	// ridge, erosion, temperature, moisture, biome_id (see FCTerrainMaterialBlend).
	Dictionary sample_surface(Vector3 direction) const;

	Parameters get_parameters() const;
	float get_planet_radius() const { return get_parameters().planet_radius; }
	float get_sea_level() const { return get_parameters().sea_level; }

protected:
	bool _set(const StringName &p_name, const Variant &p_value);
	bool _get(const StringName &p_name, Variant &r_ret) const;
	void _get_property_list(List<PropertyInfo> *p_list) const;
	static void _bind_methods();

private:
	Parameters _parameters;
	mutable zylann::RWLock _parameters_lock;
};

#endif // EDEN_PLANET_GENERATOR_V4_H
