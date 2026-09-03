extends RefCounted
class_name ExpeditionRunState

const RouteStateScript := preload("res://src/domain/expedition/expedition_route_state.gd")
const GeneralManagementServiceScript := preload("res://src/domain/campaign/general_management_service.gd")

const COMBAT_NODE_TYPES := {
	"normal_combat": true,
	"elite_combat": true,
	"military_objective": true,
	"wealth_risk": true,
	"boss": true,
}
const TEMPORARY_BUFF_TYPES := {
	"ModifyNextBattleMorale": true,
	"ModifyNextBattleAttack": true,
}

var _route
var _map: Dictionary = {}
var _state: Dictionary = {}
var _pending_combat_request: Dictionary = {}
var _pending_node_resolution: Dictionary = {}
var _progression: Dictionary = {}


func setup(
	run_id: String,
	generated_map: Dictionary,
	general_snapshot: Dictionary,
	deck: Array,
	card_overrides: Dictionary = {},
	initial_popular_support: int = 20,
	progression: Dictionary = {}
) -> PackedStringArray:
	var errors := PackedStringArray()
	if run_id.strip_edges().is_empty():
		errors.append("expedition run id must be non-empty")
	for field in ["id", "name", "talent_id", "troops", "max_troops", "morale", "max_morale", "attack", "defense", "army_composition"]:
		if not general_snapshot.has(field):
			errors.append("expedition general snapshot missing field '%s'" % field)
	if int(general_snapshot.get("troops", 0)) <= 0 or int(general_snapshot.get("max_troops", 0)) <= 0:
		errors.append("expedition must start with positive troops")
	if int(general_snapshot.get("morale", 0)) <= 0 or int(general_snapshot.get("max_morale", 0)) <= 0:
		errors.append("expedition must start with positive morale")
	if deck.is_empty():
		errors.append("expedition deck must not be empty")
	if initial_popular_support < 0 or initial_popular_support > 100:
		errors.append("expedition initial popular support must be between 0 and 100")
	if not progression.is_empty():
		errors.append_array(GeneralManagementServiceScript.validate_progression_definition(progression, "expedition.progression"))
	if not errors.is_empty():
		return errors
	_route = RouteStateScript.new()
	var route_errors: PackedStringArray = _route.setup(generated_map)
	if not route_errors.is_empty():
		return route_errors
	_map = generated_map.duplicate(true)
	_progression = progression.duplicate(true)
	var player := general_snapshot.duplicate(true)
	player.troops = mini(int(player.troops), int(player.max_troops))
	player.morale = mini(int(player.morale), int(player.max_morale))
	player.armor = 0
	_state = {
		"run_id": run_id,
		"expedition_id": generated_map.get("expedition_id", ""),
		"seed": generated_map.get("seed", 0),
		"generator_version": int(generated_map.get("generator_version", 1)),
		"map_signature": String(generated_map.get("map_signature", "legacy-v1")),
		"expedition_name": String(generated_map.get("name", "")),
		"destination_name": String(generated_map.get("destination_name", generated_map.get("name", ""))),
		"theme": String(generated_map.get("theme", "")),
		"capture_rebellion": int(generated_map.get("capture_rebellion", 0)),
		"general": player,
		"initial_general_level": int(player.get("level", 1)),
		"initial_general_experience": int(player.get("experience", 0)),
		"initial_troops": int(player.troops),
		"army_composition": player.army_composition.duplicate(true),
		"deck": deck.duplicate(),
		"card_overrides": card_overrides.duplicate(true),
		"army_counts": player.get("army_counts", {}).duplicate(true),
		"unbanked_loot": {},
		"lost_unbanked_loot": {},
		"temporary_buffs": [],
		"temporary_cards": [],
		"pending_card_unlocks": [],
		"permanent_reward_claimed": false,
		"temporary_items": [],
		"pending_encounter": {},
		"choice_action_ids": [],
		"choice_history": [],
		"applied_item_action_ids": [],
		"item_history": [],
		"pending_rebellion_delta": 0,
		"initial_popular_support": initial_popular_support,
		"pending_popular_support_delta": 0,
		"boss_modifiers": {},
		"status": "active",
		"completed_battles": 0,
		"general_died": false,
		"general_injured": false,
		"resolution_ids": [],
		"resolution_history": [],
		"settled_battle_ids": [],
		"pending_battle_experience": 0,
		"battle_experience_ledger": [],
		"pending_combat_report": {},
		"acknowledged_combat_report_action_ids": [],
		"combat_report_history": [],
		"experience_migration": {"source": "new_run", "reconstructed": true},
		"intel": {},
	}
	_pending_combat_request = {}
	_pending_node_resolution = {}
	return PackedStringArray()


