extends SceneTree
## Game side of the multiplayer test (multiplayer/mp_test.py runs it next to mp_bot.py and a local SpacetimeDB):
## plays eden_play.tscn online, walks a little so the bot sees it move, then checks the bot shows up as an avatar
## near the player and that the bot's dig reached this terrain. Saves a screenshot of the avatar.
##   godot --path demo_eden --resolution 960x540 -s res://multiplayer/_mp_test.gd -- --online --name=Tester --out=<dir>

var play: Node
var player: EdenPlayer
var out := "user://"
var ok := true
var t0 := 0
var step := 0
var dig_at := Vector3.ZERO


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.trim_prefix("--out=")
	play = load("res://eden_play.tscn").instantiate()
	root.add_child(play)
	current_scene = play
	t0 = Time.get_ticks_msec()


func _check(cond: bool, msg: String) -> void:
	print("MP_TEST %s %s" % ["ok  " if cond else "FAIL", msg])
	ok = ok and cond


func _el() -> float:
	return (Time.get_ticks_msec() - t0) / 1000.0


func _next() -> void:
	step += 1
	t0 = Time.get_ticks_msec()


func _ground(p: Vector3) -> float:
	var up := (p - player._center()).normalized()
	var q := PhysicsRayQueryParameters3D.create(p + up * 4.0, p - up * 4.0, player.collision_mask, [player.get_rid()])
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	return (hit.position - p).dot(up) if not hit.is_empty() else -4.0


func _process(_d: float) -> bool:
	if player == null:
		player = play.get("player")
		return false
	var net := player.net
	match step:
		0: # online and on the ground
			if net and net.status == "online" and player.ready_to_move and _el() > 3.0:
				_check(true, "online as %s (%d online)" % [net.identity.left(10), net.online_count()])
				print("MP_TEST ready") # mp_test.py starts the bot on this line
				Input.action_press("move_forward")
				_next()
			elif _el() > 120.0 or (net and net.status == "error"):
				_check(false, "connected to SpacetimeDB and on the ground (%s)" % (net.status if net else "no EdenNet"))
				return _finish()
		1: # walk 5 s (the bot watches us move), then wait for the bot's avatar
			if _el() > 5.0:
				Input.action_release("move_forward")
			if _el() > 5.0 and not net.avatars.is_empty():
				var avatar: Node3D = net.avatars.values()[0]
				var d := avatar.global_position.distance_to(player.global_position)
				_check(d < 20.0, "the bot's avatar is %.1f m away" % d)
				# Face it for the screenshot
				var up := player.up_direction
				player._yaw = EdenPlayer._north(up).signed_angle_to(avatar.global_position - player.global_position, up)
				_next()
			elif _el() > 40.0:
				_check(false, "another player's avatar appeared")
				return _finish()
		2: # the bot's dig (it may have landed while we walked): the ground there sits well below the untouched surface
			if net.edits_applied > 0 and dig_at == Vector3.ZERO:
				dig_at = net.last_edit_position
				t0 = Time.get_ticks_msec()
			elif dig_at != Vector3.ZERO and _el() > 2.5:
				# Untouched, the collision surface is ~0.5 m under the generator's height; the 1.3 m dig takes it ~1.5
				var gen: Object = player._planet.generator
				var up := (dig_at - player._center()).normalized()
				var surface: float = float(gen.planet_radius) + float(gen.sample_surface(up).height)
				var ground := (dig_at - player._center()).length() + _ground(dig_at)
				_check(surface - ground > 1.0, "the bot's dig is in our terrain: ground %.2f m under the surface, %.1f m from us" % [surface - ground, dig_at.distance_to(player.global_position)])
				root.get_texture().get_image().save_png(out.path_join("mp_avatar.png"))
				_check(net.online_count() >= 2, "%d players online" % net.online_count())
				_check(player.calendar.is_synced() and absf(player.calendar.days - 100.5) < 0.01 and not player.calendar.running,
						"the calendar follows the server's clock the bot set (day %.3f, %s)" % [player.calendar.days, player.calendar.date_string()])
				var built := player.builder.pieces.filter(func(p): return p.net_id != 0)
				_check(built.size() >= 1, "the bot's stone floor appeared (%d pieces from the server)" % built.size())
				if built.size() >= 1:
					_check(built[0].global_position.distance_to(player.global_position) < 20.0 and built[0].grounded,
							"it stands on our terrain, %.1f m away" % built[0].global_position.distance_to(player.global_position))
				_next()
			elif dig_at == Vector3.ZERO and _el() > 30.0:
				_check(false, "received the bot's voxel edit")
				return _finish()
		3: # chat: the bot's line arrives, then the local commands
			if _has_chat("hello from bot", 0, "Bot"):
				_check(true, "received the bot's chat line")
				_chat_commands()
				_next()
			elif _el() > 15.0:
				_check(false, "received the bot's chat line")
				return _finish()
		4: # our lines go out one at a time (the server limits how fast one player may talk)
			if _el() > 0.5 and sent < QUEUE.size():
				player.net.chat.submit(QUEUE[sent])
				sent += 1
				t0 = Time.get_ticks_msec()
			elif sent == QUEUE.size() and _el() > 1.0:
				_check(_has_chat("hello bot", 0, "Tester"), "our line came back from the server")
				_check(_has_chat("waves", 1, "Tester"), "/me came back as an emote")
				_check(not _has_chat("/bogus", 0, "Tester") and _has_chat("/not a command", 0, "Tester"), "// says a line starting with a slash aloud")
				player.net.chat.submit("/name Tester2")
				player.net.chat.submit("/tp bot")
				_check(not player.ready_to_move, "/tp sends us to the bot")
				_next()
		5:
			if _el() > 1.0:
				_check(player.net.players[player.net.identity].name == "Tester2", "/name renamed us on the server")
				return _finish()
	return false


