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
	if not _uses_category_visibility():
		_reveal_outgoing(entry_id)
	return PackedStringArray()


func restore(generated_map: Dictionary, saved: Dictionary) -> PackedStringArray:
	var errors := setup(generated_map)
	if not errors.is_empty():
		return errors
	for field in ["expedition_id", "seed", "current_node_id", "visited_node_ids", "completed_node_ids", "revealed_node_ids", "status"]:
		if not saved.has(field):
			errors.append("expedition route restore missing field '%s'" % field)
	if not errors.is_empty():
		return errors
	if saved.expedition_id != generated_map.expedition_id or int(saved.seed) != int(generated_map.seed):
		errors.append("expedition route restore identity or seed mismatch")
	var valid_ids: Dictionary = generated_map.node_by_id
	for field in ["visited_node_ids", "completed_node_ids", "revealed_node_ids"]:
		if not saved[field] is Array:
			errors.append("expedition route restore %s must be an array" % field)
			continue
		for node_id in saved[field]:
			if not valid_ids.has(node_id):
				errors.append("expedition route restore references unknown node '%s'" % node_id)
	if not valid_ids.has(saved.current_node_id):
		errors.append("expedition route restore current node is unknown")
	if not saved.status in ["active", "completed"]:
		errors.append("expedition route restore status is invalid")
	if errors.is_empty():
		_current_node_id = saved.current_node_id
		_visited.assign(saved.visited_node_ids)
		_completed = {}
		for node_id in saved.completed_node_ids:
			_completed[node_id] = true
		_revealed = {}
		for node_id in saved.revealed_node_ids:
			_revealed[node_id] = true
		_status = saved.status
		if _visited.is_empty() or _visited[0] != generated_map.entry_node_id or not _visited.has(_current_node_id):
			errors.append("expedition route restore visited path is inconsistent")
		elif _has_duplicates(_visited):
			errors.append("expedition route restore visited path contains duplicates")
		else:
			for index in range(1, _visited.size()):
				if not generated_map.outgoing.get(_visited[index - 1], []).has(_visited[index]):
					errors.append("expedition route restore visited path contains a disconnected step")
					break
		for node_id in _completed:
			if not _visited.has(node_id):
				errors.append("expedition route restore completed node was never visited")
		if _status == "completed" and _current_node_id != generated_map.boss_node_id:
			errors.append("expedition route restore completed status requires boss node")
		elif _status == "active" and _current_node_id == generated_map.boss_node_id and bool(_completed.get(_current_node_id, false)):
			errors.append("expedition route restore completed boss cannot remain active")
		if saved.has("available_next_node_ids") and saved.available_next_node_ids != available_next_node_ids():
			errors.append("expedition route restore available nodes do not match regenerated map state")
	return errors


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
	elif not _uses_category_visibility():
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


func current_node() -> Dictionary:
	return _map.get("node_by_id", {}).get(_current_node_id, {}).duplicate(true)


func reveal_node(node_id: String) -> Dictionary:
	if not _map.get("node_by_id", {}).has(node_id):
		return _failure("找不到要揭示的节点")
	_revealed[node_id] = true
	return {"ok": true, "node_id": node_id, "reason": ""}


func reveal_future_layers(layer_count: int) -> Dictionary:
	if layer_count <= 0:
		return _failure("揭示层数必须为正数")
	var current: Dictionary = current_node()
	var current_layer := int(current.get("layer", current.get("column", 0)))
	var revealed_ids: Array = []
	for node in _map.get("nodes", []):
		var layer := int(node.get("layer", node.get("column", 0)))
		if layer > current_layer and layer <= current_layer + layer_count:
			_revealed[node.id] = true
			revealed_ids.append(node.id)
	return {"ok": true, "revealed_node_ids": revealed_ids, "reason": ""}


func status() -> String:
	return _status


func visible_nodes() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for source_node in _map.get("nodes", []):
		var node: Dictionary = source_node.duplicate(true)
		var detail_revealed := bool(_revealed.get(node.id, false)) or not bool(node.get("fogged", true))
		if _uses_category_visibility():
			node.is_revealed = true
			node.is_detail_revealed = detail_revealed
			if not detail_revealed:
				node.name = _category_name(node)
				node.presentation = {"description": "路线类别已探明，具体内容尚待抵达或侦察。"}
				node.erase("enemy_id")
				node.erase("encounter_id")
				node.erase("merchant_guard_id")
		elif not detail_revealed:
			node.is_revealed = false
			node.is_detail_revealed = false
			node.name = "未知节点"
			node.node_type = "unknown"
			node.presentation = {"description": "尚未获得此处情报。"}
			node.erase("enemy_id")
			node.erase("objective_id")
		else:
			node.is_revealed = true
			node.is_detail_revealed = true
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


func _uses_category_visibility() -> bool:
	return int(_map.get("generator_version", 1)) >= 3


func _category_name(node: Dictionary) -> String:
	var node_type := String(node.get("node_type", "unknown"))
	if node_type == "normal_combat":
		return "官兵阻路" if node.get("enemy_faction", "") == "government" else "土匪阻路"
	return {
		"elite_combat": "精英强敌",
		"event": "途中事件",
		"merchant": "过路商队",
		"supply": "临时补给",
		"item": "临时物品",
		"card_reward": "军略奖励",
		"boss": "最终决战",
		"start": "义军营地",
	}.get(node_type, "未知节点")


func _failure(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}


func _has_duplicates(values: Array[String]) -> bool:
	var seen := {}
	for value in values:
		if seen.has(value):
			return true
		seen[value] = true
	return false