func restore(saved: Dictionary, generated_map: Dictionary, progression: Dictionary = {}, campaign_general: Dictionary = {}) -> PackedStringArray:
	var errors := PackedStringArray()
	for field in ["run_id", "expedition_id", "seed", "general", "initial_troops", "army_composition", "deck", "status", "route", "pending_combat"]:
		if not saved.has(field):
			errors.append("expedition restore missing field '%s'" % field)
	if not errors.is_empty():
		return errors
	if saved.expedition_id != generated_map.expedition_id or int(saved.seed) != int(generated_map.seed):
		errors.append("expedition restore identity or seed mismatch")
	var saved_generator_version := int(saved.get("generator_version", 1))
	if saved_generator_version != int(generated_map.get("generator_version", 1)):
		errors.append("expedition restore generator version mismatch")
	if saved_generator_version >= 2 and String(saved.get("map_signature", "")) != String(generated_map.get("map_signature", "")):
		errors.append("expedition restore map signature mismatch")
	if not saved.status in ["active", "awaiting_settlement", "retreated", "failed"]:
		errors.append("expedition restore status is invalid")
	_route = RouteStateScript.new()
	errors.append_array(_route.restore(generated_map, saved.route))
	if not errors.is_empty():
		return errors
	if saved.status == "awaiting_settlement" and _route.status() != "completed":
		errors.append("expedition restore awaiting settlement requires a completed route")
	if saved.status == "active" and _route.status() != "active":
		errors.append("expedition restore active run requires an active route")
	var pending = saved.pending_combat
	if not pending is Dictionary:
		errors.append("expedition restore pending_combat must be an object")
	elif not pending.is_empty():
		if saved.status != "active":
			errors.append("expedition restore terminal run cannot retain pending combat")
		elif String(pending.get("battle_id", "")) != "%s:%s" % [saved.run_id, saved.route.current_node_id]:
			errors.append("expedition restore pending combat does not match the current node")
	_validate_resolution_ledger(saved, generated_map, pending, errors)
	if not errors.is_empty():
		return errors
	_map = generated_map.duplicate(true)
	_progression = progression.duplicate(true)
	_state = saved.duplicate(true)
	_state.erase("route")
	_state.erase("visible_nodes")
	_state.erase("pending_combat")
	_pending_combat_request = pending.duplicate(true)
	_pending_node_resolution = _state.get("pending_node_resolution", {}).duplicate(true)
	_state.erase("pending_node_resolution")
	for field in ["card_overrides", "army_counts", "resolution_ids", "resolution_history", "settled_battle_ids", "intel", "pending_encounter"]:
		if not _state.has(field):
			_state[field] = {} if field in ["card_overrides", "army_counts", "intel", "pending_encounter"] else []
	for field in ["temporary_cards", "pending_card_unlocks", "temporary_items", "choice_action_ids", "choice_history", "applied_item_action_ids", "item_history"]:
		if not _state.has(field): _state[field] = []
	for field in ["battle_experience_ledger", "acknowledged_combat_report_action_ids", "combat_report_history"]:
		if not _state.has(field): _state[field] = []
	if not _state.has("pending_combat_report") or not _state.pending_combat_report is Dictionary:
		_state.pending_combat_report = {}
	if not _state.has("pending_battle_experience"):
		_state.pending_battle_experience = 0
	if not _state.has("initial_general_level"):
		_state.initial_general_level = int(campaign_general.get("level", 1))
	if not _state.has("initial_general_experience"):
		_state.initial_general_experience = int(campaign_general.get("experience", 0))
	if not _state.has("experience_migration"):
		_state.experience_migration = {"source": "legacy_restore", "reconstructed": false}
	if not bool(_state.experience_migration.get("reconstructed", false)):
		_reconstruct_legacy_battle_experience(campaign_general)
	for field in ["permanent_reward_claimed"]:
		if not _state.has(field): _state[field] = false
	for field in ["pending_rebellion_delta", "capture_rebellion"]:
		if not _state.has(field): _state[field] = 0
	if not _state.has("initial_popular_support"):
		_state.initial_popular_support = 20
	if not _state.has("pending_popular_support_delta"):
		_state.pending_popular_support_delta = 0
	if not _state.has("generator_version"): _state.generator_version = 1
	if not _state.has("map_signature"): _state.map_signature = "legacy-v1"
	return errors


