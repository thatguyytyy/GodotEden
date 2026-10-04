class_name EdenBuilder
extends Node
## Valheim-style building for EdenPlayer. G takes out the hammer:
##   a ghost of the selected piece follows the crosshair, snapping to the corners and edges of pieces it touches
##   (Shift: free placement), green when it can go there, red when not (and why);
##   LMB places it for its Wood / Stone (EdenMiner's inventory), X or MMB removes the piece under the crosshair (full
##   refund), mouse wheel / R rotates, RMB opens the piece menu (1-0 pick directly).
## Structural support: pieces touching the ground carry 1.0; others carry what their best neighbour passes on, less
## a loss per joint (more hanging sideways than resting on top, more for stone than wood). Colours show it while
## the hammer is out (blue ground, green, yellow, orange, red). A piece that can't be supported can't be placed, and
## removing a piece brings down whatever depended on it.
## Multiplayer: with EdenNet online the server is the source of truth: placing and removing are requests, pieces
## appear and go when the server's rows do (for everyone, this player included).

signal place_requested(kind: String, xform: Transform3D)
signal remove_requested(net_id: int)
signal changed

const REACH := 8.0
const ROTATE_STEP := PI / 8.0
const SNAP_RADIUS := 1.6

var active := false
var selected := 0
## Set by EdenNet while online: placing/removing go through the server
var online := false
## Every piece in the world
var pieces: Array[EdenBuildPiece] = []
## What the ghost says about the current spot: "" = can place
var ghost_problem := ""
var ghost_valid := false
var ghost_xform := Transform3D()

var _player: EdenPlayer
var _miner: EdenMiner
var _terrain: Node3D
var _root: Node3D
var _ghost: MeshInstance3D
var _ghost_mat: StandardMaterial3D
var _ghost_kind := ""
var _rotation := 0.0
var _hud: Label
var _menu: PanelContainer
var _by_net := {}


func setup(player: EdenPlayer, miner: EdenMiner, terrain: Node3D) -> void:
	_player = player
	_miner = miner
	_terrain = terrain
	# Pieces live in the world (not under the player); the player and the tools collide with and aim at them
	_root = Node3D.new()
	_root.name = "Buildings"
	player.get_tree().current_scene.add_child.call_deferred(_root)
	player.collision_mask |= EdenBuildPiece.LAYER
	for a in [["build_mode", KEY_G], ["build_remove", KEY_X], ["build_rotate", KEY_R]]:
		if not InputMap.has_action(a[0]):
			InputMap.add_action(a[0])
			var e := InputEventKey.new()
			e.physical_keycode = a[1]
			InputMap.action_add_event(a[0], e)
	_ghost = MeshInstance3D.new()
	_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ghost.top_level = true
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost.material_override = _ghost_mat
	_ghost.visible = false
	add_child(_ghost)
	_build_ui()


func kind() -> String:
	return EdenBuildPieces.ORDER[selected]


func set_active(on: bool) -> void:
	active = on
	_miner.enabled = not on
	_ghost.visible = false
	_hud.visible = on
	_menu.visible = false
	for p in pieces:
		p.show_support(on)


func select(i: int) -> void:
	selected = posmod(i, EdenBuildPieces.ORDER.size())
	_menu.visible = false
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# ------------------------------------------------------------------------------------------------------------
# Input

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("build_mode") and _player.ready_to_move:
		set_active(not active)
		return
	if not active:
		return
	# Only what building uses is consumed: mouse motion (camera look), movement and the other keys pass on
	var used := true
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode >= KEY_0 and event.physical_keycode <= KEY_9:
		select(9 if event.physical_keycode == KEY_0 else event.physical_keycode - KEY_1)
	elif event.is_action_pressed("build_rotate"):
		_rotation += PI / 2.0
	elif event.is_action_pressed("build_remove"):
		remove_target()
	elif event is InputEventMouseButton:
		if event.pressed:
			match event.button_index:
				MOUSE_BUTTON_WHEEL_UP:
					_rotation += ROTATE_STEP
				MOUSE_BUTTON_WHEEL_DOWN:
					_rotation -= ROTATE_STEP
				MOUSE_BUTTON_RIGHT:
					_menu.visible = not _menu.visible
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if _menu.visible else Input.MOUSE_MODE_CAPTURED
				MOUSE_BUTTON_MIDDLE:
					remove_target()
				MOUSE_BUTTON_LEFT:
					if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not _menu.visible:
						place()
	else:
		used = false
	if used:
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if not active:
		return
	_update_ghost()
	var d: Dictionary = EdenBuildPieces.PIECES[kind()]
	var cost := []
	for item in d.cost:
		cost.append("%d %s (have %d)" % [d.cost[item], EdenMiner.ITEMS[item][0], _miner.counts[item]])
	_hud.text = "HAMMER  %s  -  %s%s\nLMB place   RMB pieces   Wheel/R rotate   Shift free   X remove   G put away" % [
			d.name, ", ".join(cost), ("\n" + ghost_problem) if ghost_problem != "" else ""]
	_hud.modulate = Color(1, 0.75, 0.7) if ghost_problem != "" else Color.WHITE


