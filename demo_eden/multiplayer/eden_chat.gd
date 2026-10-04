class_name EdenChat
extends CanvasLayer
## Text chat for an online world. Enter (or "/") opens the box, Enter sends, Esc closes, Up/Down recall earlier
## lines. Lines go through the server (send_chat) so everyone sees them; a line starting with "/" is a command:
## /help lists them. Command output is shown only to whoever ran it. "//" at the start sends a line that begins
## with a literal "/".

const SHOW_SECONDS := 8.0
const MAX_HISTORY := 50
const COLOR_SAY := Color(1, 1, 1)
const COLOR_NAME := Color(0.7, 0.9, 1.0)
const COLOR_EMOTE := Color(0.9, 0.8, 1.0)
const COLOR_INFO := Color(0.85, 0.85, 0.5)
const COLOR_ERROR := Color(1.0, 0.55, 0.5)

## The box is open and taking keystrokes
var typing := false
## Lines shown so far (for tests): {text, kind} (kind -1: command output, -2: error)
var lines: Array[Dictionary] = []

var _net: EdenNet
var _player: EdenPlayer
var _log: RichTextLabel
var _input: LineEdit
var _show_t := 0.0
var _sent: PackedStringArray = []
var _recall := -1
## command name -> {help, usage, fn}; aliases point at the same entry
var _commands := {}


func setup(net: EdenNet, player: EdenPlayer) -> void:
	_net = net
	_player = player
	layer = 20
	_build_ui()
	_register_commands()
	net.chat_received.connect(_on_chat)
	net.chat_rejected.connect(func(reason: String): _info(reason, true))


## "/tp bob now" -> {cmd: "tp", args: ["bob", "now"]}; {} when the text isn't a command ("/" alone, "//..." and plain text)
static func parse_command(text: String) -> Dictionary:
	text = text.strip_edges()
	if not text.begins_with("/") or text.begins_with("//") or text.length() < 2 or text[1] == " ":
		return {}
	var parts := text.substr(1).split(" ", false)
	return {"cmd": parts[0].to_lower(), "args": parts.slice(1), "rest": text.substr(1 + parts[0].length()).strip_edges()}


## Runs a typed line: a command, or a message to everyone
func submit(text: String) -> void:
	text = text.strip_edges()
	if text.is_empty():
		return
	var c := parse_command(text)
	if c.is_empty():
		if text.begins_with("//"):
			text = text.substr(1)
		elif text.begins_with("/"):
			_info("Type /help for the commands.", true)
			return
		_net.send_chat(text, 0)
		return
	var entry: Dictionary = _commands.get(c.cmd, {})
	if entry.is_empty():
		_info("Unknown command /%s. Type /help." % c.cmd, true)
		return
	entry.fn.call(c.args, c.rest)


func _register_commands() -> void:
	_add_command(["help", "?"], "[command]", "Lists the commands, or explains one", _cmd_help)
	_add_command(["me"], "<action>", "Shows an action, like: Bob waves", _cmd_me)
	_add_command(["who", "players"], "", "Lists the players online", _cmd_who)
	_add_command(["name"], "<new name>", "Changes your name (1-24 characters)", _cmd_name)
	_add_command(["tp"], "<player>", "Teleports you to a player", _cmd_tp)
	_add_command(["pos"], "", "Shows where you are", _cmd_pos)
	_add_command(["time"], "", "Shows the world's date and time", _cmd_time)
	_add_command(["clear"], "", "Clears your chat window", _cmd_clear)


func _add_command(names: Array, usage: String, help: String, fn: Callable) -> void:
	var entry := {"name": names[0], "usage": usage, "help": help, "fn": fn}
	for n in names:
		_commands[n] = entry


func _cmd_help(args: PackedStringArray, _rest: String) -> void:
	if not args.is_empty():
		var e: Dictionary = _commands.get(args[0].trim_prefix("/").to_lower(), {})
		if e.is_empty():
			_info("No command /%s." % args[0], true)
		else:
			_info("/%s %s - %s" % [e.name, e.usage, e.help])
		return
	var names := []
	for e in _commands.values():
		if not e.name in names:
			names.append(e.name)
	names.sort()
	_info("Commands: " + ", ".join(names.map(func(n): return "/" + n)) + ". /help <command> explains one.")


func _cmd_me(_args: PackedStringArray, rest: String) -> void:
	if rest.is_empty():
		_info("Usage: /me <action>", true)
		return
	_net.send_chat(rest, 1)


func _cmd_who(_args: PackedStringArray, _rest: String) -> void:
	var names := []
	for id in _net.players:
		var p: Dictionary = _net.players[id]
		if p.get("online", false):
			names.append(str(p.name) + (" (you)" if id == _net.identity else ""))
	names.sort()
	_info("%d online: %s" % [names.size(), ", ".join(names)])


func _cmd_name(_args: PackedStringArray, rest: String) -> void:
	if rest.is_empty() or rest.length() > 24:
		_info("Usage: /name <1-24 characters>", true)
		return
	_net.player_name = rest
	_net._call("set_name", [rest])
	_info("You are now %s." % rest)


