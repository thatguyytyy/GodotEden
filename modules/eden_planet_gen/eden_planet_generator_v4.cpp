#include "eden_planet_generator_v4.h"

#include "modules/voxel/storage/mixel4.h"
#include "modules/voxel/thirdparty/fast_noise/FastNoiseLite.h"
#include "modules/voxel/storage/voxel_buffer.h"
#include "modules/voxel/util/io/log.h"
#include "modules/voxel/util/noise/voxel_terrain_noise.h"
#include "modules/voxel/util/profiling.h"

#include <cfloat>
#include <climits>
#include <cstddef>
#include <vector>

using namespace zylann::voxel;
using Parameters = EdenPlanetGeneratorV4::Parameters;

namespace {

inline float ss(float e0, float e1, float x) {
	const float t = CLAMP((x - e0) / (e1 - e0), 0.0f, 1.0f);
	return t * t * (3.0f - 2.0f * t);
}

// Per-thread scratch, reused across blocks
struct SurfaceBuffers {
	std::vector<float> height, ridge, erosion, landform;
	std::vector<float> radial, temperature, moisture, normalized_height, zeros;
	std::vector<float> biome, ocean, coast, river, vegetation, desert, tundra, mountain, snow;

	void resize_heights(size_t n) {
		height.resize(n);
		ridge.resize(n);
		erosion.resize(n);
		landform.resize(n);
	}
	void resize_climate(size_t n) {
		for (std::vector<float> *v : { &radial, &temperature, &moisture, &normalized_height, &zeros, &biome, &ocean,
					 &coast, &river, &vegetation, &desert, &tundra, &mountain, &snow }) {
			v->resize(n);
		}
		std::fill(zeros.begin(), zeros.end(), 0.0f);
	}
};

TerrainHeightParams make_height_params(const Parameters &p) {
	TerrainHeightParams hp = make_default_terrain_height_params();
	hp.seed = p.seed;
	hp.amplitude = p.terrain_amplitude;
	hp.feature_scale = MAX(p.terrain_feature_scale, 1.0f);
	hp.lacunarity = p.terrain_lacunarity;
	hp.gain = p.terrain_gain;
	hp.aesthetic_bias = p.terrain_aesthetic_bias;
	hp.num_octaves = CLAMP(p.terrain_octaves, 1, 16);
	hp.planet_radius = p.planet_radius;
	hp.shaping.warp_strength = p.warp_strength;
	hp.shaping.warp_scale = p.warp_scale;
	hp.shaping.mountain_blend = p.mountain_blend;
	hp.shaping.mountain_scale = p.mountain_scale;
	hp.shaping.continent_blend = p.continent_blend;
	hp.shaping.continent_scale = p.continent_scale;
	hp.shaping.island_bias = p.island_bias;
	hp.shaping.canyon_blend = p.canyon_blend;
	hp.shaping.canyon_scale = p.canyon_scale;
	hp.shaping.terrace_strength = p.terrace_strength;
	hp.shaping.terrace_count = p.terrace_count;
	return hp;
}

TerrainErosionParams make_erosion_params(const Parameters &p) {
	TerrainErosionParams ep = make_default_terrain_erosion_params();
	ep.seed = p.seed + 7919;
	ep.planet_radius = p.planet_radius;
	ep.tile_size = MAX(p.erosion_tile_size, 1.0f);
	ep.strength = p.erosion_strength;
	ep.detail = MAX(p.erosion_detail, 0.01f);
	ep.octaves = CLAMP(p.erosion_octaves, 0, 12);
	// Centered relief: the shader default -0.65 sinks everything by ~0.65 * magnitude (~660 m); V4 sets land coverage
	// with terrain_base_height instead
	ep.height_offset = 0.0f;
	return ep;
}

// Relief used to normalize climate
float get_climate_amplitude(const Parameters &p) {
	return MAX(p.terrain_amplitude + p.terrain_base_height, 1.0f);
}

// Worst-case |height|, for culling blocks away from the surface
float get_max_relief(const Parameters &p, const TerrainErosionParams &ep) {
	float r = Math::abs(p.terrain_amplitude) + Math::abs(p.terrain_base_height) + Math::abs(p.sea_level);
	if (p.use_erosion) {
		r += get_terrain_erosion_max_height(ep) * Math::abs(p.erosion_height_scale);
	}
	return r + 64.0f;
}

// Pass 1, every voxel: height (m relative to planet_radius), ridge (-1..1), erosion (0..1)
// No PlanetTectonics: probed along 2.5 m steps, oceanic_s / bias_s / border_dist_rad / boundary types jump by up to
// 0.13 / 93 m / 2.4 km between Voronoi cells, and falloff_s is ~0 almost everywhere (99th percentile 0.03), so any
// uplift driven by them makes cliffs. ponytail: bake tectonics into a smooth field (e.g. filtered cubemap) to bring
// plates back.
void compute_heights(
		const Parameters &p, const float *x, const float *y, const float *z, unsigned int count, SurfaceBuffers &b) {
	b.resize_heights(count);
	float *h = b.height.data();

	terrain_height_3d_series(x, y, z, h, count, make_height_params(p));
	for (unsigned int i = 0; i < count; ++i) {
		h[i] += p.terrain_base_height - p.planet_radius;
	}

	// Landform regions. Noise is sampled on the planet_radius sphere: heights must depend on direction only (the
	// lattice path in generate_on_lattice relies on it)
	float *lf = b.landform.data();
	if (p.landforms_enabled) {
		fast_noise_lite::FastNoiseLite regions;
		regions.SetSeed(p.seed + 3571);
		regions.SetNoiseType(fast_noise_lite::FastNoiseLite::NoiseType_OpenSimplex2);
		regions.SetFractalType(fast_noise_lite::FastNoiseLite::FractalType_FBm);
		regions.SetFractalOctaves(3);
		regions.SetFrequency(1.0f / MAX(p.landform_scale, 1.0f));
		fast_noise_lite::FastNoiseLite valleys;
		valleys.SetSeed(p.seed + 6247);
		valleys.SetNoiseType(fast_noise_lite::FastNoiseLite::NoiseType_OpenSimplex2);
		valleys.SetFractalType(fast_noise_lite::FastNoiseLite::FractalType_FBm);
		valleys.SetFractalOctaves(2);
		valleys.SetFrequency(1.0f / MAX(p.valley_scale, 1.0f));
		// 3-octave fBm sits mostly in [-0.5, 0.5]: map coverage to a threshold in that band
		const float threshold = Math::lerp(0.45f, -0.45f, CLAMP(p.mountain_coverage, 0.0f, 1.0f));
		for (unsigned int i = 0; i < count; ++i) {
			const float inv_len = p.planet_radius / MAX(Math::sqrt(x[i] * x[i] + y[i] * y[i] + z[i] * z[i]), 1e-3f);
			const float sx = x[i] * inv_len, sy = y[i] * inv_len, sz = z[i] * inv_len;
			// A wide band: foothills between plains and ranges. At +-0.1 ranges rose as walls straight out of the plain
			const float m = ss(threshold - 0.25f, threshold + 0.25f, regions.GetNoise(sx, sy, sz));
			lf[i] = m;
			const float above_sea = h[i] - p.sea_level;
			if (above_sea > 0.0f) {
				// Scaling relief above sea level keeps coastlines where they were
				h[i] = p.sea_level + above_sea * Math::lerp(p.lowland_relief, 1.0f, m);
			}
			// Valleys along the zero set of the valley noise: U-shaped channels, fading at the coast and in ranges
			const float v = Math::abs(valleys.GetNoise(sx, sy, sz));
			const float channel = 1.0f - ss(0.0f, MAX(p.valley_width, 1e-4f), v);
			h[i] -= p.valley_depth * channel * (1.0f - m) * ss(0.0f, 60.0f, h[i] - p.sea_level);
		}
	} else {
		std::fill(b.landform.begin(), b.landform.end(), 1.0f);
	}

	if (p.use_erosion) {
		// Erosion writes its relief into a temp, then only lands on dry ground
		b.radial.resize(count);
		planet_erosion_series(x, y, z, b.radial.data(), b.ridge.data(), b.erosion.data(), count, make_erosion_params(p));
		for (unsigned int i = 0; i < count; ++i) {
			const float above_sea = h[i] - p.sea_level;
			// Continental shelf fades it out so ocean floors stay smooth; the eroded relief is where mountains come from,
			// so lowlands only get a fraction of it
			const float mask = ss(-400.0f, 100.0f, above_sea) * Math::lerp(p.lowland_erosion, 1.0f, lf[i]);
			h[i] += b.radial[i] * p.erosion_height_scale * mask;
			b.ridge[i] *= mask;
			b.erosion[i] = Math::lerp(0.5f, b.erosion[i], mask);
		}
	} else {
		std::fill(b.ridge.begin(), b.ridge.end(), 0.0f);
		std::fill(b.erosion.begin(), b.erosion.end(), 0.5f);
	}

	// Rugged: crags on dry ground. Ridged fBm (sharp crests, creased gullies) at rock-outcrop scale, full in mountain
	// regions and a touch in lowlands, so slopes break up into rock instead of one smooth ramp. (Terraced ledges were
	// tried first and rejected: they read as man-made steps.) Direction-only noise (the lattice path).
	if (p.rugged_strength > 0.0f && p.rugged_height > 0.0f) {
		fast_noise_lite::FastNoiseLite crags;
		crags.SetSeed(p.seed + 8761);
		crags.SetNoiseType(fast_noise_lite::FastNoiseLite::NoiseType_OpenSimplex2);
		crags.SetFractalType(fast_noise_lite::FastNoiseLite::FractalType_Ridged);
		crags.SetFractalOctaves(4);
		crags.SetFractalLacunarity(2.1f);
		crags.SetFractalGain(0.5f);
		crags.SetFrequency(1.0f / MAX(p.rugged_scale, 1.0f));
		// Bends the crests so they don't run in straight lines
		crags.SetDomainWarpType(fast_noise_lite::FastNoiseLite::DomainWarpType_OpenSimplex2);
		crags.SetDomainWarpAmp(p.rugged_scale * 0.35f);
		for (unsigned int i = 0; i < count; ++i) {
			const float above_sea = h[i] - p.sea_level;
			const float strength = p.rugged_strength * Math::lerp(p.rugged_lowland, 1.0f, lf[i]) * ss(4.0f, 60.0f, above_sea);
			if (strength <= 0.0f) {
				continue;
			}
			const float inv_len = p.planet_radius / MAX(Math::sqrt(x[i] * x[i] + y[i] * y[i] + z[i] * z[i]), 1e-3f);
			float sx = x[i] * inv_len, sy = y[i] * inv_len, sz = z[i] * inv_len;
			crags.DomainWarp(sx, sy, sz);
			h[i] += p.rugged_height * strength * crags.GetNoise(sx, sy, sz);
		}
	}
}

// Pass 2, near-surface voxels only: climate and biome masks from final heights
void compute_climate(const Parameters &p, const float *x, const float *y, const float *z, const float *height,
		unsigned int count, SurfaceBuffers &b) {
	b.resize_climate(count);
	for (unsigned int i = 0; i < count; ++i) {
		b.radial[i] = p.planet_radius + height[i];
	}
	const float amplitude = get_climate_amplitude(p);

	TerrainClimateParams cp = make_default_terrain_climate_params();
	cp.seed = p.seed + 104729;
	cp.amplitude = amplitude;
	cp.sea_level = CLAMP(p.sea_level / amplitude, -1.0f, 1.0f);
	cp.climate_scale = MAX(p.climate_scale, 1.0f);
	cp.elevation_cooling = p.elevation_cooling;
	cp.temperature_variation = p.temperature_variation;
	cp.planet_radius = p.planet_radius;
	terrain_climate_3d_series(x, y, z, b.radial.data(), b.temperature.data(), b.moisture.data(),
			b.normalized_height.data(), count, cp);
	if (p.temperature_offset != 0.0f || p.moisture_offset != 0.0f) {
		for (unsigned int i = 0; i < count; ++i) {
			b.temperature[i] = CLAMP(b.temperature[i] + p.temperature_offset, 0.0f, 1.0f);
			b.moisture[i] = CLAMP(b.moisture[i] + p.moisture_offset, 0.0f, 1.0f);
		}
	}

	terrain_material_blend_series(b.normalized_height.data(), b.temperature.data(), b.moisture.data(), b.zeros.data(),
			b.biome.data(), b.ocean.data(), b.coast.data(), b.river.data(), b.vegetation.data(), b.desert.data(),
			b.tundra.data(), b.mountain.data(), b.snow.data(), count, cp.sea_level * 0.5f + 0.5f, p.biome_contrast);
}

struct Mixel4 {
	uint16_t indices;
	uint16_t weights;
};

// Picks the 4 strongest of MAT_COUNT weights
Mixel4 encode_materials(const float *w) {
	int order[EdenPlanetGeneratorV4::MAT_COUNT];
	for (int i = 0; i < EdenPlanetGeneratorV4::MAT_COUNT; ++i) {
		order[i] = i;
	}
	for (int i = 0; i < 4; ++i) {
		for (int j = i + 1; j < EdenPlanetGeneratorV4::MAT_COUNT; ++j) {
			if (w[order[j]] > w[order[i]]) {
				SWAP(order[i], order[j]);
			}
		}
	}
	const float sum = MAX(w[order[0]] + w[order[1]] + w[order[2]] + w[order[3]], 1e-6f);
	uint8_t q[4];
	for (int i = 0; i < 4; ++i) {
		q[i] = uint8_t(CLAMP(w[order[i]] / sum * 255.0f + 0.5f, 0.0f, 255.0f));
	}
	return Mixel4{ zylann::voxel::mixel4::encode_indices_to_packed_u16(order[0], order[1], order[2], order[3]),
		zylann::voxel::mixel4::encode_weights_to_packed_u16_lossy(q[0], q[1], q[2], q[3]) };
}

inline uint8_t unorm8(float v) {
	return uint8_t(CLAMP(v * 255.0f + 0.5f, 0.0f, 255.0f));
}

// Layout documented in eden_planet_generator_v4.h
inline uint32_t pack_surface_data(float erosion, float ridge, float moisture, float temperature) {
	return uint32_t(unorm8(erosion)) | (uint32_t(unorm8(ridge * 0.5f + 0.5f)) << 8) |
			(uint32_t(unorm8(moisture)) << 16) | (uint32_t(unorm8(temperature)) << 24);
}

void compute_material_weights(const Parameters &p, const SurfaceBuffers &b, unsigned int i, float ridge, float *w) {
	const float ocean = b.ocean[i];
	const float land = 1.0f - ocean;
	const float snow = b.snow[i];
	const float rock = CLAMP(b.mountain[i] * (1.0f - snow) + MAX(ridge, 0.0f) * p.ridge_rock_strength * land, 0.0f, 1.0f);
	const float sediment = CLAMP(MAX(-ridge, 0.0f) * p.gully_sediment_strength * land, 0.0f, 1.0f);

	w[EdenPlanetGeneratorV4::MAT_OCEAN_FLOOR] = ocean;
	w[EdenPlanetGeneratorV4::MAT_SNOW] = snow;
	// The climate kernel's coast mask is "lowest ~10% of the normalized relief". With flattened lowlands that covered
	// half the land in beach sand; only the metres right above the sea are coast
	const float above_sea = b.radial[i] - p.planet_radius - p.sea_level;
	const float coast = b.coast[i] * (1.0f - ss(3.0f, 12.0f, above_sea));
	w[EdenPlanetGeneratorV4::MAT_SAND] = MAX(coast, b.desert[i]) * (1.0f - snow);
	w[EdenPlanetGeneratorV4::MAT_ROCK] = rock * (1.0f - snow);
	w[EdenPlanetGeneratorV4::MAT_DIRT] = MAX(sediment, b.tundra[i] * 0.5f) * (1.0f - snow);
	w[EdenPlanetGeneratorV4::MAT_MOSS] = b.vegetation[i] * ss(0.62f, 0.9f, b.moisture[i]) * (1.0f - rock);
	float others = 0.0f;
	for (int m = 1; m < EdenPlanetGeneratorV4::MAT_COUNT; ++m) {
		others += w[m];
	}
	w[EdenPlanetGeneratorV4::MAT_GRASS] = land * MAX(1.0f - others, 0.05f);
}

// Transvoxel only reads materials in cells crossing the surface; the band covers slopes up to ~10:1
inline float get_material_band_width(int step) {
	return float(step) * 12.0f + 16.0f;
}

// Every surface attribute is a function of direction only: each noise stage normalizes its input position. So they are
// evaluated on a lattice of directions, a few nodes per voxel footprint at this LOD, then interpolated per voxel: about
// 4 * size^2 noise evaluations instead of size^3. Each voxel picks its cube face and lattice cell from its own position and
// the lattice depends only on the LOD, so a voxel shared by neighboring blocks gets the same value in each (no seams).
// Returns false when the lattice would not save work (blocks spanning a wide cone of directions, near the core).
bool generate_on_lattice(const Parameters &p, VoxelBuffer &buffer, const Vector3i size, const int step, const float *px,
		const float *py, const float *pz, bool write_surface_data) {
	const unsigned int count = size.x * size.y * size.z;
	// Lattice nodes per voxel footprint. Bilinear error falls with its square: at 1, coarse LODs were off by up to half a
	// voxel near steep relief
	const float nodes_per_voxel = 2.0f;
	// Equal-angle cube map (u = angle on the face, not tan of it): node spacing on the sphere stays within ~1.4x across a
	// face, where the plain gnomonic map crowds nodes 3x toward the edges and blew the node budget there
	const float inv_du = p.planet_radius * nodes_per_voxel / float(step);

	struct Rect {
		int u0 = INT_MAX, v0 = INT_MAX, u1 = INT_MIN, v1 = INT_MIN;
		int w = 0;
		unsigned int base = 0;
	};
	Rect rects[6];
	thread_local std::vector<uint8_t> vface;
	thread_local std::vector<float> vu, vv;
	vface.resize(count);
	vu.resize(count);
	vv.resize(count);
	float min_r = FLT_MAX;
	float max_r = 0.0f;
	for (unsigned int i = 0; i < count; ++i) {
		const float c[3] = { px[i], py[i], pz[i] };
		const int a = Math::abs(c[0]) >= Math::abs(c[1]) && Math::abs(c[0]) >= Math::abs(c[2])
				? 0
				: (Math::abs(c[1]) >= Math::abs(c[2]) ? 1 : 2);
		const float major = Math::abs(c[a]);
		if (major == 0.0f) {
			return false;
		}
		const int face = a * 2 + (c[a] < 0.0f ? 1 : 0);
		const float fu = Math::atan(c[(a + 1) % 3] / major) * inv_du;
		const float fv = Math::atan(c[(a + 2) % 3] / major) * inv_du;
		vface[i] = face;
		vu[i] = fu;
		vv[i] = fv;
		Rect &r = rects[face];
		const int iu = int(Math::floor(fu));
		const int iv = int(Math::floor(fv));
		r.u0 = MIN(r.u0, iu);
		r.u1 = MAX(r.u1, iu + 1);
		r.v0 = MIN(r.v0, iv);
		r.v1 = MAX(r.v1, iv + 1);
		const float rad = Math::sqrt(c[0] * c[0] + c[1] * c[1] + c[2] * c[2]);
		min_r = MIN(min_r, rad);
		max_r = MAX(max_r, rad);
	}

	int64_t total = 0;
	for (Rect &r : rects) {
		if (r.u0 > r.u1) {
			continue;
		}
		r.w = r.u1 - r.u0 + 1;
		r.base = static_cast<unsigned int>(total);
		total += int64_t(r.w) * (r.v1 - r.v0 + 1);
	}
	// A node costs about what a voxel does on the exact path
	if (total > count / 2) {
		return false;
	}
	const unsigned int node_count = static_cast<unsigned int>(total);

	thread_local std::vector<float> nx, ny, nz;
	thread_local SurfaceBuffers nsb;
	nx.resize(node_count);
	ny.resize(node_count);
	nz.resize(node_count);
	for (int face = 0; face < 6; ++face) {
		const Rect &r = rects[face];
		if (r.w == 0) {
			continue;
		}
		const int a = face / 2;
		const float s = (face & 1) ? -1.0f : 1.0f;
		unsigned int n = r.base;
		for (int v = r.v0; v <= r.v1; ++v) {
			for (int u = r.u0; u <= r.u1; ++u) {
				float d[3];
				d[a] = s;
				d[(a + 1) % 3] = Math::tan(float(u) / inv_du);
				d[(a + 2) % 3] = Math::tan(float(v) / inv_du);
				const float k = p.planet_radius / Math::sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
				nx[n] = d[0] * k;
				ny[n] = d[1] * k;
				nz[n] = d[2] * k;
				++n;
			}
		}
	}
	compute_heights(p, nx.data(), ny.data(), nz.data(), node_count, nsb);

	// Interpolated heights stay within the node range, so a block entirely above or below it has no surface
	float min_h = FLT_MAX;
	float max_h = -FLT_MAX;
	for (unsigned int n = 0; n < node_count; ++n) {
		min_h = MIN(min_h, nsb.height[n]);
		max_h = MAX(max_h, nsb.height[n]);
	}
	const float min_alt = min_r - p.planet_radius;
	const float max_alt = max_r - p.planet_radius;
	if (min_alt > max_h && !(p.bake_ocean_water && min_alt <= p.sea_level)) {
		buffer.clear_channel_f(VoxelBuffer::CHANNEL_SDF, 100.0f);
		return true;
	}
	if (max_alt < min_h) {
		buffer.clear_channel_f(VoxelBuffer::CHANNEL_SDF, -100.0f);
		return true;
	}

	compute_climate(p, nx.data(), ny.data(), nz.data(), nsb.height.data(), node_count, nsb);
	thread_local std::vector<Mixel4> node_mix;
	thread_local std::vector<uint32_t> node_data;
	node_mix.resize(node_count);
	node_data.resize(node_count);
	for (unsigned int n = 0; n < node_count; ++n) {
		float w[EdenPlanetGeneratorV4::MAT_COUNT];
		compute_material_weights(p, nsb, n, nsb.ridge[n], w);
		node_mix[n] = encode_materials(w);
		node_data[n] = pack_surface_data(nsb.erosion[n], nsb.ridge[n], nsb.moisture[n], nsb.temperature[n]);
	}

	const float band_width = get_material_band_width(step);
	unsigned int i = 0;
	for (int z = 0; z < size.z; ++z) {
		for (int y = 0; y < size.y; ++y) {
			for (int x = 0; x < size.x; ++x) {
				const Rect &r = rects[vface[i]];
				const float fu = vu[i];
				const float fv = vv[i];
				const int iu = int(Math::floor(fu));
				const int iv = int(Math::floor(fv));
				const float tu = fu - iu;
				const float tv = fv - iv;
				const unsigned int n00 = r.base + (iv - r.v0) * r.w + (iu - r.u0);
				const unsigned int n01 = n00 + r.w;
				const float *h = nsb.height.data();
				const float height = Math::lerp(Math::lerp(h[n00], h[n00 + 1], tu), Math::lerp(h[n01], h[n01 + 1], tu), tv);

				const float alt = Math::sqrt(px[i] * px[i] + py[i] * py[i] + pz[i] * pz[i]) - p.planet_radius;
				const float sdf = alt - height;
				buffer.set_voxel_f(sdf, x, y, z, VoxelBuffer::CHANNEL_SDF);
				if (p.bake_ocean_water && sdf > 0.0f && alt <= p.sea_level && height < p.sea_level) {
					buffer.set_voxel_f(1.0f, x, y, z, VoxelBuffer::CHANNEL_DATA5);
				}
				if (Math::abs(sdf) < band_width) {
					// Nearest node: material indices don't interpolate
					const unsigned int n = (tv < 0.5f ? n00 : n01) + (tu < 0.5f ? 0 : 1);
					buffer.set_voxel(node_mix[n].indices, x, y, z, VoxelBuffer::CHANNEL_INDICES);
					buffer.set_voxel(node_mix[n].weights, x, y, z, VoxelBuffer::CHANNEL_WEIGHTS);
					if (write_surface_data) {
						buffer.set_voxel(node_data[n], x, y, z, VoxelBuffer::CHANNEL_DATA6);
					}
				}
				++i;
			}
		}
	}
	return true;
}

} // namespace

