extends RefCounted
class_name CombatController

const DeterministicRngScript := preload("res://src/domain/random/deterministic_rng.gd")
const CombatEventLogScript := preload("res://src/domain/combat/combat_event_log.gd")
const DamageCalculatorScript := preload("res://src/domain/combat/damage_calculator.gd")
const ConditionEvaluatorScript := preload("res://src/domain/combat/condition_evaluator.gd")
const DeckStateScript := preload("res://src/domain/combat/deck_state.gd")
const EnemyIntentPlannerScript := preload("res://src/domain/combat/enemy_intent_planner.gd")

const DEFAULT_ACTION_POINTS := 3
const DEFAULT_DRAW_COUNT := 5
const MORALE_MINIMUM := 0
const MORALE_MAXIMUM := 100

var _registry
var _deck_rng
var _ai_rng
var _outcome_rng
var _deck
var _log
var _state: Dictionary = {}
var _result: Dictionary = {}


func setup(request: Dictionary, content_registry) -> PackedStringArray:
	var errors := _validate_request(request, content_registry)
	if not errors.is_empty():
		return errors

	_registry = content_registry
	var battle_seed := int(request.get("seed", 0))
	_deck_rng = DeterministicRngScript.new(battle_seed ^ 0x44EC5EED)
	_ai_rng = DeterministicRngScript.new(battle_seed ^ 0xA11E57)
	_outcome_rng = DeterministicRngScript.new(battle_seed ^ 0x0C7C0A1E)
	_deck = DeckStateScript.new()
	_log = CombatEventLogScript.new()
	_deck.setup(request.deck, _deck_rng)
	_state = {
		"battle_id": request.get("battle_id", "development_battle"),
		"seed": int(request.get("seed", 0)),
		"phase": "setup",
		"turn": 0,
		"action_points": 0,
		"draw_count": int(request.get("draw_count", DEFAULT_DRAW_COUNT)),
		"starting_action_points": int(request.get("starting_action_points", DEFAULT_ACTION_POINTS)),
		"player": _normalize_combatant(request.player),
		"enemy": _normalize_combatant(request.enemy),
		"enemy_skills": request.enemy.get("skills", []).duplicate(true),
		"enemy_cooldowns": {},
		"enemy_intent": {},
		"turn_stats": _new_turn_stats(),
		"status": "active",
	}
	_result = {}
	_log.record("battle_started", {"battle_id": _state.battle_id, "seed": _state.seed})
	_start_player_turn()
	return PackedStringArray()


func play_card(hand_index: int) -> Dictionary:
	if not is_active() or _state.phase != "player_action":
		return _failure("当前阶段不能出牌")
	if hand_index < 0 or hand_index >= _deck.hand.size():
		return _failure("手牌索引无效")
	var card_id: String = _deck.hand[hand_index]
	var card: Dictionary = _registry.get_card(card_id)
	if card.is_empty():
		return _failure("找不到卡牌：%s" % card_id)
	var cost := int(card.get("cost", 0))
	if cost > int(_state.action_points):
		return _failure("行动力不足")
	var condition_result := card_availability(hand_index)
	if not condition_result.ok:
		return condition_result

	_state.action_points -= cost
	_deck.play_from_hand(hand_index, bool(card.get("exhaust", false)))
	_state.turn_stats.cards_played += 1
	if card.get("tags", []).has("attack"):
		_state.turn_stats.attack_cards_played += 1
	_log.record("card_played", {"card_id": card_id, "cost": cost})

	for effect in card.effects:
		_resolve_effect(effect, "player")
		if not is_active():
			break
	return {"ok": true, "card_id": card_id, "result": _result.duplicate(true)}


func card_availability(hand_index: int) -> Dictionary:
	if hand_index < 0 or hand_index >= _deck.hand.size():
		return _failure("手牌索引无效")
	var card: Dictionary = _registry.get_card(_deck.hand[hand_index])
	if card.is_empty():
		return _failure("卡牌定义缺失")
	if int(card.get("cost", 0)) > int(_state.action_points):
		return _failure("行动力不足")
	var evaluated := ConditionEvaluatorScript.evaluate_all(
		card.get("conditions", []),
		_condition_context("player")
	)
	if not evaluated.passed:
		return _failure(evaluated.reason)
	return {"ok": true, "reason": ""}


