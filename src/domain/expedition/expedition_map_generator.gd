extends RefCounted
class_name ExpeditionMapGenerator

const DeterministicRngScript := preload("res://src/domain/random/deterministic_rng.gd")
const DefinitionValidatorScript := preload("res://src/domain/expedition/expedition_definition_validator.gd")


static func generate(definition: Dictionary, seed: int, requested_version: int = -1) -> Dictionary:
	var errors: PackedStringArray = DefinitionValidatorScript.validate(definition, "expedition generator input")
	if not errors.is_empty():
		return {"ok": false, "error": "; ".join(errors), "map": {}}
	var version := requested_version
	if version < 0:
		version = 1 if definition.has("nodes") else int(definition.get("generator_profile", {}).get("version", 2))
	if version == 2:
		var legacy_profile := _profile_for_version(definition, 2)
		if legacy_profile.is_empty():
			return {"ok": false, "error": "expedition has no generator profile for version 2", "map": {}}
		return _generate_v2(definition, seed, legacy_profile)
	if version == 3:
		var active_profile := _profile_for_version(definition, 3)
		if active_profile.is_empty():
			return {"ok": false, "error": "expedition has no generator profile for version 3", "map": {}}
		return _generate_v3(definition, seed, active_profile)
	if version == 4:
		var fragment_profile := _profile_for_version(definition, 4)
		if fragment_profile.is_empty():
			return {"ok": false, "error": "expedition has no generator profile for version 4", "map": {}}
		return _generate_v4(definition, seed, fragment_profile)
	if version != 1 or not definition.has("nodes"):
		return {"ok": false, "error": "unsupported expedition generator version %d" % version, "map": {}}
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
			"generator_version": 1,
			"map_signature": "legacy-v1",
		},
	}


static func _generate_v2(definition: Dictionary, seed: int, profile: Dictionary) -> Dictionary:
	var topology_rng = DeterministicRngScript.new(_derive_seed(seed, 0x544F50))
	var node_rng = DeterministicRngScript.new(_derive_seed(seed, 0x4E4F44))
	var enemy_rng = DeterministicRngScript.new(_derive_seed(seed, 0x454E45))
	var event_rng = DeterministicRngScript.new(_derive_seed(seed, 0x45564E))
	var nodes: Array = []
	var layers: Array = []
	var prefix := String(profile.node_prefix)
	var start := _node("%s.start" % prefix, "义军营地", 0, 0, "start", false)
	start.always_revealed = true
	nodes.append(start)
	layers.append([start])
	for layer in range(1, 8):
		# The start node may expose at most two exits, so layer one is fixed to two
		# lanes. Later layers retain the configured 2–3 node variance.
		var count := int(profile.nodes_per_middle_layer_min) if layer == 1 else topology_rng.next_int(int(profile.nodes_per_middle_layer_min), int(profile.nodes_per_middle_layer_max))
		var layer_nodes: Array = []
		for lane in count:
			var node_type := _node_type_for_layer(layer, lane, node_rng, profile)
			var generated := _node("%s.l%d.n%d" % [prefix, layer, lane], _node_name(node_type), layer, lane, node_type, true)
			if node_type == "normal_combat":
				var faction := _choose_faction(profile, enemy_rng)
				if lane == 0 and layer == 1:
					faction = "government"
				elif lane == 1 and layer == 1:
					faction = "bandit"
				generated.enemy_faction = faction
				generated.enemy_id = String(enemy_rng.choose(profile.normal_enemy_pools[faction]))
			elif node_type == "elite_combat":
				generated.enemy_id = String(enemy_rng.choose(profile.elite_enemy_pool))
			elif node_type == "merchant":
				generated.merchant_guard_id = String(enemy_rng.choose(profile.merchant_guard_pool))
			elif node_type == "event":
				generated.encounter_id = String(event_rng.choose(profile.event_pool))
			elif node_type == "card_reward":
				generated.reward_kind = "temporary"
			if layer == 3:
				generated.post_battle_reward = "temporary"
			elif layer == 5:
				generated.post_battle_reward = "elite"
			layer_nodes.append(generated)
			nodes.append(generated)
		layers.append(layer_nodes)
	var boss := _node("%s.boss" % prefix, String(definition.name).trim_prefix("攻取").trim_prefix("肃清") + "决战", 8, 0, "boss", false)
	boss.always_revealed = true
	boss.enemy_id = String(profile.boss_enemy_id)
	nodes.append(boss)
	layers.append([boss])
	var edges := _connect_layers(layers, topology_rng)
	var node_by_id := {}
	var outgoing := {}
	for node in nodes:
		node_by_id[node.id] = node
	for edge in edges:
		if not outgoing.has(edge.from):
			outgoing[edge.from] = []
		outgoing[edge.from].append(edge.to)
	var map := {
		"expedition_id": definition.id,
		"name": definition.name,
		"destination_name": definition.get("destination_name", definition.name),
		"theme": definition.get("theme", ""),
		"capture_rebellion": int(definition.get("capture_rebellion", 0)),
		"seed": seed,
		"entry_node_id": start.id,
		"boss_node_id": boss.id,
		"nodes": nodes,
		"node_by_id": node_by_id,
		"edges": edges,
		"outgoing": outgoing,
		"strategic_objectives": {},
		"generator_version": 2,
	}
	map.map_signature = _map_signature(map)
	return {"ok": true, "error": "", "map": map}


