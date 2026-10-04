@tool
class_name EdenBodyPainter
extends SubViewport
## Paints one sky body's surface (a moon or the parent planet) with the universal planet shader into an
## equirectangular map, which the sky shader wraps on the body and lights with the real sun. The map is repainted a
## few times a second, so clouds, storms and fires move without costing a full render every frame.

const SHADER := preload("res://shaders/planet_universal_parent.gdshader")

## Seconds between repaints (the surface moves slowly); 0 paints it once
@export var refresh_interval := 0.25

var material := ShaderMaterial.new()
var _since := 0.0


static func create(width: int, params: Dictionary) -> EdenBodyPainter:
	var p := EdenBodyPainter.new()
	p.size = Vector2i(width, width / 2)
	p.disable_3d = true
	p.render_target_update_mode = SubViewport.UPDATE_ONCE
	p.material.shader = SHADER
	p.set_look(params)
	var rect := ColorRect.new()
	rect.size = Vector2(p.size)
	rect.material = p.material
	p.add_child(rect)
	return p


## The body's shader settings (anything not given is the shader's default), and a repaint
func set_look(params: Dictionary) -> void:
	for k in material.shader.get_shader_uniform_list():
		material.set_shader_parameter(k.name, null) # (back to the default)
	# An unlit albedo map, full detail, none of the shader's "sensor" effects; then the body's own look
	var all := {"equirect_output": true, "sensor_gating": false, "pixelate_mode": 0, "sensor_level": 1.0,
			"auto_lod": false, "sun_color": Color.WHITE, "ambient_light": 0.0, "randomize_params": false}
	all.merge(params, true)
	for k in all:
		material.set_shader_parameter(k, all[k])
	render_target_update_mode = SubViewport.UPDATE_ONCE


func _process(delta: float) -> void:
	_since += delta
	if refresh_interval > 0.0 and _since >= refresh_interval:
		_since = 0.0
		render_target_update_mode = SubViewport.UPDATE_ONCE