func preview_card_damage(hand_index: int) -> int:
	if hand_index < 0 or hand_index >= _deck.hand.size():
		return 0
	var card: Dictionary = _registry.get_card(_deck.hand[hand_index])
	for effect in card.get("effects", []):
		if effect.get("type", "") == "DealDamage":
			return DamageCalculatorScript.preview(effect, _state.player, _state.enemy)
		if effect.get("type", "") == "RepeatAttack":
			return DamageCalculatorScript.preview(effect, _state.player, _state.enemy) * int(effect.get("times", 1))
	return 0


func end_player_turn() -> Dictionary:
	if not is_active() or _state.phase != "player_action":
		return _failure("当前阶段不能结束回合")
	var discarded: Array = _deck.discard_hand()
	_log.record("player_turn_ended", {"discarded": discarded})
	_execute_enemy_turn()
	if is_active():
		_start_player_turn()
	return {"ok": true, "result": _result.duplicate(true)}


func retreat() -> Dictionary:
	if not is_active() or _state.phase != "player_action":
		return _failure("当前阶段不能撤退")
	_state.status = "retreated"
	_state.phase = "result"
	_result = _build_result("retreated", "player_retreat", false, false, false)
	_log.record("battle_retreated", {"remaining_troops": _state.player.troops})
	return {"ok": true, "result": _result.duplicate(true)}


func is_active() -> bool:
	return _state.get("status", "") == "active"


func snapshot() -> Dictionary:
	var value := _state.duplicate(true)
	value["deck"] = _deck.snapshot() if _deck != null else {}
	value["events"] = _log.snapshot() if _log != null else []
	value["result"] = _result.duplicate(true)
	return value


func result() -> Dictionary:
	return _result.duplicate(true)


func event_log() -> Array[Dictionary]:
	return _log.snapshot() if _log != null else []


func _start_player_turn() -> void:
	_state.turn += 1
	_state.phase = "player_turn_start"
	_state.player.armor = 0
	_state.action_points = _state.starting_action_points
	_state.turn_stats = _new_turn_stats()
	_tick_enemy_cooldowns()
	var drawn: Array = _deck.draw(_state.draw_count)
	_state.enemy_intent = EnemyIntentPlannerScript.choose_intent(
		_state.enemy_skills,
		_public_combatant(_state.enemy),
		_public_combatant(_state.player),
		_state.turn_stats,
		_state.enemy_cooldowns,
		_ai_rng
	)
	_state.phase = "player_action"
	_log.record("player_turn_started", {"turn": _state.turn, "drawn": drawn})
	_log.record("enemy_intent_revealed", {
		"skill_id": _state.enemy_intent.get("id", "none"),
		"intent_type": _state.enemy_intent.get("intent_type", "none"),
	})


func _execute_enemy_turn() -> void:
	_state.phase = "enemy_turn"
	_state.enemy.armor = 0
	var intent: Dictionary = _state.enemy_intent
	if intent.is_empty():
		_log.record("enemy_skipped", {})
		return
	_log.record("enemy_skill_started", {"skill_id": intent.get("id", "")})
	for effect in intent.get("effects", []):
		_resolve_effect(effect, "enemy")
		if not is_active():
			break
	var cooldown := int(intent.get("cooldown", 0))
	if cooldown > 0:
		_state.enemy_cooldowns[intent.get("id", "")] = cooldown


