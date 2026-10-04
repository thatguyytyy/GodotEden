extends SceneTree
## Gameplay test on eden_play.tscn: digging and placing ground (and what they give back), refusals, chopping a
## tree, and building: a stone foundation, a floor snapped beside it, a wall snapped onto its edge, wooden floors
## hung off the wall until support runs out, then removing the wall brings them down. Screenshots along the way.
##   godot --audio-driver Dummy --path demo_eden --resolution 1280x720 -s res://building/_build_test.gd -- --out=<dir>

var play: Node
var player: EdenPlayer
var miner: EdenMiner
var builder: EdenBuilder
var out := "user://"
var ok := true
var t0 := 0
var step := 0
var dig_at := Vector3.ZERO
var ground0 := 0.0
var wall: EdenBuildPiece
var hanging := 0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.trim_prefix("--out=")
	play = load("res://eden_play.tscn").instantiate()
	root.add_child(play)
	current_scene = play
	t0 = Time.get_ticks_msec()


func _check(cond: bool, msg: String) -> void:
	print("BUILD_TEST %s %s" % ["ok  " if cond else "FAIL", msg])
	ok = ok and cond


func _el() -> float:
	return (Time.get_ticks_msec() - t0) / 1000.0


func _next() -> void:
	step += 1
	t0 = Time.get_ticks_msec()


func _shot(name: String) -> void:
	root.get_texture().get_image().save_png(out.path_join("build_%s.png" % name))


# Height along up of the ground under p (vertical ray, terrain only)
func _ground(p: Vector3) -> float:
	var up := (p - player._center()).normalized()
	var q := PhysicsRayQueryParameters3D.create(p + up * 4.0, p - up * 6.0, 1, [player.get_rid()])
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	return (hit.position - p).dot(up) if not hit.is_empty() else -99.0


func _process(_d: float) -> bool:
	if player == null:
		player = play.get("player")
		return false
	match step:
		0: # on the ground, looking down a little
			if player.ready_to_move and _el() > 3.0:
				miner = player.miner
				builder = player.builder
				_check(miner != null and builder != null, "the player has the miner and the builder")
				player._pitch = -0.7
				_next()
			elif _el() > 120.0:
				_check(false, "spawned")
				return _finish()
		1: # dig
			if _el() > 1.0:
				_check(miner.has_target, "crosshair on the ground")
				dig_at = miner.target_position
				ground0 = _ground(dig_at)
				var item := miner.dig()
				_check(item >= 0 and miner.counts[item] == 1, "dug up 1 %s" % (EdenMiner.ITEMS[item][0] if item >= 0 else "?"))
				_next()
		2: # the hole; then place Stone into it
			if _el() > 1.5:
				var g := _ground(dig_at)
				_check(g < ground0 - 0.5, "the ground there dropped %.2f m" % (ground0 - g))
				_check(miner.has_target, "still aiming at ground (the hole)")
				miner.counts[EdenMiner.STONE] = 1
				miner.select(EdenMiner.STONE)
				_check(miner.place(), "placed Stone")
				_check(miner.counts[EdenMiner.STONE] == 0, "it used the Stone")
				_check(not miner.place(), "can't place with none left")
				_next()
		3: # the placed ground mines back as what it was made of
			if _el() > 1.5:
				var mat := miner.material_at(miner.target_position - miner.target_normal * 0.3)
				_check(mat == 1, "the placed ground is rock (material %d)" % mat)
				var item := miner.dig()
				_check(item == EdenMiner.STONE, "and mines back as Stone (%s)" % (EdenMiner.ITEMS[item][0] if item >= 0 else "?"))
				miner.counts[EdenMiner.WOOD] = 3
				miner.select(EdenMiner.WOOD)
				_check(not miner.place() and miner.counts[EdenMiner.WOOD] == 3, "Wood can't be placed as ground")
				# Too close: aim at the player's own feet
				miner.select(EdenMiner.STONE)
				miner.counts[EdenMiner.STONE] = 1
				var saved := miner.target_position
				miner.target_position = player.global_position
				_check(not miner.place() and miner.counts[EdenMiner.STONE] == 1, "won't place ground inside the player")
				miner.target_position = saved
				_next()
		4: # chop the nearest tree
			var tree := _nearest_tree()
			_check(tree != null, "a tree collider nearby")
			if tree == null:
				_next()
				return false
			var wood0 := miner.counts[EdenMiner.WOOD]
			var tree_kind := _kind_name(tree)
			var got := -1
			var hits := 0
			while got < 0 and hits < 10:
				miner.gather_target = tree
				miner.gather_kind = _kind_name(tree)
				got = miner.gather()
				hits += 1
			_check(got == EdenMiner.WOOD and miner.counts[EdenMiner.WOOD] > wood0,
					"felled a %s in %d hits: +%d Wood" % [tree_kind, hits, miner.counts[EdenMiner.WOOD] - wood0])
			_check(tree.is_queued_for_deletion(), "the tree is gone")
			_next()
		5: # build
			miner.counts[EdenMiner.WOOD] = 40
			miner.counts[EdenMiner.STONE] = 20
			builder.set_active(true)
			_build()
			_next()
		6:
			if _el() > 1.0:
				_shot("structure")
				# Take the wall away: what hung off it comes down
				var before := builder.pieces.size()
				var stone0 := miner.counts[EdenMiner.STONE]
				builder.remove(wall)
				miner.counts[EdenMiner.STONE] += 3 # (remove_target refunds; remove() is the bare removal)
				var after := builder.pieces.size()
				_check(before - after == 1 + hanging, "removing the wall brought down the %d floors it held (%d -> %d pieces)" % [hanging, before, after])
				_check(miner.counts[EdenMiner.STONE] == stone0 + 3, "stone refunded")
				_next()
		7:
			if _el() > 1.0:
				_shot("after_collapse")
				return _finish()
	return false


