extends RefCounted
class_name ExpeditionRouteState

var _map: Dictionary = {}
var _current_node_id := ""
var _visited: Array[String] = []
var _completed := {}
var _revealed := {}
var _status := "uninitialized"


func setup(generated_map: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	for field in ["entry_node_id", "boss_node_id", "node_by_id", "outgoing"]:
		if not generated_map.has(field):
			errors.append("expedition map missing field '%s'" % field)
	if not errors.is_empty():
		return errors
	var entry_id: String = generated_map.get("entry_node_id", "")
	if not generated_map.node_by_id.has(entry_id):
		errors.append("expedition map entry node is missing")
		return errors
	_map = generated_map.duplicate(true)
	_current_node_id = entry_id
	_visited = [entry_id]
	_completed = {entry_id: true}
	_revealed = {entry_id: true}
	_status = "active"
	for node in _map.get("nodes", []):
		if bool(node.get("always_revealed", false)):
			_revealed[node.id] = true
	_reveal_outgoing(entry_id)
	return PackedStringArray()


func advance_to(node_id: String) -> Dictionary:
	if _status != "active":
		return _failure("当前远征路线不可继续推进")
	if not bool(_completed.get(_current_node_id, false)):
		return _failure("必须先完成当前节点")
	if not available_next_node_ids().has(node_id):
		return _failure("目标节点不与当前节点相连")
	if _visited.has(node_id):
		return _failure("不能返回已经走过的节点")
	_current_node_id = node_id
	_visited.append(node_id)
	_revealed[node_id] = true
	return {"ok": true, "node_id": node_id, "reason": ""}


func complete_current_node() -> Dictionary:
	if _status != "active":
		return _failure("当前远征路线不能结算节点")
	if bool(_completed.get(_current_node_id, false)):
		return _failure("当前节点已经完成")
	_completed[_current_node_id] = true
	if _current_node_id == _map.get("boss_node_id", ""):
		_status = "completed"
	else:
		_reveal_outgoing(_current_node_id)
	return {"ok": true, "node_id": _current_node_id, "reason": ""}


func available_next_node_ids() -> Array[String]:
	var result: Array[String] = []
	if _status != "active" or not bool(_completed.get(_current_node_id, false)):
		return result
	for node_id in _map.get("outgoing", {}).get(_current_node_id, []):
		if not _visited.has(node_id):
			result.append(node_id)
	return result


func visible_nodes() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for source_node in _map.get("nodes", []):
		var node: Dictionary = source_node.duplicate(true)
		var is_revealed := bool(_revealed.get(node.id, false)) or not bool(node.get("fogged", true))
		node.is_revealed = is_revealed
		if not is_revealed:
			node.name = "未知节点"
			node.node_type = "unknown"
			node.presentation = {"description": "尚未获得此处情报。"}
			node.erase("enemy_id")
			node.erase("objective_id")
		result.append(node)
	return result


func snapshot() -> Dictionary:
	var completed_ids: Array = _completed.keys()
	var revealed_ids: Array = _revealed.keys()
	completed_ids.sort()
	revealed_ids.sort()
	return {
		"expedition_id": _map.get("expedition_id", ""),
		"seed": _map.get("seed", 0),
		"current_node_id": _current_node_id,
		"visited_node_ids": _visited.duplicate(),
		"completed_node_ids": completed_ids,
		"revealed_node_ids": revealed_ids,
		"available_next_node_ids": available_next_node_ids(),
		"status": _status,
	}


func _reveal_outgoing(node_id: String) -> void:
	for next_id in _map.get("outgoing", {}).get(node_id, []):
		_revealed[next_id] = true


func _failure(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
