class_name EdenInventorySlot
extends PanelContainer
## One slot of EdenInventoryUI: the item's swatch and amount (a hotbar slot also shows its key and the item's name).
## Only a view: EdenInventoryUI finds the slot under the pointer itself (slot_at) and handles the clicks and drags.

var index := 0
var is_hotbar := false
var item := -1

var _title: Label
var _swatch: ColorRect
var _amount: Label


func _init(p_index: int, p_hotbar: bool) -> void:
	index = p_index
	is_hotbar = p_hotbar
	custom_minimum_size = Vector2(76, 64) if is_hotbar else Vector2(60, 60)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)
	if is_hotbar:
		_title = _label(12)
		box.add_child(_title)
	_swatch = ColorRect.new()
	_swatch.custom_minimum_size = Vector2(24, 16)
	_swatch.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_swatch)
	_amount = _label(13)
	box.add_child(_amount)
	show_item(-1, 0, false, false)


## Shows `amount` of `item` (-1: empty). selected: the gold edge; dim: greyed (a shortcut to an item you have none of)
func show_item(p_item: int, amount: int, selected: bool, dim: bool) -> void:
	item = p_item
	var has := item >= 0
	_swatch.visible = has
	if has:
		_swatch.color = EdenMiner.ITEMS[item][2]
	_amount.text = str(amount) if has else ""
	if is_hotbar:
		_title.text = "%d  %s" % [index + 1, EdenMiner.ITEMS[item][0] if has else ""]
	modulate.a = 0.45 if dim else 1.0
	add_theme_stylebox_override("panel", _style(selected))


func _label(font_size: int) -> Label:
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 4)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


# (the look of EdenMiner's own hotbar slots)
static func _style(on: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0, 0, 0, 0.55 if on else 0.35)
	s.border_color = Color(1, 0.9, 0.5) if on else Color(1, 1, 1, 0.2)
	s.set_border_width_all(2)
	s.set_corner_radius_all(4)
	s.set_content_margin_all(4)
	return s
