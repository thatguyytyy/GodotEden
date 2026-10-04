extends SceneTree
## Builds the Synty character from the pack in Character/Synty:
##   synty_anims.res       AnimationLibrary of every in-place clip ("A_Walk_F_Masc.fbx" -> "Walk_F"); locomotion,
##                         idles and falls loop
##   synty_anim_tree.tres  the state machine EdenCharacterAnim drives (see there for the parameters)
##   eden_character.tscn   the mesh + an EdenCharacterAnim playing the two
## Run after changing the pack or the tree layout (overwrites all three; edit the tree here, not in the editor):
##   godot --headless --path demo_eden -s Character/_build_synty_anims.gd

const DIR := "res://Character/Synty/"
const OUT := "res://Character/"
## Air part of each jump clip (s): from takeoff to just before the landing dip. The clips are a whole jump in place;
## the body's own velocity does the rising and falling.
const JUMPS := {"Jump_Idle": [0.0, 0.62, 1.30], "Jump_Walking": [1.45, 1.05, 1.62], "Jump_Running": [2.59, 0.42, 1.15], "Jump_Sprinting": [7.24, 0.40, 1.00]}
## Swim clips (UE5 Mannequin rig): the speed each sits at in the Swim blend (m/s ahead; back is negative) and how far
## the body is lifted (m: the player floats with its feet EdenPlayer.float_depth = 1.35 m under, so the crawl, lying
## level 0.6 m above the feet, came out under water)
const SWIM_DIR := "res://Character/Swim/"
const SWIMS := {"Idle": [0.0, 0.0], "Front": [1.8, 0.6], "Backward": [-1.2, 0.0]}
## Mannequin bone -> Synty bone. Unmapped Mannequin bones (spine_02/04, neck_02, ik_*) fold into their mapped
## parents' world rotation; unmapped Synty ones (fingertips, eyes) keep their rest.
const SWIM_BONES := {"pelvis": "Hips", "Spine_01": "Spine_01", "spine_03": "Spine_02", "Spine_05": "Spine_03",
	"neck_01": "Neck", "head": "Head",
	"Clavicle_L": "Clavicle_L", "UpperArm_L": "Shoulder_L", "LowerArm_L": "Elbow_L", "Hand_L": "Hand_L",
	"Clavicle_R": "Clavicle_R", "UpperArm_R": "Shoulder_R", "LowerArm_R": "Elbow_R", "Hand_R": "Hand_R",
	"Thumb_01_L": "Thumb_01", "Thumb_02_L": "Thumb_02", "Thumb_03_L": "Thumb_03",
	"Index_01_L": "IndexFinger_01", "Index_02_L": "IndexFinger_02", "Index_03_L": "IndexFinger_03",
	"middle_01_l": "Finger_01", "middle_02_l": "Finger_02", "middle_03_l": "Finger_03",
	"Thumb_01_R": "Thumb_01_1", "Thumb_02_R": "Thumb_02_1", "Thumb_03_R": "Thumb_03_1",
	"Index_01_R": "IndexFinger_01_1", "Index_05_R": "IndexFinger_02_1", "Index_03_R": "IndexFinger_03_1",
	"middle_01_r": "Finger_01_1", "middle_02_r": "Finger_02_1", "middle_03_r": "Finger_03_1",
	"thigh_l": "UpperLeg_L", "calf_l": "LowerLeg_L", "foot_l": "Ankle_L", "Ball_L": "Ball_L",
	"thigh_r": "UpperLeg_R", "calf_r": "LowerLeg_R", "foot_r": "Ankle_R", "Ball_R": "Ball_R"}


