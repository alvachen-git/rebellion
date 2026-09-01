extends RefCounted
class_name ExpeditionMapGenerator

const DeterministicRngScript := preload("res://src/domain/random/deterministic_rng.gd")
const DefinitionValidatorScript := preload("res://src/domain/expedition/expedition_definition_validator.gd")


static func generate(definition: Dictionary, seed: int) -> Dictionary:
	var errors: PackedStringArray = DefinitionValidatorScript.validate(definition, "expedition generator input")
	if not errors.is_empty():
		return {"ok": false, "error": "; ".join(errors), "map": {}}
	var rng = DeterministicRngScript.new(seed ^ 0x4E4150)
	var nodes: Array = []
	var node_by_id := {}
	for source_node in definition.nodes:
		var node: Dictionary = source_node.duplicate(true)
		if node.has("node_type_options"):
			var options: Array = node.node_type_options
			node.node_type = rng.choose(options)
			node.generated_from_options = true
			node.erase("node_type_options")
		else:
			node.generated_from_options = false
		nodes.append(node)
		node_by_id[node.id] = node
	var outgoing := {}
	for edge in definition.edges:
		if not outgoing.has(edge.from):
			outgoing[edge.from] = []
		outgoing[edge.from].append(edge.to)
	return {
		"ok": true,
		"error": "",
		"map": {
			"expedition_id": definition.id,
			"name": definition.name,
			"seed": seed,
			"entry_node_id": definition.entry_node_id,
			"boss_node_id": definition.boss_node_id,
			"nodes": nodes,
			"node_by_id": node_by_id,
			"edges": definition.edges.duplicate(true),
			"outgoing": outgoing,
			"strategic_objectives": definition.strategic_objectives.duplicate(true),
		},
	}
