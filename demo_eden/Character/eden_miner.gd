class_name EdenMiner
extends Node
## Voxel mining and building for EdenPlayer, with a small inventory and its UI (made by the player at runtime).
##   Hold LMB: dig where the crosshair points (within reach), collecting the ground's material; aimed at a tree,
##   log or boulder, chop / break it (a few hits) for Wood or Stone.
##   RMB: place the selected material there (not inside yourself). 1-6 / mouse wheel pick a slot, Tab the inventory.
##   T: the RMB brush (SHAPES): Mound (soft rise that blends into the ground), Ball, Block (2 m cube, square to the
##   planet), Flatten (levels to the aimed point's height), Smooth. Flatten and Smooth cost nothing.
## Wood and Stone are also what EdenBuilder's pieces cost.
## The material comes from the voxel data (the dominant texture of the V4 Mixel4 channels) and falls back to the
## generator's surface material; placed ground is painted with its own material, so it mines back as itself.

signal inventory_changed
## A dig (mode 0), place (mode 1) or felled tree / broken rock (mode 2), or a brush edit (modes 3-6, SHAPES) made
## here: EdenNet sends it to the others
signal edited(world_position: Vector3, radius: float, mode: int, material: int)

## [name, V4 material index (MAT_*), swatch colour]
const ITEMS := [
	["Dirt", 4, Color(0.42, 0.3, 0.2)],
	["Stone", 1, Color(0.52, 0.52, 0.55)],
	["Sand", 3, Color(0.86, 0.78, 0.55)],
	["Snow", 2, Color(0.95, 0.97, 1.0)],
	["Moss", 5, Color(0.3, 0.45, 0.2)],
	["Wood", -1, Color(0.55, 0.36, 0.2)], # not ground: for building (EdenBuilder)
]
const WOOD := 5
const STONE := 1
## Foliage kinds that can be gathered: [item, amount, hits]
const GATHER := {
	"OAK": [WOOD, 5, 5], "BIRCH": [WOOD, 4, 4], "WILLOW": [WOOD, 5, 5], "FRUIT_TREE": [WOOD, 4, 4], "PINE": [WOOD, 5, 5],
	"PALM": [WOOD, 3, 4], "DEAD_TREE": [WOOD, 3, 3], "LOG": [WOOD, 3, 2],
	"BOULDER": [STONE, 3, 4], "ROCK_SLAB": [STONE, 4, 5], "ROCK_SPIRE": [STONE, 4, 5],
}
## V4 material (MAT_GRASS .. MAT_OCEAN_FLOOR) -> the item mining it gives
const MATERIAL_ITEM := [0, 1, 3, 2, 0, 4, 2]
## RMB brushes (T cycles): [name, edit mode, radius, uses an item]
const SHAPES := [
	["Mound", 3, 2.4, true],
	["Ball", 1, 1.3, true],
	["Block", 4, 1.0, true],
	["Flatten", 5, 2.8, false],
	["Smooth", 6, 2.4, false],
]

@export var reach := 6.0
## Terrain voxels are 1 m: smaller spheres only dent the surface
@export var dig_radius := 1.3
## Placing is the exact inverse of digging (same sphere, centred on the surface): what one dig takes, one place puts back
@export var place_radius := 1.3
@export var repeat_time := 0.25

var counts: Array[int] = [0, 0, 0, 0, 0, 0]
var selected := 0
## Set before setup() by a plugin that draws its own hotbar and inventory (EdenInventory): no hotbar or inventory
## panel is made here and 1-6, the wheel and Tab are left to it; selected can then be -1 (nothing in hand)
var external_ui := false
var shape := 0
## Where the crosshair meets the ground within reach (has_target false otherwise)
var has_target := false
var target_position := Vector3.ZERO
var target_normal := Vector3.UP
## A tree / log / boulder under the crosshair instead (its collider), and what it gives
var gather_target: Node3D
var gather_kind := ""
## Set by EdenBuilder while building: the hammer takes the mouse buttons
var enabled := true