func _init() -> void:
	var lib := AnimationLibrary.new()
	for f: String in _fbx_files(DIR + "Animations"):
		if "RootMotion" in f:
			continue
		var scene: Node = load(f).instantiate()
		var player: AnimationPlayer = scene.find_children("*", "AnimationPlayer", true, false)[0]
		var anim: Animation = player.get_animation(player.get_animation_list()[0]).duplicate(true)
		scene.free()
		var name := f.get_file().get_basename().trim_prefix("A_").trim_suffix("_Masc").trim_suffix("_Neut")
		var loops := ("/Locomotion/" in f and not "/Turn/" in f) or "/Idle/" in f or "InAir_Fall" in name
		anim.loop_mode = Animation.LOOP_LINEAR if loops else Animation.LOOP_NONE
		lib.add_animation(name, anim)
	# The pack has no swimming: the EDEN (UE5 Mannequin rig) swim clips, retargeted onto the Synty skeleton
	var target: Node = load(DIR + "PolygonSyntyCharacter.fbx").instantiate()
	var tskel: Skeleton3D = target.find_children("*", "Skeleton3D", true, false)[0]
	for clip in SWIMS:
		var anim := _retarget(SWIM_DIR + "EDEN_AS_Swimming_%s.FBX" % clip, tskel, SWIMS[clip][1])
		anim.loop_mode = Animation.LOOP_LINEAR
		lib.add_animation("Swim_" + clip, anim)
	target.free()
	print("clips: ", lib.get_animation_list().size())
	_check(ResourceSaver.save(lib, OUT + "synty_anims.res", ResourceSaver.FLAG_COMPRESS))

	var tree := _tree()
	_check(ResourceSaver.save(tree, OUT + "synty_anim_tree.tres"))

	var root := Node3D.new()
	root.name = "EdenCharacter"
	var model: Node3D = load(DIR + "PolygonSyntyCharacter.fbx").instantiate()
	model.name = "Model"
	root.add_child(model)
	model.owner = root
	var anim_tree := AnimationTree.new()
	anim_tree.name = "AnimationTree"
	anim_tree.set_script(load(OUT + "eden_character_anim.gd"))
	root.add_child(anim_tree)
	anim_tree.owner = root
	anim_tree.root_node = NodePath("../Model")
	anim_tree.add_animation_library("", load(OUT + "synty_anims.res"))
	anim_tree.tree_root = load(OUT + "synty_anim_tree.tres")
	var packed := PackedScene.new()
	_check(packed.pack(root))
	_check(ResourceSaver.save(packed, OUT + "eden_character.tscn"))
	root.free()
	print("built synty_anims.res, synty_anim_tree.tres, eden_character.tscn")
	quit()


