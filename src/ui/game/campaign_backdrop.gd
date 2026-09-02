extends Control
class_name CampaignBackdrop

const Tokens := preload("res://src/ui/theme/visual_tokens.gd")
const CAMP_TEXTURE := preload("res://assets/art/scenes/rebel_camp_stage1.png")


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


func _draw() -> void:
	var canvas := size
	draw_texture_rect(CAMP_TEXTURE, Rect2(Vector2.ZERO, canvas), false)
	# 稳定的浅纸幕布保证正文对比度；背景仍提供层次，但不与 UI 争夺阅读焦点。
	draw_rect(Rect2(Vector2.ZERO, canvas), Tokens.with_alpha(Tokens.PAPER_BRIGHT, 0.56))