var _player: EdenPlayer
var _terrain: VoxelLodTerrain
var _tool: VoxelTool
var _cooldown := 0.0
var _preview: MeshInstance3D
var _slots: Array[PanelContainer] = []
var _slot_labels: Array[Label] = []
var _panel: PanelContainer
var _panel_label: Label
var _toast: Label
var _toast_t := 0.0
# Seconds the target sphere stays up after the tool was last used
var _active_t := 0.0
var _foliage: EdenFoliage
var _hits := {} # collider instance id -> hits so far


func setup(player: EdenPlayer, terrain: VoxelLodTerrain) -> void:
	_player = player
	_terrain = terrain
	_tool = terrain.get_voxel_tool()
	_tool.sdf_strength = 1.0
	for c in terrain.get_children():
		if c is EdenFoliage:
			_foliage = c
	for i in ITEMS.size():
		var a := "slot_%d" % (i + 1)
		if not InputMap.has_action(a):
			InputMap.add_action(a)
			var e := InputEventKey.new()
			e.physical_keycode = KEY_1 + i
			InputMap.action_add_event(a, e)
	if not InputMap.has_action("terrain_shape"):
		InputMap.add_action("terrain_shape")
		var e := InputEventKey.new()
		e.physical_keycode = KEY_T
		InputMap.action_add_event("terrain_shape", e)
	if not InputMap.has_action("inventory"):
		InputMap.add_action("inventory")
		var e := InputEventKey.new()
		e.physical_keycode = KEY_TAB
		InputMap.action_add_event("inventory", e)
	_build_preview()
	_build_ui()
	_refresh_ui()


# ------------------------------------------------------------------------------------------------------------
# Actions (the input handlers call these; tests can too)

## Digs a sphere at the target and collects its material. Returns the item index collected, or -1
func dig() -> int:
	if not has_target:
		return -1
	var item := _item_at(target_position - target_normal * 0.3)
	apply_edit(target_position, dig_radius, 0, 0)
	edited.emit(target_position, dig_radius, 0, 0)
	counts[item] += 1
	_toast_msg("+1 %s" % ITEMS[item][0])
	inventory_changed.emit()
	_refresh_ui()
	return item


## One hit on the tree / log / boulder under the crosshair; the last hit fells or breaks it and collects its Wood or
## Stone. Returns the item collected (-1 while it still stands, or with nothing to hit)
func gather() -> int:
	if gather_target == null or not is_instance_valid(gather_target):
		return -1
	var g: Array = GATHER[gather_kind]
	var id := gather_target.get_instance_id()
	_hits[id] = _hits.get(id, 0) + 1
	if _player._steps:
		_player._steps.trigger_footstep(AudioStreamEdenAmbience.SURFACE_ROCK if g[0] == STONE else AudioStreamEdenAmbience.SURFACE_DIRT, 1.3, 0.0)
	if _hits[id] < g[2]:
		_toast_msg("%s %d / %d" % ["Chopping" if g[0] == WOOD else "Breaking", _hits[id], g[2]])
		return -1
	_hits.erase(id)
	var at := gather_target.global_position
	gather_target.call("queue_free_and_notify_instancer")
	gather_target = null
	edited.emit(at, 1.0, 2, 0)
	counts[g[0]] += g[1]
	_toast_msg("+%d %s" % [g[1], ITEMS[g[0]][0]])
	inventory_changed.emit()
	_refresh_ui()
	return g[0]


## Places the selected material against the target. Returns false when out of it, blocked or no target
func place() -> bool:
	if not has_target:
		return false
	var sh: Array = SHAPES[shape]
	if not sh[3]:
		apply_edit(target_position, sh[2], sh[1], 0)
		edited.emit(target_position, sh[2], sh[1], 0)
		return true
	if selected < 0:
		return false
	if ITEMS[selected][1] < 0:
		_toast_msg("%s is for building: G for the hammer" % ITEMS[selected][0])
		return false
	if counts[selected] <= 0:
		_toast_msg("No %s left" % ITEMS[selected][0])
		return false
	var at := target_position
	var r: float = sh[2]
	if sh[1] == 4:
		at += target_normal * r # the block rests against what was hit
	# (a mound's edge is a gentle rise, so only its core counts)
	if _inside_player(at, (r * 1.5 if sh[1] == 4 else minf(r, place_radius)) + 0.15):
		_toast_msg("Too close")
		return false
	apply_edit(at, r, sh[1], ITEMS[selected][1])
	edited.emit(at, r, sh[1], ITEMS[selected][1])
	counts[selected] -= 1
	inventory_changed.emit()
	_refresh_ui()
	return true