func _tree() -> AnimationNodeStateMachine:
	var sm := AnimationNodeStateMachine.new()

	# Grounded: every gait cycle is stretched to 1 s so they stay in step when blended (the pack's cycles all start
	# on the same foot, and each gait's directions share one length); `rate` plays them at the clip's cadence.
	#   stand   the direction of travel in the character's frame (x its left, y forward, m/s): idle at the centre,
	#           walk and run rings of eight directions, sprint straight ahead. Each clip sits at its own root-motion
	#           velocity (read from its RootMotion twin), so the feet match the ground speed in every direction.
	#   uphill / downhill  the 25-degree forward gaits by speed; `incline` blends them in on slopes
	#   crouch  the crouch idle and its eight directions
	var stand := _directions(["Walk", "Run"], "Idle_Standing")
	stand.add_blend_point(_cycle("Sprint_F"), _velocity("Sprint/A_Sprint_F"))
	var uphill := _slope("Up25F")
	var downhill := _slope("Down25F")
	var incline := AnimationNodeBlend3.new()
	incline.sync = true
	var crouch := _directions(["Crouch"], "Idle_Crouching")
	var mix := AnimationNodeBlend2.new()
	mix.sync = true
	var grounded := AnimationNodeBlendTree.new()
	grounded.add_node("downhill", downhill, Vector2(0, -150))
	grounded.add_node("stand", stand, Vector2(0, 0))
	grounded.add_node("uphill", uphill, Vector2(0, 150))
	grounded.add_node("incline", incline, Vector2(250, 0))
	grounded.add_node("crouch", crouch, Vector2(250, 250))
	grounded.add_node("crouch_mix", mix, Vector2(500, 100))
	grounded.add_node("rate", AnimationNodeTimeScale.new(), Vector2(700, 100))
	grounded.connect_node("incline", 0, "downhill")
	grounded.connect_node("incline", 1, "stand")
	grounded.connect_node("incline", 2, "uphill")
	grounded.connect_node("crouch_mix", 0, "incline")
	grounded.connect_node("crouch_mix", 1, "crouch")
	grounded.connect_node("rate", 0, "crouch_mix")
	grounded.connect_node("output", 0, "rate")
	grounded.set_node_position("output", Vector2(900, 100))

	# Jump: the air part of the clip for the speed the jump started at
	var jump := AnimationNodeBlendSpace1D.new()
	jump.max_space = 8.0
	for clip in JUMPS:
		var a := _clip(clip)
		a.use_custom_timeline = true
		a.start_offset = JUMPS[clip][1]
		a.timeline_length = JUMPS[clip][2] - JUMPS[clip][1]
		a.loop_mode = Animation.LOOP_NONE
		jump.add_blend_point(a, JUMPS[clip][0])
	# Fall: by downward speed; Land: by impact speed
	var fall := AnimationNodeBlendSpace1D.new()
	fall.max_space = 20.0
	fall.add_blend_point(_clip("InAir_FallShort"), 0.0)
	fall.add_blend_point(_clip("InAir_FallLarge"), 12.0)
	var land := AnimationNodeBlendSpace1D.new()
	land.max_space = 20.0
	land.add_blend_point(_clip("Land_IdleSoft"), 3.0)
	land.add_blend_point(_clip("Land_IdleMedium"), 7.0)
	land.add_blend_point(_clip("Land_IdleHard"), 12.0)

	# Swim: by speed ahead (treading water at 0, back strokes backward)
	var swim := AnimationNodeBlendSpace1D.new()
	swim.min_space = -3.0
	swim.max_space = 4.0
	for clip in SWIMS:
		swim.add_blend_point(_clip("Swim_" + clip), SWIMS[clip][0])

	sm.add_node("Swim", swim, Vector2(300, 350))
	sm.add_node("Grounded", grounded, Vector2(300, 100))
	sm.add_node("Jump", jump, Vector2(550, 0))
	sm.add_node("Fall", fall, Vector2(800, 100))
	sm.add_node("Land", land, Vector2(550, 250))
	sm.add_transition("Start", "Grounded", _go("", 0.0))
	sm.add_transition("Grounded", "Jump", _go("jump", 0.1))
	sm.add_transition("Grounded", "Fall", _go("falling", 0.3))
	sm.add_transition("Jump", "Fall", _go("falling", 0.3)) # (the jump clip holds its last frame until the descent)
	for from in ["Jump", "Fall"]:
		var hard := _go("land", 0.1)
		hard.priority = 0
		sm.add_transition(from, "Land", hard)
		var soft := _go("grounded", 0.15)
		soft.priority = 1
		sm.add_transition(from, "Grounded", soft)
	var land_done := _go("", 0.25)
	land_done.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END
	sm.add_transition("Land", "Grounded", land_done)
	sm.add_transition("Land", "Jump", _go("jump", 0.1))
	for from in ["Grounded", "Jump", "Fall", "Land"]:
		sm.add_transition(from, "Swim", _go("swimming", 0.4))
	sm.add_transition("Swim", "Grounded", _go("grounded", 0.4))
	sm.add_transition("Swim", "Jump", _go("jump", 0.2))
	sm.add_transition("Swim", "Fall", _go("falling", 0.3))
	return sm


## Eight directions for each gait around an idle: forward, the forward diagonals and the sides from the "Fwd"
## strafes (hips facing ahead), backward and the back diagonals from the "Bck" ones
func _directions(gaits: Array, idle: String) -> AnimationNodeBlendSpace2D:
	var bs := AnimationNodeBlendSpace2D.new()
	bs.min_space = Vector2(-8, -8)
	bs.max_space = Vector2(8, 8)
	bs.x_label = "left"
	bs.y_label = "forward"
	bs.sync = true
	bs.add_blend_point(_cycle(idle), Vector2.ZERO)
	for gait: String in gaits:
		for d in ["FwdStrafeF", "FwdStrafeFL", "FwdStrafeFR", "FwdStrafeL", "FwdStrafeR", "BckStrafeB", "BckStrafeBL", "BckStrafeBR"]:
			var clip: String = gait + "_" + d
			bs.add_blend_point(_cycle(clip), _velocity(gait + "/A_" + clip))
	return bs


