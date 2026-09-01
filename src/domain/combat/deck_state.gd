extends RefCounted
class_name DeckState

var draw_pile: Array = []
var hand: Array = []
var discard_pile: Array = []
var exhaust_pile: Array = []
var _rng


func setup(card_ids: Array, deterministic_rng) -> void:
	_rng = deterministic_rng
	draw_pile = _rng.shuffled_copy(card_ids)
	hand.clear()
	discard_pile.clear()
	exhaust_pile.clear()


func draw(count: int) -> Array:
	var drawn: Array = []
	for index in maxi(count, 0):
		if draw_pile.is_empty():
			_reshuffle_discard()
		if draw_pile.is_empty():
			break
		var card_id = draw_pile.pop_back()
		hand.append(card_id)
		drawn.append(card_id)
	return drawn


func play_from_hand(hand_index: int, exhaust: bool) -> String:
	if hand_index < 0 or hand_index >= hand.size():
		return ""
	var card_id: String = hand.pop_at(hand_index)
	if exhaust:
		exhaust_pile.append(card_id)
	else:
		discard_pile.append(card_id)
	return card_id


func discard_hand() -> Array:
	var discarded := hand.duplicate()
	discard_pile.append_array(hand)
	hand.clear()
	return discarded


func snapshot() -> Dictionary:
	return {
		"draw_pile": draw_pile.duplicate(),
		"hand": hand.duplicate(),
		"discard_pile": discard_pile.duplicate(),
		"exhaust_pile": exhaust_pile.duplicate(),
	}


func _reshuffle_discard() -> void:
	if discard_pile.is_empty():
		return
	draw_pile = _rng.shuffled_copy(discard_pile)
	discard_pile.clear()