func _validate_resolution_ledger(saved: Dictionary, generated_map: Dictionary, pending: Variant, errors: PackedStringArray) -> void:
	var node_by_id = generated_map.get("node_by_id", {})
	var resolution_ids = saved.get("resolution_ids", [])
	var history = saved.get("resolution_history", [])
	var settled_battle_ids = saved.get("settled_battle_ids", [])
	var pending_resolution = saved.get("pending_node_resolution", {})
	var pending_encounter = saved.get("pending_encounter", {})
	var pending_report = saved.get("pending_combat_report", {})
	if not resolution_ids is Array or not history is Array or not settled_battle_ids is Array:
		errors.append("expedition restore resolution ledgers must be arrays")
		return
	if not pending_resolution is Dictionary:
		errors.append("expedition restore pending_node_resolution must be an object")
		return
	if not pending_encounter is Dictionary:
		errors.append("expedition restore pending_encounter must be an object")
		return
	if not pending_report is Dictionary:
		errors.append("expedition restore pending_combat_report must be an object")
		return
	if not pending_encounter.is_empty() and (not pending is Dictionary or not pending.is_empty()):
		errors.append("expedition restore choice checkpoint cannot also retain combat")
	if not pending_report.is_empty() and (not pending is Dictionary or not pending.is_empty()):
		errors.append("expedition restore combat report cannot also retain pending combat")
	if not pending_encounter.is_empty():
		var completes_node := bool(pending_encounter.get("complete_node_on_choice", false))
		if completes_node and pending_resolution.is_empty():
			errors.append("expedition restore node choice requires its pending resolution")
		if not completes_node and not pending_resolution.is_empty():
			errors.append("expedition restore post-battle reward cannot retain a pending resolution")
		var encounter_id := String(pending_encounter.get("encounter_id", ""))
		var choices = pending_encounter.get("choices", null)
		if encounter_id.is_empty() or not choices is Array or choices.size() < 2:
			errors.append("expedition restore pending encounter content is invalid")
		else:
			var choice_ids := {}
			for choice in choices:
				var choice_id := String(choice.get("choice_id", "")) if choice is Dictionary else ""
				if choice_id.is_empty() or choice_ids.has(choice_id):
					errors.append("expedition restore pending encounter has invalid choice ids")
					break
				choice_ids[choice_id] = true
	var unique_resolution_ids := {}
	for resolution_id in resolution_ids:
		var normalized_id := String(resolution_id)
		if normalized_id.is_empty() or unique_resolution_ids.has(normalized_id):
			errors.append("expedition restore resolution_ids contains an empty or duplicate id")
		else:
			unique_resolution_ids[normalized_id] = true
	var history_ids := {}
	for entry in history:
		if not entry is Dictionary:
			errors.append("expedition restore resolution_history entries must be objects")
			continue
		var resolution_id := String(entry.get("resolution_id", ""))
		var node_id := String(entry.get("node_id", ""))
		if not unique_resolution_ids.has(resolution_id) or history_ids.has(resolution_id):
			errors.append("expedition restore resolution_history does not match resolution_ids")
		if not node_by_id.has(node_id):
			errors.append("expedition restore resolution_history references an unknown node")
		history_ids[resolution_id] = true
	if history_ids.size() != unique_resolution_ids.size():
		errors.append("expedition restore resolution history and id ledger sizes differ")
	var unique_battle_ids := {}
	for battle_id in settled_battle_ids:
		var normalized_id := String(battle_id)
		if normalized_id.is_empty() or unique_battle_ids.has(normalized_id):
			errors.append("expedition restore settled_battle_ids contains an empty or duplicate id")
		else:
			unique_battle_ids[normalized_id] = true
	var experience_ledger = saved.get("battle_experience_ledger", [])
	if not experience_ledger is Array:
		errors.append("expedition restore battle_experience_ledger must be an array")
	else:
		var experience_battle_ids := {}
		var experience_total := 0
		for entry in experience_ledger:
			if not entry is Dictionary:
				errors.append("expedition restore battle experience entries must be objects")
				continue
			var experience_battle_id := String(entry.get("battle_id", ""))
			var amount = entry.get("amount", null)
			if experience_battle_id.is_empty() or experience_battle_ids.has(experience_battle_id) or not unique_battle_ids.has(experience_battle_id):
				errors.append("expedition restore battle experience references an invalid battle")
			elif not _is_non_negative_whole_number(amount):
				errors.append("expedition restore battle experience amount must be non-negative")
			else:
				experience_battle_ids[experience_battle_id] = true
				experience_total += int(amount)
		if experience_total != int(saved.get("pending_battle_experience", 0)):
			errors.append("expedition restore pending battle experience does not match its ledger")
	var acknowledged_action_ids = saved.get("acknowledged_combat_report_action_ids", [])
	var report_history = saved.get("combat_report_history", [])
	if not acknowledged_action_ids is Array or not report_history is Array:
		errors.append("expedition restore combat report ledgers must be arrays")
	else:
		var unique_action_ids := {}
		for action_id in acknowledged_action_ids:
			var normalized_action_id := String(action_id)
			if normalized_action_id.is_empty() or unique_action_ids.has(normalized_action_id):
				errors.append("expedition restore combat report action ids must be non-empty and unique")
			else:
				unique_action_ids[normalized_action_id] = true
		var history_action_ids := {}
		var history_report_ids := {}
		for entry in report_history:
			if not entry is Dictionary:
				errors.append("expedition restore combat report history entries must be objects")
				continue
			var action_id := String(entry.get("action_id", ""))
			var report_id := String(entry.get("report_id", ""))
			var battle_id := String(entry.get("battle_id", ""))
			if not unique_action_ids.has(action_id) or history_action_ids.has(action_id):
				errors.append("expedition restore combat report history does not match action ids")
			if report_id.is_empty() or history_report_ids.has(report_id) or not unique_battle_ids.has(battle_id):
				errors.append("expedition restore combat report history identity is invalid")
			history_action_ids[action_id] = true
			history_report_ids[report_id] = true
		if history_action_ids.size() != unique_action_ids.size():
			errors.append("expedition restore combat report history and action ledger sizes differ")
	if not pending_report.is_empty():
		for field in ["report_id", "battle_id", "node_id", "node_type", "enemy_id", "experience_gained", "pending_experience_total", "troops_before", "troops_after", "troops_delta", "morale_before", "morale_after", "morale_delta", "loot_gained", "unbanked_loot_total", "completed_battles", "route_progress", "post_battle_reward_pending", "expedition_terminal"]:
			if not pending_report.has(field):
				errors.append("expedition restore pending combat report missing field '%s'" % field)
		var report_id := String(pending_report.get("report_id", ""))
		var report_battle_id := String(pending_report.get("battle_id", ""))
		var report_node_id := String(pending_report.get("node_id", ""))
		if report_id.is_empty() or not unique_battle_ids.has(report_battle_id):
			errors.append("expedition restore pending combat report identity is invalid")
		if not node_by_id.has(report_node_id):
			errors.append("expedition restore pending combat report references an unknown node")
		if not pending_report.get("loot_gained", null) is Dictionary or not pending_report.get("unbanked_loot_total", null) is Dictionary or not pending_report.get("route_progress", null) is Dictionary:
			errors.append("expedition restore pending combat report aggregates must be objects")
		for field in ["experience_gained", "pending_experience_total", "troops_before", "troops_after", "morale_before", "morale_after", "completed_battles"]:
			if not _is_non_negative_whole_number(pending_report.get(field)):
				errors.append("expedition restore pending combat report field '%s' must be non-negative" % field)
		for field in ["post_battle_reward_pending", "expedition_terminal"]:
			if not pending_report.get(field) is bool:
				errors.append("expedition restore pending combat report field '%s' must be boolean" % field)
	if pending_resolution.is_empty():
		return
	var pending_node_id := String(pending_resolution.get("node_id", ""))
	if pending_node_id != String(saved.route.current_node_id):
		errors.append("expedition restore pending node resolution does not match the current node")
	var pending_resolution_id := String(pending_resolution.get("resolution_id", ""))
	if pending_resolution_id.is_empty():
		errors.append("expedition restore pending node resolution id must be non-empty")
	elif unique_resolution_ids.has(pending_resolution_id):
		errors.append("expedition restore pending node resolution is already settled")
	if not pending_encounter.is_empty():
		if not bool(pending_resolution.get("requires_choice", false)):
			errors.append("expedition restore choice checkpoint requires a choice resolution")
		return
	if not pending is Dictionary or pending.is_empty():
		errors.append("expedition restore pending node resolution requires pending combat")
		return
	if unique_battle_ids.has(String(pending.get("battle_id", ""))):
		errors.append("expedition restore pending combat is already settled")
	if int(pending_resolution.get("battle_seed", -1)) != int(pending.get("seed", -2)):
		errors.append("expedition restore pending node resolution seed does not match combat request")


func advance_to(node_id: String) -> Dictionary:
	if not _can_change_route():
		return _failure("当前远征状态不能推进路线")
	return _route.advance_to(node_id)


func complete_noncombat_node() -> Dictionary:
	if not _can_change_route():
		return _failure("当前远征状态不能结算节点")
	var node: Dictionary = _route.current_node()
	if COMBAT_NODE_TYPES.has(node.get("node_type", "")):
		return _failure("战斗节点必须通过 CombatResult 结算")
	return _route.complete_current_node()


func settle_noncombat_resolution(resolution: Dictionary) -> Dictionary:
	if not _can_change_route():
		return _failure("当前远征状态不能结算节点")
	var validation: String = _validate_resolution(resolution, false)
	if not validation.is_empty():
		return _failure(validation)
	if _state.resolution_ids.has(resolution.resolution_id):
		return {"ok": true, "duplicate": true, "node_id": resolution.node_id, "reason": ""}
	var next_state: Dictionary = _state.duplicate(true)
	_apply_effects(next_state, resolution.get("immediate_effects", {}), resolution.resolution_id)
	var route_result: Dictionary = _route.complete_current_node()
	if not route_result.ok:
		return route_result
	_record_resolution(next_state, resolution, "noncombat")
	_state = next_state
	return {"ok": true, "duplicate": false, "node_id": resolution.node_id, "reason": ""}


