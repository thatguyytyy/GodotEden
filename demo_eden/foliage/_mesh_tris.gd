extends SceneTree
## Triangles per foliage mesh: each layer kind's near mesh (and vertices), its simplified mid mesh, and its voxelized far mesh at a few resolutions.
##   godot --headless --path demo_eden -s res://foliage/_mesh_tris.gd


static func tris(m: Mesh) -> int:
	var n := 0
	for s in m.get_surface_count():
		var a := m.surface_get_arrays(s)
		var idx = a[Mesh.ARRAY_INDEX]
		n += (idx.size() if idx is PackedInt32Array and idx.size() > 0 else a[Mesh.ARRAY_VERTEX].size()) / 3
	return n


func _initialize() -> void:
	var cfg: EdenFoliageConfig = load("res://foliage/eden_foliage_default.tres")
	var seen := {}
	for b in cfg.biomes:
		for l in b.layers:
			var kind: String = EdenFoliageLayer.kind_name(l.kind)
			if seen.has(kind) or l.is_grass():
				continue
			seen[kind] = true
			var m: Mesh = EdenFoliageMeshes.build(l, 0).mesh
			var near := tris(m)
			var verts: int = m.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() if m.get_surface_count() > 0 else 0
			var mid := tris(EdenFoliageMeshes.build_simplified(l, 0, 0.5))
			var far := []
			for res in [3, 5, 8]:
				far.append(tris(EdenFoliageMeshes.build_far(l, 0, res)))
			print("TRIS %-12s near %5d (%5d verts)  mid %5d   far res3/5/8: %s" % [kind, near, verts, mid, far])
	quit()