## A slope gait by forward speed (idle at 0)
func _slope(kind: String) -> AnimationNodeBlendSpace1D:
	var bs := AnimationNodeBlendSpace1D.new()
	bs.max_space = 8.0
	bs.sync = true
	bs.add_blend_point(_cycle("Idle_Standing"), 0.0)
	for gait: String in ["Walk", "Run", "Sprint"]:
		bs.add_blend_point(_cycle(gait + "_" + kind), _velocity(gait + "/A_" + gait + "_" + kind).y)
	return bs


## Root-motion velocity of a locomotion clip (m/s in the character's frame: x its left, y forward), from its
## RootMotion twin ("Walk/A_Walk_F" -> Locomotion/Walk/A_Walk_F_RootMotion_Masc.fbx)
func _velocity(clip: String) -> Vector2:
	var scene: Node = load(DIR + "Animations/Masculine/Locomotion/" + clip + "_RootMotion_Masc.fbx").instantiate()
	var player: AnimationPlayer = scene.find_children("*", "AnimationPlayer", true, false)[0]
	var anim := player.get_animation(player.get_animation_list()[0])
	scene.free()
	var t := anim.find_track("Skeleton3D:Root", Animation.TYPE_POSITION_3D)
	var d: Vector3 = anim.track_get_key_value(t, anim.track_get_key_count(t) - 1) - anim.track_get_key_value(t, 0)
	return Vector2(d.x, d.z) / anim.length


## A looping gait cycle, stretched to a 1 s timeline
func _cycle(clip: String) -> AnimationNodeAnimation:
	var a := _clip(clip)
	a.use_custom_timeline = true
	a.timeline_length = 1.0
	a.stretch_time_scale = true
	a.loop_mode = Animation.LOOP_LINEAR
	return a


func _clip(clip: String) -> AnimationNodeAnimation:
	var a := AnimationNodeAnimation.new()
	a.animation = clip
	return a