func begin_choice_resolution(resolution: Dictionary) -> Dictionary:
	if not _can_change_route():
		return _failure("当前远征状态不能创建选择检查点")
	var validation := _validate_resolution(resolution, false)
	if not validation.is_empty():
		return _failure(validation)
	if not bool(resolution.get("requires_choice", false)) or not resolution.get("encounter", null) is Dictionary or resolution.encounter.is_empty():
		return _failure("节点解析没有可选择内容")
	_pending_node_resolution = resolution.duplicate(true)
	_state.pending_encounter = resolution.encounter.duplicate(true)
	return {"ok": true, "duplicate": false, "encounter": _state.pending_encounter.duplicate(true), "reason": ""}


func pending_encounter() -> Dictionary:
	return _state.get("pending_encounter", {}).duplicate(true)


func choice_availability(choice_id: String) -> Dictionary:
	var encounter: Dictionary = _state.get("pending_encounter", {})
	if encounter.is_empty():
		return {"ok": false, "available": false, "reason": "当前没有待处理选择"}
	var choice := _find_choice(encounter.get("choices", []), choice_id)
	if choice.is_empty():
		return {"ok": false, "available": false, "reason": "找不到该选择"}
	var reason := _requirements_error(choice.get("requirements", {}))
	return {"ok": true, "available": reason.is_empty(), "reason": reason}


func submit_encounter_choice(action_id: String, choice_id: String, enemy: Dictionary = {}) -> Dictionary:
	if action_id.strip_edges().is_empty() or choice_id.strip_edges().is_empty():
		return _failure("选择需要稳定 action_id 和 choice_id")
	if _state.get("choice_action_ids", []).has(action_id):
		return {"ok": true, "duplicate": true, "reason": ""}
	var encounter: Dictionary = _state.get("pending_encounter", {})
	if encounter.is_empty() or _state.get("status", "") != "active" or not _pending_combat_request.is_empty():
		return _failure("当前没有可提交的远征选择")
	var choice := _find_choice(encounter.get("choices", []), choice_id)
	if choice.is_empty():
		return _failure("找不到选择 '%s'" % choice_id)
	var requirement_error := _requirements_error(choice.get("requirements", {}))
	if not requirement_error.is_empty():
		return _failure(requirement_error)
	if bool(choice.get("permanent", false)) and bool(_state.get("permanent_reward_claimed", false)):
		return _failure("本次远征已经选择过永久军略")
	var next_state := _state.duplicate(true)
	var applied_effects: Dictionary = choice.get("resolved_effects", choice.get("effects", {}))
	_apply_effects(next_state, applied_effects, "%s:%s" % [encounter.encounter_id, choice_id])
	next_state.choice_action_ids.append(action_id)
	next_state.choice_history.append({"action_id": action_id, "encounter_id": encounter.encounter_id, "choice_id": choice_id, "risk": bool(choice.get("risk", false))})
	if bool(choice.get("permanent", false)):
		next_state.permanent_reward_claimed = true
	_state = next_state
	_apply_route_effects(applied_effects)
	_state.pending_encounter = {}
	if int(_state.general.troops) <= 0 or int(_state.general.morale) <= 0:
		if not _pending_node_resolution.is_empty() and not _state.resolution_ids.has(_pending_node_resolution.get("resolution_id", "")):
			_record_resolution(_state, _pending_node_resolution, "event-failure:%s" % choice_id)
		_state.general_died = false
		_state.general_injured = true
		_state.lost_unbanked_loot = _state.unbanked_loot.duplicate(true)
		_state.unbanked_loot = {}
		_state.temporary_buffs.clear()
		_state.temporary_items.clear()
		_state.temporary_cards.clear()
		_state.status = "failed"
		_pending_node_resolution = {}
		return {"ok": true, "duplicate": false, "started_combat": false, "terminal": true, "choice_id": choice_id, "reason": "event state reached zero"}
	if not String(choice.get("combat_enemy_id", "")).is_empty():
		if enemy.is_empty() or enemy.get("id", "") != choice.combat_enemy_id:
			return _failure("袭击选择缺少匹配的商队护卫")
		var combat_resolution: Dictionary = _pending_node_resolution.duplicate(true)
		combat_resolution.enemy_id = choice.combat_enemy_id
		combat_resolution.victory_loot = choice.get("combat_victory_loot", {}).duplicate(true)
		combat_resolution.victory_item = String(choice.get("combat_victory_item", ""))
		combat_resolution.choice_combat = true
		combat_resolution.chosen_action_id = action_id
		combat_resolution.battle_seed = int(combat_resolution.get("battle_seed", 0)) ^ _stable_hash(choice_id)
		_pending_node_resolution = combat_resolution
		var combat: Dictionary = begin_combat(enemy, int(combat_resolution.battle_seed))
		if not combat.ok:
			return combat
		return {"ok": true, "duplicate": false, "started_combat": true, "request": combat.request, "reason": ""}
	if bool(encounter.get("complete_node_on_choice", false)):
		var completed: Dictionary = _route.complete_current_node()
		if not completed.ok:
			return completed
		if not _pending_node_resolution.is_empty() and not _state.resolution_ids.has(_pending_node_resolution.get("resolution_id", "")):
			_record_resolution(_state, _pending_node_resolution, "choice:%s" % choice_id)
	_pending_node_resolution = {}
	return {"ok": true, "duplicate": false, "started_combat": false, "choice_id": choice_id, "reason": ""}


func use_temporary_item(action_id: String, item_instance_id: String, item_definition: Dictionary) -> Dictionary:
	if action_id.strip_edges().is_empty() or item_instance_id.strip_edges().is_empty():
		return _failure("使用物品需要稳定 action_id 和物品实例 ID")
	if _state.get("applied_item_action_ids", []).has(action_id):
		return {"ok": true, "duplicate": true, "reason": ""}
	if _state.get("status", "") != "active" or not _pending_combat_request.is_empty() or not _state.get("pending_combat_report", {}).is_empty():
		return _failure("战斗中或远征结束后不能使用临时物品")
	var item_index := -1
	for index in _state.temporary_items.size():
		if _state.temporary_items[index].get("instance_id", "") == item_instance_id:
			item_index = index
			break
	if item_index < 0:
		return _failure("找不到临时物品实例")
	var item_id := String(_state.temporary_items[item_index].item_id)
	if item_definition.get("id", item_id) != item_id or not item_definition.get("effects", null) is Dictionary:
		return _failure("临时物品定义不匹配")
	var next_state := _state.duplicate(true)
	_apply_effects(next_state, item_definition.effects, "item-use:%s" % action_id)
	next_state.temporary_items.remove_at(item_index)
	next_state.applied_item_action_ids.append(action_id)
	next_state.item_history.append({"action_id": action_id, "item_instance_id": item_instance_id, "item_id": item_id})
	_state = next_state
	_apply_route_effects(item_definition.effects)
	return {"ok": true, "duplicate": false, "item_id": item_id, "reason": ""}


