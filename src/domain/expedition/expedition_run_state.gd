extends RefCounted
class_name ExpeditionRunState

const RouteStateScript := preload("res://src/domain/expedition/expedition_route_state.gd")

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


func setup(
	run_id: String,
	generated_map: Dictionary,
	general_snapshot: Dictionary,
	deck: Array,
	card_overrides: Dictionary = {}
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
	if not errors.is_empty():
		return errors
	_route = RouteStateScript.new()
	var route_errors: PackedStringArray = _route.setup(generated_map)
	if not route_errors.is_empty():
		return route_errors
	_map = generated_map.duplicate(true)
	var player := general_snapshot.duplicate(true)
	player.troops = mini(int(player.troops), int(player.max_troops))
	player.morale = mini(int(player.morale), int(player.max_morale))
	player.armor = 0
	_state = {
		"run_id": run_id,
		"expedition_id": generated_map.get("expedition_id", ""),
		"seed": generated_map.get("seed", 0),
		"general": player,
		"initial_troops": int(player.troops),
		"army_composition": player.army_composition.duplicate(true),
		"deck": deck.duplicate(),
		"card_overrides": card_overrides.duplicate(true),
		"army_counts": player.get("army_counts", {}).duplicate(true),
		"unbanked_loot": {},
		"lost_unbanked_loot": {},
		"temporary_buffs": [],
		"boss_modifiers": {},
		"status": "active",
		"completed_battles": 0,
		"general_died": false,
		"general_injured": false,
		"resolution_ids": [],
		"resolution_history": [],
		"settled_battle_ids": [],
		"intel": {},
	}
	_pending_combat_request = {}
	_pending_node_resolution = {}
	return PackedStringArray()


func restore(saved: Dictionary, generated_map: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	for field in ["run_id", "expedition_id", "seed", "general", "initial_troops", "army_composition", "deck", "status", "route", "pending_combat"]:
		if not saved.has(field):
			errors.append("expedition restore missing field '%s'" % field)
	if not errors.is_empty():
		return errors
	if saved.expedition_id != generated_map.expedition_id or int(saved.seed) != int(generated_map.seed):
		errors.append("expedition restore identity or seed mismatch")
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
	_state = saved.duplicate(true)
	_state.erase("route")
	_state.erase("visible_nodes")
	_state.erase("pending_combat")
	_pending_combat_request = pending.duplicate(true)
	_pending_node_resolution = _state.get("pending_node_resolution", {}).duplicate(true)
	_state.erase("pending_node_resolution")
	for field in ["card_overrides", "army_counts", "resolution_ids", "resolution_history", "settled_battle_ids", "intel"]:
		if not _state.has(field):
			_state[field] = {} if field in ["card_overrides", "army_counts", "intel"] else []
	return errors


func _validate_resolution_ledger(saved: Dictionary, generated_map: Dictionary, pending: Variant, errors: PackedStringArray) -> void:
	var node_by_id = generated_map.get("node_by_id", {})
	var resolution_ids = saved.get("resolution_ids", [])
	var history = saved.get("resolution_history", [])
	var settled_battle_ids = saved.get("settled_battle_ids", [])
	var pending_resolution = saved.get("pending_node_resolution", {})
	if not resolution_ids is Array or not history is Array or not settled_battle_ids is Array:
		errors.append("expedition restore resolution ledgers must be arrays")
		return
	if not pending_resolution is Dictionary:
		errors.append("expedition restore pending_node_resolution must be an object")
		return
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
	if pending_resolution.is_empty():
		return
	if not pending is Dictionary or pending.is_empty():
		errors.append("expedition restore pending node resolution requires pending combat")
		return
	var pending_node_id := String(pending_resolution.get("node_id", ""))
	if pending_node_id != String(saved.route.current_node_id):
		errors.append("expedition restore pending node resolution does not match the current node")
	var pending_resolution_id := String(pending_resolution.get("resolution_id", ""))
	if pending_resolution_id.is_empty():
		errors.append("expedition restore pending node resolution id must be non-empty")
	elif unique_resolution_ids.has(pending_resolution_id):
		errors.append("expedition restore pending node resolution is already settled")
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
	if not COMBAT_NODE_TYPES.has(node.get("node_type", "")):
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
	var applied: Dictionary
	if result.get("status", "") == "victory":
		applied = apply_victory_result(result)
		if not applied.ok:
			return applied
		for resource_id in resolution.get("victory_loot", {}):
			_state.unbanked_loot[resource_id] = int(_state.unbanked_loot.get(resource_id, 0)) + int(resolution.victory_loot[resource_id])
		_record_resolution(_state, resolution, "victory")
	else:
		applied = apply_terminal_combat_result(result)
		if not applied.ok:
			return applied
	_state.settled_battle_ids.append(battle_id)
	_pending_node_resolution = {}
	applied.duplicate = false
	return applied


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
	}
	return {"ok": true, "request": request, "reason": ""}


func snapshot() -> Dictionary:
	var result := _state.duplicate(true)
	result.route = _route.snapshot() if _route != null else {}
	result.visible_nodes = _route.visible_nodes() if _route != null else []
	result.pending_combat = _pending_combat_request.duplicate(true)
	result.pending_node_resolution = _pending_node_resolution.duplicate(true)
	return result


func current_node() -> Dictionary:
	return _route.current_node() if _route != null else {}


func _can_change_route() -> bool:
	return _state.get("status", "") == "active" and _pending_combat_request.is_empty()


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
	for key in effects.get("intel", {}):
		state.intel[key] = effects.intel[key]


func _record_resolution(state: Dictionary, resolution: Dictionary, outcome: String) -> void:
	state.resolution_ids.append(resolution.resolution_id)
	state.resolution_history.append({"resolution_id": resolution.resolution_id, "node_id": resolution.node_id, "node_type": resolution.node_type, "outcome": outcome})