func _cmd_tp(_args: PackedStringArray, rest: String) -> void:
	if rest.is_empty():
		_info("Usage: /tp <player>", true)
		return
	var id := find_player(rest)
	if id == "":
		_info("No player online matching \"%s\"." % rest, true)
		return
	if id == _net.identity:
		_info("You are already there.", true)
		return
	var p: Dictionary = _net.players[id]
	var at := Vector3(float(p.x), float(p.y), float(p.z))
	if at.length() < 1.0:
		_info("%s hasn't arrived yet." % p.name, true)
		return
	_player.restore_position(at + at.normalized() * 1.0, float(p.yaw))
	_info("Teleporting to %s." % p.name)


## The online player (not us) whose name is `query`, else the only one it starts, else the only one it's in
## (case ignored); "" when none or ambiguous. Our own name matches too, so /tp on yourself says so.
func find_player(query: String) -> String:
	query = query.to_lower()
	var starts := []
	var inside := []
	for id in _net.players:
		var p: Dictionary = _net.players[id]
		if not p.get("online", false):
			continue
		var n := str(p.name).to_lower()
		if n == query:
			return id
		if n.begins_with(query):
			starts.append(id)
		elif query in n:
			inside.append(id)
	if starts.size() == 1:
		return starts[0]
	return inside[0] if starts.is_empty() and inside.size() == 1 else ""


func _cmd_pos(_args: PackedStringArray, _rest: String) -> void:
	var rel := _player.global_position - _player._center()
	_info("x %.1f  y %.1f  z %.1f  (%.1f m from the planet's centre)" % [rel.x, rel.y, rel.z, rel.length()])


func _cmd_time(_args: PackedStringArray, _rest: String) -> void:
	if _player.calendar == null:
		_info("This world has no calendar.", true)
	else:
		_info(_player.calendar.date_string())


func _cmd_clear(_args: PackedStringArray, _rest: String) -> void:
	lines.clear()
	_log.clear()


# ------------------------------------------------------------------------------------------------------------
# Display

func _on_chat(sender: String, sender_name: String, text: String, kind: int, live: bool) -> void:
	_add_line(sender, sender_name, text, kind)
	if live:
		_show()


## A line only this player sees (command output)
func _info(text: String, error := false) -> void:
	_append([[COLOR_ERROR if error else COLOR_INFO, text]])
	lines.append({"text": text, "kind": -2 if error else -1})
	_show()


func _add_line(_sender: String, sender_name: String, text: String, kind: int) -> void:
	if kind == 1:
		_append([[COLOR_EMOTE, "* %s %s" % [sender_name, text]]])
	else:
		_append([[COLOR_NAME, sender_name + ": "], [COLOR_SAY, text]])
	lines.append({"text": text, "kind": kind, "name": sender_name})


# Plain text only (add_text never reads BBCode, so nobody's name or message can format the box)
func _append(parts: Array) -> void:
	if _log.get_parsed_text() != "":
		_log.newline()
	for part in parts:
		_log.push_color(part[0])
		_log.add_text(part[1])
		_log.pop()
	while _log.get_paragraph_count() > MAX_HISTORY:
		_log.remove_paragraph(0)


func _show() -> void:
	_show_t = SHOW_SECONDS


func _build_ui() -> void:
	var box := VBoxContainer.new()
	box.anchor_top = 1.0
	box.anchor_bottom = 1.0
	box.offset_left = 16
	box.offset_top = -330
	box.offset_right = 560
	box.offset_bottom = -16
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.alignment = BoxContainer.ALIGNMENT_END
	add_child(box)
	_log = RichTextLabel.new()
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.scroll_following = true
	_log.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_log.selection_enabled = false
	_log.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_log.add_theme_constant_override("outline_size", 6)
	box.add_child(_log)
	_input = LineEdit.new()
	_input.max_length = 500
	_input.placeholder_text = "Say something, or /help"
	_input.visible = false
	_input.text_submitted.connect(_on_submitted)
	_input.gui_input.connect(_on_input_key)
	box.add_child(_input)


func _process(delta: float) -> void:
	_show_t = maxf(_show_t - delta, 0.0)
	_log.modulate.a = 1.0 if typing else clampf(_show_t, 0.0, 1.0)


func _unhandled_input(event: InputEvent) -> void:
	if typing or not event is InputEventKey or not event.pressed or event.echo or _player.ui_open():
		return
	var prefill := ""
	match event.physical_keycode:
		KEY_ENTER, KEY_KP_ENTER:
			pass
		KEY_SLASH:
			prefill = "/"
		_:
			return
	get_viewport().set_input_as_handled()
	open(prefill)


func open(prefill := "") -> void:
	typing = true
	_player.typing = true
	_input.visible = true
	_input.text = prefill
	_input.caret_column = prefill.length()
	_recall = -1
	_input.grab_focus.call_deferred()


func close() -> void:
	typing = false
	_player.typing = false
	_input.release_focus()
	_input.visible = false
	_input.text = ""
	if not _player.ui_open():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_submitted(text: String) -> void:
	text = text.strip_edges()
	if text != "":
		if _sent.is_empty() or _sent[-1] != text:
			_sent.append(text)
		submit(text)
	close()


func _on_input_key(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed:
		return
	match event.physical_keycode:
		KEY_ESCAPE:
			_input.accept_event()
			close()
		KEY_UP, KEY_DOWN:
			_input.accept_event()
			if _sent.is_empty():
				return
			_recall = clampi((_sent.size() if _recall < 0 else _recall) + (-1 if event.physical_keycode == KEY_UP else 1), 0, _sent.size())
			_input.text = _sent[_recall] if _recall < _sent.size() else ""
			_input.caret_column = _input.text.length()
