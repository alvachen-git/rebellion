extends Control

const INK := Color("#151715")
const DISTANT_INK := Color("#242721")
const MIST := Color("#596052")
const BRONZE := Color("#b88b45")
const PLAYER_CLOTH := Color("#314842")
const ENEMY_CLOTH := Color("#5b302b")


func _ready() -> void:
	resized.connect(queue_redraw)


func _draw() -> void:
	var width := size.x
	var height := size.y
	draw_rect(Rect2(Vector2.ZERO, size), Color("#20231f"))
	_draw_mountains(width, height)
	_draw_ground(width, height)
	_draw_army_mass(Vector2(width * 0.26, height * 0.72), PLAYER_CLOTH, -1.0)
	_draw_army_mass(Vector2(width * 0.73, height * 0.39), ENEMY_CLOTH, 1.0)
	draw_line(Vector2(width * 0.49, height * 0.24), Vector2(width * 0.49, height * 0.8), Color(BRONZE, 0.2), 1.0)


func _draw_mountains(width: float, height: float) -> void:
	var rear := PackedVector2Array([
		Vector2(0, height * 0.42),
		Vector2(width * 0.14, height * 0.18),
		Vector2(width * 0.29, height * 0.4),
		Vector2(width * 0.47, height * 0.14),
		Vector2(width * 0.67, height * 0.4),
		Vector2(width * 0.85, height * 0.2),
		Vector2(width, height * 0.37),
		Vector2(width, height * 0.58),
		Vector2(0, height * 0.58),
	])
	draw_colored_polygon(rear, DISTANT_INK)
	var mist_color := Color(MIST, 0.13)
	draw_rect(Rect2(0, height * 0.36, width, height * 0.18), mist_color)


func _draw_ground(width: float, height: float) -> void:
	draw_colored_polygon(PackedVector2Array([
		Vector2(0, height * 0.53),
		Vector2(width, height * 0.48),
		Vector2(width, height),
		Vector2(0, height),
	]), INK)
	for index in 6:
		var y := height * (0.58 + index * 0.07)
		draw_line(Vector2(0, y), Vector2(width, y - height * 0.03), Color("#2d3029"), 1.0)


func _draw_army_mass(origin: Vector2, cloth_color: Color, facing: float) -> void:
	for row in 3:
		for column in 6:
			var offset := Vector2(column * 17.0 * facing, row * 18.0)
			var point := origin + offset
			draw_circle(point, 4.5, Color("#0d0e0d"))
			draw_line(point + Vector2(0, 4), point + Vector2(0, 16), Color("#0d0e0d"), 3.0)
			if column % 3 == 0:
				draw_line(point + Vector2(2, 3), point + Vector2(2, -20), BRONZE, 2.0)
				draw_colored_polygon(PackedVector2Array([
					point + Vector2(3, -19),
					point + Vector2(18 * facing, -14),
					point + Vector2(3, -5),
				]), cloth_color)
