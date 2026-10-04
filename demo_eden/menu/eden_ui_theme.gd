class_name EdenUITheme
## The game's UI look, shared by the main menu and the in-game menus: the Press Start 2P pixel font (menu/fonts,
## SIL OFL), wooden pill buttons with a gold rim (pixel art drawn here, scaled up without smoothing), dark panels
## with a gold edge, and the striped title lettering.

const FONT_PATH := "res://menu/fonts/PressStart2P-Regular.ttf"
const INK := Color(0.12, 0.07, 0.03)
const GOLD := Color(0.93, 0.75, 0.38)
const CREAM := Color(1.0, 0.9, 0.72)
const TEAL := Color(0.32, 0.8, 0.76)
const PANEL := Color(0.05, 0.06, 0.08, 0.9)
## Pixel-art scale: one art pixel is this many screen pixels
const PIXEL := 3

const TITLE_SHADER := """
shader_type canvas_item;
// The letter faces (drawn white) become cream cut by scanlines every few screen rows, as on an old arcade marquee;
// the teal shadow under them keeps its colour
uniform vec4 light_color : source_color = vec4(1.0, 0.9, 0.72, 1.0);
uniform vec4 line_color : source_color = vec4(0.95, 0.55, 0.3, 1.0);
uniform float period = 9.0;
uniform float line = 2.0;
void fragment() {
	float a = texture(TEXTURE, UV).a * COLOR.a;
	bool face = COLOR.r > 0.95 && COLOR.g > 0.95 && COLOR.b > 0.95;
	float on_line = step(period - line, mod(FRAGCOORD.y, period));
	vec3 c = face ? mix(light_color.rgb, line_color.rgb, on_line) : COLOR.rgb;
	COLOR = vec4(c, a);
}
"""

static var _theme: Theme
static var _font: FontFile


static func font() -> FontFile:
	if _font == null:
		_font = load(FONT_PATH)
		_font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		_font.hinting = TextServer.HINTING_NONE
		_font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	return _font


## The Theme for any Control tree (set it on the root Control)
static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font = font()
	t.default_font_size = 16
	for type in ["Label", "Button", "LineEdit", "OptionButton", "CheckButton", "CheckBox", "TabBar", "ItemList", "RichTextLabel", "SpinBox"]:
		t.set_color("font_color", type, CREAM)
	t.set_color("font_color", "Button", INK)
	t.set_color("font_hover_color", "Button", INK)
	t.set_color("font_pressed_color", "Button", INK)
	t.set_color("font_focus_color", "Button", INK)
	t.set_color("font_disabled_color", "Button", Color(INK, 0.45))
	t.set_font_size("font_size", "Button", 16)
	t.set_stylebox("normal", "Button", wood_button(0))
	t.set_stylebox("hover", "Button", wood_button(1))
	t.set_stylebox("pressed", "Button", wood_button(2))
	t.set_stylebox("focus", "Button", wood_button(1))
	t.set_stylebox("disabled", "Button", wood_button(3))
	# Option buttons and checks read as controls on a panel, not big planks
	for type in ["OptionButton", "CheckButton", "CheckBox"]:
		t.set_stylebox("normal", type, flat(Color(0.14, 0.11, 0.08), GOLD.darkened(0.4), 1, 4))
		t.set_stylebox("hover", type, flat(Color(0.2, 0.15, 0.1), GOLD, 1, 4))
		t.set_stylebox("pressed", type, flat(Color(0.1, 0.08, 0.06), GOLD, 1, 4))
		t.set_stylebox("focus", type, StyleBoxEmpty.new())
		t.set_color("font_hover_color", type, GOLD)
		t.set_color("font_pressed_color", type, GOLD)
		t.set_font_size("font_size", type, 12)
	t.set_stylebox("panel", "PanelContainer", panel())
	t.set_stylebox("panel", "Panel", panel())
	t.set_stylebox("normal", "LineEdit", flat(Color(0.03, 0.03, 0.04), GOLD.darkened(0.4), 2, 4))
	t.set_stylebox("focus", "LineEdit", flat(Color(0.03, 0.03, 0.04), GOLD, 2, 4))
	t.set_color("caret_color", "LineEdit", GOLD)
	t.set_font_size("font_size", "LineEdit", 14)
	t.set_font_size("font_size", "Label", 14)
	t.set_font_size("font_size", "ItemList", 13)
	t.set_stylebox("panel", "ItemList", flat(Color(0.03, 0.03, 0.04, 0.8), GOLD.darkened(0.5), 2, 4))
	t.set_stylebox("focus", "ItemList", StyleBoxEmpty.new())
	t.set_stylebox("selected", "ItemList", flat(Color(GOLD, 0.25), GOLD, 1, 2))
	t.set_stylebox("selected_focus", "ItemList", flat(Color(GOLD, 0.3), GOLD, 1, 2))
	t.set_stylebox("hovered", "ItemList", flat(Color(GOLD, 0.1), Color.TRANSPARENT, 0, 2))
	t.set_color("font_selected_color", "ItemList", GOLD)
	t.set_constant("v_separation", "ItemList", 10)
	# Tabs
	t.set_stylebox("tab_selected", "TabContainer", flat(Color(0.2, 0.15, 0.1), GOLD, 2, 4))
	t.set_stylebox("tab_unselected", "TabContainer", flat(Color(0.08, 0.07, 0.06), GOLD.darkened(0.5), 1, 4))
	t.set_stylebox("tab_hovered", "TabContainer", flat(Color(0.14, 0.11, 0.08), GOLD, 1, 4))
	t.set_stylebox("panel", "TabContainer", flat(Color(0.03, 0.03, 0.04, 0.6), GOLD.darkened(0.5), 1, 4))
	t.set_color("font_selected_color", "TabContainer", GOLD)
	t.set_color("font_unselected_color", "TabContainer", CREAM.darkened(0.3))
	t.set_color("font_hovered_color", "TabContainer", CREAM)
	t.set_font_size("font_size", "TabContainer", 16)
	t.set_constant("side_margin", "TabContainer", 0)
	# Sliders: a gold grabber on a dark groove
	t.set_stylebox("slider", "HSlider", flat(Color(0.03, 0.03, 0.04), GOLD.darkened(0.5), 1, 3))
	t.set_stylebox("grabber_area", "HSlider", flat(GOLD.darkened(0.3), Color.TRANSPARENT, 0, 3))
	t.set_stylebox("grabber_area_highlight", "HSlider", flat(GOLD, Color.TRANSPARENT, 0, 3))
	t.set_stylebox("separator", "HSeparator", flat(GOLD.darkened(0.5), Color.TRANSPARENT, 0, 0))
	t.set_constant("separation", "HSeparator", 6)
	_theme = t
	return t