## Another rig's clip on the Synty skeleton, in place. Each mapped bone takes the source bone's change of world
## rotation from its rest, applied to the Synty bone first turned onto the source's rest direction (the Mannequin
## rests in an A-pose, Synty in a T-pose), in body frames matched by hips, head and thighs. The hips' offset follows,
## scaled by body size.
func _retarget(path: String, tskel: Skeleton3D, lift: float) -> Animation:
	var scene: Node = load(path).instantiate()
	var sskel: Skeleton3D = scene.find_children("*", "Skeleton3D", true, false)[0]
	var player: AnimationPlayer = scene.find_children("*", "AnimationPlayer", true, false)[0]
	var src: Animation = player.get_animation(player.get_animation_list()[0])
	var f := (_body(tskel, "Hips", "Head", "UpperLeg_L", "UpperLeg_R") * _body(sskel, "pelvis", "head", "thigh_l", "thigh_r").inverse()).get_rotation_quaternion()
	var t_hips := tskel.find_bone("Hips")
	var s_pelvis := sskel.find_bone("pelvis")
	var size := (_rest_pos(tskel, "Head") - _rest_pos(tskel, "Hips")).length() / (_rest_pos(sskel, "head") - _rest_pos(sskel, "pelvis")).length()
	# Target bone -> [source bone, the turn of its rest onto the source's rest direction]
	var map := {}
	for s: String in SWIM_BONES:
		var si := sskel.find_bone(s)
		var ti := tskel.find_bone(SWIM_BONES[s])
		if si < 0 or ti < 0:
			push_error("swim retarget: no bone %s / %s" % [s, SWIM_BONES[s]])
			continue
		# The bone's direction: to its first mapped child (a hand to its middle finger); a leaf turns with its parent
		var child := ""
		for s2: String in SWIM_BONES:
			if tskel.get_bone_parent(tskel.find_bone(SWIM_BONES[s2])) == ti and (child == "" or s2.begins_with("middle")):
				child = s2
		var turn := Quaternion()
		if child != "" and ti != t_hips:
			var ds := f * (_rest_pos(sskel, child) - _rest_pos(sskel, s)).normalized()
			var dt := (_rest_pos(tskel, SWIM_BONES[child]) - _rest_pos(tskel, SWIM_BONES[s])).normalized()
			turn = Quaternion(dt, ds)
		elif map.has(tskel.get_bone_parent(ti)):
			turn = map[tskel.get_bone_parent(ti)][1]
		map[ti] = [si, turn]
	var out := Animation.new()
	out.length = src.length
	var tracks := {}
	for ti in map:
		tracks[ti] = out.add_track(Animation.TYPE_ROTATION_3D)
		out.track_set_path(tracks[ti], "Skeleton3D:" + tskel.get_bone_name(ti))
	var hips_pos := out.add_track(Animation.TYPE_POSITION_3D)
	out.track_set_path(hips_pos, "Skeleton3D:Hips")
	var s_root := sskel.get_bone_global_rest(sskel.get_bone_parent(s_pelvis))
	var pelvis_rest := sskel.get_bone_global_rest(s_pelvis).origin
	var frames := ceili(src.length * 30.0)
	for k in frames + 1:
		var time := minf(k / 30.0, src.length)
		# Source world rotations (its root held at rest: in place)
		var sg := []
		for i in sskel.get_bone_count():
			var local := sskel.get_bone_rest(i).basis.get_rotation_quaternion()
			var tr := src.find_track("Skeleton3D:" + sskel.get_bone_name(i), Animation.TYPE_ROTATION_3D)
			if tr >= 0 and sskel.get_bone_parent(i) >= 0:
				local = src.rotation_track_interpolate(tr, time)
			var p := sskel.get_bone_parent(i)
			sg.append(sg[p] * local if p >= 0 else local)
		var tg := []
		for i in tskel.get_bone_count():
			var p := tskel.get_bone_parent(i)
			var parent: Quaternion = tg[p] if p >= 0 else Quaternion()
			var g: Quaternion
			if map.has(i):
				var si: int = map[i][0]
				var rs := sskel.get_bone_global_rest(si).basis.get_rotation_quaternion()
				var rt := tskel.get_bone_global_rest(i).basis.get_rotation_quaternion()
				g = (f * sg[si] * rs.inverse() * f.inverse()) * map[i][1] * rt
				out.rotation_track_insert_key(tracks[i], time, (parent.inverse() * g).normalized())
			else:
				g = parent * tskel.get_bone_rest(i).basis.get_rotation_quaternion()
			tg.append(g)
		var tr := src.find_track("Skeleton3D:pelvis", Animation.TYPE_POSITION_3D)
		var pelvis := s_root * (src.position_track_interpolate(tr, time) if tr >= 0 else sskel.get_bone_rest(s_pelvis).origin)
		var hips := tskel.get_bone_global_rest(t_hips).origin + f * (pelvis - pelvis_rest) * size + Vector3.UP * lift
		out.position_track_insert_key(hips_pos, time, tskel.get_bone_global_rest(tskel.get_bone_parent(t_hips)).affine_inverse() * hips)
	scene.free()
	return out


## A rig's body frame at rest: x its left (right thigh to left), y up (hips to head)
static func _body(skel: Skeleton3D, hips: String, head: String, left: String, right: String) -> Basis:
	var up := (_rest_pos(skel, head) - _rest_pos(skel, hips)).normalized()
	var x := _rest_pos(skel, left) - _rest_pos(skel, right)
	x = (x - up * x.dot(up)).normalized()
	return Basis(x, up, x.cross(up))


static func _rest_pos(skel: Skeleton3D, bone: String) -> Vector3:
	return skel.get_bone_global_rest(skel.find_bone(bone)).origin


## An automatic transition on `condition` (none: always)
func _go(condition: String, xfade: float) -> AnimationNodeStateMachineTransition:
	var t := AnimationNodeStateMachineTransition.new()
	t.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
	t.advance_condition = condition
	t.xfade_time = xfade
	return t


func _fbx_files(dir: String) -> Array:
	var out := []
	for d in DirAccess.get_directories_at(dir):
		out.append_array(_fbx_files(dir + "/" + d))
	for f in DirAccess.get_files_at(dir):
		if f.get_extension().to_lower() == "fbx":
			out.append(dir + "/" + f)
	return out


func _check(err: int) -> void:
	if err != OK:
		push_error("save failed: %s" % error_string(err))
		quit(1)