static func _generate_v3(definition: Dictionary, seed: int, profile: Dictionary) -> Dictionary:
	var topology_rng = DeterministicRngScript.new(_derive_seed(seed, 0x544F50))
	var node_rng = DeterministicRngScript.new(_derive_seed(seed, 0x4E4F44))
	var enemy_rng = DeterministicRngScript.new(_derive_seed(seed, 0x454E45))
	var event_rng = DeterministicRngScript.new(_derive_seed(seed, 0x45564E))
	var prefix := String(profile.node_prefix)
	var nodes: Array = []
	var layers: Array = []
	var start := _node("%s.start" % prefix, "义军营地", 0, 0, "start", false)
	start.always_revealed = true
	start.category_revealed = true
	start.detail_revealed = true
	nodes.append(start)
	layers.append([start])

	var event_lanes: Array = node_rng.shuffled_copy([0, 1, 2])
	var event_ids: Array = event_rng.shuffled_copy(profile.event_pool)
	var event_index := 0
	var first_layer_faction_lanes: Array = enemy_rng.shuffled_copy([0, 1, 2])
	for layer in range(1, 8):
		var layer_nodes: Array = []
		var layer_types := _v3_types_for_layer(layer, event_lanes, node_rng)
		for lane in 3:
			var node_type := String(layer_types[lane])
			var generated := _node("%s.l%d.n%d" % [prefix, layer, lane], _node_name(node_type), layer, lane, node_type, true)
			generated.category_revealed = true
			generated.detail_revealed = false
			if node_type == "normal_combat":
				var faction := _choose_faction(profile, enemy_rng)
				if layer == 1 and lane == int(first_layer_faction_lanes[0]):
					faction = "government"
				elif layer == 1 and lane == int(first_layer_faction_lanes[1]):
					faction = "bandit"
				generated.enemy_faction = faction
				generated.enemy_id = String(enemy_rng.choose(profile.normal_enemy_pools[faction]))
			elif node_type == "elite_combat":
				generated.enemy_id = String(enemy_rng.choose(profile.elite_enemy_pool))
			elif node_type == "merchant":
				generated.merchant_guard_id = String(enemy_rng.choose(profile.merchant_guard_pool))
			elif node_type == "event":
				generated.encounter_id = String(event_ids[event_index])
				event_index += 1
			elif node_type == "card_reward":
				generated.reward_kind = "temporary"
			if layer == 3:
				generated.post_battle_reward = "temporary"
			elif layer == 5:
				generated.post_battle_reward = "elite"
			layer_nodes.append(generated)
			nodes.append(generated)
		layers.append(layer_nodes)

	var boss := _node("%s.boss" % prefix, String(definition.name).trim_prefix("攻取").trim_prefix("肃清") + "决战", 8, 1, "boss", false)
	boss.always_revealed = true
	boss.category_revealed = true
	boss.detail_revealed = true
	boss.enemy_id = String(profile.boss_enemy_id)
	nodes.append(boss)
	layers.append([boss])
	var edges := _connect_three_lanes(layers, topology_rng)
	var node_by_id := {}
	var outgoing := {}
	for node in nodes:
		node_by_id[node.id] = node
	for edge in edges:
		if not outgoing.has(edge.from):
			outgoing[edge.from] = []
		outgoing[edge.from].append(edge.to)
	var map := {
		"expedition_id": definition.id,
		"name": definition.name,
		"destination_name": definition.get("destination_name", definition.name),
		"theme": definition.get("theme", ""),
		"capture_rebellion": int(definition.get("capture_rebellion", 0)),
		"seed": seed,
		"entry_node_id": start.id,
		"boss_node_id": boss.id,
		"nodes": nodes,
		"node_by_id": node_by_id,
		"edges": edges,
		"outgoing": outgoing,
		"strategic_objectives": {},
		"generator_version": 3,
	}
	map.map_signature = _map_signature(map)
	return {"ok": true, "error": "", "map": map}