# ------------------------------------------------------------------------------------------------------------
# The ghost: where the selected piece would go, snapped

func _ray() -> Dictionary:
	var cam := _player.get_camera()
	var from := cam.global_position
	var head := _player.global_position + _player.up_direction * 1.5
	var to := from - cam.global_basis.z * ((from - head).length() + REACH)
	var q := PhysicsRayQueryParameters3D.create(from, to, 1 | EdenBuildPiece.LAYER, [_player.get_rid()])
	var hit := _player.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty() or hit.position.distance_to(head) > REACH:
		return {}
	return hit


## Works out where the selected piece would go for the crosshair (ghost_xform) and whether it can (ghost_valid)
func _update_ghost() -> void:
	var k := kind()
	if _ghost_kind != k:
		_ghost_kind = k
		_ghost.mesh = EdenBuildPieces.mesh(k)
	var hit := _ray()
	if hit.is_empty():
		_ghost.visible = false
		ghost_valid = false
		ghost_problem = "Aim at the ground or a piece within reach"
		return
	var hit_piece: EdenBuildPiece = hit.collider as EdenBuildPiece
	var p: Vector3 = hit.position
	var up := (p - _player._center()).normalized()
	var basis: Basis
	if hit_piece:
		# Line up with the piece it's built onto (turned by the player's rotation)
		basis = hit_piece.global_basis * Basis(Vector3.UP, _rotation)
	else:
		var cam_fwd := -_player.get_camera().global_basis.z
		var fwd := (cam_fwd - up * cam_fwd.dot(up))
		fwd = fwd.normalized() if fwd.length_squared() > 1e-6 else EdenPlayer._north(up)
		basis = Basis.looking_at(fwd, up) * Basis(Vector3.UP, _rotation)
	# Out of what was hit by the piece's half-extent along the hit normal (resting on it, not in it)
	var n: Vector3 = hit.normal
	var half: Vector3 = _extent(k) * 0.5
	var push := absf(basis.x.dot(n)) * half.x + absf(basis.y.dot(n)) * half.y + absf(basis.z.dot(n)) * half.z
	var xf := Transform3D(basis, p + n * push)
	if not Input.is_key_pressed(KEY_SHIFT):
		xf = _snap(xf, k, p)
	ghost_xform = xf
	ghost_problem = _problem(k, xf)
	ghost_valid = ghost_problem == ""
	_ghost.global_transform = xf
	_ghost.visible = true
	var c := Color(0.3, 1.0, 0.45) if ghost_valid else Color(1.0, 0.3, 0.25)
	if ghost_valid:
		c = EdenBuildPieces.support_color(_support_for(k, xf)).lerp(c, 0.4)
	_ghost_mat.albedo_color = Color(c.r, c.g, c.b, 0.45)


# The piece's size as its bounding extent (ramps and stairs are 2 x 2 x 2)
static func _extent(k: String) -> Vector3:
	var d: Dictionary = EdenBuildPieces.PIECES[k]
	return Vector3(2, 2, 2) if d.shape != "box" else d.size


