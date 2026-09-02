extends RefCounted
class_name ExpeditionEncounterResolver

const DeterministicRngScript := preload("res://src/domain/random/deterministic_rng.gd")
const COMBAT_NODE_TYPES := {"normal_combat": true, "elite_combat": true, "military_objective": true, "wealth_risk": true, "boss": true}

var _definition: Dictionary = {}
var _legacy := false


func setup(definition: Dictionary) -> PackedStringArray:
	_definition = {}
	_legacy = definition.has("expedition_id") and not definition.has("events")
	var errors := PackedStringArray()
	var fields := ["id", "balance_status", "expedition_id", "battle_seed_salt", "normal_enemy_pools", "objective_enemies", "elite_enemy_pool", "wealth_enemy_pool", "victory_rewards", "noncombat_effects"] if _legacy else ["id", "balance_status", "battle_seed_salt", "normal_victory_reward", "elite_victory_reward", "supply_effect", "merchant", "reward_card_ids", "items", "events"]
	for field in fields:
		if not definition.has(field):
			errors.append("encounter config missing field '%s'" % field)
	if not _legacy:
		if definition.get("reward_card_ids", []).size() != 6: errors.append("Rogue encounter config requires exactly six reward cards")
		if definition.get("items", {}).size() != 4: errors.append("Rogue encounter config requires exactly four run items")
		if definition.get("events", {}).size() != 36: errors.append("Rogue encounter config requires exactly thirty-six events")
		var region_counts := {"common": 0, "heyuan": 0, "shimen": 0, "linze": 0}
		for event_id in definition.get("events", {}):
			var parts := String(event_id).split(".")
			if parts.size() >= 3 and region_counts.has(parts[1]):
				region_counts[parts[1]] += 1
			var event = definition.events[event_id]
			if not event is Dictionary or not event.get("choices", null) is Array:
				errors.append("Rogue event '%s' must contain choices" % event_id)
				continue
			var choices: Array = event.choices
			if choices.size() < 2 or choices.size() > 3:
				errors.append("Rogue event '%s' must contain two or three choices" % event_id)
			var choice_ids := {}
			var has_safe := false
			for choice in choices:
				var choice_id := String(choice.get("choice_id", ""))
				if choice_id.is_empty() or choice_ids.has(choice_id):
					errors.append("Rogue event '%s' requires unique non-empty choice ids" % event_id)
				choice_ids[choice_id] = true
				if not choice.has("risk_outcomes"):
					has_safe = true
			if not has_safe:
				errors.append("Rogue event '%s' requires a deterministic safe choice" % event_id)
		if region_counts != {"common": 12, "heyuan": 8, "shimen": 8, "linze": 8}:
			errors.append("Rogue events require 12 common and 8 per destination")
	if definition.get("balance_status", "") != "prototype_temporary": errors.append("encounter config must remain prototype_temporary")
	if errors.is_empty(): _definition = definition.duplicate(true)
	return errors


func resolve(node: Dictionary, expedition_seed: int, expedition_definition: Dictionary = {}) -> Dictionary:
	if _definition.is_empty(): return _failure("encounter resolver is not configured")
	if String(node.get("id", "")).is_empty() or String(node.get("node_type", "")).is_empty(): return _failure("encounter node requires id and node_type")
	if _legacy: return _resolve_legacy(node, expedition_seed)
	var node_id := String(node.id)
	var node_type := String(node.node_type)
	var resolution := {"resolution_id": "resolution:%s:%d:%s" % [expedition_definition.get("id", "generated"), expedition_seed, node_id], "node_id": node_id, "node_type": node_type, "route": "generated", "enemy_id": "", "battle_seed": _derive_seed(expedition_seed, node_id), "immediate_effects": {}, "victory_loot": {}, "requires_choice": false, "encounter": {}, "post_battle_encounter": {}}
	if COMBAT_NODE_TYPES.has(node_type):
		resolution.enemy_id = String(node.get("enemy_id", ""))
		if resolution.enemy_id.is_empty(): return _failure("Rogue combat node has no enemy for '%s'" % node_id)
		if node_type == "boss": resolution.victory_loot = expedition_definition.get("generator_profile", {}).get("boss_reward", {}).duplicate(true)
		elif node_type == "elite_combat": resolution.victory_loot = _definition.elite_victory_reward.duplicate(true)
		else: resolution.victory_loot = _definition.normal_victory_reward.duplicate(true)
		var reward_kind := String(node.get("post_battle_reward", ""))
		if not reward_kind.is_empty(): resolution.post_battle_encounter = _reward_encounter(reward_kind, expedition_seed, node_id, false)
	elif node_type == "supply": resolution.immediate_effects = _definition.supply_effect.duplicate(true)
	elif node_type == "event":
		var event_id := String(node.get("encounter_id", ""))
		if not _definition.events.has(event_id): return _failure("Rogue event '%s' is missing" % event_id)
		resolution.requires_choice = true
		resolution.encounter = _event_encounter(event_id, expedition_seed, node_id)
	elif node_type == "merchant":
		resolution.requires_choice = true
		resolution.encounter = _merchant_encounter(node, expedition_seed)
	elif node_type == "item":
		resolution.requires_choice = true
		resolution.encounter = _item_encounter(expedition_seed, node_id)
	elif node_type == "card_reward":
		resolution.requires_choice = true
		resolution.encounter = _reward_encounter("temporary", expedition_seed, node_id, true)
	return {"ok": true, "errors": PackedStringArray(), "resolution": resolution}