Parameters EdenPlanetGeneratorV4::get_parameters() const {
	zylann::RWLockRead rlock(_parameters_lock);
	return _parameters;
}

void EdenPlanetGeneratorV4::generate_series(
		zylann::Span<const float> positions_x,
		zylann::Span<const float> positions_y,
		zylann::Span<const float> positions_z,
		unsigned int channel,
		zylann::Span<float> out_values,
		zylann::Vector3f min_pos,
		zylann::Vector3f max_pos
) {
	ZN_PROFILE_SCOPE();

	const unsigned int count = positions_x.size();
	if (count == 0) {
		return;
	}

	// SDF is the only channel this can answer. The materials this generator
	// writes are MIXEL4, packed index and weight pairs in two integer channels,
	// and a series call returns one float array -- there is no meaningful way to
	// express them here. Callers that need materials must go through
	// generate_block.
	if (channel != zylann::voxel::VoxelBuffer::CHANNEL_SDF) {
		ZN_PRINT_ERROR_ONCE("EdenPlanetGeneratorV4::generate_series only supports CHANNEL_SDF");
		for (unsigned int i = 0; i < count; ++i) {
			out_values[i] = 0.0f;
		}
		return;
	}

	const Parameters p = get_parameters();

	thread_local SurfaceBuffers sb;
	compute_heights(p, positions_x.data(), positions_y.data(), positions_z.data(), count, sb);

	// Same formula generate_block uses: altitude above the reference sphere,
	// minus the terrain height at that direction. Note there is no half-step
	// offset here -- the caller gives exact points rather than cell corners.
	for (unsigned int i = 0; i < count; ++i) {
		const float x = positions_x[i];
		const float y = positions_y[i];
		const float z = positions_z[i];
		const float alt = Math::sqrt(x * x + y * y + z * z) - p.planet_radius;
		out_values[i] = alt - sb.height[i];
	}
}

