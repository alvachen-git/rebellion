extends Control
class_name ArtIcon

const Tokens := preload("res://src/ui/theme/visual_tokens.gd")

@export var icon_id := "resource.grain":
	set(value):
		icon_id = value
		queue_redraw()
@export var icon_color := Tokens.DEEP_TEAL:
	set(value):
		icon_color = value
		queue_redraw()
@export var accessible_label := "资源":
	set(value):
		accessible_label = value
		tooltip_text = value


func _ready() -> void:
	if custom_minimum_size == Vector2.ZERO:
		custom_minimum_size = Vector2(24, 24)
	tooltip_text = accessible_label
	mouse_filter = Control.MOUSE_FILTER_PASS
	queue_redraw()


func configure(next_icon_id: String, label: String, pixel_size := 24) -> void:
	icon_id = next_icon_id
	accessible_label = label
	custom_minimum_size = Vector2(pixel_size, pixel_size)
	queue_redraw()


func _draw() -> void:
	var s := minf(size.x, size.y)
	var center := size * 0.5
	var radius := s * 0.34
	match icon_id:
		"resource.grain":
			_draw_grain(center, s)
		"resource.wood":
			_draw_wood(center, s)
		"resource.iron":
			_draw_iron(center, s)
		"army.infantry":
			_draw_weapon(center, s, false)
		"army.archer":
			_draw_bow(center, s)
		"army.cavalry":
			_draw_horse(center, s)
		"status.troops":
			_draw_people(center, s)
		"status.morale":
			_draw_banner(center, s)
		"status.armor":
			_draw_shield(center, s)
		"status.action":
			_draw_action(center, s)
		"status.injury":
			_draw_cross(center, s)
		"status.death":
			_draw_death(center, s)
		"node.combat":
			_draw_weapon(center, s, true)
		"node.objective":
			_draw_fort(center, s)
		"node.event":
			_draw_scroll(center, s)
		"node.loot":
			_draw_chest(center, s)
		_:
			draw_circle(center, radius, Color(icon_color, 0.12))
			draw_arc(center, radius, 0.0, TAU, 24, icon_color, maxf(1.5, s * 0.08), true)


func _line(points: PackedVector2Array, width: float) -> void:
	draw_polyline(points, icon_color, width, true)


func _draw_grain(c: Vector2, s: float) -> void:
	_line(PackedVector2Array([c + Vector2(-s * 0.2, s * 0.32), c + Vector2(s * 0.14, -s * 0.34)]), maxf(1.5, s * 0.07))
	for i in 4:
		var y := -s * 0.22 + i * s * 0.13
		draw_circle(c + Vector2(-s * 0.04, y), s * 0.08, icon_color)
		draw_circle(c + Vector2(s * 0.10, y - s * 0.04), s * 0.07, icon_color)


func _draw_wood(c: Vector2, s: float) -> void:
	draw_rect(Rect2(c + Vector2(-s * 0.34, -s * 0.11), Vector2(s * 0.68, s * 0.22)), icon_color, false, maxf(1.5, s * 0.07))
	draw_circle(c + Vector2(s * 0.33, 0), s * 0.11, icon_color, false, maxf(1.5, s * 0.06))


func _draw_iron(c: Vector2, s: float) -> void:
	var points := PackedVector2Array([c + Vector2(-s * 0.3, s * 0.12), c + Vector2(-s * 0.18, -s * 0.24), c + Vector2(s * 0.18, -s * 0.3), c + Vector2(s * 0.32, s * 0.05), c + Vector2(s * 0.12, s * 0.3), c + Vector2(-s * 0.2, s * 0.27), c + Vector2(-s * 0.3, s * 0.12)])
	_line(points, maxf(1.5, s * 0.07))


func _draw_weapon(c: Vector2, s: float, crossed: bool) -> void:
	_line(PackedVector2Array([c + Vector2(-s * 0.28, s * 0.3), c + Vector2(s * 0.28, -s * 0.31)]), maxf(1.5, s * 0.08))
	_line(PackedVector2Array([c + Vector2(-s * 0.16, s * 0.12), c + Vector2(-s * 0.02, s * 0.26)]), maxf(1.5, s * 0.07))
	if crossed:
		_line(PackedVector2Array([c + Vector2(s * 0.28, s * 0.3), c + Vector2(-s * 0.28, -s * 0.31)]), maxf(1.5, s * 0.08))


func _draw_bow(c: Vector2, s: float) -> void:
	draw_arc(c + Vector2(-s * 0.06, 0), s * 0.34, -PI * 0.48, PI * 0.48, 16, icon_color, maxf(1.5, s * 0.07), true)
	_line(PackedVector2Array([c + Vector2(s * 0.22, -s * 0.3), c + Vector2(s * 0.22, s * 0.3)]), maxf(1.2, s * 0.05))