## The terrain change itself: remove a sphere (mode 0), add one painted with a V4 material (mode 1), remove the
## foliage there (mode 2: a tree someone felled), or a brush (SHAPES): mound (3), block (4), flatten (5), smooth (6).
## Also used for edits other players made (EdenNet), so everything here depends only on the arguments.
func apply_edit(world_position: Vector3, radius: float, mode: int, material: int) -> void:
	if mode == 2:
		if _foliage:
			_foliage.remove_instances_in_sphere(_foliage.to_local(world_position), radius)
		return
	var local := _terrain.to_local(world_position)
	if mode == 0:
		_tool.mode = VoxelTool.MODE_REMOVE
		_tool.do_sphere(local, radius)
		return
	if mode == 6:
		_tool.smooth_sphere(local, radius, 2)
		return
	if mode == 5 or mode == 4:
		_sdf_brush(local, radius, mode)
		if mode == 5:
			return
	elif mode == 3:
		_tool.mode = VoxelTool.MODE_ADD
		_tool.grow_sphere(local, radius, 1.2)
	else:
		_tool.mode = VoxelTool.MODE_ADD
		_tool.do_sphere(local, radius)
	_tool.mode = VoxelTool.MODE_TEXTURE_PAINT
	_tool.texture_index = material
	_tool.texture_opacity = 1.0
	_tool.texture_falloff = 0.2
	_tool.do_sphere(local, radius + 0.6)


# Flatten (5): blends the ground toward the plane through `c`, square to the planet, over a disc of radius r.
# Block (4): unions a cube of half-size r, square to the planet and facing its north. Terrain-local (voxel) units.
# ponytail: per-voxel GDScript over a ~(2r+3)^3 box (a few hundred voxels); move to C++ if brushes get big.
func _sdf_brush(c: Vector3, r: float, mode: int) -> void:
	var up := c.normalized() # terrain origin is the planet centre
	var north := EdenPlayer._north(up)
	var east := up.cross(north).normalized()
	north = east.cross(up)
	var ext := ceili(r * (1.8 if mode == 4 else 1.0)) + 2
	var origin := Vector3i(c.floor()) - Vector3i(ext, ext, ext)
	var buf := VoxelBuffer.new()
	buf.create(ext * 2 + 1, ext * 2 + 1, ext * 2 + 1)
	var ch := VoxelBuffer.CHANNEL_SDF
	_tool.copy(origin, buf, 1 << ch)
	for x in ext * 2 + 1:
		for y in ext * 2 + 1:
			for z in ext * 2 + 1:
				var d := Vector3(origin + Vector3i(x, y, z)) - c
				var old := buf.get_voxel_f(x, y, z, ch)
				var h := d.dot(up)
				if mode == 5:
					var across := (d - up * h).length()
					var w := 1.0 - smoothstep(r * 0.55, r, across)
					if w > 0.0 and absf(h) < r:
						buf.set_voxel_f(lerpf(old, h, w), x, y, z, ch)
				else:
					var q := Vector3(absf(d.dot(east)), absf(h), absf(d.dot(north))) - Vector3(r, r, r)
					var box := Vector3(maxf(q.x, 0.0), maxf(q.y, 0.0), maxf(q.z, 0.0)).length() + minf(maxf(q.x, maxf(q.y, q.z)), 0.0)
					buf.set_voxel_f(minf(old, box), x, y, z, ch)
	_tool.paste(origin, buf, 1 << ch)


