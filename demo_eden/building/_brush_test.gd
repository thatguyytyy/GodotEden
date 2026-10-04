extends SceneTree
## Terrain brushes (EdenMiner.SHAPES, T in game) on eden_play.tscn: a mound raises the ground, a block stands up from
## it, flatten levels it back toward the aimed height, smooth runs. Screenshots along the way.
##   godot --audio-driver Dummy --path demo_eden --resolution 1280x720 -s res://building/_brush_test.gd -- --out=<dir>

var play: Node
var player: EdenPlayer
var miner: EdenMiner
var out := "user://"
var ok := true
var t0 := 0
var step := 0
var at := Vector3.ZERO
var ground0 := 0.0
var mound_h := 0.0
var block_at := Vector3.ZERO
var block_g0 := 0.0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.trim_prefix("--out=")
	play = load("res://eden_play.tscn").instantiate()
	root.add_child(play)
	current_scene = play
	t0 = Time.get_ticks_msec()


func _check(cond: bool, msg: String) -> void:
	print("BRUSH_TEST %s %s" % ["ok  " if cond else "FAIL", msg])
	ok = ok and cond


func _el() -> float:
	return (Time.get_ticks_msec() - t0) / 1000.0


func _next() -> void:
	step += 1
	t0 = Time.get_ticks_msec()


func _shot(name: String) -> void:
	root.get_texture().get_image().save_png(out.path_join("brush_%s.png" % name))


func _ground(p: Vector3) -> float:
	var up := (p - player._center()).normalized()
	var q := PhysicsRayQueryParameters3D.create(p + up * 6.0, p - up * 6.0, 1, [player.get_rid()])
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	return (hit.position - p).dot(up) if not hit.is_empty() else -99.0


func _brush(name: String) -> void:
	for i in EdenMiner.SHAPES.size():
		if EdenMiner.SHAPES[i][0] == name:
			miner.shape = i


func _process(_d: float) -> bool:
	if player == null:
		player = play.get("player")
		return false
	match step:
		0:
			if player.ready_to_move and _el() > 3.0:
				miner = player.miner
				player._pitch = -0.35
				_next()
			elif _el() > 120.0:
				_check(false, "spawned")
				return _finish()
		1: # mound
			if _el() > 1.0:
				_check(miner.has_target, "crosshair on the ground")
				at = miner.target_position
				ground0 = _ground(at)
				_shot("0_before")
				miner.counts[0] = 5
				miner.select(0)
				_brush("Mound")
				_check(miner.place(), "placed a mound")
				_check(miner.counts[0] == 4, "it used one Dirt")
				_next()
		2:
			if _el() > 1.5:
				mound_h = _ground(at) - ground0
				_check(mound_h > 0.3, "the mound raised the ground %.2f m" % mound_h)
				_shot("1_mound")
				_brush("Block")
				# a 2 m cube needs room: 2.5 m further out than the mound, on the ground there
				var up := (at - player._center()).normalized()
				var out_dir := (at - player.global_position).slide(up).normalized()
				block_at = at + out_dir * 2.5
				block_at += up * _ground(block_at)
				block_g0 = _ground(block_at)
				miner.target_position = block_at
				miner.target_normal = up
				_check(miner.place(), "placed a block (%s)" % miner._toast.text)
				_next()
		3:
			if _el() > 1.5:
				_shot("2_block")
				var h := _ground(block_at) - block_g0
				_check(h > 1.5, "a block stands there (%.2f m tall)" % h)
				_brush("Flatten")
				var n := miner.counts[0]
				# flatten to the original height: aim at where the ground was
				miner.target_position = at + (at - player._center()).normalized() * ground0
				for i in 3:
					_check(miner.place(), "flatten pass %d" % i)
				_check(miner.counts[0] == n, "flatten is free")
				_next()
		4:
			if _el() > 1.5:
				var h := _ground(at) - ground0
				_check(absf(h) < mound_h, "flatten brought it back down (%.2f m from the original)" % h)
				_shot("3_flat")
				_brush("Smooth")
				_check(miner.place(), "smoothed")
				_next()
		5:
			if _el() > 1.5:
				_shot("4_smooth")
				return _finish()
	return false


func _finish() -> bool:
	print("BRUSH_TEST %s" % ("PASSED" if ok else "FAILED"))
	quit(0 if ok else 1)
	return true
