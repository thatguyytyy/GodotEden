class_name EdenInventoryUI
extends CanvasLayer
## EdenInventory's screen, over an EdenInventoryLayout kept in step with EdenMiner.counts.
##   Hotbar (bottom, always shown): 9 shortcuts to item types, each showing how many you have in all. 1-9 or the
##   wheel pick a slot (the item goes in hand: EdenMiner.select), Z puts it away (nothing in hand).
##   Backpack window (Tab; Tab, Esc or a click outside closes; the pointer shows and walking still works): 36 stacks.
##   A stack or a hotbar shortcut moves either way: press, drag and release on another slot, or click it (it stays
##   in the pointer) and click where it goes.
##     Stacks: LMB takes the stack, RMB half of it; put down on the same item they merge, on another they swap; RMB
##     with a stack in the pointer puts down one. Put on a hotbar slot, a stack makes it that item's shortcut (and
##     goes back). Dragged out of the window it goes back.
##     Shortcuts: onto another hotbar slot they swap; anywhere else they're removed. RMB on one removes it too.
##     1-9 over a stack makes that hotbar slot its shortcut.
##   Shift+click does nothing yet (kept for quick-moving into containers).
## Closing with a mouse button down hands the mouse back to the game only once it's released, so that click doesn't
## dig. The arrangement is saved (EdenInventoryLayout.save_path) a moment after it changes and on leaving.

const HOLSTER_ACTION := "holster"
const SAVE_DELAY := 2.0

var layout: EdenInventoryLayout

var _player: EdenPlayer
var _miner: EdenMiner
## The hotbar slot in hand (-1: nothing) and the item that put in EdenMiner's hand
var _hot := 0
var _in_hand := -1
var _hot_slots: Array[EdenInventorySlot] = []
var _bag_slots: Array[EdenInventorySlot] = []
var _window: PanelContainer
var _footer: Label
var _held: EdenInventorySlot
var _tip: Label
var _hover: EdenInventorySlot
## A hotbar shortcut in the pointer (-1: none) and the slot it came off
var _held_hot := -1
var _held_hot_from := -1
## The slot a press picked something up from (null: none), to tell a drag (released elsewhere) from a click
var _press_from: EdenInventorySlot
## The window closed with a button down: capture the mouse once it's up
var _capture_on_release := false
var _dirty := true
var _save_t := -1.0


func _init() -> void:
	layer = 50


func setup(player: EdenPlayer, miner: EdenMiner) -> void:
	_player = player
	_miner = miner
	for i in EdenInventoryLayout.HOTBAR:
		_ensure_action("slot_%d" % (i + 1), KEY_1 + i)
	_ensure_action(HOLSTER_ACTION, KEY_Z)
	layout = EdenInventoryLayout.new(EdenMiner.ITEMS.size())
	layout.load_from()
	layout.sync(miner.counts)
	_build()
	_select(0)


## Whether the backpack window is open
func is_open() -> bool:
	return _window.visible


func open() -> void:
	_window.visible = true
	_capture_on_release = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_dirty = true


func close() -> void:
	_put_back()
	_press_from = null
	_window.visible = false
	_hover = null
	_capture_on_release = true
	_changed()


## The hotbar or backpack slot under a screen position (backpack only while the window is open), or null
func slot_at(pos: Vector2) -> EdenInventorySlot:
	for s in _hot_slots:
		if s.get_global_rect().has_point(pos):
			return s
	if is_open():
		for s in _bag_slots:
			if s.get_global_rect().has_point(pos):
				return s
	return null


func _exit_tree() -> void:
	if layout:
		layout.save_to()


# ------------------------------------------------------------------------------------------------------------

# The hotbar slot `i` goes in hand: its item, or nothing (-1, or an empty slot)
func _select(i: int) -> void:
	_hot = i
	_in_hand = layout.hotbar[i] if i >= 0 else -1
	_miner.select(_in_hand)
	_dirty = true


# The wheel: the next / previous hotbar slot, empty ones included
func _cycle(step: int) -> void:
	var from := _hot if _hot >= 0 else (-1 if step > 0 else 0)
	_select(posmod(from + step, EdenInventoryLayout.HOTBAR))


func _changed() -> void:
	_dirty = true
	if _save_t < 0.0:
		_save_t = SAVE_DELAY