func item_definition(item_id: String) -> Dictionary:
	return _definition.get("items", {}).get(item_id, {}).duplicate(true)


func item_definitions() -> Dictionary:
	return _definition.get("items", {}).duplicate(true)


func reward_card_ids() -> Array:
	return _definition.get("reward_card_ids", []).duplicate()


func event_definition(event_id: String) -> Dictionary:
	return _definition.get("events", {}).get(event_id, {}).duplicate(true)


func _event_encounter(event_id: String, expedition_seed: int, node_id: String) -> Dictionary:
	var source: Dictionary = _definition.events[event_id]
	var choices: Array = []
	for raw_choice in source.choices:
		var choice: Dictionary = raw_choice.duplicate(true)
		if choice.has("risk_outcomes"):
			var outcomes: Array = choice.risk_outcomes
			var rng = DeterministicRngScript.new(_derive_seed(expedition_seed, "%s:%s" % [node_id, choice.choice_id]))
			choice.resolved_effects = outcomes[rng.next_int(0, outcomes.size() - 1)].get("effects", {}).duplicate(true)
			choice.risk = true
			choice.erase("risk_outcomes")
		else: choice.risk = false
		choices.append(choice)
	return {"kind": "event", "encounter_id": event_id, "title": source.name, "description": source.description, "choices": choices, "complete_node_on_choice": true}


func _merchant_encounter(node: Dictionary, expedition_seed: int) -> Dictionary:
	var item_ids: Array = _definition.items.keys(); item_ids.sort()
	var item_rng = DeterministicRngScript.new(_derive_seed(expedition_seed, "%s:item" % node.id))
	var card_rng = DeterministicRngScript.new(_derive_seed(expedition_seed, "%s:card" % node.id))
	var item_id := String(item_ids[item_rng.next_int(0, item_ids.size() - 1)])
	var card_id := String(_definition.reward_card_ids[card_rng.next_int(0, _definition.reward_card_ids.size() - 1)])
	var merchant: Dictionary = _definition.merchant
	return {"kind": "merchant", "encounter_id": "merchant:%s" % node.id, "title": "过路商队", "description": "只能选择一项交易，或承担袭商后果。", "complete_node_on_choice": true, "choices": [
		{"choice_id": "trade_item", "label": "交易 · %s" % _definition.items[item_id].name, "description": "支付25银，获得临时物品。", "requirements": {"loot": merchant.item_price.duplicate(true), "inventory_space": 1}, "effects": {"consume_loot": merchant.item_price.duplicate(true), "add_item": item_id}},
		{"choice_id": "trade_card", "label": "交易 · 临时军略", "description": "支付35银，将一张卡加入本次远征。", "requirements": {"loot": merchant.card_price.duplicate(true)}, "effects": {"consume_loot": merchant.card_price.duplicate(true), "add_temporary_card": card_id}},
		{"choice_id": "trade_service", "label": "交易 · 补给服务", "description": "支付25粮，恢复兵力与士气。", "requirements": {"loot": merchant.service_price.duplicate(true)}, "effects": _merged_effects({"consume_loot": merchant.service_price.duplicate(true)}, merchant.service_effect)},
		{"choice_id": "attack", "label": "袭击商队", "description": "进入护卫战并增加8点叛乱值。", "effects": {"rebellion_delta": int(merchant.attack_rebellion)}, "combat_enemy_id": String(node.get("merchant_guard_id", "")), "combat_victory_loot": merchant.attack_reward.duplicate(true), "combat_victory_item": item_id},
		{"choice_id": "leave", "label": "离开", "description": "不交易，也不与商队冲突。", "effects": {}}
	]}