func add_unbanked_loot(resource_id: String, amount: int) -> Dictionary:
	if _state.get("status", "") != "active":
		return _failure("当前远征不能获得战利品")
	if resource_id.strip_edges().is_empty():
		return _failure("战利品资源 ID 不能为空")
	if amount <= 0:
		return _failure("战利品数量必须为正数")
	_state.unbanked_loot[resource_id] = int(_state.unbanked_loot.get(resource_id, 0)) + amount
	return {"ok": true, "resource_id": resource_id, "amount": amount, "reason": ""}


func add_temporary_buff(buff: Dictionary) -> Dictionary:
	if _state.get("status", "") != "active":
		return _failure("当前远征不能获得临时状态")
	for field in ["id", "type", "amount"]:
		if not buff.has(field):
			return _failure("临时状态缺少字段：%s" % field)
	if String(buff.get("id", "")).strip_edges().is_empty():
		return _failure("临时状态 ID 不能为空")
	if not TEMPORARY_BUFF_TYPES.has(buff.get("type", "")):
		return _failure("不支持的远征临时状态：%s" % buff.get("type", ""))
	if int(buff.get("amount", 0)) <= 0:
		return _failure("临时状态数值必须为正数")
	var stored := buff.duplicate(true)
	stored.remaining_battles = 1
	_state.temporary_buffs.append(stored)
	return {"ok": true, "buff_id": stored.id, "reason": ""}


func reveal_map_node(node_id: String) -> Dictionary:
	if _state.get("status", "") != "active":
		return _failure("当前远征不能揭示地图")
	return _route.reveal_node(node_id)


func begin_combat(enemy: Dictionary, battle_seed: int) -> Dictionary:
	if _state.get("status", "") != "active":
		return _failure("当前远征不能开始战斗")
	if not _pending_combat_request.is_empty():
		return _failure("当前节点已有待结算战斗")
	var node: Dictionary = _route.current_node()
	if not COMBAT_NODE_TYPES.has(node.get("node_type", "")) and not bool(_pending_node_resolution.get("choice_combat", false)):
		return _failure("当前节点不是战斗节点")
	if enemy.is_empty() or String(enemy.get("id", "")).is_empty():
		return _failure("敌军定义不能为空")
	if node.get("node_type", "") == "boss" and enemy.get("id", "") != node.get("enemy_id", ""):
		return _failure("Boss 节点必须使用配置的敌军")
	var player: Dictionary = _state.general.duplicate(true)
	player.armor = 0
	var consumed_buff_ids: Array[String] = []
	for buff in _state.temporary_buffs:
		match buff.get("type", ""):
			"ModifyNextBattleMorale":
				player.morale = mini(int(player.max_morale), int(player.morale) + int(buff.amount))
			"ModifyNextBattleAttack":
				player.attack = float(player.attack) + float(buff.amount)
		consumed_buff_ids.append(buff.id)
	_state.temporary_buffs.clear()
	var request_boss_modifiers := {}
	if node.get("node_type", "") == "boss":
		request_boss_modifiers = _state.boss_modifiers.duplicate(true)
	_pending_combat_request = {
		"battle_id": "%s:%s" % [_state.run_id, node.id],
		"seed": battle_seed,
		"player": player,
		"enemy": enemy.duplicate(true),
		"deck": _state.deck.duplicate(),
		"card_overrides": _state.get("card_overrides", {}).duplicate(true),
		"boss_modifiers": request_boss_modifiers,
		"expedition_context": {
			"run_id": _state.run_id,
			"node_id": node.id,
			"consumed_buff_ids": consumed_buff_ids,
		},
	}
	return {"ok": true, "request": _pending_combat_request.duplicate(true), "reason": ""}


func begin_combat_resolution(resolution: Dictionary, enemy: Dictionary) -> Dictionary:
	var validation := _validate_resolution(resolution, true)
	if not validation.is_empty():
		return _failure(validation)
	_pending_node_resolution = resolution.duplicate(true)
	var result := begin_combat(enemy, int(resolution.battle_seed))
	if not result.ok:
		_pending_node_resolution = {}
	return result


func pending_combat_request() -> Dictionary:
	return _pending_combat_request.duplicate(true)


func apply_victory_result(result: Dictionary) -> Dictionary:
	if _pending_combat_request.is_empty():
		return _failure("没有待结算战斗")
	var battle_error := _validate_battle_result_id(result)
	if not battle_error.is_empty():
		return _failure(battle_error)
	if result.get("status", "") != "victory":
		return _failure("M4-03 只接收胜利结果；撤退和失败留待 M4-05")
	for field in ["player_remaining_troops", "player_remaining_morale"]:
		if not result.has(field):
			return _failure("CombatResult 缺少字段：%s" % field)
	var troops := int(result.player_remaining_troops)
	var morale := int(result.player_remaining_morale)
	if troops <= 0 or troops > int(_state.general.max_troops):
		return _failure("CombatResult 剩余兵力越界")
	if morale <= 0 or morale > int(_state.general.max_morale):
		return _failure("CombatResult 剩余士气越界")
	var completed_node: Dictionary = _route.current_node()
	_state.general.troops = troops
	_state.general.morale = morale
	_state.general.armor = 0
	_state.completed_battles = int(_state.completed_battles) + 1
	if completed_node.get("node_type", "") == "military_objective":
		var objective_id: String = completed_node.get("objective_id", "")
		if not objective_id.is_empty():
			_state.boss_modifiers[objective_id] = true
	var route_result: Dictionary = _route.complete_current_node()
	if not route_result.ok:
		return route_result
	_pending_combat_request = {}
	if _route.status() == "completed":
		_state.status = "awaiting_settlement"
		_state.temporary_buffs.clear()
	return {"ok": true, "node_id": route_result.node_id, "reason": ""}


