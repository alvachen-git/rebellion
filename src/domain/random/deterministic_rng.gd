extends RefCounted
class_name DeterministicRng

var _rng := RandomNumberGenerator.new()
var _initial_seed: int = 0


func _init(initial_seed: int = 0) -> void:
	reset(initial_seed)


func reset(seed_value: int) -> void:
	_initial_seed = seed_value
	_rng.seed = seed_value


func initial_seed() -> int:
	return _initial_seed


func state() -> int:
	return _rng.state


func restore_state(state_value: int) -> void:
	_rng.state = state_value


func next_int(minimum: int, maximum: int) -> int:
	return _rng.randi_range(minimum, maximum)


func next_float() -> float:
	return _rng.randf()


func choose(values: Array):
	if values.is_empty():
		return null
	return values[next_int(0, values.size() - 1)]


func shuffled_copy(values: Array) -> Array:
	var result := values.duplicate(true)
	for index in range(result.size() - 1, 0, -1):
		var swap_index := next_int(0, index)
		var temporary = result[index]
		result[index] = result[swap_index]
		result[swap_index] = temporary
	return result