func _holding() -> bool:
	return layout.held_item >= 0 or _held_hot >= 0


# Whatever is in the pointer goes back where it came from
func _put_back() -> void:
	if _held_hot >= 0:
		if layout.hotbar[_held_hot_from] == -1:
			layout.hotbar[_held_hot_from] = _held_hot
		_held_hot = -1
		_held_hot_from = -1
		_select(_hot)
	layout.return_held()


# Mouse buttons while the window is open (all of them handled here, before the GUI and the game)
func _input(event: InputEvent) -> void:
	if not is_open() or not (event is InputEventMouseButton) \
			or event.button_index not in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		return
	get_viewport().set_input_as_handled()
	var pos: Vector2 = event.position
	var s := slot_at(pos)
	if event.pressed:
		_press(s, pos, event.button_index, event.shift_pressed)
	elif _press_from != null:
		# A release on the slot it was picked up from is a click: it stays in the pointer for the next click.
		# Anywhere else it's a drag: put it down there.
		var from := _press_from
		_press_from = null
		if s != from:
			_put(s, pos, MOUSE_BUTTON_LEFT, true)


func _press(s: EdenInventorySlot, pos: Vector2, button: MouseButton, shift: bool) -> void:
	_press_from = null
	if shift:
		return
	if _holding():
		_put(s, pos, button, false)
		return
	if s == null:
		if not _window.get_global_rect().has_point(pos):
			close()
		return
	if s.is_hotbar:
		if button == MOUSE_BUTTON_RIGHT:
			layout.assign(s.index, -1)
			_select(_hot)
		elif layout.hotbar[s.index] >= 0:
			_held_hot = layout.hotbar[s.index]
			_held_hot_from = s.index
			layout.hotbar[s.index] = -1
			_select(_hot)
			_press_from = s
	else:
		layout.pick(s.index, button == MOUSE_BUTTON_RIGHT)
		if layout.held_item >= 0:
			_press_from = s
	_changed()


# Puts down what the pointer holds on slot `s` (null: no slot there). dragged: a drag's release, not a click.
func _put(s: EdenInventorySlot, pos: Vector2, button: MouseButton, dragged: bool) -> void:
	var outside := s == null and not _window.get_global_rect().has_point(pos)
	if _held_hot >= 0:
		if s != null and s.is_hotbar:
			layout.hotbar[_held_hot_from] = layout.hotbar[s.index]
			layout.hotbar[s.index] = _held_hot
		_held_hot = -1
		_held_hot_from = -1
		_select(_hot)
		if outside and not dragged:
			close()
	elif s == null:
		if outside:
			if dragged:
				layout.return_held()
			else:
				close()
	elif s.is_hotbar:
		layout.assign(s.index, layout.held_item)
		layout.return_held()
		_select(_hot)
	else:
		layout.drop(s.index, button == MOUSE_BUTTON_RIGHT)
	_changed()


func _unhandled_input(event: InputEvent) -> void:
	if _player.typing:
		return
	if event.is_action_pressed("inventory"):
		if is_open():
			close()
		else:
			open()
	elif is_open() and event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE:
		close()
	elif event.is_action_pressed(HOLSTER_ACTION) and _miner.enabled:
		# (with nothing in hand there's nothing to put away)
		if _in_hand < 0:
			return
		_select(-1)
	elif _miner.enabled and event is InputEventMouseButton and event.pressed and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
			and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		_cycle(-1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1)
	else:
		for i in EdenInventoryLayout.HOTBAR:
			if event.is_action_pressed("slot_%d" % (i + 1)):
				if is_open() and _hover and not _hover.is_hotbar and layout.items[_hover.index] >= 0:
					layout.assign(i, layout.items[_hover.index])
					_select(_hot)
					_changed()
				elif _miner.enabled:
					_select(i)
				get_viewport().set_input_as_handled()
				return
		return
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if layout.sync(_miner.counts):
		_changed()
	# (a new item can land on the slot in hand)
	if _hot >= 0 and layout.hotbar[_hot] != _in_hand:
		_select(_hot)
	# (something else picked what's in hand, e.g. a test: show it on its shortcut, if it has one)
	if _miner.selected != _in_hand:
		_in_hand = _miner.selected
		_hot = layout.hotbar.find(_in_hand) if _in_hand >= 0 else -1
		_dirty = true
	if _capture_on_release and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) \
			and not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_capture_on_release = false
		if not is_open() and not _player.ui_open():
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _save_t >= 0.0:
		_save_t -= delta
		if _save_t < 0.0:
			layout.save_to()
	var mouse := _window.get_global_mouse_position()
	var hover := slot_at(mouse) if is_open() else null
	if hover != _hover:
		_hover = hover
		_dirty = true
	_held.position = mouse - _held.size * 0.5
	_tip.position = mouse + Vector2(18, 18)
	if _dirty:
		_dirty = false
		_refresh()