func _resolve_effect(effect: Dictionary, source_side: String) -> void:
	if not is_active():
		return
	var source: Dictionary = _state[source_side]
	var target_side := _target_side(source_side, effect.get("target", "opponent"))
	var target: Dictionary = _state[target_side]
	var effect_type: String = effect.get("type", "")
	match effect_type:
		"DealDamage":
			_apply_damage(source_side, target_side, effect)
		"RepeatAttack":
			for index in maxi(int(effect.get("times", 1)), 0):
				_apply_damage(source_side, target_side, effect)
				if not is_active():
					break
		"GainArmor":
			var amount := maxi(int(effect.get("amount", 0)), 0)
			target.armor += amount
			_log.record("armor_gained", {"side": target_side, "amount": amount, "armor": target.armor})
		"ModifyMorale":
			_apply_morale(target_side, int(effect.get("amount", 0)))
		"ConsumeOwnMorale":
			_apply_morale(source_side, -absi(int(effect.get("amount", 0))))
		"DrawCards":
			if source_side == "player":
				var drawn: Array = _deck.draw(maxi(int(effect.get("amount", 0)), 0))
				_log.record("cards_drawn", {"cards": drawn})
		"GainActionPoint":
			if source_side == "player":
				var amount := int(effect.get("amount", 0))
				_state.action_points = maxi(int(_state.action_points) + amount, 0)
				_log.record("action_points_changed", {"amount": amount, "value": _state.action_points})
		"ModifyDefense":
			var amount := int(effect.get("amount", 0))
			target.defense = maxi(int(target.defense) + amount, 0)
			_log.record("defense_changed", {"side": target_side, "amount": amount, "defense": target.defense})
		"ApplyStatus":
			var status_id: String = effect.get("status_id", "")
			if not status_id.is_empty():
				var stacks := int(effect.get("stacks", 1))
				target.statuses[status_id] = int(target.statuses.get(status_id, 0)) + stacks
				_log.record("status_applied", {"side": target_side, "status_id": status_id, "stacks": stacks})
		"ConditionalEffect":
			var condition_result := ConditionEvaluatorScript.evaluate_all(
				effect.get("conditions", []),
				_condition_context(source_side)
			)
			if condition_result.passed:
				for nested_effect in effect.get("effects", []):
					_resolve_effect(nested_effect, source_side)
					if not is_active():
						break
			else:
				_log.record("conditional_effect_skipped", {"reason": condition_result.reason})
		_:
			_log.record("unsupported_effect", {"type": effect_type})
	_check_outcome()


func _apply_damage(source_side: String, target_side: String, effect: Dictionary) -> void:
	var source: Dictionary = _state[source_side]
	var target: Dictionary = _state[target_side]
	var calculated := DamageCalculatorScript.preview(effect, source, target)
	var absorbed := mini(int(target.armor), calculated)
	target.armor -= absorbed
	var troop_damage := calculated - absorbed
	target.troops = maxi(int(target.troops) - troop_damage, 0)
	_log.record("damage_dealt", {
		"source": source_side,
		"target": target_side,
		"calculated": calculated,
		"armor_absorbed": absorbed,
		"troop_damage": troop_damage,
		"remaining_troops": target.troops,
	})
	_check_outcome()


func _apply_morale(target_side: String, amount: int) -> void:
	var target: Dictionary = _state[target_side]
	var before := int(target.morale)
	target.morale = clampi(before + amount, MORALE_MINIMUM, int(target.max_morale))
	var actual_change := int(target.morale) - before
	if target_side == "enemy" and actual_change < 0:
		_state.turn_stats.enemy_morale_lost += -actual_change
	_log.record("morale_changed", {"side": target_side, "amount": actual_change, "morale": target.morale})
	_check_outcome()


func _check_outcome() -> void:
	if not is_active():
		return
	if int(_state.player.troops) <= 0:
		_finish_defeat("player_troops_zero", true, false)
		return
	if int(_state.enemy.troops) <= 0:
		_finish_victory("enemy_troops_zero")
		return
	if int(_state.player.morale) <= 0:
		var died: bool = _outcome_rng.next_int(1, 100) <= 20
		_finish_defeat("player_morale_zero", died, not died)
		return
	if int(_state.enemy.morale) <= 0:
		_finish_victory("enemy_morale_zero")