## Redraws the hotbar and inventory (after something else changed the counts, e.g. EdenBuilder)
func refresh() -> void:
	inventory_changed.emit()
	_refresh_ui()


## A short message above the hotbar
func toast(text: String) -> void:
	_toast_msg(text)


## Picks the item in hand (-1: nothing, with external_ui)
func select(slot: int) -> void:
	selected = -1 if slot < 0 and external_ui else posmod(slot, ITEMS.size())
	_refresh_ui()


# ------------------------------------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	for i in ITEMS.size():
		if enabled and not external_ui and event.is_action_pressed("slot_%d" % (i + 1)):
			select(i)
	if enabled and event.is_action_pressed("terrain_shape"):
		shape = (shape + 1) % SHAPES.size()
		_toast_msg("Brush: %s" % SHAPES[shape][0])
		_refresh_ui()
	if not external_ui and event.is_action_pressed("inventory"):
		_panel.visible = not _panel.visible
	if enabled and event is InputEventMouseButton and event.pressed and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and not external_ui:
			select(selected - 1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and not external_ui:
			select(selected + 1)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			place()
			_cooldown = repeat_time * 2.0


func _process(delta: float) -> void:
	_update_target()
	_cooldown -= delta
	if enabled and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and _cooldown <= 0.0:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			if gather_target:
				gather()
				_cooldown = repeat_time * 1.6
			elif dig() >= 0:
				_cooldown = repeat_time
		elif Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			place()
			_cooldown = repeat_time
	_toast_t -= delta
	_toast.modulate.a = clampf(_toast_t / 0.4, 0.0, 1.0)


# The crosshair ray (from the camera through the screen centre), kept to `reach` from the player's head
func _update_target() -> void:
	has_target = false
	gather_target = null
	var cam := _player.get_camera()
	if cam == null or not _player.ready_to_move or not enabled:
		_preview.visible = false
		return
	var from := cam.global_position
	var dir := -cam.global_basis.z
	var head := _player.global_position + _player.up_direction * 1.5
	var to := from + dir * ((from - head).length() + reach)
	var q := PhysicsRayQueryParameters3D.create(from, to, _player.collision_mask, [_player.get_rid()])
	var hit := _player.get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty() and hit.position.distance_to(head) <= reach:
		# (unloading foliage bodies are detached, then queue_free'd: they linger in physics for a frame)
		if hit.collider is VoxelInstancerRigidBody and not hit.collider.is_queued_for_deletion() and _foliage:
			var kind = _foliage.item_kinds.get(hit.collider.get_library_item_id())
			var kind_name: String = EdenFoliageLayer.kind_name(kind) if kind != null else ""
			if GATHER.has(kind_name):
				gather_target = hit.collider
				gather_kind = kind_name
		elif _is_terrain(hit.collider):
			has_target = true
			target_position = hit.position
			target_normal = hit.normal
	_active_t -= get_process_delta_time()
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_active_t = 2.0
	_preview.visible = has_target and _active_t > 0.0
	if has_target:
		_preview.global_position = target_position
		_preview.scale = Vector3.ONE * (SHAPES[shape][2] / dig_radius if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) else 1.0)


func _is_terrain(collider: Object) -> bool:
	# (the foliage's colliders sit under the terrain node too)
	return collider == _terrain or (collider is Node and _terrain.is_ancestor_of(collider) and not collider is VoxelInstancerRigidBody)


func _inside_player(p: Vector3, margin: float) -> bool:
	var up := _player.up_direction
	var base := _player.global_position
	var along := clampf((p - base).dot(up), 0.0, 1.8)
	return p.distance_to(base + up * along) < EdenPlayer.RADIUS + margin


# The item for the ground at p: the dominant material in the voxel data, else the generator's surface material
func _item_at(p: Vector3) -> int:
	var mat := material_at(p)
	if mat < 0:
		var gen: Object = _terrain.generator
		mat = int(gen.sample_surface(p - _terrain.global_position).material) if gen and gen.has_method("sample_surface") else 4
	return MATERIAL_ITEM[clampi(mat, 0, MATERIAL_ITEM.size() - 1)]