func _refresh() -> void:
	for i in EdenInventoryLayout.HOTBAR:
		var item := layout.hotbar[i]
		var count: int = _miner.counts[item] if item >= 0 else 0
		_hot_slots[i].show_item(item, count, i == _hot, item >= 0 and count == 0)
	for i in EdenInventoryLayout.SLOTS:
		_bag_slots[i].show_item(layout.items[i], layout.amounts[i], _hover == _bag_slots[i], false)
	if _held_hot >= 0:
		_held.show_item(_held_hot, _miner.counts[_held_hot], true, _miner.counts[_held_hot] == 0)
	else:
		_held.show_item(layout.held_item, layout.held_amount, true, false)
	_held.visible = _holding()
	var notes := PackedStringArray()
	for item in EdenMiner.ITEMS.size():
		var more := layout.overflow(item, _miner.counts[item])
		if more > 0:
			notes.append("+%d %s with no room to show (backpack full)" % [more, EdenMiner.ITEMS[item][0]])
	notes.append("Drag or click to move   RMB half / one   1-9 over an item: hotbar   Drag off the hotbar / RMB: remove")
	_footer.text = "\n".join(notes)
	var tip_item := _hover.item if _hover and not _holding() and is_open() else -1
	_tip.visible = tip_item >= 0
	if tip_item >= 0:
		var it: Array = EdenMiner.ITEMS[tip_item]
		_tip.text = "%s\n%d in all\n%s" % [it[0], _miner.counts[tip_item],
				"Ground: RMB places it" if it[1] >= 0 else "Building material: G for the hammer"]


# ------------------------------------------------------------------------------------------------------------

func _build() -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	_window = PanelContainer.new()
	_window.visible = false
	_window.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_window.add_to_group("eden_pointer_ui")
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.06, 0.08, 0.92)
	style.border_color = Color(1, 0.9, 0.5, 0.6)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(14)
	_window.add_theme_stylebox_override("panel", style)
	center.add_child(_window)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_window.add_child(box)
	var title := Label.new()
	title.text = "INVENTORY"
	title.add_theme_font_size_override("font_size", 20)
	box.add_child(title)
	var grid := GridContainer.new()
	grid.columns = EdenInventoryLayout.HOTBAR
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(grid)
	for i in EdenInventoryLayout.SLOTS:
		var s := EdenInventorySlot.new(i, false)
		grid.add_child(s)
		_bag_slots.append(s)
	_footer = Label.new()
	_footer.add_theme_font_size_override("font_size", 12)
	_footer.modulate = Color(1, 1, 1, 0.7)
	box.add_child(_footer)

	# The hotbar, where EdenMiner's was
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	bar.position.y -= 16
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bar)
	for i in EdenInventoryLayout.HOTBAR:
		var s := EdenInventorySlot.new(i, true)
		bar.add_child(s)
		_hot_slots.append(s)

	# The stack or shortcut in the pointer, and the item tooltip
	_held = EdenInventorySlot.new(-1, false)
	_held.top_level = true
	_held.visible = false
	add_child(_held)
	_tip = Label.new()
	_tip.top_level = true
	_tip.visible = false
	_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tip_style := StyleBoxFlat.new()
	tip_style.bg_color = Color(0, 0, 0, 0.85)
	tip_style.set_corner_radius_all(4)
	tip_style.set_content_margin_all(8)
	_tip.add_theme_stylebox_override("normal", tip_style)
	_tip.add_theme_font_size_override("font_size", 13)
	add_child(_tip)


static func _ensure_action(action: String, key: Key) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var e := InputEventKey.new()
	e.physical_keycode = key
	InputMap.action_add_event(action, e)