VoxelGenerator::Result EdenPlanetGeneratorV4::generate_block(VoxelQueryData input) {
	Result result;
	const Parameters p = get_parameters();

	VoxelBuffer &buffer = input.voxel_buffer;
	const Vector3i origin = input.origin_in_voxels;
	const Vector3i size = buffer.get_size();
	const int step = 1 << input.lod;
	const float half_step = step * 0.5f;

	const TerrainErosionParams ep = make_erosion_params(p);
	const float max_relief = get_max_relief(p, ep);
	float rock_w[MAT_COUNT] = { 0, 1, 0, 0, 0, 0, 0 };
	const Mixel4 rock = encode_materials(rock_w);

	// Cull blocks entirely inside or outside the relief shell
	{
		const float block_world_size = float(size.x * step);
		const Vector3 center = Vector3(origin.x, origin.y, origin.z) + Vector3(1, 1, 1) * (block_world_size * 0.5f);
		const float half_diag = block_world_size * 0.8660254f;
		const float dist = center.length();
		if (dist + half_diag < p.planet_radius - max_relief) {
			buffer.clear_channel_f(VoxelBuffer::CHANNEL_SDF, -100.0f);
			buffer.clear_channel(VoxelBuffer::CHANNEL_INDICES, rock.indices);
			buffer.clear_channel(VoxelBuffer::CHANNEL_WEIGHTS, rock.weights);
			result.max_lod_hint = true;
			return result;
		}
		if (dist - half_diag > p.planet_radius + max_relief) {
			buffer.clear_channel_f(VoxelBuffer::CHANNEL_SDF, 100.0f);
			result.max_lod_hint = true;
			return result;
		}
	}

	const unsigned int count = size.x * size.y * size.z;
	thread_local std::vector<float> px, py, pz;
	thread_local std::vector<float> bx, by, bz, bh;
	thread_local std::vector<unsigned int> band;
	thread_local SurfaceBuffers sb;

	px.resize(count);
	py.resize(count);
	pz.resize(count);
	{
		unsigned int i = 0;
		for (int z = 0; z < size.z; ++z) {
			for (int y = 0; y < size.y; ++y) {
				for (int x = 0; x < size.x; ++x) {
					px[i] = float(origin.x) + x * step + half_step;
					py[i] = float(origin.y) + y * step + half_step;
					pz[i] = float(origin.z) + z * step + half_step;
					++i;
				}
			}
		}
	}

	const bool write_surface_data = buffer.get_channel_depth(VoxelBuffer::CHANNEL_DATA6) == VoxelBuffer::DEPTH_32_BIT;
	buffer.clear_channel(VoxelBuffer::CHANNEL_INDICES, rock.indices);
	buffer.clear_channel(VoxelBuffer::CHANNEL_WEIGHTS, rock.weights);
	if (write_surface_data) {
		buffer.clear_channel(VoxelBuffer::CHANNEL_DATA6, pack_surface_data(0.5f, 0.0f, 0.5f, 0.5f));
	}

	if (generate_on_lattice(p, buffer, size, step, px.data(), py.data(), pz.data(), write_surface_data)) {
		return result;
	}

	// Exact path, one evaluation per voxel
	compute_heights(p, px.data(), py.data(), pz.data(), count, sb);
	const float band_width = get_material_band_width(step);
	band.clear();
	bx.clear();
	by.clear();
	bz.clear();
	bh.clear();

	{
		unsigned int i = 0;
		for (int z = 0; z < size.z; ++z) {
			for (int y = 0; y < size.y; ++y) {
				for (int x = 0; x < size.x; ++x) {
					const float alt = Math::sqrt(px[i] * px[i] + py[i] * py[i] + pz[i] * pz[i]) - p.planet_radius;
					const float sdf = alt - sb.height[i];
					buffer.set_voxel_f(sdf, x, y, z, VoxelBuffer::CHANNEL_SDF);
					if (p.bake_ocean_water && sdf > 0.0f && alt <= p.sea_level && sb.height[i] < p.sea_level) {
						buffer.set_voxel_f(1.0f, x, y, z, VoxelBuffer::CHANNEL_DATA5);
					}
					if (Math::abs(sdf) < band_width) {
						band.push_back(i);
						bx.push_back(px[i]);
						by.push_back(py[i]);
						bz.push_back(pz[i]);
						bh.push_back(sb.height[i]);
					}
					++i;
				}
			}
		}
	}

	if (band.empty()) {
		return result;
	}

	// Pass 2 only resizes climate buffers, pass 1 ridge/erosion stay valid (indexed by voxel)
	compute_climate(p, bx.data(), by.data(), bz.data(), bh.data(), band.size(), sb);

	const unsigned int area = size.x * size.y;
	for (size_t k = 0; k < band.size(); ++k) {
		const unsigned int i = band[k];
		const int z = i / area;
		const int y = (i % area) / size.x;
		const int x = i % size.x;

		float w[MAT_COUNT];
		compute_material_weights(p, sb, k, sb.ridge[i], w);
		const Mixel4 m = encode_materials(w);
		buffer.set_voxel(m.indices, x, y, z, VoxelBuffer::CHANNEL_INDICES);
		buffer.set_voxel(m.weights, x, y, z, VoxelBuffer::CHANNEL_WEIGHTS);
		if (write_surface_data) {
			buffer.set_voxel(pack_surface_data(sb.erosion[i], sb.ridge[i], sb.moisture[k], sb.temperature[k]), x, y, z,
					VoxelBuffer::CHANNEL_DATA6);
		}
	}

	return result;
}