static func _generate_v4(definition: Dictionary, seed: int, profile: Dictionary) -> Dictionary:
	var topology_rng = DeterministicRngScript.new(_derive_seed(seed, 0x544F50))
	var node_rng = DeterministicRngScript.new(_derive_seed(seed, 0x4E4F44))
	var enemy_rng = DeterministicRngScript.new(_derive_seed(seed, 0x454E45))
	var event_rng = DeterministicRngScript.new(_derive_seed(seed, 0x45564E))
	var chosen_template := _choose_topology_template(profile.topology_templates, topology_rng)
	if chosen_template.is_empty():
		return {"ok": false, "error": "version 4 has no usable topology template", "map": {}}
	var counts: Array = chosen_template.layer_node_counts
	var prefix := String(profile.node_prefix)
	var nodes: Array = []
	var layers: Array = []
	var start := _node("%s.start" % prefix, "义军营地", 0, 0, "start", false)
	start.always_revealed = true
	start.category_revealed = true
	start.detail_revealed = true
	nodes.append(start)
	layers.append([start])

	var event_ids: Array = event_rng.shuffled_copy(profile.event_pool)
	var event_index := 0
	var first_layer_faction_lanes: Array = enemy_rng.shuffled_copy(range(int(counts[0])))
	for layer in range(1, 8):
		var count := int(counts[layer - 1])
		var layer_nodes: Array = []
		var layer_types := _v4_types_for_layer(layer, count, node_rng)
		for lane in count:
			var node_type := String(layer_types[lane])
			var generated := _node("%s.l%d.n%d" % [prefix, layer, lane], _node_name(node_type), layer, lane, node_type, true)
			generated.category_revealed = true
			generated.detail_revealed = false
			if node_type == "normal_combat":
				var faction := _choose_faction(profile, enemy_rng)
				if layer == 1 and lane == int(first_layer_faction_lanes[0]):
					faction = "government"
				elif layer == 1 and lane == int(first_layer_faction_lanes[1]):
					faction = "bandit"
				generated.enemy_faction = faction
				generated.enemy_id = String(enemy_rng.choose(profile.normal_enemy_pools[faction]))
			elif node_type == "elite_combat":
				generated.enemy_id = String(enemy_rng.choose(profile.elite_enemy_pool))
			elif node_type == "merchant":
				generated.merchant_guard_id = String(enemy_rng.choose(profile.merchant_guard_pool))
			elif node_type == "event":
				generated.encounter_id = String(event_ids[event_index])
				event_index += 1
			elif node_type == "card_reward":
				generated.reward_kind = "temporary"
			if layer == 3:
				generated.post_battle_reward = "temporary"
			elif layer == 5:
				generated.post_battle_reward = "elite"
			layer_nodes.append(generated)
			nodes.append(generated)
		layers.append(layer_nodes)

	var boss := _node("%s.boss" % prefix, String(definition.name).trim_prefix("攻取").trim_prefix("肃清") + "决战", 8, 0, "boss", false)
	boss.always_revealed = true
	boss.category_revealed = true
	boss.detail_revealed = true
	boss.enemy_id = String(profile.boss_enemy_id)
	nodes.append(boss)
	layers.append([boss])
	var edges := _connect_planar_layers(layers, topology_rng)
	var node_by_id := {}
	var outgoing := {}
	for node in nodes:
		node_by_id[node.id] = node
	for edge in edges:
		if not outgoing.has(edge.from):
			outgoing[edge.from] = []
		outgoing[edge.from].append(edge.to)
	var map := {
		"expedition_id": definition.id,
		"name": definition.name,
		"destination_name": definition.get("destination_name", definition.name),
		"theme": definition.get("theme", ""),
		"capture_rebellion": int(definition.get("capture_rebellion", 0)),
		"seed": seed,
		"entry_node_id": start.id,
		"boss_node_id": boss.id,
		"nodes": nodes,
		"node_by_id": node_by_id,
		"edges": edges,
		"outgoing": outgoing,
		"strategic_objectives": {},
		"generator_version": 4,
		"topology_variant": String(chosen_template.id),
	}
	map.map_signature = _map_signature(map)
	return {"ok": true, "error": "", "map": map}