func _item_encounter(expedition_seed: int, node_id: String) -> Dictionary:
	var item_ids: Array = _definition.items.keys(); item_ids.sort()
	var rng = DeterministicRngScript.new(_derive_seed(expedition_seed, "%s:item-node" % node_id))
	var item_id := String(item_ids[rng.next_int(0, item_ids.size() - 1)])
	return {"kind": "item", "encounter_id": "item:%s" % node_id, "title": "遗落军资", "description": "路旁发现%s。" % _definition.items[item_id].name, "complete_node_on_choice": true, "choices": [{"choice_id": "take", "label": "带走", "description": _definition.items[item_id].description, "requirements": {"inventory_space": 1}, "effects": {"add_item": item_id}}, {"choice_id": "leave", "label": "留下", "description": "不占用物品栏。", "effects": {}}]}


func _reward_encounter(kind: String, expedition_seed: int, node_id: String, complete_node: bool) -> Dictionary:
	var rng = DeterministicRngScript.new(_derive_seed(expedition_seed, "%s:reward:%s" % [node_id, kind]))
	var cards: Array = rng.shuffled_copy(_definition.reward_card_ids)
	var choices: Array = []
	for index in 3:
		var permanent := kind == "elite" and index == 0
		choices.append({"choice_id": "card_%d" % index, "label": "永久军略" if permanent else "临时军略", "description": "选择后立即加入本次远征牌组。", "card_id": cards[index], "permanent": permanent, "effects": {"add_temporary_card": cards[index], "pending_card_unlock": cards[index] if permanent else ""}})
	choices.append({"choice_id": "skip", "label": "跳过", "description": "保持当前牌组。", "effects": {}})
	return {"kind": "reward", "encounter_id": "reward:%s:%s" % [node_id, kind], "title": "军略所得", "description": "三选一，或放弃奖励。", "choices": choices, "complete_node_on_choice": complete_node}


func _resolve_legacy(node: Dictionary, expedition_seed: int) -> Dictionary:
	var node_id: String = node.id; var node_type: String = node.node_type
	var resolution := {"resolution_id": "resolution:%s:%d:%s" % [_definition.expedition_id, expedition_seed, node_id], "node_id": node_id, "node_type": node_type, "route": String(node.get("route", "shared")), "enemy_id": "", "battle_seed": _derive_seed(expedition_seed, node_id), "immediate_effects": {}, "victory_loot": _definition.victory_rewards.get(node_type, {}).duplicate(true), "requires_choice": false, "encounter": {}, "post_battle_encounter": {}}
	if COMBAT_NODE_TYPES.has(node_type):
		match node_type:
			"boss": resolution.enemy_id = String(node.get("enemy_id", ""))
			"military_objective": resolution.enemy_id = String(_definition.objective_enemies.get(node.id, ""))
			"elite_combat": resolution.enemy_id = _choose(_definition.elite_enemy_pool, expedition_seed, node_id)
			"wealth_risk": resolution.enemy_id = _choose(_definition.wealth_enemy_pool, expedition_seed, node_id)
			"normal_combat": resolution.enemy_id = _choose(_definition.normal_enemy_pools.get(node.get("route", ""), []), expedition_seed, node_id)
		if resolution.enemy_id.is_empty(): return _failure("encounter resolver has no enemy for '%s'" % node_id)
	else:
		var route_key := "%s:%s" % [node.get("route", ""), node_type]
		resolution.immediate_effects = _definition.noncombat_effects.get(route_key, _definition.noncombat_effects.get(node_type, {})).duplicate(true)
	return {"ok": true, "errors": PackedStringArray(), "resolution": resolution}


func _choose(pool: Array, seed: int, node_id: String) -> String:
	if pool.is_empty(): return ""
	return String(DeterministicRngScript.new(_derive_seed(seed ^ 0x454E43, node_id)).choose(pool))


func _derive_seed(seed: int, value: String) -> int:
	var hash_value := 2166136261
	for byte in value.to_utf8_buffer(): hash_value = int((hash_value ^ int(byte)) * 16777619) & 0x7fffffff
	return (seed ^ hash_value ^ int(_definition.get("battle_seed_salt", 0))) & 0x7fffffff


func _merged_effects(first: Dictionary, second: Dictionary) -> Dictionary:
	var result := first.duplicate(true)
	for key in second: result[key] = second[key].duplicate(true) if second[key] is Dictionary or second[key] is Array else second[key]
	return result


func _failure(message: String) -> Dictionary:
	return {"ok": false, "errors": PackedStringArray([message]), "resolution": {}}
