class_name EdenBuildPieces
extends RefCounted
## The building pieces (Valheim-style, on a 2 m grid): their cost, size, snap points and how well they carry
## weight, plus the meshes, colliders and materials. A piece's local frame: y up (the planet's up where it was
## placed), origin at its centre.

enum Mat { WOOD, STONE }

## Structural support per material: what a piece keeps of its neighbour's support through a vertical (resting on)
## or horizontal (hanging off) joint, and the least it needs to stand. Ground contact gives 1.0.
const SUPPORT := {
	Mat.WOOD: {"vertical": 0.92, "horizontal": 0.72, "min": 0.2},
	Mat.STONE: {"vertical": 0.97, "horizontal": 0.45, "min": 0.3},
}

## id -> definition. cost: {EdenMiner item index: amount}. shape: "box" (size) or "ramp" (a 2 x 2 x 2 diagonal).
const PIECES := {
	"wood_floor": {"name": "Wood floor", "mat": Mat.WOOD, "cost": {5: 2}, "shape": "box", "size": Vector3(2, 0.2, 2)},
	"wood_wall": {"name": "Wood wall", "mat": Mat.WOOD, "cost": {5: 2}, "shape": "box", "size": Vector3(2, 2, 0.2)},
	"wood_half_wall": {"name": "Wood half wall", "mat": Mat.WOOD, "cost": {5: 1}, "shape": "box", "size": Vector3(2, 1, 0.2)},
	"wood_beam": {"name": "Wood beam", "mat": Mat.WOOD, "cost": {5: 1}, "shape": "box", "size": Vector3(2, 0.22, 0.22)},
	"wood_pole": {"name": "Wood pole", "mat": Mat.WOOD, "cost": {5: 1}, "shape": "box", "size": Vector3(0.22, 2, 0.22)},
	"wood_roof": {"name": "Wood roof 45°", "mat": Mat.WOOD, "cost": {5: 2}, "shape": "ramp", "size": Vector3(2, 0.14, 2.83)},
	"wood_stairs": {"name": "Wood stairs", "mat": Mat.WOOD, "cost": {5: 2}, "shape": "stairs", "size": Vector3(2, 2, 2)},
	"stone_floor": {"name": "Stone floor", "mat": Mat.STONE, "cost": {1: 3}, "shape": "box", "size": Vector3(2, 0.4, 2)},
	"stone_wall": {"name": "Stone wall", "mat": Mat.STONE, "cost": {1: 3}, "shape": "box", "size": Vector3(2, 2, 0.4)},
	"stone_pillar": {"name": "Stone pillar", "mat": Mat.STONE, "cost": {1: 2}, "shape": "box", "size": Vector3(0.5, 2, 0.5)},
}
const ORDER := ["wood_floor", "wood_wall", "wood_half_wall", "wood_beam", "wood_pole", "wood_roof", "wood_stairs",
		"stone_floor", "stone_wall", "stone_pillar"]

static var _meshes := {}
static var _shapes := {}
static var _materials := {}


## Snap points in the piece's frame: corners and edge middles of its faces, so neighbours line up edge to edge
static func snap_points(id: String) -> PackedVector3Array:
	var d: Dictionary = PIECES[id]
	var s: Vector3 = d.size * 0.5
	var pts := PackedVector3Array()
	match d.shape:
		"ramp", "stairs":
			# The eave (low, front) and ridge (high, back) edges, and the sides' middles
			for x in [-1.0, 0.0, 1.0]:
				pts.append(Vector3(x, -1.0, 1.0))
				pts.append(Vector3(x, 1.0, -1.0))
			pts.append(Vector3(-1.0, 0.0, 0.0))
			pts.append(Vector3(1.0, 0.0, 0.0))
		_:
			if s.y < s.x and s.y < s.z: # floor: corners and edges of the top face (to stand walls on, and to line up
				# with other floors) and of the bottom face (to rest on walls and beams)
				for y in [s.y, -s.y]:
					for x in [-s.x, 0.0, s.x]:
						for z in [-s.z, 0.0, s.z]:
							if x != 0.0 or z != 0.0:
								pts.append(Vector3(x, y, z))
			elif s.z < s.x: # wall / beam: along x, in its centre plane
				for x in [-s.x, 0.0, s.x]:
					for y in [-s.y, 0.0, s.y]:
						if x != 0.0 or y != 0.0 or s.y < 0.2:
							pts.append(Vector3(x, y, 0.0))
			else: # pole / pillar: along y
				for y in [-s.y, 0.0, s.y]:
					pts.append(Vector3(0.0, y, 0.0))
	return pts


