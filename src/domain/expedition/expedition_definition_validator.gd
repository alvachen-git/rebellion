extends RefCounted
class_name ExpeditionDefinitionValidator

const ALLOWED_NODE_TYPES := {
	"start": true,
	"normal_combat": true,
	"elite_combat": true,
	"event": true,
	"supply": true,
	"intel": true,
	"military_objective": true,
	"loot": true,
	"wealth_risk": true,
	"boss": true,
}
const REQUIRED_OBJECTIVES := {
	"official_road": "armory_destroyed",
	"village_path": "beacon_destroyed",
	"grain_route": "granary_destroyed",
}


static func validate(data: Dictionary, source: String = "<memory>") -> PackedStringArray:
	var errors := PackedStringArray()
	for field in ["id", "name", "node_count_min", "node_count_max", "entry_node_id", "boss_node_id", "nodes", "edges", "strategic_objectives", "presentation"]:
		if not data.has(field):
			errors.append("%s: missing expedition field '%s'" % [source, field])
	if String(data.get("id", "")).strip_edges().is_empty():
		errors.append("%s: expedition id must be a non-empty string" % source)
	var nodes = data.get("nodes", null)
	if not nodes is Array:
		errors.append("%s: expedition nodes must be an array" % source)
		return errors
	var minimum := int(data.get("node_count_min", 0))
	var maximum := int(data.get("node_count_max", 0))
	if minimum < 1 or maximum < minimum:
		errors.append("%s: expedition node count range is invalid" % source)
	elif nodes.size() < minimum or nodes.size() > maximum:
		errors.append("%s: expedition node count must be between %d and %d" % [source, minimum, maximum])
	var node_by_id := {}
	for index in nodes.size():
		var node = nodes[index]
		if not node is Dictionary:
			errors.append("%s: node[%d] must be an object" % [source, index])
			continue
		_validate_node(node, source, index, errors)
		var node_id: String = node.get("id", "")
		if not node_id.is_empty():
			if node_by_id.has(node_id):
				errors.append("%s: duplicate expedition node id '%s'" % [source, node_id])
			else:
				node_by_id[node_id] = node
	_validate_entry_and_boss(data, node_by_id, source, errors)
	var outgoing := _validate_edges(data.get("edges", null), node_by_id, source, errors)
	_validate_reachability(data, node_by_id, outgoing, source, errors)
	_validate_strategic_objectives(data.get("strategic_objectives", null), node_by_id, source, errors)
	return errors


static func _validate_node(node: Dictionary, source: String, index: int, errors: PackedStringArray) -> void:
	for field in ["id", "name", "column", "route", "fogged", "presentation"]:
		if not node.has(field):
			errors.append("%s: node[%d] missing field '%s'" % [source, index, field])
	if String(node.get("id", "")).strip_edges().is_empty():
		errors.append("%s: node[%d] id must be non-empty" % [source, index])
	if int(node.get("column", -1)) < 0:
		errors.append("%s: node[%d] column must be non-negative" % [source, index])
	if not node.get("fogged", null) is bool:
		errors.append("%s: node[%d] fogged must be boolean" % [source, index])
	var has_fixed := node.has("node_type")
	var has_options := node.has("node_type_options")
	if has_fixed == has_options:
		errors.append("%s: node[%d] requires exactly one node_type or node_type_options" % [source, index])
	elif has_fixed:
		if not ALLOWED_NODE_TYPES.has(node.get("node_type", "")):
			errors.append("%s: node[%d] has unsupported node_type '%s'" % [source, index, node.get("node_type", "")])
		if node.get("node_type", "") == "boss" and String(node.get("enemy_id", "")).is_empty():
			errors.append("%s: boss node[%d] requires enemy_id" % [source, index])
	else:
		var options = node.get("node_type_options", null)
		if not options is Array or options.is_empty():
			errors.append("%s: node[%d] node_type_options must be a non-empty array" % [source, index])
		else:
			for option in options:
				if not ALLOWED_NODE_TYPES.has(option):
					errors.append("%s: node[%d] has unsupported node type option '%s'" % [source, index, option])


