extends Control

const Tokens := preload("res://src/ui/theme/visual_tokens.gd")
const BATTLE_TEXTURE := preload("res://assets/art/scenes/chenwu_songgu_battlefield_v2.png")


func _ready() -> void:
	resized.connect(queue_redraw)


func _draw() -> void:
	draw_texture_rect(BATTLE_TEXTURE, Rect2(Vector2.ZERO, size), false)
	# Keep the plate bright while muting residual texture behind live battlefield UI.
	draw_rect(Rect2(Vector2.ZERO, size), Tokens.with_alpha(Tokens.PAPER_BRIGHT, 0.055))
