class_name EdenRemotePlayer
extends Node3D
## Another player seen through EdenNet: the same character and animation tree as the local player, gliding to the
## position/facing the server last reported and animated from the reported state and speed. A name tag floats
## above.

const MODEL := preload("res://Character/eden_character.tscn")

var _planet: Node3D
var _target := Vector3.ZERO
var _yaw := 0.0
var _has_target := false
var _animator: EdenCharacterAnim
var _label: Label
var _local: EdenPlayer
var _grounded := true
var _last_press = null


static func create(planet: Node3D, local: EdenPlayer = null) -> EdenRemotePlayer:
	var r := EdenRemotePlayer.new()
	r._planet = planet
	r._local = local
	var model: Node3D = MODEL.instantiate()
	model.rotation.y = PI # the rig faces +Z; the body's forward is -Z
	r.add_child(model)
	r._animator = model.get_node("AnimationTree")
	# The name tag is 2D, over the screen: as a Label3D (no depth test, to show through walls) the atmosphere's fog
	# pass took its distance from whatever was behind it and fogged it like the far hills
	var layer := CanvasLayer.new()
	r.add_child(layer)
	r._label = Label.new()
	r._label.add_theme_font_size_override("font_size", 16)
	r._label.add_theme_color_override("font_outline_color", Color.BLACK)
	r._label.add_theme_constant_override("outline_size", 6)
	r._label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(r._label)
	return r


func set_target(world_pos: Vector3, yaw: float, state: String, speed: float, player_name: String) -> void:
	_target = world_pos
	_yaw = yaw
	if not _has_target:
		_has_target = true
		global_position = world_pos
	_label.text = player_name
	_animator.ground_speed = speed
	_animator.crouching = state.begins_with("crouch")
	_animator.airborne = state == "jump" or state == "fall"
	_animator.vertical_speed = 3.0 if state == "jump" else -3.0
	_animator.swimming = state == "swim" or state == "tread"
	_grounded = not (_animator.airborne or _animator.swimming)


func _process(delta: float) -> void:
	if not _has_target:
		return
	# Glide toward the last report (updates come ~10 per second); far off (a teleport) jump straight there
	if global_position.distance_to(_target) > 20.0:
		global_position = _target
	global_position = global_position.lerp(_target, 1.0 - exp(-delta * 10.0))
	var up := (global_position - _planet.global_position).normalized()
	var forward := EdenPlayer._north(up).rotated(up, _yaw)
	global_basis = global_basis.slerp(Basis.looking_at(forward, up), 1.0 - exp(-delta * 10.0)).orthonormalized()
	# Name tag over the head, on screen
	var cam := get_viewport().get_camera_3d()
	var head := global_position + up * 2.1
	_label.visible = cam != null and not cam.is_position_behind(head)
	if _label.visible:
		_label.position = cam.unproject_position(head) - Vector2(_label.size.x * 0.5, _label.size.y)
	# Their footsteps in the snow, live, within EdenNet.TRAIL_RANGE of us (the trail map covers ~30 m round us). The
	# server's snow_trail rows carry the same paths for when we come near later
	if _local and _local._ambience and _local.global_position.distance_to(global_position) < EdenNet.TRAIL_RANGE:
		_last_press = EdenPlayer.press_snow_stroke(_local._ambience, _last_press, global_position, _grounded)
	else:
		_last_press = null