static func _profile_for_version(definition: Dictionary, version: int) -> Dictionary:
	var active: Dictionary = definition.get("generator_profile", {})
	if int(active.get("version", -1)) == version:
		return active
	var legacy: Dictionary = definition.get("legacy_generator_profiles", {})
	return legacy.get(str(version), {}).duplicate(true)


static func _v3_types_for_layer(layer: int, event_lanes: Array, rng) -> Array:
	if layer in [1, 3, 7]:
		return ["normal_combat", "normal_combat", "normal_combat"]
	if layer == 5:
		return ["elite_combat", "elite_combat", "elite_combat"]
	var event_slot: int = int(event_lanes[0] if layer == 2 else (event_lanes[1] if layer == 4 else event_lanes[2]))
	var companion_types := ["merchant", "supply"] if layer == 2 else (["merchant", "item"] if layer == 4 else ["supply", "card_reward"])
	companion_types = rng.shuffled_copy(companion_types)
	var result := ["", "", ""]
	result[event_slot] = "event"
	var companion_index := 0
	for lane in 3:
		if lane == event_slot:
			continue
		result[lane] = companion_types[companion_index]
		companion_index += 1
	return result


static func _v4_types_for_layer(layer: int, count: int, rng) -> Array:
	if layer in [1, 3, 7]:
		var normal_types: Array = []
		normal_types.resize(count)
		normal_types.fill("normal_combat")
		return normal_types
	if layer == 5:
		var elite_types: Array = []
		elite_types.resize(count)
		elite_types.fill("elite_combat")
		return elite_types
	var result: Array = ["event"]
	if layer == 2:
		result.append("merchant")
	elif layer == 4:
		result.append("merchant")
		result.append("item")
	else:
		result.append("supply")
		result.append("card_reward")
	while result.size() < count:
		result.append("supply")
	return rng.shuffled_copy(result)


static func _choose_topology_template(templates: Array, rng) -> Dictionary:
	var total_weight := 0
	for template in templates:
		total_weight += maxi(int(template.get("weight", 1)), 1)
	if total_weight <= 0:
		return {}
	var roll: int = rng.next_int(1, total_weight)
	for template in templates:
		roll -= maxi(int(template.get("weight", 1)), 1)
		if roll <= 0:
			return template.duplicate(true)
	return templates.back().duplicate(true)


static func _connect_three_lanes(layers: Array, rng) -> Array:
	var edges: Array = []
	for lane in 3:
		_add_edge(edges, {}, layers[0][0].id, layers[1][lane].id)
	for layer in range(1, 7):
		for lane in 3:
			_add_edge(edges, {}, layers[layer][lane].id, layers[layer + 1][lane].id)
		if layer in [2, 5]:
			var cross_options := [[0, 1], [1, 0], [1, 2], [2, 1]]
			var chosen: Array = cross_options[rng.next_int(0, cross_options.size() - 1)]
			_add_edge(edges, {}, layers[layer][int(chosen[0])].id, layers[layer + 1][int(chosen[1])].id)
	for lane in 3:
		_add_edge(edges, {}, layers[7][lane].id, layers[8][0].id)
	return edges


