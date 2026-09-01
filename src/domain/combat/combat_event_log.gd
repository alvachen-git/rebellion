extends RefCounted
class_name CombatEventLog

var _events: Array[Dictionary] = []
var _sequence := 0


func record(event_type: String, payload: Dictionary = {}) -> void:
	_sequence += 1
	_events.append({
		"sequence": _sequence,
		"type": event_type,
		"payload": payload.duplicate(true),
	})


func snapshot() -> Array[Dictionary]:
	return _events.duplicate(true)


func count() -> int:
	return _events.size()