# Snaps the ghost onto the pieces around the aim point: the target snap point nearest the aim, joined by the
# ghost's snap point nearest to it
func _snap(xf: Transform3D, k: String, aim: Vector3) -> Transform3D:
	var best_t := Vector3.INF
	var best_d := SNAP_RADIUS
	var best_piece: EdenBuildPiece
	var best_sp := Vector3.ZERO
	for piece in pieces:
		if piece.global_position.distance_to(aim) > 4.0:
			continue
		for sp in EdenBuildPieces.snap_points(piece.kind):
			var w: Vector3 = piece.global_transform * sp
			var d := w.distance_to(aim)
			if d < best_d:
				best_d = d
				best_t = w
				best_piece = piece
				best_sp = sp
	if best_t == Vector3.INF:
		return xf
	# A piece of the same size lined up with it: the neighbour across that snap point, in the same plane (floor beside
	# floor, wall beside or on top of wall). Nearest-point matching would join a floor's bottom edge to the other's top
	# edge when aiming at its top: a step up instead of a flat floor.
	var size: Vector3 = _extent(k)
	if EdenBuildPieces.PIECES[k].shape == "box" and _extent(best_piece.kind).is_equal_approx(_aligned_size(size, best_piece.global_basis, xf.basis)):
		var ts := _extent(best_piece.kind)
		var thin := 0 if ts.x <= ts.y and ts.x <= ts.z else (1 if ts.y <= ts.z else 2)
		var local := best_sp
		local[thin] = 0.0
		xf.origin = best_piece.global_transform * (local * 2.0)
		return xf
	var best_g := Vector3.ZERO
	var best_gd := INF
	for sp in EdenBuildPieces.snap_points(k):
		var w: Vector3 = xf * sp
		var d := w.distance_to(best_t)
		if d < best_gd:
			best_gd = d
			best_g = w
	xf.origin += best_t - best_g
	return xf


# A piece of `size` in basis gb, measured along the axes of basis tb; Vector3.INF unless the axes line up
static func _aligned_size(size: Vector3, tb: Basis, gb: Basis) -> Vector3:
	var out := Vector3.ZERO
	for i in 3:
		for j in 3:
			var c := absf(tb[i].normalized().dot(gb[j].normalized()))
			if c > 0.02 and c < 0.98:
				return Vector3.INF
			out[i] += c * size[j]
	return out


# Why the selected piece can't go at xf ("" if it can)
func _problem(k: String, xf: Transform3D) -> String:
	var d: Dictionary = EdenBuildPieces.PIECES[k]
	for item in d.cost:
		if _miner.counts[item] < d.cost[item]:
			return "Need %d %s (Wood from trees and logs, Stone from boulders or digging rock)" % [d.cost[item], EdenMiner.ITEMS[item][0]]
	if not _touching(k, xf, -0.12).is_empty():
		return "Blocked by another piece"
	if _overlaps_player(k, xf):
		return "You're in the way"
	if _support_for(k, xf) < EdenBuildPieces.SUPPORT[EdenBuildPieces.material_of(k)].min:
		return "Not enough support: build it from the ground or off a stronger piece"
	return ""


# Colliders of `mask` the piece's shape (scaled by `grow`) would touch at xf
func _overlaps(k: String, xf: Transform3D, mask: int, grow: float, exclude: Array = []) -> Array:
	var s: Array = EdenBuildPieces.shape(k)
	var shape: BoxShape3D = (s[0] as BoxShape3D).duplicate()
	shape.size = shape.size * grow if grow < 1.0 else shape.size + Vector3.ONE * (grow - 1.0)
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.transform = xf * s[1]
	q.collision_mask = mask
	q.exclude = exclude
	var out := []
	for r in _player.get_world_3d().direct_space_state.intersect_shape(q, 32):
		out.append(r.collider)
	return out


func _overlaps_player(k: String, xf: Transform3D) -> bool:
	var inv := xf.affine_inverse()
	var half := _extent(k) * 0.5 + Vector3.ONE * EdenPlayer.RADIUS
	for h in [0.2, 0.9, 1.6]:
		var l: Vector3 = inv * (_player.global_position + _player.up_direction * h)
		if absf(l.x) < half.x and absf(l.y) < half.y and absf(l.z) < half.z:
			return true
	return false


# Touching the terrain (not trees and rocks, not other pieces)
func _grounded(k: String, xf: Transform3D) -> bool:
	for c in _overlaps(k, xf, 1, 1.15, [_player.get_rid()]):
		if not c is VoxelInstancerRigidBody and not c is EdenBuildPiece and c != _player:
			return true
	return false