static func _connect_planar_layers(layers: Array, rng) -> Array:
	var edges: Array = []
	for layer_index in range(layers.size() - 1):
		var from_nodes: Array = layers[layer_index]
		var to_nodes: Array = layers[layer_index + 1]
		for from_index in from_nodes.size():
			var target_index := _proportional_index(from_index, from_nodes.size(), to_nodes.size())
			_add_edge(edges, {}, from_nodes[from_index].id, to_nodes[target_index].id)
		for to_index in to_nodes.size():
			var source_index := _proportional_index(to_index, to_nodes.size(), from_nodes.size())
			_add_edge(edges, {}, from_nodes[source_index].id, to_nodes[to_index].id)
		if layer_index > 0 and layer_index < layers.size() - 2 and from_nodes.size() == to_nodes.size() and from_nodes.size() > 1 and rng.next_int(0, 1) == 1:
			var boundary: int = rng.next_int(0, from_nodes.size() - 2)
			if rng.next_int(0, 1) == 0:
				_add_edge(edges, {}, from_nodes[boundary].id, to_nodes[boundary + 1].id)
			else:
				_add_edge(edges, {}, from_nodes[boundary + 1].id, to_nodes[boundary].id)
	return edges


static func _proportional_index(index: int, source_count: int, target_count: int) -> int:
	if target_count <= 1:
		return 0
	if source_count <= 1:
		return target_count / 2
	return clampi(int(round(float(index) * float(target_count - 1) / float(source_count - 1))), 0, target_count - 1)


static func _node(id: String, name: String, layer: int, lane: int, node_type: String, fogged: bool) -> Dictionary:
	return {
		"id": id,
		"name": name,
		"column": layer,
		"layer": layer,
		"lane": lane,
		"route": "generated",
		"node_type": node_type,
		"fogged": fogged,
		"presentation": {"description": _node_description(node_type)},
	}


static func _node_type_for_layer(layer: int, lane: int, rng, profile: Dictionary) -> String:
	if layer in [1, 3, 7]:
		return "normal_combat"
	if layer == 5:
		return "elite_combat"
	if layer == 2:
		if lane == 0 or rng.next_int(1, 100) <= int(profile.get("merchant_weight", 20)):
			return "merchant"
		return String(rng.choose(["event", "supply", "event"]))
	if layer == 4:
		if lane == 0 or rng.next_int(1, 100) <= int(profile.get("merchant_weight", 20)):
			return "merchant"
		return String(rng.choose(["event", "item", "event"]))
	if layer == 6:
		return "card_reward" if rng.next_int(0, 1) == 1 else String(rng.choose(["event", "supply", "event"]))
	return "event"


static func _choose_faction(profile: Dictionary, rng) -> String:
	var government := int(profile.normal_faction_weights.government)
	var bandit := int(profile.normal_faction_weights.bandit)
	return "government" if rng.next_int(1, government + bandit) <= government else "bandit"


