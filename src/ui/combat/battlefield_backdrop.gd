extends Control

const Tokens := preload("res://src/ui/theme/visual_tokens.gd")
const BATTLE_TEXTURE := preload("res://assets/art/scenes/heyuan_battlefield.png")
const INK := Tokens.INK
const DISTANT_INK := Tokens.MOUNTAIN_BLUE
const MIST := Tokens.MIST
const BRONZE := Tokens.LIGHT_GOLD_DARK
const PLAYER_CLOTH := Tokens.DEEP_TEAL
const ENEMY_CLOTH := Tokens.CINNABAR


func _ready() -> void:
	resized.connect(queue_redraw)


func _draw() -> void:
	var width := size.x
	var height := size.y
	draw_texture_rect(BATTLE_TEXTURE, Rect2(Vector2.ZERO, size), false)
	draw_rect(Rect2(Vector2.ZERO, size), Tokens.with_alpha(Tokens.PAPER_BRIGHT, 0.16))
	_draw_mountains(width, height)
	_draw_ground(width, height)
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
	draw_colored_polygon(rear, Tokens.with_alpha(DISTANT_INK, 0.18))
	var mist_color := Color(MIST, 0.48)
	draw_rect(Rect2(0, height * 0.36, width, height * 0.18), mist_color)


func _draw_ground(width: float, height: float) -> void:
	draw_colored_polygon(PackedVector2Array([
		Vector2(0, height * 0.53),
		Vector2(width, height * 0.48),
		Vector2(width, height),
		Vector2(0, height),
	]), Tokens.with_alpha(Tokens.MINERAL_GREEN, 0.14))
	for index in 6:
		var y := height * (0.58 + index * 0.07)
		draw_line(Vector2(0, y), Vector2(width, y - height * 0.03), Tokens.with_alpha(Tokens.DEEP_TEAL, 0.16), 1.0)
