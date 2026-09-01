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


func setup(
	run_id: String,
	generated_map: Dictionary,
	general_snapshot: Dictionary,
	deck: Array
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
		"deck": deck.duplicate(),
		"unbanked_loot": {},
		"temporary_buffs": [],
		"boss_modifiers": {},
		"status": "active",
		"completed_battles": 0,
	}
	_pending_combat_request = {}
	return PackedStringArray()


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
	_pending_combat_request = {
		"battle_id": "%s:%s" % [_state.run_id, node.id],
		"seed": battle_seed,
		"player": player,
		"enemy": enemy.duplicate(true),
		"deck": _state.deck.duplicate(),
		"boss_modifiers": _state.boss_modifiers.duplicate(true),
		"expedition_context": {
			"run_id": _state.run_id,
			"node_id": node.id,
			"consumed_buff_ids": consumed_buff_ids,
		},
	}
	return {"ok": true, "request": _pending_combat_request.duplicate(true), "reason": ""}


func pending_combat_request() -> Dictionary:
	return _pending_combat_request.duplicate(true)


func apply_victory_result(result: Dictionary) -> Dictionary:
	if _pending_combat_request.is_empty():
		return _failure("没有待结算战斗")
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
	_state.general.troops = troops
	_state.general.morale = morale
	_state.general.armor = 0
	_state.completed_battles = int(_state.completed_battles) + 1
	var route_result: Dictionary = _route.complete_current_node()
	if not route_result.ok:
		return route_result
	_pending_combat_request = {}
	if _route.status() == "completed":
		_state.status = "awaiting_settlement"
	return {"ok": true, "node_id": route_result.node_id, "reason": ""}


func snapshot() -> Dictionary:
	var result := _state.duplicate(true)
	result.route = _route.snapshot() if _route != null else {}
	result.visible_nodes = _route.visible_nodes() if _route != null else []
	result.pending_combat = _pending_combat_request.duplicate(true)
	return result


func _can_change_route() -> bool:
	return _state.get("status", "") == "active" and _pending_combat_request.is_empty()


func _failure(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