static func _connect_layers(layers: Array, rng) -> Array:
	var edges: Array = []
	for layer_index in range(layers.size() - 1):
		var from_nodes: Array = layers[layer_index]
		var to_nodes: Array = layers[layer_index + 1]
		var incoming := {}
		var outgoing_counts := {}
		for from_index in from_nodes.size():
			var primary := mini(from_index, to_nodes.size() - 1)
			_add_edge(edges, incoming, from_nodes[from_index].id, to_nodes[primary].id)
			outgoing_counts[from_nodes[from_index].id] = 1
		for to_index in to_nodes.size():
			if not incoming.has(to_nodes[to_index].id):
				var source_id := _source_with_capacity(from_nodes, outgoing_counts, to_index)
				_add_edge(edges, incoming, source_id, to_nodes[to_index].id)
				outgoing_counts[source_id] = int(outgoing_counts.get(source_id, 0)) + 1
		if to_nodes.size() > 1:
			for from_index in from_nodes.size():
				var source_id := String(from_nodes[from_index].id)
				if int(outgoing_counts.get(source_id, 0)) >= 2 or rng.next_int(0, 1) == 0:
					continue
				var secondary := (from_index + 1) % to_nodes.size()
				if _edge_exists(edges, source_id, String(to_nodes[secondary].id)):
					secondary = (secondary + 1) % to_nodes.size()
				if not _edge_exists(edges, source_id, String(to_nodes[secondary].id)):
					_add_edge(edges, incoming, source_id, to_nodes[secondary].id)
					outgoing_counts[source_id] = int(outgoing_counts.get(source_id, 0)) + 1
	return edges


static func _source_with_capacity(from_nodes: Array, outgoing_counts: Dictionary, preferred_index: int) -> String:
	var candidates: Array[String] = []
	for node in from_nodes:
		var node_id := String(node.id)
		if int(outgoing_counts.get(node_id, 0)) < 2:
			candidates.append(node_id)
	if candidates.is_empty():
		return String(from_nodes[mini(preferred_index, from_nodes.size() - 1)].id)
	candidates.sort_custom(func(left: String, right: String) -> bool:
		var left_count := int(outgoing_counts.get(left, 0))
		var right_count := int(outgoing_counts.get(right, 0))
		return left_count < right_count if left_count != right_count else left < right
	)
	return candidates[0]


static func _edge_exists(edges: Array, from_id: String, to_id: String) -> bool:
	for edge in edges:
		if edge.from == from_id and edge.to == to_id:
			return true
	return false


static func _add_edge(edges: Array, incoming: Dictionary, from_id: String, to_id: String) -> void:
	for edge in edges:
		if edge.from == from_id and edge.to == to_id:
			return
	edges.append({"from": from_id, "to": to_id})
	incoming[to_id] = true


static func _node_name(node_type: String) -> String:
	return {
		"normal_combat": "敌军阻路",
		"elite_combat": "强敌据险",
		"merchant": "过路商队",
		"event": "途中异事",
		"supply": "临时补给",
		"item": "遗落军资",
		"card_reward": "军略所得",
	}.get(node_type, "未知去处")


static func _node_description(node_type: String) -> String:
	return {
		"normal_combat": "必须击退阻路敌军。",
		"elite_combat": "强敌镇守此处，胜后可获得稀有军略。",
		"merchant": "可以交易、袭击或直接离开。",
		"event": "选择会带来不同代价与收益。",
		"supply": "恢复部分兵力与士气。",
		"item": "获得一件本次远征使用的临时物品。",
		"card_reward": "从三张临时卡牌中选择一张。",
	}.get(node_type, "前路尚未探明。")


static func _derive_seed(seed: int, salt: int) -> int:
	return (seed ^ salt ^ 0x6D3652) & 0x7fffffff


static func _map_signature(map: Dictionary) -> String:
	var parts: Array[String] = [String(map.expedition_id), str(map.seed), str(map.generator_version)]
	if int(map.get("generator_version", 2)) >= 4:
		parts.append("topology=%s" % String(map.get("topology_variant", "")))
	for node in map.nodes:
		parts.append("%s|%s|%s|%s" % [node.id, node.node_type, node.get("enemy_id", ""), node.get("encounter_id", "")])
		if int(map.get("generator_version", 2)) >= 3:
			parts.append("%s|lane=%s|faction=%s|guard=%s|reward=%s" % [node.id, node.get("lane", ""), node.get("enemy_faction", ""), node.get("merchant_guard_id", ""), node.get("reward_kind", "")])
	for edge in map.edges:
		parts.append("%s>%s" % [edge.from, edge.to])
	var hash_value := 2166136261
	for byte in "\n".join(parts).to_utf8_buffer():
		hash_value = int((hash_value ^ int(byte)) * 16777619) & 0x7fffffff
	return "v%d-%08x" % [int(map.get("generator_version", 2)), hash_value]