int EdenPlanetGeneratorV4::get_used_channels_mask() const {
	return (1 << VoxelBuffer::CHANNEL_SDF) | (1 << VoxelBuffer::CHANNEL_INDICES) | (1 << VoxelBuffer::CHANNEL_WEIGHTS) |
			(1 << VoxelBuffer::CHANNEL_DATA5) | (1 << VoxelBuffer::CHANNEL_DATA6);
}

Dictionary EdenPlanetGeneratorV4::sample_surface(Vector3 direction) const {
	const Parameters p = get_parameters();
	const Vector3 pos = direction.normalized() * p.planet_radius;
	const float x = pos.x, y = pos.y, z = pos.z;
	SurfaceBuffers b;
	compute_heights(p, &x, &y, &z, 1, b);
	const float height = b.height[0];
	const float ridge = b.ridge[0];
	const float erosion = b.erosion[0];
	compute_climate(p, &x, &y, &z, &height, 1, b);

	Dictionary d;
	d["height"] = height;
	d["ridge"] = ridge;
	d["erosion"] = erosion;
	d["temperature"] = b.temperature[0];
	d["moisture"] = b.moisture[0];
	d["biome_id"] = int(b.biome[0]);
	d["landform"] = b.landform[0]; // 0 lowland .. 1 mountain range
	float w[MAT_COUNT];
	compute_material_weights(p, b, 0, ridge, w);
	int dominant = 0;
	for (int m = 1; m < MAT_COUNT; ++m) {
		dominant = w[m] > w[dominant] ? m : dominant;
	}
	d["material"] = dominant; // MAT_*
	return d;
}