func _neighbors(k: String, xf: Transform3D, exclude: EdenBuildPiece = null) -> Array[EdenBuildPiece]:
	return _touching(k, xf, 0.06, exclude)


# Pieces whose boxes come within `margin` of piece k's box at xf (negative: overlap by more than -margin). Geometry
# only, not physics queries: a piece added this frame isn't in the physics broadphase yet (and the server sends a
# whole base in one go when joining)
func _touching(k: String, xf: Transform3D, margin: float, exclude: EdenBuildPiece = null) -> Array[EdenBuildPiece]:
	var a := _box(k, xf)
	var out: Array[EdenBuildPiece] = []
	for p in pieces:
		if p == exclude or p.global_position.distance_to(xf.origin) > 6.0:
			continue
		if _boxes_touch(a, _box(p.kind, p.global_transform), margin):
			out.append(p)
	return out


# [centre, basis (unit axes), half extents] of a piece's collision box
static func _box(k: String, xf: Transform3D) -> Array:
	var s: Array = EdenBuildPieces.shape(k)
	var t: Transform3D = xf * (s[1] as Transform3D)
	return [t.origin, t.basis.orthonormalized(), (s[0] as BoxShape3D).size * 0.5]


# Oriented boxes within `margin` of each other: the separating axis test (faces of both, and their edge pairs)
static func _boxes_touch(a: Array, b: Array, margin: float) -> bool:
	var d: Vector3 = b[0] - a[0]
	var ab: Basis = a[1]
	var bb: Basis = b[1]
	var axes := [ab.x, ab.y, ab.z, bb.x, bb.y, bb.z]
	for i in 3:
		for j in 3:
			var c: Vector3 = ab[i].cross(bb[j])
			if c.length_squared() > 1e-6:
				axes.append(c.normalized())
	for l: Vector3 in axes:
		var ra: float = a[2].x * absf(ab.x.dot(l)) + a[2].y * absf(ab.y.dot(l)) + a[2].z * absf(ab.z.dot(l))
		var rb: float = b[2].x * absf(bb.x.dot(l)) + b[2].y * absf(bb.y.dot(l)) + b[2].z * absf(bb.z.dot(l))
		if absf(d.dot(l)) > ra + rb + margin:
			return false
	return true


# The support the piece would have at xf, from the ground or its neighbours
func _support_for(k: String, xf: Transform3D) -> float:
	if _grounded(k, xf):
		return 1.0
	var best := 0.0
	for nb in _neighbors(k, xf):
		best = maxf(best, nb.support * _transfer(k, xf.origin, nb))
	return best


# What a piece of kind k at `at` keeps of neighbour nb's support: resting on it (nb below) or hanging off its side
func _transfer(k: String, at: Vector3, nb: EdenBuildPiece) -> float:
	var up := (at - _player._center()).normalized()
	var s: Dictionary = EdenBuildPieces.SUPPORT[EdenBuildPieces.material_of(k)]
	return s.vertical if (nb.global_position - at).dot(up) < -0.3 else s.horizontal


# ------------------------------------------------------------------------------------------------------------
# Placing and removing

## Places the selected piece at the ghost (pays for it). Online, asks the server instead. Returns whether it did
func place() -> bool:
	_update_ghost()
	return ghost_valid and place_at(kind(), ghost_xform) == ""


## Places piece k at xf if it can go there (the same checks and cost as the ghost). Returns "" or the reason not
func place_at(k: String, xf: Transform3D) -> String:
	var problem := _problem(k, xf)
	if problem != "":
		_miner.toast(problem)
		return problem
	var d: Dictionary = EdenBuildPieces.PIECES[k]
	for item in d.cost:
		_miner.counts[item] -= d.cost[item]
	_miner.refresh()
	if online:
		place_requested.emit(k, xf)
	else:
		spawn(k, xf)
	return ""


## Where piece k would snap to near aim, starting from xf (the ghost's snapping, for scripted use)
func snapped(k: String, xf: Transform3D, aim: Vector3) -> Transform3D:
	return _snap(xf, k, aim)