static func material_of(id: String) -> int:
	return PIECES[id].mat


static func mesh(id: String) -> Mesh:
	if _meshes.has(id):
		return _meshes[id]
	var d: Dictionary = PIECES[id]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	match d.shape:
		"ramp":
			_box(st, Transform3D(Basis(Vector3.RIGHT, PI * 0.25), Vector3.ZERO), d.size)
		"stairs":
			# Four steps, 0.5 m each, from the front (z = +1, low) to the back (high); stringers at the sides
			for i in 4:
				var y := -1.0 + 0.25 + 0.5 * i
				_box(st, Transform3D(Basis(), Vector3(0, y, 0.75 - 0.5 * i)), Vector3(1.8, 0.14, 0.5))
			for x in [-0.95, 0.95]:
				_box(st, Transform3D(Basis(Vector3.RIGHT, PI * 0.25), Vector3(x, -0.05, 0.05)), Vector3(0.1, 0.25, 2.7))
		_:
			_box(st, Transform3D(), d.size)
	st.generate_normals()
	var m := st.commit()
	m.surface_set_material(0, material(d.mat))
	_meshes[id] = m
	return m


static func shape(id: String) -> Array:
	## [Shape3D, Transform3D in the piece's frame]
	if _shapes.has(id):
		return _shapes[id]
	var d: Dictionary = PIECES[id]
	var box := BoxShape3D.new()
	var xf := Transform3D()
	match d.shape:
		"ramp", "stairs":
			box.size = Vector3(2.0, 0.2 if d.shape == "ramp" else 0.5, 2.83)
			xf = Transform3D(Basis(Vector3.RIGHT, PI * 0.25), Vector3.ZERO)
		_:
			box.size = d.size
	_shapes[id] = [box, xf]
	return _shapes[id]


# A box of `size` (faces not shared, so flat shading stays crisp) transformed by xf
static func _box(st: SurfaceTool, xf: Transform3D, size: Vector3) -> void:
	var h := size * 0.5
	var faces := [
		[Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)], [Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)],
		[Vector3(0, 1, 0), Vector3(0, 0, 1), Vector3(1, 0, 0)], [Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)],
		[Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)], [Vector3(0, 0, -1), Vector3(0, 1, 0), Vector3(1, 0, 0)],
	]
	for f in faces:
		var n: Vector3 = f[0]
		var u: Vector3 = f[1]
		var v: Vector3 = f[2]
		var c := n * h
		var du := u * h
		var dv := v * h
		var q := [c - du - dv, c + du - dv, c + du + dv, c - du + dv]
		# Clockwise seen from outside: Godot's front face (counter-clockwise put every normal inward)
		for i in [0, 2, 1, 0, 3, 2]:
			st.add_vertex(xf * q[i])


## The shared look: planks for wood, coursed blocks for stone, from the local position (so every piece lines up
## with its neighbours). instance uniform `tint`: the support colours in build mode.
static func material(m: int) -> ShaderMaterial:
	if _materials.has(m):
		return _materials[m]
	var mat := ShaderMaterial.new()
	mat.shader = load("res://building/eden_build.gdshader")
	mat.set_shader_parameter("u_stone", m == Mat.STONE)
	mat.set_shader_parameter("u_color", Color(0.55, 0.38, 0.22) if m == Mat.WOOD else Color(0.56, 0.55, 0.52))
	_materials[m] = mat
	return mat


## Colour for a support value (build mode): blue on the ground, then green, yellow, orange, red as it weakens
static func support_color(s: float) -> Color:
	if s >= 0.999:
		return Color(0.35, 0.55, 1.0)
	if s > 0.6:
		return Color(0.35, 0.85, 0.35)
	if s > 0.4:
		return Color(0.95, 0.85, 0.25)
	if s > 0.28:
		return Color(1.0, 0.55, 0.15)
	return Color(0.95, 0.2, 0.15)
