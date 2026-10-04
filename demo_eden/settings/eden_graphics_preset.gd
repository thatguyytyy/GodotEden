@tool
class_name EdenGraphicsPreset
extends Resource
## One graphics quality level (Low, Medium, High, Ultra) for EdenGraphics: what it sets on the viewport and on the
## planet's nodes. Edit the presets in settings/eden_graphics_presets.tres or on the EdenGraphics node.

@export var name := "High"

@export_group("Resolution & AA")
## 3D render resolution relative to the window (the UI stays sharp)
@export_range(0.5, 1.0, 0.01) var render_scale := 1.0
## Upscaler used below 1.0: FSR 1 keeps edges crisper than bilinear
@export_enum("Bilinear", "FSR 1") var upscaler := 1
@export_enum("None", "FXAA", "MSAA 2x", "MSAA 4x") var antialiasing := 1

@export_group("Grass")
## Grass tufts per m², relative to the foliage config
@export_range(0.0, 2.0, 0.01) var grass_density := 1.0
## Grass fades out by this camera distance (m)
@export_range(15.0, 150.0, 1.0) var grass_distance := 60.0
@export_range(2, 12) var grass_blades := 7
## Past this distance (m) tufts use grass_far_blades
@export_range(0.0, 100.0, 1.0) var grass_lod_distance := 25.0
@export_range(1, 12) var grass_far_blades := 4

@export_group("Foliage")
## Trees, bushes, rocks: density relative to the config
@export_range(0.1, 2.0, 0.01) var foliage_density := 1.0
## Trees and big bushes are drawn at full detail within this distance (m), simplified beyond: the biggest lever on
## slow GPUs (near trees are 3,000-15,000 triangles each)
@export_range(0.0, 400.0, 1.0) var foliage_detail_distance := 60.0
## Detail of the voxelized far trees (triangles grow with its square)
@export_range(0.3, 2.0, 0.05) var foliage_far_detail := 1.0
## How far trees and rocks stay visible, in metres per metre of their size
@export_range(50.0, 2000.0, 1.0) var foliage_far_visibility := 400.0

@export_group("Effects")
@export var ssao := true
@export var glow := true
## Atmosphere light shafts (EdenPlanetAtmosphere); 0 samples = off
@export_range(0, 256, 1) var light_ray_samples := 128
## Ocean screen-space reflection ray steps; 0 = no reflections
@export_range(0, 64, 1) var ocean_reflection_steps := 16
## Raymarched clouds (EdenCloudShell.volumetric) instead of the stylised layers: ~2-6 ms more at 1080p on a GTX 750 Ti
@export var volumetric_clouds := false
## Volumetric clouds: flat-sided low-poly facets or soft, smooth cloud (EdenCloudShell.vol_facet_mix)
@export_enum("Low-poly", "Smooth") var cloud_style := 0
## Volumetric clouds: raymarch samples per pixel (EdenCloudShell.vol_steps): fewer is faster, more is finer
@export_range(16, 128, 8) var cloud_steps := 48


static func make(p_name: String, values: Dictionary) -> EdenGraphicsPreset:
	var p := EdenGraphicsPreset.new()
	p.name = p_name
	for k in values:
		p.set(k, values[k])
	return p


## The shipped levels, tuned on a GTX 750 Ti at 1080p (Medium) up to a modern card (Ultra)
static func defaults() -> Array[EdenGraphicsPreset]:
	return [
		make("Low", {render_scale = 0.6, upscaler = 1, antialiasing = 0, grass_density = 0.35, grass_distance = 32.0,
				grass_blades = 4, grass_lod_distance = 12.0, grass_far_blades = 3, foliage_density = 0.7, foliage_detail_distance = 20.0, foliage_far_detail = 0.45,
				foliage_far_visibility = 200.0, ssao = false, glow = false, light_ray_samples = 0, ocean_reflection_steps = 0}),
		make("Medium", {render_scale = 0.77, upscaler = 1, antialiasing = 1, grass_density = 0.6, grass_distance = 45.0,
				grass_blades = 5, grass_lod_distance = 18.0, grass_far_blades = 3, foliage_density = 0.85, foliage_detail_distance = 35.0, foliage_far_detail = 0.6,
				foliage_far_visibility = 300.0, ssao = false, glow = true, light_ray_samples = 64, ocean_reflection_steps = 8}),
		make("High", {render_scale = 1.0, upscaler = 1, antialiasing = 1, grass_density = 1.0, grass_distance = 60.0,
				grass_blades = 7, grass_lod_distance = 25.0, grass_far_blades = 4, foliage_density = 1.0, foliage_detail_distance = 60.0, foliage_far_detail = 1.0,
				foliage_far_visibility = 400.0, ssao = true, glow = true, light_ray_samples = 128, ocean_reflection_steps = 16}),
		make("Ultra", {render_scale = 1.0, upscaler = 1, antialiasing = 2, grass_density = 1.3, grass_distance = 85.0,
				grass_blades = 7, grass_lod_distance = 35.0, grass_far_blades = 5, foliage_density = 1.0, foliage_detail_distance = 110.0, foliage_far_detail = 1.2,
				foliage_far_visibility = 650.0, ssao = true, glow = true, light_ray_samples = 128, ocean_reflection_steps = 24, volumetric_clouds = true}),
	]
