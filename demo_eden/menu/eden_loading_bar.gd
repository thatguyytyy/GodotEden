class_name EdenLoadingBar
extends Control
## A thin loading bar. `value` is 0..1, or -1 when there's no measure: a gold segment then sweeps along it.

var value := -1.0


func _init() -> void:
	custom_minimum_size = Vector2(420, 6)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(EdenUITheme.CREAM, 0.15))
	if value >= 0.0:
		draw_rect(Rect2(0, 0, size.x * clampf(value, 0.0, 1.0), size.y), EdenUITheme.GOLD)
		return
	var w := size.x * 0.3
	var x := fmod(Time.get_ticks_msec() / 1000.0 * 0.8, 1.0) * (size.x + w) - w
	var a := maxf(x, 0.0)
	draw_rect(Rect2(a, 0, minf(x + w, size.x) - a, size.y), EdenUITheme.GOLD)