func apply_terminal_combat_result(result: Dictionary) -> Dictionary:
	if _pending_combat_request.is_empty():
		return _failure("没有待结算战斗")
	var battle_error := _validate_battle_result_id(result)
	if not battle_error.is_empty():
		return _failure(battle_error)
	var result_status: String = result.get("status", "")
	if not result_status in ["retreated", "defeat"]:
		return _failure("终止结果必须是撤退或失败")
	for field in ["player_remaining_troops", "player_remaining_morale", "general_died", "general_injured"]:
		if not result.has(field):
			return _failure("CombatResult 缺少字段：%s" % field)
	var troops := int(result.player_remaining_troops)
	var morale := int(result.player_remaining_morale)
	if troops < 0 or troops > int(_state.general.max_troops):
		return _failure("CombatResult 剩余兵力越界")
	if morale < 0 or morale > int(_state.general.max_morale):
		return _failure("CombatResult 剩余士气越界")
	if result_status == "retreated":
		if troops <= 0 or morale <= 0:
			return _failure("主动撤退必须保留正数兵力和士气")
		if bool(result.general_died) or bool(result.general_injured):
			return _failure("主动撤退必须保证武将生还且不新增重伤")
	_state.general.troops = troops
	_state.general.morale = morale
	_state.general.armor = 0
	_state.general_died = bool(result.general_died)
	_state.general_injured = bool(result.general_injured)
	_state.lost_unbanked_loot = _state.unbanked_loot.duplicate(true)
	_state.unbanked_loot = {}
	_state.temporary_buffs.clear()
	_state.temporary_items.clear()
	_state.temporary_cards.clear()
	_state.pending_encounter = {}
	_pending_combat_request = {}
	_state.status = "retreated" if result_status == "retreated" else "failed"
	return {"ok": true, "status": _state.status, "reason": ""}


func apply_combat_result(result: Dictionary) -> Dictionary:
	var battle_id := String(result.get("battle_id", ""))
	if _pending_combat_request.is_empty() and _state.get("settled_battle_ids", []).has(battle_id):
		return {"ok": true, "duplicate": true, "reason": ""}
	if _pending_node_resolution.is_empty():
		return _failure("当前战斗缺少节点解析检查点")
	var resolution := _pending_node_resolution.duplicate(true)
	var combat_request := _pending_combat_request.duplicate(true)
	var applied: Dictionary
	if result.get("status", "") == "victory":
		applied = apply_victory_result(result)
		if not applied.ok:
			return applied
		for resource_id in resolution.get("victory_loot", {}):
			_state.unbanked_loot[resource_id] = int(_state.unbanked_loot.get(resource_id, 0)) + int(resolution.victory_loot[resource_id])
		var victory_item := String(resolution.get("victory_item", ""))
		var item_gained := ""
		if not victory_item.is_empty() and _state.temporary_items.size() < 3:
			_state.temporary_items.append({"instance_id": "%s:victory-item" % resolution.resolution_id, "item_id": victory_item})
			item_gained = victory_item
		_record_resolution(_state, resolution, "victory")
		if _state.get("status", "") == "active" and resolution.get("post_battle_encounter", null) is Dictionary and not resolution.post_battle_encounter.is_empty():
			_state.pending_encounter = resolution.post_battle_encounter.duplicate(true)
		var experience_gained := _award_battle_experience(resolution, battle_id)
		_state.pending_combat_report = _build_combat_report(combat_request, result, resolution, experience_gained, item_gained)
	else:
		applied = apply_terminal_combat_result(result)
		if not applied.ok:
			return applied
	_state.settled_battle_ids.append(battle_id)
	_pending_node_resolution = {}
	applied.duplicate = false
	return applied


func pending_combat_report() -> Dictionary:
	return _state.get("pending_combat_report", {}).duplicate(true)


func acknowledge_combat_report(action_id: String, report_id: String) -> Dictionary:
	if action_id.strip_edges().is_empty() or report_id.strip_edges().is_empty():
		return _failure("确认战报需要稳定 action_id 和 report_id")
	if _state.get("acknowledged_combat_report_action_ids", []).has(action_id):
		return {"ok": true, "duplicate": true, "reason": ""}
	var report: Dictionary = _state.get("pending_combat_report", {})
	if report.is_empty():
		return _failure("当前没有待确认战报")
	if String(report.get("report_id", "")) != report_id:
		return _failure("战报已过期，请刷新当前状态")
	_state.acknowledged_combat_report_action_ids.append(action_id)
	_state.combat_report_history.append({
		"action_id": action_id,
		"report_id": report_id,
		"battle_id": report.get("battle_id", ""),
		"experience_gained": int(report.get("experience_gained", 0)),
	})
	_state.pending_combat_report = {}
	return {"ok": true, "duplicate": false, "report_id": report_id, "reason": ""}


func create_settlement_request() -> Dictionary:
	var outcome_by_status := {
		"awaiting_settlement": "success",
		"retreated": "retreated",
		"failed": "failed",
	}
	var run_status: String = _state.get("status", "")
	if not outcome_by_status.has(run_status):
		return _failure("远征尚未进入可结算状态")
	var succeeded := run_status == "awaiting_settlement"
	var request := {
		"request_id": "settlement:%s" % _state.run_id,
		"run_id": _state.run_id,
		"expedition_id": _state.expedition_id,
		"outcome": outcome_by_status[run_status],
		"general_id": _state.general.id,
		"remaining_troops": int(_state.general.troops),
		"initial_troops": int(_state.initial_troops),
		"army_composition": _state.army_composition.duplicate(true),
		"remaining_morale": int(_state.general.morale),
		"general_died": bool(_state.general_died),
		"general_injured": bool(_state.general_injured),
		"loot_to_bank": _state.unbanked_loot.duplicate(true) if succeeded else {},
		"lost_unbanked_loot": {} if succeeded else _state.lost_unbanked_loot.duplicate(true),
		"boss_modifiers": _state.boss_modifiers.duplicate(true),
		"completed_battles": int(_state.completed_battles),
		"rebellion_delta": int(_state.pending_rebellion_delta) + (int(_state.capture_rebellion) if succeeded else 0),
		"popular_support_delta": int(_state.pending_popular_support_delta),
		"pending_card_unlocks": _state.pending_card_unlocks.duplicate() if succeeded else [],
		"experience_gained": int(_state.get("pending_battle_experience", 0)),
	}
	return {"ok": true, "request": request, "reason": ""}