func _build() -> void:
	var up := player.up_direction
	var fwd := EdenPlayer._north(up).rotated(up, player._yaw)
	var basis := Basis.looking_at(fwd, up)
	var spot := player.global_position + fwd * 5.0
	var g := spot + up * _ground(spot)
	# Clear the plot (as you'd clear land): no trees or bushes in the way of the pieces or the view
	miner._foliage.remove_instances_in_sphere(miner._foliage.to_local(spot - basis.z * 5.0), 16.0)
	var cost_stone := miner.counts[EdenMiner.STONE]
	# Foundation
	var f1 := Transform3D(basis, g + up * 0.2)
	_check(builder.place_at("stone_floor", f1) == "", "placed a stone floor on the ground")
	var floor1: EdenBuildPiece = builder.pieces[-1]
	_check(floor1.grounded and is_equal_approx(floor1.support, 1.0), "it stands on the ground (support %.2f)" % floor1.support)
	_check(miner.counts[EdenMiner.STONE] == cost_stone - 3, "cost 3 Stone")
	# A second floor, roughly beside it: snapping lines it up edge to edge
	var aim := f1 * Vector3(1.0, 0.2, 0.0)
	var raw := Transform3D(basis, f1.origin + basis.x * 2.3 + up * 0.15)
	var f2 := builder.snapped("stone_floor", raw, aim)
	_check(f2.origin.distance_to(f1.origin + basis.x * 2.0) < 0.02, "a floor snaps edge to edge (off by %.3f m)" % f2.origin.distance_to(f1.origin + basis.x * 2.0))
	# Aimed at the floor's top near its edge (the ghost pushed up onto it): still level beside it, not a step up
	var on_top := builder.snapped("stone_floor", Transform3D(basis, f1.origin + basis.x * 0.9 + up * 0.4), f1 * Vector3(0.8, 0.2, 0.0))
	_check(on_top.origin.distance_to(f1.origin + basis.x * 2.0) < 0.02, "aimed at its top, a floor still snaps level beside it (off by %.3f m)" % on_top.origin.distance_to(f1.origin + basis.x * 2.0))
	_check(builder.place_at("stone_floor", f2) == "", "placed it")
	# A wall on the foundation's back edge
	var edge := f1 * Vector3(0.0, 0.2, -1.0)
	var w := builder.snapped("stone_wall", Transform3D(basis, edge + up * 1.3 + basis.x * 0.3), edge)
	_check(w.origin.distance_to(edge + up * 1.0) < 0.02, "a wall snaps onto the floor's edge (off by %.3f m)" % w.origin.distance_to(edge + up * 1.0))
	var wr := builder.place_at("stone_wall", w)
	_check(wr == "", "placed the wall %s" % wr)
	wall = builder.pieces[-1]
	_check(wall.support > 0.9, "the wall is carried by the floor (support %.2f)" % wall.support)
	_check(builder.place_at("stone_wall", w) != "", "can't place a second wall in the same spot")
	# Wooden floors hung off the top of the wall, outward, until support gives out
	var prev_aim := w * Vector3(0.0, 1.0, 0.0)
	var reason := ""
	for i in 8:
		var raw_f := Transform3D(basis, prev_aim - basis.z * 1.0 + up * 0.1)
		var fx := builder.snapped("wood_floor", raw_f, prev_aim)
		reason = builder.place_at("wood_floor", fx)
		if reason != "":
			break
		hanging += 1
		var p: EdenBuildPiece = builder.pieces[-1]
		print("BUILD_TEST info hanging floor %d support %.2f" % [hanging, p.support])
		prev_aim = fx * Vector3(0.0, 0.1, -1.0)
	_check(hanging >= 2 and hanging <= 6 and reason.begins_with("Not enough support"),
			"hung %d wooden floors off the wall before: %s" % [hanging, reason])
	# A side-on view of the structure for the screenshot: stand off to the side and look across at it
	player.global_position = spot + basis.x * 10.0 - basis.z * 5.0 + up * (_ground(spot + basis.x * 10.0 - basis.z * 5.0) + 0.1)
	player._yaw += PI * 0.5
	player._pitch = -0.1
	player.camera_distance = 6.0


func _nearest_tree() -> Node3D:
	var best: Node3D = null
	var best_d := 80.0
	for b in play.find_children("*", "VoxelInstancerRigidBody", true, false):
		var k := _kind_name(b)
		if EdenMiner.GATHER.has(k) and EdenMiner.GATHER[k][0] == EdenMiner.WOOD and k != "LOG":
			var d: float = b.global_position.distance_to(player.global_position)
			if d < best_d:
				best_d = d
				best = b
	return best


func _kind_name(b: Node) -> String:
	var kind = miner._foliage.item_kinds.get(b.get_library_item_id())
	return EdenFoliageLayer.kind_name(kind) if kind != null else ""


func _finish() -> bool:
	print("BUILD_TEST ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
	return true