## Removes the piece under the crosshair, refunding it; whatever it held up comes down (no refund for those)
func remove_target() -> bool:
	var hit := _ray()
	var piece := hit.get("collider") as EdenBuildPiece
	if piece == null:
		return false
	var d: Dictionary = EdenBuildPieces.PIECES[piece.kind]
	for item in d.cost:
		_miner.counts[item] += d.cost[item]
	_miner.refresh()
	remove(piece)
	return true


## A piece into the world (placed here, or a server row arriving). Connects it and works out support
func spawn(k: String, xf: Transform3D, p_net_id := 0) -> EdenBuildPiece:
	if p_net_id != 0 and _by_net.has(p_net_id):
		return _by_net[p_net_id]
	var piece := EdenBuildPiece.create(k)
	piece.net_id = p_net_id
	if not _root.is_inside_tree():
		_player.get_tree().current_scene.add_child(_root)
	_root.add_child(piece)
	piece.global_transform = xf
	piece.grounded = _grounded(k, xf)
	piece.neighbors = _neighbors(k, xf, piece)
	for nb in piece.neighbors:
		nb.neighbors.append(piece)
	pieces.append(piece)
	if p_net_id != 0:
		_by_net[p_net_id] = piece
	_solve()
	changed.emit()
	return piece


## Takes a piece out (online: asks the server; the row's deletion removes it)
func remove(piece: EdenBuildPiece) -> void:
	if online and piece.net_id != 0:
		remove_requested.emit(piece.net_id)
		return
	despawn(piece)


func despawn(piece: EdenBuildPiece) -> void:
	if not is_instance_valid(piece) or not pieces.has(piece):
		return
	pieces.erase(piece)
	_by_net.erase(piece.net_id)
	for nb in piece.neighbors:
		nb.neighbors.erase(piece)
	piece.queue_free()
	_solve()
	changed.emit()


func despawn_net(p_net_id: int) -> void:
	if _by_net.has(p_net_id):
		despawn(_by_net[p_net_id])


# Support for every piece: grounded ones carry 1, the rest the best their neighbours pass on (relaxed until it
# settles). Pieces left below their material's minimum collapse.
func _solve() -> void:
	for p in pieces:
		p.support = 1.0 if p.grounded else 0.0
	for _i in 64:
		var moved := false
		for p in pieces:
			if p.grounded:
				continue
			var best := 0.0
			for nb in p.neighbors:
				best = maxf(best, nb.support * _transfer(p.kind, p.global_position, nb))
			if absf(best - p.support) > 1e-4:
				p.support = best
				moved = true
		if not moved:
			break
	var falling: Array[EdenBuildPiece] = []
	for p in pieces:
		if p.support < EdenBuildPieces.SUPPORT[p.material()].min:
			falling.append(p)
		p.show_support(active)
	for p in falling:
		_miner.toast("%s collapsed" % EdenBuildPieces.PIECES[p.kind].name)
		remove(p) # (re-solves; online the server's deletes do)


# ------------------------------------------------------------------------------------------------------------
# UI: the hammer's line above the hotbar, the piece menu (RMB)

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_hud.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hud.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_hud.position.y -= 92
	_hud.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud.add_theme_constant_override("outline_size", 5)
	_hud.visible = false
	layer.add_child(_hud)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(center)
	_menu = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.1, 0.12, 0.94)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(14)
	_menu.add_theme_stylebox_override("panel", style)
	_menu.visible = false
	center.add_child(_menu)
	var box := VBoxContainer.new()
	_menu.add_child(box)
	var title := Label.new()
	title.text = "Build"
	title.add_theme_font_size_override("font_size", 22)
	box.add_child(title)
	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	box.add_child(grid)
	for i in EdenBuildPieces.ORDER.size():
		var id: String = EdenBuildPieces.ORDER[i]
		var d: Dictionary = EdenBuildPieces.PIECES[id]
		var b := Button.new()
		var cost := []
		for item in d.cost:
			cost.append("%d %s" % [d.cost[item], EdenMiner.ITEMS[item][0]])
		b.text = "%d  %s\n%s" % [(i + 1) % 10, d.name, ", ".join(cost)]
		b.custom_minimum_size = Vector2(150, 64)
		b.pressed.connect(select.bind(i))
		grid.add_child(b)