const QUEUE := ["hello bot", "/me waves", "//not a command"]
var sent := 0


func _has_chat(text: String, kind: int, from: String) -> bool:
	for m in player.net.chat_log:
		if m.text == text and m.kind == kind and m.name == from:
			return true
	return false


func _last_line() -> Dictionary:
	return player.net.chat.lines[-1] if not player.net.chat.lines.is_empty() else {}


func _chat_commands() -> void:
	var chat: EdenChat = player.net.chat
	_check(EdenChat.parse_command("/tp  Bob Smith").get("cmd") == "tp" and EdenChat.parse_command("/tp  Bob Smith").rest == "Bob Smith", "parse_command splits a command and its argument")
	_check(EdenChat.parse_command("hello").is_empty() and EdenChat.parse_command("//hi").is_empty() and EdenChat.parse_command("/").is_empty(), "plain text and // are not commands")
	chat.submit("/who")
	_check(_last_line().get("text", "").contains("Tester") and _last_line().get("text", "").contains("Bot"), "/who lists both players: %s" % _last_line().get("text"))
	chat.submit("/pos")
	_check(_last_line().get("text", "").begins_with("x "), "/pos: %s" % _last_line().get("text"))
	chat.submit("/time")
	_check(_last_line().get("kind") == -1, "/time: %s" % _last_line().get("text"))
	chat.submit("/help")
	_check(_last_line().get("text", "").contains("/tp"), "/help lists the commands")
	chat.submit("/help me")
	_check(_last_line().get("text", "").contains("action"), "/help me explains /me")
	chat.submit("/bogus")
	_check(_last_line().get("kind") == -2, "an unknown command is reported: %s" % _last_line().get("text"))
	chat.submit("/tp nobody")
	_check(_last_line().get("kind") == -2, "/tp to nobody is reported")


func _finish() -> bool:
	Input.action_release("move_forward")
	print("MP_TEST ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
	return true