func snapshot() -> Dictionary:
	var result := _state.duplicate(true)
	var projected := GeneralManagementServiceScript.project_experience(
		int(_state.get("initial_general_level", 1)),
		int(_state.get("initial_general_experience", 0)),
		int(_state.get("pending_battle_experience", 0)),
		_progression
	)
	result.projected_general_level = int(projected.level)
	result.projected_general_experience = int(projected.experience)
	result.projected_attribute_growth = projected.attribute_growth.duplicate(true)
	result.projected_popular_support = clampi(int(_state.get("initial_popular_support", 20)) + int(_state.get("pending_popular_support_delta", 0)), 0, 100)
	result.route = _route.snapshot() if _route != null else {}
	result.visible_nodes = _route.visible_nodes() if _route != null else []
	result.map_edges = _map.get("edges", []).duplicate(true)
	result.pending_combat = _pending_combat_request.duplicate(true)
	result.pending_node_resolution = _pending_node_resolution.duplicate(true)
	return result


func current_node() -> Dictionary:
	return _route.current_node() if _route != null else {}


func _can_change_route() -> bool:
	return _state.get("status", "") == "active" and _pending_combat_request.is_empty() and _state.get("pending_encounter", {}).is_empty() and _state.get("pending_combat_report", {}).is_empty()


func _failure(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}


func _validate_battle_result_id(result: Dictionary) -> String:
	if String(result.get("battle_id", "")).is_empty():
		return "CombatResult 缺少 battle_id" if not _pending_node_resolution.is_empty() else ""
	if result.battle_id != _pending_combat_request.get("battle_id", ""):
		return "CombatResult battle_id 与当前待处理战斗不一致"
	return ""


func _validate_resolution(resolution: Dictionary, requires_combat: bool) -> String:
	for field in ["resolution_id", "node_id", "node_type"]:
		if String(resolution.get(field, "")).is_empty():
			return "节点解析缺少字段：%s" % field
	var node: Dictionary = _route.current_node()
	if resolution.node_id != node.get("id", "") or resolution.node_type != node.get("node_type", ""):
		return "节点解析与当前节点不一致"
	if requires_combat != COMBAT_NODE_TYPES.has(resolution.node_type):
		return "节点解析的战斗类型不一致"
	return ""


func _apply_effects(state: Dictionary, effects: Dictionary, resolution_id: String) -> void:
	for resource_id in effects.get("consume_loot", {}):
		state.unbanked_loot[resource_id] = maxi(0, int(state.unbanked_loot.get(resource_id, 0)) - int(effects.consume_loot[resource_id]))
		if int(state.unbanked_loot[resource_id]) == 0:
			state.unbanked_loot.erase(resource_id)
	for resource_id in effects.get("loot", {}):
		state.unbanked_loot[resource_id] = int(state.unbanked_loot.get(resource_id, 0)) + int(effects.loot[resource_id])
	var buff = effects.get("buff", null)
	if buff is Dictionary:
		state.temporary_buffs.append({"id": "%s:buff" % resolution_id, "type": buff.type, "amount": int(buff.amount), "remaining_battles": 1})
	if effects.has("restore_troops_ratio"):
		var amount := int(floor(float(state.general.max_troops) * float(effects.restore_troops_ratio)))
		state.general.troops = mini(int(state.general.max_troops), int(state.general.troops) + amount)
	if effects.has("restore_morale"):
		state.general.morale = mini(int(state.general.max_morale), int(state.general.morale) + int(effects.restore_morale))
	if effects.has("troops_delta"):
		state.general.troops = clampi(int(state.general.troops) + int(effects.troops_delta), 0, int(state.general.max_troops))
	if effects.has("morale_delta"):
		state.general.morale = clampi(int(state.general.morale) + int(effects.morale_delta), 0, int(state.general.max_morale))
	var temporary_card := String(effects.get("add_temporary_card", ""))
	if not temporary_card.is_empty():
		state.deck.append(temporary_card)
		state.temporary_cards.append(temporary_card)
	var pending_unlock := String(effects.get("pending_card_unlock", ""))
	if not pending_unlock.is_empty() and not state.pending_card_unlocks.has(pending_unlock):
		state.pending_card_unlocks.append(pending_unlock)
	var item_id := String(effects.get("add_item", ""))
	if not item_id.is_empty() and state.temporary_items.size() < 3:
		state.temporary_items.append({"instance_id": "%s:item:%d" % [resolution_id, state.temporary_items.size()], "item_id": item_id})
	var consume_item_id := String(effects.get("consume_item_id", ""))
	if not consume_item_id.is_empty():
		for index in state.temporary_items.size():
			if state.temporary_items[index].item_id == consume_item_id:
				state.temporary_items.remove_at(index)
				break
	if effects.has("rebellion_delta"):
		state.pending_rebellion_delta = int(state.pending_rebellion_delta) + int(effects.rebellion_delta)
	if effects.has("popular_support_delta"):
		state.pending_popular_support_delta = int(state.get("pending_popular_support_delta", 0)) + int(effects.popular_support_delta)
	var boss_modifier_id := String(effects.get("boss_modifier_id", ""))
	if not boss_modifier_id.is_empty():
		state.boss_modifiers[boss_modifier_id] = true
	for key in effects.get("intel", {}):
		state.intel[key] = effects.intel[key]


func _apply_route_effects(effects: Dictionary) -> void:
	if effects.has("reveal_layers"):
		_route.reveal_future_layers(int(effects.reveal_layers))


func _requirements_error(requirements: Dictionary) -> String:
	for resource_id in requirements.get("loot", {}):
		if int(_state.unbanked_loot.get(resource_id, 0)) < int(requirements.loot[resource_id]):
			return "本次远征的未入库资源不足"
	if int(requirements.get("inventory_space", 0)) > 0 and _state.temporary_items.size() + int(requirements.inventory_space) > 3:
		return "临时物品栏已满"
	var required_item := String(requirements.get("item_id", ""))
	if not required_item.is_empty():
		var found := false
		for item in _state.temporary_items:
			if item.get("item_id", "") == required_item:
				found = true
				break
		if not found:
			return "缺少所需临时物品"
	for attribute_id in requirements.get("attribute", {}):
		if int(_state.general.get("attributes", {}).get(attribute_id, _state.general.get(attribute_id, 0))) < int(requirements.attribute[attribute_id]):
			return "武将%s不足" % attribute_id
	var projected_support := clampi(int(_state.get("initial_popular_support", 20)) + int(_state.get("pending_popular_support_delta", 0)), 0, 100)
	if requirements.has("popular_support_min") and projected_support < int(requirements.popular_support_min):
		return "义军民望需要至少%d" % int(requirements.popular_support_min)
	if requirements.has("popular_support_max") and projected_support > int(requirements.popular_support_max):
		return "义军民望需要不高于%d" % int(requirements.popular_support_max)
	return ""