// Properties ----------------------------------------------------------------------------------------------------------

namespace {

enum PropKind { PK_GROUP, PK_FLOAT, PK_INT, PK_BOOL };

struct PropDef {
	const char *name;
	PropKind kind;
	size_t offset;
	const char *hint_range;
};

#define V4_GROUP(label) { label, PK_GROUP, 0, "" }
#define V4_PROP(name, kind, hint) { #name, kind, offsetof(Parameters, name), hint }

const PropDef g_prop_defs[] = {
	V4_GROUP("Planet"),
	V4_PROP(planet_radius, PK_FLOAT, "100,1000000,1,or_greater"),
	V4_PROP(seed, PK_INT, ""),
	V4_PROP(sea_level, PK_FLOAT, "-5000,5000,1"),
	V4_PROP(bake_ocean_water, PK_BOOL, ""),
	V4_GROUP("Terrain"),
	V4_PROP(terrain_base_height, PK_FLOAT, "-5000,5000,1"),
	V4_PROP(terrain_amplitude, PK_FLOAT, "0,20000,1"),
	V4_PROP(terrain_feature_scale, PK_FLOAT, "10,200000,1"),
	V4_PROP(terrain_octaves, PK_INT, "1,16,1"),
	V4_PROP(terrain_lacunarity, PK_FLOAT, "1,4,0.01"),
	V4_PROP(terrain_gain, PK_FLOAT, "0,1,0.01"),
	V4_PROP(terrain_aesthetic_bias, PK_FLOAT, "0,1,0.01"),
	V4_PROP(warp_strength, PK_FLOAT, "0,20000,1"),
	V4_PROP(warp_scale, PK_FLOAT, "10,200000,1"),
	V4_PROP(mountain_blend, PK_FLOAT, "0,1,0.01"),
	V4_PROP(mountain_scale, PK_FLOAT, "10,200000,1"),
	V4_PROP(continent_blend, PK_FLOAT, "0,1,0.01"),
	V4_PROP(continent_scale, PK_FLOAT, "10,500000,1"),
	V4_PROP(island_bias, PK_FLOAT, "-1,1,0.01"),
	V4_PROP(canyon_blend, PK_FLOAT, "0,1,0.01"),
	V4_PROP(canyon_scale, PK_FLOAT, "10,200000,1"),
	V4_PROP(terrace_strength, PK_FLOAT, "0,1,0.01"),
	V4_PROP(terrace_count, PK_FLOAT, "1,64,1"),
	V4_GROUP("Landforms"),
	V4_PROP(landforms_enabled, PK_BOOL, ""),
	V4_PROP(mountain_coverage, PK_FLOAT, "0,1,0.01"),
	V4_PROP(landform_scale, PK_FLOAT, "100,200000,1"),
	V4_PROP(lowland_relief, PK_FLOAT, "0,1,0.01"),
	V4_PROP(lowland_erosion, PK_FLOAT, "0,1,0.01"),
	V4_PROP(valley_depth, PK_FLOAT, "0,1000,1"),
	V4_PROP(valley_width, PK_FLOAT, "0,0.5,0.001"),
	V4_PROP(valley_scale, PK_FLOAT, "100,100000,1"),
	V4_GROUP("Rugged"),
	V4_PROP(rugged_strength, PK_FLOAT, "0,2,0.01"),
	V4_PROP(rugged_lowland, PK_FLOAT, "0,1,0.01"),
	V4_PROP(rugged_height, PK_FLOAT, "0,200,0.5"),
	V4_PROP(rugged_scale, PK_FLOAT, "10,5000,1"),
	V4_GROUP("Erosion"),
	V4_PROP(use_erosion, PK_BOOL, ""),
	V4_PROP(erosion_height_scale, PK_FLOAT, "0,4,0.01"),
	V4_PROP(erosion_tile_size, PK_FLOAT, "100,100000,1,or_greater"),
	V4_PROP(erosion_strength, PK_FLOAT, "0,1,0.001"),
	V4_PROP(erosion_detail, PK_FLOAT, "0.01,4,0.01"),
	V4_PROP(erosion_octaves, PK_INT, "0,12,1"),
	V4_GROUP("Climate & Materials"),
	V4_PROP(climate_scale, PK_FLOAT, "10,500000,1"),
	V4_PROP(elevation_cooling, PK_FLOAT, "0,1,0.01"),
	V4_PROP(temperature_variation, PK_FLOAT, "0,1,0.01"),
	V4_PROP(biome_contrast, PK_FLOAT, "0,1,0.01"),
	V4_PROP(ridge_rock_strength, PK_FLOAT, "0,2,0.01"),
	V4_PROP(gully_sediment_strength, PK_FLOAT, "0,2,0.01"),
	V4_PROP(temperature_offset, PK_FLOAT, "-1,1,0.01"),
	V4_PROP(moisture_offset, PK_FLOAT, "-1,1,0.01"),
};

#undef V4_GROUP
#undef V4_PROP

const PropDef *find_prop(const StringName &name) {
	for (const PropDef &d : g_prop_defs) {
		if (d.kind != PK_GROUP && name == StringName(d.name)) {
			return &d;
		}
	}
	return nullptr;
}

} // namespace