## The dominant V4 material (MAT_*) in the voxel data at p, or -1 where there is none loaded
func material_at(p: Vector3) -> int:
	var v := Vector3i(_terrain.to_local(p).round())
	_tool.channel = VoxelBuffer.CHANNEL_WEIGHTS
	var weights := _tool.get_voxel(v)
	_tool.channel = VoxelBuffer.CHANNEL_INDICES
	var indices := _tool.get_voxel(v)
	_tool.channel = VoxelBuffer.CHANNEL_SDF
	var mat := -1
	if weights != 0:
		# Mixel4: four 4-bit indices and weights; pick the heaviest
		var best := -1
		for k in 4:
			var w := (weights >> (4 * k)) & 0xF
			if w > best:
				best = w
				mat = (indices >> (4 * k)) & 0xF
	return mat if mat < MATERIAL_ITEM.size() else -1


# ------------------------------------------------------------------------------------------------------------
# UI: crosshair, hotbar, inventory panel (Tab), toast; a faint sphere where the tool will act

func _build_preview() -> void:
	_preview = MeshInstance3D.new()
	var m := SphereMesh.new()
	m.radius = dig_radius
	m.height = dig_radius * 2.0
	m.radial_segments = 16
	m.rings = 8
	_preview.mesh = m
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1, 1, 1, 0.12)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_preview.material_override = mat
	_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_preview.top_level = true
	_preview.visible = false
	add_child(_preview)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	var cross := Label.new()
	cross.text = "+"
	cross.add_theme_font_size_override("font_size", 22)
	cross.add_theme_color_override("font_outline_color", Color.BLACK)
	cross.add_theme_constant_override("outline_size", 4)
	cross.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	cross.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cross.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	root.add_child(cross)

	_toast = Label.new()
	_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.position.y -= 110
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.add_theme_color_override("font_outline_color", Color.BLACK)
	_toast.add_theme_constant_override("outline_size", 5)
	root.add_child(_toast)
	if external_ui:
		return

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	bar.position.y -= 16
	root.add_child(bar)
	for i in ITEMS.size():
		var slot := PanelContainer.new()
		slot.custom_minimum_size = Vector2(76, 58)
		var box := VBoxContainer.new()
		box.alignment = BoxContainer.ALIGNMENT_CENTER
		slot.add_child(box)
		var swatch := ColorRect.new()
		swatch.color = ITEMS[i][2]
		swatch.custom_minimum_size = Vector2(22, 14)
		swatch.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		box.add_child(swatch)
		var label := Label.new()
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 12)
		box.add_child(label)
		bar.add_child(slot)
		_slots.append(slot)
		_slot_labels.append(label)

	_panel = PanelContainer.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_panel.custom_minimum_size = Vector2(300, 0)
	_panel.visible = false
	_panel_label = Label.new()
	_panel.add_child(_panel_label)
	root.add_child(_panel)


func _slot_style(on: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0, 0, 0, 0.55 if on else 0.35)
	s.border_color = Color(1, 0.9, 0.5) if on else Color(1, 1, 1, 0.2)
	s.set_border_width_all(2)
	s.set_corner_radius_all(4)
	s.set_content_margin_all(4)
	return s


func _refresh_ui() -> void:
	if _slots.is_empty():
		return
	var lines := PackedStringArray(["INVENTORY   (Tab to close)", ""])
	var total := 0
	for i in ITEMS.size():
		_slots[i].add_theme_stylebox_override("panel", _slot_style(i == selected))
		_slot_labels[i].text = "%d  %s\n%d" % [i + 1, ITEMS[i][0], counts[i]]
		lines.append("%s %-6s %4d" % [">" if i == selected else " ", ITEMS[i][0], counts[i]])
		total += counts[i]
	lines.append("")
	lines.append("Total %d   LMB dig, RMB place (%s, T brush), 1-6 / wheel select" % [total, SHAPES[shape][0]])
	_panel_label.text = "\n".join(lines)


func _toast_msg(text: String) -> void:
	_toast.text = text
	_toast_t = 1.2
