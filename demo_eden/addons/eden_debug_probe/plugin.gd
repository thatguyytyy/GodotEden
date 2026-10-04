@tool
extends EditorPlugin
## Ctrl + left click in the 3D viewport: probes the Eden planet under the cursor (see EdenProbe) and shows the
## result in a HUD over the viewport. Esc or a Ctrl+click on empty sky hides it. Each probe is also printed to the
## Output panel for copying.

const PANEL_WIDTH := 430.0
const MARGIN := 12.0

var _sections := []
var _hit_world := Vector3.ZERO
var _camera: Camera3D
var _status := ""
var _export := WasmExport.new()


## multiplayer/server has a .gdignore (its build output isn't for Godot), so exports skip it: pack the server
## module's .wasm by hand, for hosting from the exported game (EdenWorlds.MODULE_WASM)
class WasmExport extends EditorExportPlugin:
	func _get_name() -> String:
		return "EdenServerWasm"

	func _export_begin(_features: PackedStringArray, _debug: bool, _path: String, _flags: int) -> void:
		var bytes := FileAccess.get_file_as_bytes(EdenWorlds.MODULE_WASM)
		if bytes.is_empty():
			push_error("Eden export: %s is missing, hosting won't work (spacetime build -p multiplayer/server/spacetimedb)" % EdenWorlds.MODULE_WASM)
		else:
			add_file(EdenWorlds.MODULE_WASM, bytes, false)


func _enter_tree() -> void:
	# Receive viewport input whatever node is selected
	set_input_event_forwarding_always_enabled()
	add_export_plugin(_export)


func _exit_tree() -> void:
	remove_export_plugin(_export)


func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and event.ctrl_pressed:
		_probe(camera, event.position)
		return EditorPlugin.AFTER_GUI_INPUT_STOP # don't also select/deselect nodes
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE and _visible():
		_clear()
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	return EditorPlugin.AFTER_GUI_INPUT_PASS


func _visible() -> bool:
	return not _sections.is_empty() or not _status.is_empty()


func _clear() -> void:
	_sections = []
	_status = ""
	update_overlays()


func _probe(camera: Camera3D, mouse: Vector2) -> void:
	_camera = camera
	var terrain := EdenProbe.find_planet(EditorInterface.get_edited_scene_root())
	if terrain == null:
		_sections = []
		_status = "No VoxelLodTerrain with an EdenPlanetGeneratorV4 in this scene."
		update_overlays()
		return
	var origin := camera.project_ray_origin(mouse)
	var dir := camera.project_ray_normal(mouse)
	var hit = EdenProbe.raycast(terrain, origin, dir)
	if hit == null:
		_clear() # clicked the sky
		return
	_status = ""
	_hit_world = terrain.global_transform * hit
	_sections = EdenProbe.describe(terrain, hit, camera.global_position)
	print(_as_text())
	update_overlays()


func _as_text() -> String:
	var lines := ["--- Eden probe ---"]
	for s in _sections:
		lines.append("[%s]" % s[0])
		for row in s[1]:
			lines.append("  %-16s %s" % [row[0], row[1]])
	return "\n".join(lines)


func _forward_3d_draw_over_viewport(overlay: Control) -> void:
	if not _visible():
		return
	var font := overlay.get_theme_default_font()
	var size := 13
	var line_h := font.get_height(size) + 3.0
	var ink := Color(0.93, 0.95, 0.93)
	var muted := Color(0.62, 0.68, 0.66)
	var accent := Color(0.98, 0.72, 0.28)

	# Marker at the probed point (in the viewport the click came from)
	if _camera and not _sections.is_empty() and overlay.get_viewport() == _camera.get_viewport() \
			and not _camera.is_position_behind(_hit_world):
		var sp := _camera.unproject_position(_hit_world)
		overlay.draw_circle(sp, 7.0, Color(0, 0, 0, 0.55))
		overlay.draw_arc(sp, 7.0, 0.0, TAU, 24, accent, 2.0, true)
		overlay.draw_line(sp + Vector2(-13, 0), sp + Vector2(-9, 0), accent, 2.0)
		overlay.draw_line(sp + Vector2(9, 0), sp + Vector2(13, 0), accent, 2.0)
		overlay.draw_line(sp + Vector2(0, -13), sp + Vector2(0, -9), accent, 2.0)
		overlay.draw_line(sp + Vector2(0, 9), sp + Vector2(0, 13), accent, 2.0)

	# Panel, bottom-left (the top-left holds the viewport menus)
	var lines := []
	if not _status.is_empty():
		lines.append(["status", _status, ""])
	for s in _sections:
		lines.append(["header", s[0], ""])
		for row in s[1]:
			lines.append(["row", row[0], row[1]])
	lines.append(["hint", "Ctrl+click to probe · Esc to hide · also printed to Output", ""])
	var label_w := 118.0
	var width := PANEL_WIDTH
	var wrapped := []
	for l in lines:
		if l[0] == "row":
			# Wrap long values under their label
			var avail := width - label_w - MARGIN * 2
			var words: PackedStringArray = String(l[2]).split(" ")
			var cur := ""
			var first := true
			for w in words:
				var cand := w if cur.is_empty() else cur + " " + w
				if font.get_string_size(cand, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > avail and not cur.is_empty():
					wrapped.append(["row", l[1] if first else "", cur])
					first = false
					cur = w
				else:
					cur = cand
			wrapped.append(["row", l[1] if first else "", cur])
		else:
			wrapped.append(l)
	var height := MARGIN * 2
	for l in wrapped:
		height += line_h + (6.0 if l[0] == "header" else 0.0)
	var vp_size := overlay.size
	var pos := Vector2(MARGIN, maxf(MARGIN, vp_size.y - height - MARGIN - 28.0))
	overlay.draw_rect(Rect2(pos, Vector2(width, height)), Color(0.06, 0.07, 0.08, 0.86))
	overlay.draw_rect(Rect2(pos, Vector2(width, height)), Color(1, 1, 1, 0.12), false, 1.0)
	var y := pos.y + MARGIN + font.get_ascent(size)
	for l in wrapped:
		match l[0]:
			"header":
				y += 6.0
				overlay.draw_string(font, Vector2(pos.x + MARGIN, y), String(l[1]).to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, size - 1, accent)
			"row":
				overlay.draw_string(font, Vector2(pos.x + MARGIN, y), l[1], HORIZONTAL_ALIGNMENT_LEFT, -1, size, muted)
				overlay.draw_string(font, Vector2(pos.x + MARGIN + label_w, y), l[2], HORIZONTAL_ALIGNMENT_LEFT, -1, size, ink)
			"status":
				overlay.draw_string(font, Vector2(pos.x + MARGIN, y), l[1], HORIZONTAL_ALIGNMENT_LEFT, width - MARGIN * 2, size, accent)
			"hint":
				overlay.draw_string(font, Vector2(pos.x + MARGIN, y), l[1], HORIZONTAL_ALIGNMENT_LEFT, width - MARGIN * 2, size - 2, muted)
		y += line_h