bool EdenPlanetGeneratorV4::_set(const StringName &p_name, const Variant &p_value) {
	const PropDef *d = find_prop(p_name);
	if (d == nullptr) {
		return false;
	}
	{
		zylann::RWLockWrite wlock(_parameters_lock);
		char *field = reinterpret_cast<char *>(&_parameters) + d->offset;
		switch (d->kind) {
			case PK_FLOAT:
				*reinterpret_cast<float *>(field) = float(p_value);
				break;
			case PK_INT:
				*reinterpret_cast<int *>(field) = int(p_value);
				break;
			case PK_BOOL:
				*reinterpret_cast<bool *>(field) = bool(p_value);
				break;
			default:
				break;
		}
	}
	emit_changed();
	return true;
}

bool EdenPlanetGeneratorV4::_get(const StringName &p_name, Variant &r_ret) const {
	const PropDef *d = find_prop(p_name);
	if (d == nullptr) {
		return false;
	}
	zylann::RWLockRead rlock(_parameters_lock);
	const char *field = reinterpret_cast<const char *>(&_parameters) + d->offset;
	switch (d->kind) {
		case PK_FLOAT:
			r_ret = *reinterpret_cast<const float *>(field);
			break;
		case PK_INT:
			r_ret = *reinterpret_cast<const int *>(field);
			break;
		case PK_BOOL:
			r_ret = *reinterpret_cast<const bool *>(field);
			break;
		default:
			return false;
	}
	return true;
}