static func flat(bg: Color, border: Color, width := 2, margin := 8) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(width)
	s.set_content_margin_all(margin)
	s.anti_aliasing = false
	return s


## A dark panel with a double gold edge
static func panel() -> StyleBoxFlat:
	var s := flat(PANEL, GOLD, PIXEL, 24)
	s.shadow_color = Color(0, 0, 0, 0.5)
	s.shadow_size = 8
	s.expand_margin_left = 0
	return s


## A wooden pill plank: 0 normal, 1 hover (lighter), 2 pressed (darker), 3 disabled (greyed). Drawn as pixel art
## (ART_W x ART_H) and scaled by PIXEL without smoothing; the round ends are the stylebox's fixed margins, so buttons
## of any width keep them.
static func wood_button(state: int) -> StyleBoxTexture:
	var s := StyleBoxTexture.new()
	s.texture = ImageTexture.create_from_image(wood_image(state))
	var m := 7 * PIXEL
	s.texture_margin_left = m
	s.texture_margin_right = m
	s.texture_margin_top = 4 * PIXEL
	s.texture_margin_bottom = 4 * PIXEL
	s.content_margin_left = 10 * PIXEL
	s.content_margin_right = 10 * PIXEL
	s.content_margin_top = 4 * PIXEL
	s.content_margin_bottom = 4 * PIXEL
	s.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
	return s


const ART_W := 64
const ART_H := 12


static func wood_image(state: int) -> Image:
	var noise := FastNoiseLite.new()
	noise.seed = 7
	noise.frequency = 0.08
	var img := Image.create(ART_W, ART_H, false, Image.FORMAT_RGBA8)
	var shade: float = [1.0, 1.18, 0.82, 0.7][state]
	var r := ART_H * 0.5
	for y in ART_H:
		for x in ART_W:
			# Signed distance to the pill's edge (in art pixels): negative inside
			var cx := clampf(x + 0.5, r, ART_W - r)
			var d := Vector2(x + 0.5 - cx, y + 0.5 - r).length() - r
			if d > 0.0:
				continue
			var c: Color
			if d > -1.0:
				c = Color(0.22, 0.13, 0.05) # outline
			elif d > -2.0:
				c = GOLD.darkened(0.1 if y < ART_H / 2 else 0.3) # the rim, lit from above
			else:
				# Grain: long streaks along the plank, stretched noise
				var g := noise.get_noise_2d(x * 0.25, y * 2.2)
				c = Color(0.62, 0.43, 0.2).lerp(Color(0.78, 0.58, 0.3), 0.5 + 0.5 * g)
				if y == 2:
					c = c.lightened(0.12)
			if state == 3:
				var l := c.get_luminance()
				c = Color(l, l, l)
			img.set_pixel(x, y, Color(c.r * shade, c.g * shade, c.b * shade, 1.0))
	img.resize(ART_W * PIXEL, ART_H * PIXEL, Image.INTERPOLATE_NEAREST)
	return img


## Title lettering: cream with scanlines over a teal shadow offset down-right (the letters' depth)
static func title(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font())
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color.WHITE) # (the shader's cue for the letter faces)
	l.add_theme_color_override("font_shadow_color", TEAL)
	l.add_theme_constant_override("shadow_offset_x", maxi(2, size / 14))
	l.add_theme_constant_override("shadow_offset_y", maxi(2, size / 14))
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = TITLE_SHADER
	mat.shader = sh
	mat.set_shader_parameter("period", maxf(4.0, round(size / 10.0)))
	mat.set_shader_parameter("line", maxf(1.0, round(size / 40.0)))
	l.material = mat
	return l