static func _validate_entry_and_boss(data: Dictionary, node_by_id: Dictionary, source: String, errors: PackedStringArray) -> void:
	var entry_id: String = data.get("entry_node_id", "")
	var boss_id: String = data.get("boss_node_id", "")
	if not node_by_id.has(entry_id):
		errors.append("%s: entry_node_id references unknown node '%s'" % [source, entry_id])
	elif node_by_id[entry_id].get("node_type", "") != "start":
		errors.append("%s: entry node must use node_type 'start'" % source)
	if not node_by_id.has(boss_id):
		errors.append("%s: boss_node_id references unknown node '%s'" % [source, boss_id])
	elif node_by_id[boss_id].get("node_type", "") != "boss":
		errors.append("%s: boss node must use node_type 'boss'" % source)


static func _validate_edges(edges, node_by_id: Dictionary, source: String, errors: PackedStringArray) -> Dictionary:
	var outgoing := {}
	if not edges is Array:
		errors.append("%s: expedition edges must be an array" % source)
		return outgoing
	var seen := {}
	for index in edges.size():
		var edge = edges[index]
		if not edge is Dictionary:
			errors.append("%s: edge[%d] must be an object" % [source, index])
			continue
		var from_id: String = edge.get("from", "")
		var to_id: String = edge.get("to", "")
		if not node_by_id.has(from_id) or not node_by_id.has(to_id):
			errors.append("%s: edge[%d] references unknown node" % [source, index])
			continue
		var edge_key := "%s>%s" % [from_id, to_id]
		if seen.has(edge_key):
			errors.append("%s: duplicate edge '%s'" % [source, edge_key])
			continue
		seen[edge_key] = true
		if int(node_by_id[to_id].column) <= int(node_by_id[from_id].column):
			errors.append("%s: edge '%s' must advance to a higher column" % [source, edge_key])
		if not outgoing.has(from_id):
			outgoing[from_id] = []
		outgoing[from_id].append(to_id)
	return outgoing


static func _validate_reachability(data: Dictionary, node_by_id: Dictionary, outgoing: Dictionary, source: String, errors: PackedStringArray) -> void:
	var entry_id: String = data.get("entry_node_id", "")
	if not node_by_id.has(entry_id):
		return
	var reachable := {entry_id: true}
	var frontier := [entry_id]
	while not frontier.is_empty():
		var current: String = frontier.pop_front()
		for next_id in outgoing.get(current, []):
			if not reachable.has(next_id):
				reachable[next_id] = true
				frontier.append(next_id)
	for node_id in node_by_id:
		if not reachable.has(node_id):
			errors.append("%s: node '%s' is unreachable from entry" % [source, node_id])
	var boss_id: String = data.get("boss_node_id", "")
	if node_by_id.has(boss_id) and not reachable.has(boss_id):
		errors.append("%s: boss node is unreachable from entry" % source)


static func _validate_strategic_objectives(objectives, node_by_id: Dictionary, source: String, errors: PackedStringArray) -> void:
	if not objectives is Dictionary:
		errors.append("%s: strategic_objectives must be an object" % source)
		return
	for route_id in REQUIRED_OBJECTIVES:
		var objective = objectives.get(route_id, null)
		if not objective is Dictionary:
			errors.append("%s: missing strategic objective for route '%s'" % [source, route_id])
			continue
		var node_id: String = objective.get("node_id", "")
		if not node_by_id.has(node_id):
			errors.append("%s: strategic objective references unknown node '%s'" % [source, node_id])
			continue
		var node: Dictionary = node_by_id[node_id]
		if node.get("node_type", "") != "military_objective" or node.get("route", "") != route_id:
			errors.append("%s: strategic objective '%s' must match its route military node" % [source, route_id])
		if objective.get("boss_modifier_id", "") != REQUIRED_OBJECTIVES[route_id]:
			errors.append("%s: route '%s' has the wrong boss modifier" % [source, route_id])
		if node.get("objective_id", "") != REQUIRED_OBJECTIVES[route_id]:
			errors.append("%s: route '%s' military node has the wrong objective_id" % [source, route_id])