func _draw_horse(c: Vector2, s: float) -> void:
	_line(PackedVector2Array([c + Vector2(-s * 0.3, s * 0.25), c + Vector2(-s * 0.2, -s * 0.18), c + Vector2(s * 0.06, -s * 0.3), c + Vector2(s * 0.3, -s * 0.1), c + Vector2(s * 0.12, s * 0.03), c + Vector2(s * 0.26, s * 0.3)]), maxf(1.5, s * 0.07))
	draw_circle(c + Vector2(s * 0.18, -s * 0.13), s * 0.035, icon_color)


func _draw_people(c: Vector2, s: float) -> void:
	for offset in [-0.17, 0.17]:
		draw_circle(c + Vector2(s * offset, -s * 0.13), s * 0.11, icon_color)
		draw_arc(c + Vector2(s * offset, s * 0.22), s * 0.2, PI, TAU, 12, icon_color, maxf(1.5, s * 0.07), true)


func _draw_banner(c: Vector2, s: float) -> void:
	_line(PackedVector2Array([c + Vector2(-s * 0.26, s * 0.36), c + Vector2(-s * 0.26, -s * 0.34)]), maxf(1.5, s * 0.07))
	draw_colored_polygon(PackedVector2Array([c + Vector2(-s * 0.22, -s * 0.3), c + Vector2(s * 0.3, -s * 0.18), c + Vector2(s * 0.12, s * 0.04), c + Vector2(-s * 0.22, -s * 0.04)]), icon_color)


func _draw_shield(c: Vector2, s: float) -> void:
	var points := PackedVector2Array([c + Vector2(-s * 0.3, -s * 0.27), c + Vector2(s * 0.3, -s * 0.27), c + Vector2(s * 0.24, s * 0.14), c + Vector2(0, s * 0.34), c + Vector2(-s * 0.24, s * 0.14), c + Vector2(-s * 0.3, -s * 0.27)])
	_line(points, maxf(1.5, s * 0.07))


func _draw_action(c: Vector2, s: float) -> void:
	var points := PackedVector2Array([c + Vector2(s * 0.04, -s * 0.36), c + Vector2(-s * 0.25, s * 0.02), c + Vector2(0, s * 0.02), c + Vector2(-s * 0.06, s * 0.36), c + Vector2(s * 0.28, -s * 0.08), c + Vector2(s * 0.03, -s * 0.08)])
	draw_colored_polygon(points, icon_color)


func _draw_cross(c: Vector2, s: float) -> void:
	draw_rect(Rect2(c + Vector2(-s * 0.09, -s * 0.32), Vector2(s * 0.18, s * 0.64)), icon_color)
	draw_rect(Rect2(c + Vector2(-s * 0.32, -s * 0.09), Vector2(s * 0.64, s * 0.18)), icon_color)


func _draw_death(c: Vector2, s: float) -> void:
	draw_circle(c + Vector2(0, -s * 0.05), s * 0.28, icon_color, false, maxf(1.5, s * 0.07))
	draw_circle(c + Vector2(-s * 0.1, -s * 0.08), s * 0.04, icon_color)
	draw_circle(c + Vector2(s * 0.1, -s * 0.08), s * 0.04, icon_color)
	_line(PackedVector2Array([c + Vector2(-s * 0.15, s * 0.25), c + Vector2(s * 0.15, s * 0.25)]), maxf(1.5, s * 0.07))


func _draw_fort(c: Vector2, s: float) -> void:
	draw_rect(Rect2(c + Vector2(-s * 0.3, -s * 0.12), Vector2(s * 0.6, s * 0.4)), icon_color, false, maxf(1.5, s * 0.07))
	for x in [-0.24, 0.0, 0.24]:
		draw_rect(Rect2(c + Vector2(s * x - s * 0.06, -s * 0.28), Vector2(s * 0.12, s * 0.18)), icon_color)


func _draw_scroll(c: Vector2, s: float) -> void:
	draw_rect(Rect2(c + Vector2(-s * 0.25, -s * 0.3), Vector2(s * 0.5, s * 0.6)), icon_color, false, maxf(1.5, s * 0.07))
	_line(PackedVector2Array([c + Vector2(-s * 0.13, -s * 0.08), c + Vector2(s * 0.13, -s * 0.08)]), maxf(1.2, s * 0.05))
	_line(PackedVector2Array([c + Vector2(-s * 0.13, s * 0.08), c + Vector2(s * 0.08, s * 0.08)]), maxf(1.2, s * 0.05))


func _draw_chest(c: Vector2, s: float) -> void:
	draw_rect(Rect2(c + Vector2(-s * 0.32, -s * 0.08), Vector2(s * 0.64, s * 0.36)), icon_color, false, maxf(1.5, s * 0.07))
	draw_arc(c + Vector2(0, -s * 0.08), s * 0.31, PI, TAU, 16, icon_color, maxf(1.5, s * 0.07), true)
	draw_rect(Rect2(c + Vector2(-s * 0.05, s * 0.03), Vector2(s * 0.1, s * 0.15)), icon_color)
