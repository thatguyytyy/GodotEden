class_name EdenCharacterAnim
extends AnimationTree
## Drives the Synty character's state machine (synty_anim_tree.tres, clips in synty_anims.res; both made by
## _build_synty_anims.gd): Grounded (idle, walk/run in eight directions, sprint ahead, slope gaits, crouch) ->
## Jump -> Fall -> Land. The owner sets the inputs from its physics step, as for the old procedural EdenAnimator,
## plus the direction of travel in the body's frame; `step` fires as each foot strikes.

signal step(foot: int, strength: float)

## Clip speeds (m/s, from the RootMotion variants) and cycle lengths (s; every direction of a gait shares its length):
## the gait cycles are stretched to 1 s in the tree, and the TimeScale plays them at the clip's own cadence for the
## speed, so feet don't slide
const STAND_SPEEDS := [0.0, 1.45, 2.59, 7.24]
const STAND_CYCLES := [1.77, 1.03, 0.70, 0.60]
const CROUCH_SPEEDS := [0.0, 1.45]
const CROUCH_CYCLES := [1.77, 1.03]
## Where each foot strikes in the (normalised) cycle: the left foot is furthest forward at ~0.85, the right at ~0.35
const STRIKE_PHASE := [0.85, 0.35]

var ground_speed := 0.0
var airborne := false
var crouching := false
var swimming := false
var vertical_speed := 0.0
## Which way the body moves in its own frame (x its left, y ahead; unit length): straight ahead, sideways and
## backward pick the matching strafe clips
var move_direction := Vector2(0, 1)
## Ground slope along the direction of travel, -1 (25 deg down) .. 1 (25 deg up)
var incline := 0.0
## Speed that counts as a full-strength footstep
var run_speed := 2.6
## idle, walk, run, sprint, crouch_idle, crouch_walk, jump, fall, swim, tread (what EdenNet sends)
var state := "idle"

var _crouch := 0.0
var _incline := 0.0
var _phase := 0.0
var _land_t := 10.0
var _was_grounded := true
var _playback: AnimationNodeStateMachinePlayback


func _ready() -> void:
	_playback = get("parameters/playback")


## The body just touched down after falling at `impact` m/s
func land(impact: float) -> void:
	set("parameters/Land/blend_position", impact)
	_land_t = 0.0 if impact > 3.0 and ground_speed < 1.5 else 10.0 # moving on, the gait carries straight through


func _process(delta: float) -> void:
	var air := airborne and not swimming
	_crouch = move_toward(_crouch, 1.0 if crouching else 0.0, delta * 5.0)
	_incline = lerpf(_incline, 0.0 if air else incline, 1.0 - exp(-delta * 4.0))
	_land_t += delta
	set("parameters/conditions/jump", air and vertical_speed > 0.5)
	set("parameters/conditions/falling", air and vertical_speed <= 0.5)
	set("parameters/conditions/land", not air and _land_t < 0.2)
	set("parameters/conditions/grounded", not air and not swimming)
	set("parameters/conditions/swimming", swimming)
	if air:
		if _was_grounded:
			set("parameters/Jump/blend_position", ground_speed)
		set("parameters/Fall/blend_position", -vertical_speed)
	_was_grounded = not air
	var travel := move_direction.normalized() * ground_speed if move_direction.length_squared() > 0.01 else Vector2(0, ground_speed)
	set("parameters/Grounded/stand/blend_position", travel)
	set("parameters/Grounded/crouch/blend_position", travel)
	set("parameters/Swim/blend_position", travel.y)
	set("parameters/Grounded/uphill/blend_position", ground_speed)
	set("parameters/Grounded/downhill/blend_position", ground_speed)
	# The slope clips only go forward: sideways or backward the level gaits stay
	set("parameters/Grounded/incline/blend_amount", _incline * clampf(travel.y / maxf(ground_speed, 0.01), 0.0, 1.0))
	set("parameters/Grounded/crouch_mix/blend_amount", _crouch)
	var rate := lerpf(cycle_rate(ground_speed, STAND_SPEEDS, STAND_CYCLES), cycle_rate(ground_speed, CROUCH_SPEEDS, CROUCH_CYCLES), _crouch)
	set("parameters/Grounded/rate/scale", rate)

	# Footsteps at the strike phases of the synced gait cycle (it restarts with the Grounded state)
	var node := _playback.get_current_node() if _playback else &""
	if node != &"Grounded":
		_phase = 0.0
	elif ground_speed > 0.3 and not swimming:
		var before := _phase
		_phase = fposmod(_phase + rate * delta, 1.0)
		var strength := clampf(ground_speed / run_speed, 0.25, 1.0) * lerpf(1.0, 0.5, _crouch)
		for foot in 2:
			if _crossed(before, _phase, STRIKE_PHASE[foot]):
				step.emit(foot, strength)
	if swimming:
		state = "swim" if ground_speed > 0.4 else "tread"
	elif node == &"Jump" or node == &"Fall":
		state = "jump" if vertical_speed > 0.5 else "fall"
	elif crouching:
		state = "crouch_walk" if ground_speed > 0.15 else "crouch_idle"
	else:
		state = "sprint" if ground_speed > 4.5 else ("run" if ground_speed > 2.0 else ("walk" if ground_speed > 0.15 else "idle"))


## Cycles per second at `speed`: blend-space neighbours interpolated (their stride speed interpolates the same way,
## so it matches `speed` between them), scaled up past the fastest clip
static func cycle_rate(speed: float, speeds: Array, cycles: Array) -> float:
	var n := speeds.size()
	if speed >= speeds[n - 1]:
		return speed / speeds[n - 1] / cycles[n - 1]
	for i in n - 1:
		if speed < speeds[i + 1]:
			var t: float = (speed - speeds[i]) / (speeds[i + 1] - speeds[i])
			return lerpf(1.0 / cycles[i], 1.0 / cycles[i + 1], maxf(t, 0.0))
	return 1.0 / cycles[0]


static func _crossed(a: float, b: float, at: float) -> bool:
	return (a < at and b >= at) if b >= a else (a < at or b >= at)