func _finish_victory(reason: String) -> void:
	_state.status = "victory"
	_state.phase = "result"
	_result = _build_result("victory", reason, false, false, false)
	_log.record("battle_finished", _result)


func _finish_defeat(reason: String, general_died: bool, general_injured: bool) -> void:
	_state.status = "defeat"
	_state.phase = "result"
	var game_over := general_died and bool(_state.player.get("is_player_character", false))
	_result = _build_result("defeat", reason, general_died, general_injured, game_over)
	_log.record("battle_finished", _result)


func _build_result(
	status: String,
	reason: String,
	general_died: bool,
	general_injured: bool,
	game_over: bool
) -> Dictionary:
	return {
		"status": status,
		"reason": reason,
		"turns": int(_state.turn),
		"player_remaining_troops": int(_state.player.troops),
		"player_remaining_morale": int(_state.player.morale),
		"enemy_remaining_troops": int(_state.enemy.troops),
		"enemy_remaining_morale": int(_state.enemy.morale),
		"general_died": general_died,
		"general_injured": general_injured,
		"game_over": game_over,
	}


func _condition_context(source_side: String) -> Dictionary:
	var target_side := "enemy" if source_side == "player" else "player"
	return {
		"actor": _state[source_side],
		"target": _state[target_side],
		"turn_stats": _state.turn_stats,
	}


func _target_side(source_side: String, target_spec: String) -> String:
	if target_spec == "self":
		return source_side
	return "enemy" if source_side == "player" else "player"


func _tick_enemy_cooldowns() -> void:
	for skill_id in _state.enemy_cooldowns.keys():
		var remaining := maxi(int(_state.enemy_cooldowns[skill_id]) - 1, 0)
		_state.enemy_cooldowns[skill_id] = remaining


func _normalize_combatant(source: Dictionary) -> Dictionary:
	var morale := clampi(int(source.get("morale", MORALE_MAXIMUM)), MORALE_MINIMUM, MORALE_MAXIMUM)
	return {
		"id": source.get("id", "unknown"),
		"is_player_character": bool(source.get("is_player_character", false)),
		"troops": maxi(int(source.get("troops", 1)), 0),
		"max_troops": maxi(int(source.get("max_troops", source.get("troops", 1))), 1),
		"morale": morale,
		"max_morale": clampi(int(source.get("max_morale", MORALE_MAXIMUM)), 1, MORALE_MAXIMUM),
		"attack": maxf(float(source.get("attack", 0.0)), 0.0),
		"defense": maxf(float(source.get("defense", 0.0)), 0.0),
		"armor": maxi(int(source.get("armor", 0)), 0),
		"army_composition": source.get("army_composition", {}).duplicate(true),
		"statuses": source.get("statuses", {}).duplicate(true),
	}


func _public_combatant(combatant: Dictionary) -> Dictionary:
	return combatant.duplicate(true)


func _new_turn_stats() -> Dictionary:
	return {
		"cards_played": 0,
		"attack_cards_played": 0,
		"enemy_morale_lost": 0,
	}


func _validate_request(request: Dictionary, content_registry) -> PackedStringArray:
	var errors := PackedStringArray()
	for field in ["player", "enemy", "deck", "seed"]:
		if not request.has(field):
			errors.append("combat request missing field '%s'" % field)
	if request.has("player") and not request.player is Dictionary:
		errors.append("combat request player must be an object")
	if request.has("enemy") and not request.enemy is Dictionary:
		errors.append("combat request enemy must be an object")
	if request.has("deck"):
		if not request.deck is Array or request.deck.is_empty():
			errors.append("combat request deck must be a non-empty array")
		else:
			for card_id in request.deck:
				if not card_id is String or not content_registry.has_card(card_id):
					errors.append("combat request references unknown card '%s'" % str(card_id))
	if request.has("enemy") and request.enemy is Dictionary:
		if not request.enemy.get("skills", null) is Array or request.enemy.get("skills", []).is_empty():
			errors.append("combat request enemy must have at least one skill")
	return errors


func _failure(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
