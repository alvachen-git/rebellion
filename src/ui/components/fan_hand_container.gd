extends Container
class_name FanHandContainer

@export var card_separation := -4.0
@export var angle_step_degrees := 2.2
@export var edge_drop := 5.0


func _ready() -> void:
	child_order_changed.connect(queue_sort)
	resized.connect(queue_sort)
	queue_sort()


func _get_minimum_size() -> Vector2:
	var cards := _cards()
	if cards.is_empty():
		return Vector2.ZERO
	var width := 0.0
	var height := 0.0
	for card in cards:
		var minimum := card.get_combined_minimum_size()
		width += minimum.x
		height = maxf(height, minimum.y)
	width += card_separation * float(cards.size() - 1)
	var edge_distance := (float(cards.size()) - 1.0) * 0.5
	return Vector2(width, height + edge_distance * edge_drop + 18.0)


func _notification(what: int) -> void:
	if what != NOTIFICATION_SORT_CHILDREN:
		return
	var cards := _cards()
	if cards.is_empty():
		return
	var center := (float(cards.size()) - 1.0) * 0.5
	var cursor_x := 0.0
	for index in cards.size():
		var card := cards[index]
		var minimum := card.get_combined_minimum_size()
		var distance := float(index) - center
		var base_y := absf(distance) * edge_drop
		fit_child_in_rect(card, Rect2(cursor_x, base_y, minimum.x, minimum.y))
		card.rotation_degrees = distance * angle_step_degrees
		card.pivot_offset = card.size * 0.5
		card.set_meta("fan_base_y", base_y)
		cursor_x += minimum.x + card_separation


func _cards() -> Array[Control]:
	var result: Array[Control] = []
	for child in get_children():
		if child is Control and child.visible:
			result.append(child)
	return result