void EdenPlanetGeneratorV4::_get_property_list(List<PropertyInfo> *p_list) const {
	for (const PropDef &d : g_prop_defs) {
		switch (d.kind) {
			case PK_GROUP:
				p_list->push_back(PropertyInfo(Variant::NIL, d.name, PROPERTY_HINT_NONE, "", PROPERTY_USAGE_GROUP));
				break;
			case PK_FLOAT:
				p_list->push_back(PropertyInfo(Variant::FLOAT, d.name, PROPERTY_HINT_RANGE, d.hint_range));
				break;
			case PK_INT:
				p_list->push_back(PropertyInfo(
						Variant::INT, d.name, d.hint_range[0] != 0 ? PROPERTY_HINT_RANGE : PROPERTY_HINT_NONE, d.hint_range));
				break;
			case PK_BOOL:
				p_list->push_back(PropertyInfo(Variant::BOOL, d.name));
				break;
		}
	}
}

void EdenPlanetGeneratorV4::_bind_methods() {
	ClassDB::bind_method(D_METHOD("sample_surface", "direction"), &EdenPlanetGeneratorV4::sample_surface);
	ClassDB::bind_method(D_METHOD("get_planet_radius"), &EdenPlanetGeneratorV4::get_planet_radius);
	ClassDB::bind_method(D_METHOD("get_sea_level"), &EdenPlanetGeneratorV4::get_sea_level);
}