func _award_battle_experience(resolution: Dictionary, battle_id: String) -> int:
	for entry in _state.get("battle_experience_ledger", []):
		if entry is Dictionary and entry.get("battle_id", "") == battle_id:
			return 0
	var victory_type := _victory_type(resolution)
	var amount := int(_progression.get("victory_experience", {}).get(victory_type, 0))
	_state.pending_battle_experience = int(_state.get("pending_battle_experience", 0)) + amount
	_state.battle_experience_ledger.append({
		"battle_id": battle_id,
		"node_id": String(resolution.get("node_id", "")),
		"victory_type": victory_type,
		"amount": amount,
	})
	return amount


func _build_combat_report(combat_request: Dictionary, result: Dictionary, resolution: Dictionary, experience_gained: int, item_gained: String) -> Dictionary:
	var battle_id := String(combat_request.get("battle_id", ""))
	var experience_after := int(_state.get("initial_general_experience", 0)) + int(_state.get("pending_battle_experience", 0))
	var experience_before := experience_after - experience_gained
	var projection := GeneralManagementServiceScript.project_experience(
		int(_state.get("initial_general_level", 1)),
		int(_state.get("initial_general_experience", 0)),
		int(_state.get("pending_battle_experience", 0)),
		_progression
	)
	var current_level := int(_state.get("initial_general_level", 1))
	var max_level := int(_progression.get("max_level", current_level))
	var next_level_experience := int(_progression.get("experience_thresholds", {}).get(str(current_level + 1), experience_after)) if current_level < max_level else experience_after
	var node: Dictionary = _map.get("node_by_id", {}).get(String(resolution.get("node_id", "")), {})
	var max_layer := 0
	for map_node in _map.get("nodes", []):
		if map_node is Dictionary:
			max_layer = maxi(max_layer, int(map_node.get("layer", map_node.get("column", 0))))
	return {
		"report_id": "combat-report:%s" % battle_id,
		"battle_id": battle_id,
		"node_id": String(resolution.get("node_id", "")),
		"node_type": String(resolution.get("node_type", "")),
		"victory_type": _victory_type(resolution),
		"enemy_id": String(combat_request.get("enemy", {}).get("id", "")),
		"experience_gained": experience_gained,
		"pending_experience_total": int(_state.get("pending_battle_experience", 0)),
		"initial_experience": int(_state.get("initial_general_experience", 0)),
		"experience_before": experience_before,
		"projected_experience": int(projection.experience),
		"current_level": current_level,
		"projected_level": int(projection.level),
		"next_level_experience": next_level_experience,
		"projected_attribute_growth": projection.attribute_growth.duplicate(true),
		"troops_before": int(combat_request.get("player", {}).get("troops", result.get("player_remaining_troops", 0))),
		"troops_after": int(result.get("player_remaining_troops", 0)),
		"troops_delta": int(result.get("player_remaining_troops", 0)) - int(combat_request.get("player", {}).get("troops", result.get("player_remaining_troops", 0))),
		"morale_before": int(combat_request.get("player", {}).get("morale", result.get("player_remaining_morale", 0))),
		"morale_after": int(result.get("player_remaining_morale", 0)),
		"morale_delta": int(result.get("player_remaining_morale", 0)) - int(combat_request.get("player", {}).get("morale", result.get("player_remaining_morale", 0))),
		"loot_gained": resolution.get("victory_loot", {}).duplicate(true),
		"unbanked_loot_total": _state.unbanked_loot.duplicate(true),
		"item_gained": item_gained,
		"completed_battles": int(_state.completed_battles),
		"route_progress": {"layer": int(node.get("layer", node.get("column", 0))), "max_layer": max_layer},
		"post_battle_reward_pending": not _state.get("pending_encounter", {}).is_empty(),
		"expedition_terminal": _state.get("status", "") != "active",
	}


func _reconstruct_legacy_battle_experience(campaign_general: Dictionary) -> void:
	_state.initial_general_level = int(campaign_general.get("level", _state.get("initial_general_level", 1)))
	_state.initial_general_experience = int(campaign_general.get("experience", _state.get("initial_general_experience", 0)))
	_state.pending_battle_experience = 0
	_state.battle_experience_ledger = []
	for entry in _state.get("resolution_history", []):
		if not entry is Dictionary or entry.get("outcome", "") != "victory":
			continue
		var resolution := {
			"node_id": String(entry.get("node_id", "")),
			"node_type": String(entry.get("node_type", "")),
			"choice_combat": String(entry.get("node_type", "")) == "merchant",
		}
		var battle_id := "%s:%s" % [_state.run_id, resolution.node_id]
		var victory_type := _victory_type(resolution)
		var amount := int(_progression.get("victory_experience", {}).get(victory_type, 0))
		_state.pending_battle_experience = int(_state.pending_battle_experience) + amount
		_state.battle_experience_ledger.append({"battle_id": battle_id, "node_id": resolution.node_id, "victory_type": victory_type, "amount": amount})
	_state.experience_migration = {
		"source": String(_state.get("experience_migration", {}).get("source", "legacy_resolution_history")),
		"reconstructed": true,
		"experience": int(_state.pending_battle_experience),
	}


func _victory_type(resolution: Dictionary) -> String:
	if bool(resolution.get("choice_combat", false)) or resolution.get("node_type", "") == "merchant":
		return "merchant_combat"
	return String(resolution.get("node_type", ""))


func _find_choice(choices: Array, choice_id: String) -> Dictionary:
	for choice in choices:
		if choice is Dictionary and choice.get("choice_id", "") == choice_id:
			return choice.duplicate(true)
	return {}


func _stable_hash(value: String) -> int:
	var hash_value := 2166136261
	for byte in value.to_utf8_buffer():
		hash_value = int((hash_value ^ int(byte)) * 16777619) & 0x7fffffff
	return hash_value


func _record_resolution(state: Dictionary, resolution: Dictionary, outcome: String) -> void:
	state.resolution_ids.append(resolution.resolution_id)
	state.resolution_history.append({"resolution_id": resolution.resolution_id, "node_id": resolution.node_id, "node_type": resolution.node_type, "outcome": outcome})


func _is_non_negative_whole_number(value: Variant) -> bool:
	if value is int:
		return value >= 0
	return value is float and is_finite(value) and value == floor(value) and value >= 0.0
