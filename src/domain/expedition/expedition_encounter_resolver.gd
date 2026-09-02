extends RefCounted
class_name ExpeditionEncounterResolver

const DeterministicRngScript := preload("res://src/domain/random/deterministic_rng.gd")

const COMBAT_NODE_TYPES := {"normal_combat": true, "elite_combat": true, "military_objective": true, "wealth_risk": true, "boss": true}

var _definition: Dictionary = {}


func setup(definition: Dictionary) -> PackedStringArray:
	_definition = {}
	var errors := PackedStringArray()
	for field in ["id", "balance_status", "expedition_id", "battle_seed_salt", "normal_enemy_pools", "objective_enemies", "elite_enemy_pool", "wealth_enemy_pool", "victory_rewards", "noncombat_effects"]:
		if not definition.has(field):
			errors.append("encounter config missing field '%s'" % field)
	if definition.get("balance_status", "") != "prototype_temporary":
		errors.append("encounter config must remain prototype_temporary")
	if errors.is_empty():
		_definition = definition.duplicate(true)
	return errors


func resolve(node: Dictionary, expedition_seed: int) -> Dictionary:
	if _definition.is_empty():
		return _failure("encounter resolver is not configured")
	if String(node.get("id", "")).is_empty() or String(node.get("node_type", "")).is_empty():
		return _failure("encounter node requires id and node_type")
	var node_id: String = node.id
	var node_type: String = node.node_type
	var resolution := {
		"resolution_id": "resolution:%s:%d:%s" % [_definition.expedition_id, expedition_seed, node_id],
		"node_id": node_id,
		"node_type": node_type,
		"route": String(node.get("route", "shared")),
		"enemy_id": "",
		"battle_seed": _derive_seed(expedition_seed, node_id),
		"immediate_effects": {},
		"victory_loot": _definition.victory_rewards.get(node_type, {}).duplicate(true),
	}
	if COMBAT_NODE_TYPES.has(node_type):
		resolution.enemy_id = _resolve_enemy(node, expedition_seed)
		if resolution.enemy_id.is_empty():
			return _failure("encounter resolver has no enemy for '%s'" % node_id)
	else:
		resolution.immediate_effects = _resolve_noncombat_effects(node)
	return {"ok": true, "errors": PackedStringArray(), "resolution": resolution}


func _resolve_enemy(node: Dictionary, expedition_seed: int) -> String:
	match String(node.node_type):
		"boss":
			return String(node.get("enemy_id", ""))
		"military_objective":
			return String(_definition.objective_enemies.get(node.id, ""))
		"elite_combat":
			return _choose(_definition.elite_enemy_pool, expedition_seed, String(node.id))
		"wealth_risk":
			return _choose(_definition.wealth_enemy_pool, expedition_seed, String(node.id))
		"normal_combat":
			return _choose(_definition.normal_enemy_pools.get(node.get("route", ""), []), expedition_seed, String(node.id))
	return ""


func _resolve_noncombat_effects(node: Dictionary) -> Dictionary:
	var route_key := "%s:%s" % [node.get("route", ""), node.node_type]
	if _definition.noncombat_effects.has(route_key):
		return _definition.noncombat_effects[route_key].duplicate(true)
	if _definition.noncombat_effects.has(node.node_type):
		return _definition.noncombat_effects[node.node_type].duplicate(true)
	return {}


func _choose(pool: Array, seed: int, node_id: String) -> String:
	if pool.is_empty():
		return ""
	var rng = DeterministicRngScript.new(_derive_seed(seed ^ 0x454E43, node_id))
	return String(rng.choose(pool))


func _derive_seed(seed: int, value: String) -> int:
	var hash_value := 2166136261
	for byte in value.to_utf8_buffer():
		hash_value = int((hash_value ^ int(byte)) * 16777619) & 0x7fffffff
	return (seed ^ hash_value ^ int(_definition.battle_seed_salt)) & 0x7fffffff


func _failure(message: String) -> Dictionary:
	return {"ok": false, "errors": PackedStringArray([message]), "resolution": {}}
