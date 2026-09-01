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
var _active_player_card: Dictionary = {}
var _active_card_damage_multiplier := 1.0


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
	var player_source: Dictionary = request.player.duplicate(true)
	if String(player_source.get("talent_id", "")).is_empty() and content_registry.has_general(player_source.get("id", "")):
		player_source.talent_id = content_registry.get_general(player_source.id).get("talent_id", "")
	var player_talent_id: String = player_source.get("talent_id", "")
	var enemy_source: Dictionary = request.enemy.duplicate(true)
	if String(enemy_source.get("talent_id", "")).is_empty() and content_registry.has_enemy(enemy_source.get("id", "")):
		enemy_source.talent_id = content_registry.get_enemy(enemy_source.id).get("talent_id", "")
	var enemy_talent_id: String = enemy_source.get("talent_id", "")
	_state = {
		"battle_id": request.get("battle_id", "development_battle"),
		"seed": int(request.get("seed", 0)),
		"phase": "setup",
		"turn": 0,
		"action_points": 0,
		"draw_count": int(request.get("draw_count", DEFAULT_DRAW_COUNT)),
		"starting_action_points": int(request.get("starting_action_points", DEFAULT_ACTION_POINTS)),
		"player": _normalize_combatant(player_source),
		"player_talent": content_registry.get_talent(player_talent_id) if not player_talent_id.is_empty() else {},
		"enemy": _normalize_combatant(enemy_source),
		"enemy_talent": content_registry.get_talent(enemy_talent_id) if not enemy_talent_id.is_empty() else {},
		"enemy_initial_armor": maxi(int(enemy_source.get("armor", 0)), 0),
		"enemy_initial_armor_active": int(enemy_source.get("armor", 0)) > 0,
		"enemy_talent_battle_triggers": {},
		"enemy_intent_suppression": {},
		"enemy_skills": enemy_source.get("skills", []).duplicate(true),
		"enemy_cooldowns": {},
		"enemy_intent": {},
		"turn_stats": _new_turn_stats(),
		"status": "active",
	}
	_result = {}
	_active_player_card = {}
	_active_card_damage_multiplier = 1.0
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

	_active_player_card = card
	_active_card_damage_multiplier = 1.0
	_try_trigger_pre_card_talent(card)
	_active_card_damage_multiplier = _consume_prepared_attack_multiplier(card)
	for effect in card.effects:
		_resolve_effect(effect, "player")
		if not is_active():
			break
	_try_trigger_post_card_talent(card)
	_active_player_card = {}
	_active_card_damage_multiplier = 1.0
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
	var source: Dictionary = _state.player.duplicate(true)
	var target: Dictionary = _state.enemy.duplicate(true)
	_preview_pre_card_talent(card, source, target)
	var multiplier := _peek_prepared_attack_multiplier(card)
	return _preview_effect_list(card.get("effects", []), source, target, multiplier)


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
	var excluded_intent_types := _active_enemy_intent_suppressions()
	_state.enemy_intent = EnemyIntentPlannerScript.choose_intent(
		_state.enemy_skills,
		_public_combatant(_state.enemy),
		_public_combatant(_state.player),
		_state.turn_stats,
		_state.enemy_cooldowns,
		_ai_rng,
		excluded_intent_types
	)
	_consume_enemy_intent_suppressions(excluded_intent_types)
	_state.phase = "player_action"
	_log.record("player_turn_started", {"turn": _state.turn, "drawn": drawn})
	_log.record("enemy_intent_revealed", {
		"skill_id": _state.enemy_intent.get("id", "none"),
		"intent_type": _state.enemy_intent.get("intent_type", "none"),
	})


func _execute_enemy_turn() -> void:
	_state.phase = "enemy_turn"
	_state.enemy_initial_armor_active = false
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
			_apply_damage(source_side, target_side, _with_active_damage_multiplier(effect, source_side))
		"RepeatAttack":
			for index in maxi(int(effect.get("times", 1)), 0):
				_apply_damage(source_side, target_side, _with_active_damage_multiplier(effect, source_side))
				if not is_active():
					break
		"GainArmor":
			var amount := maxi(int(effect.get("amount", 0)), 0)
			target.armor += amount
			_log.record("armor_gained", {"side": target_side, "amount": amount, "armor": target.armor})
			if source_side == "player" and target_side == "player" and not _active_player_card.is_empty():
				_try_trigger_armor_talent()
		"ModifyMorale":
			_apply_morale(target_side, int(effect.get("amount", 0)), source_side)
		"ConsumeOwnMorale":
			_apply_morale(source_side, -absi(int(effect.get("amount", 0))), source_side)
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
		"DealDamageFromArmor":
			var damage_effect := _armor_damage_effect(effect, source)
			_apply_damage(source_side, target_side, _with_active_damage_multiplier(damage_effect, source_side))
			if bool(effect.get("clear_armor_after", false)):
				var cleared := int(source.armor)
				source.armor = 0
				_log.record("armor_spent", {"side": source_side, "amount": cleared, "armor": 0})
		"ConvertArmorToDamage":
			var consume_ratio := clampf(float(effect.get("consume_ratio", 1.0)), 0.0, 1.0)
			var consumed := mini(roundi(float(source.armor) * consume_ratio), int(source.armor))
			var damage_effect := effect.duplicate(true)
			damage_effect.base_power = float(consumed) * float(effect.get("ratio", 1.0))
			source.armor -= consumed
			_log.record("armor_converted", {"side": source_side, "amount": consumed, "armor": source.armor})
			_apply_damage(source_side, target_side, _with_active_damage_multiplier(damage_effect, source_side))
		"RetaliateOnDamage":
			var reaction := {
				"base_power": float(effect.get("base_power", 0.0)),
				"uses": maxi(int(effect.get("uses", 1)), 1),
			}
			target.retaliations.append(reaction)
			target.statuses["m3.counter_stance"] = int(target.statuses.get("m3.counter_stance", 0)) + reaction.uses
			_log.record("retaliation_prepared", {"side": target_side, "base_power": reaction.base_power, "uses": reaction.uses})
		"PrepareTaggedAttack":
			var prepared := {
				"tag": effect.get("tag", ""),
				"multiplier": maxf(float(effect.get("multiplier", 1.0)), 0.0),
				"uses": maxi(int(effect.get("uses", 1)), 1),
			}
			target.prepared_attacks.append(prepared)
			var status_id := "m3.prepared_attack.%s" % prepared.tag
			target.statuses[status_id] = int(target.statuses.get(status_id, 0)) + prepared.uses
			_log.record("tagged_attack_prepared", {"side": target_side, "tag": prepared.tag, "multiplier": prepared.multiplier, "uses": prepared.uses})
		"RestoreTroops":
			var before := int(target.troops)
			target.troops = mini(before + maxi(int(effect.get("amount", 0)), 0), int(target.max_troops))
			_log.record("troops_restored", {"side": target_side, "amount": int(target.troops) - before, "troops": target.troops})
		_:
			_log.record("unsupported_effect", {"type": effect_type})
	_check_outcome()


func _apply_damage(source_side: String, target_side: String, effect: Dictionary) -> void:
	var source: Dictionary = _state[source_side]
	var target: Dictionary = _state[target_side]
	var armor_before := int(target.armor)
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
	if source_side == "player" and target_side == "enemy" and armor_before > 0 and int(target.armor) == 0:
		_try_trigger_enemy_initial_armor_broken()
	_check_outcome()
	if is_active() and source_side == "enemy" and target_side == "player" and calculated > 0:
		_trigger_retaliation()


func _apply_morale(target_side: String, amount: int, source_side: String = "") -> void:
	amount = _apply_enemy_morale_talent(target_side, amount, source_side)
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
		"name": source.get("name", source.get("id", "unknown")),
		"talent_id": source.get("talent_id", ""),
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
		"retaliations": source.get("retaliations", []).duplicate(true),
		"prepared_attacks": source.get("prepared_attacks", []).duplicate(true),
	}


func _public_combatant(combatant: Dictionary) -> Dictionary:
	return combatant.duplicate(true)


func _new_turn_stats() -> Dictionary:
	return {
		"cards_played": 0,
		"attack_cards_played": 0,
		"enemy_morale_lost": 0,
		"talent_triggers": {},
		"enemy_talent_triggers": {},
	}


func _apply_enemy_morale_talent(target_side: String, amount: int, source_side: String) -> int:
	if target_side != "enemy" or source_side != "player" or amount >= 0:
		return amount
	var talent: Dictionary = _state.get("enemy_talent", {})
	var trigger: Dictionary = talent.get("trigger", {})
	if trigger.get("type", "") != "FirstMoraleLossEachPlayerTurn":
		return amount
	var talent_id: String = talent.get("id", "")
	var counts: Dictionary = _state.turn_stats.get("enemy_talent_triggers", {})
	if int(counts.get(talent_id, 0)) >= int(trigger.get("per_turn_limit", 1)):
		return amount
	for effect in talent.get("effects", []):
		if effect.get("type", "") != "ScaleIncomingMorale":
			continue
		var original_amount := amount
		var multiplier := clampf(float(effect.get("multiplier", 1.0)), 0.0, 1.0)
		amount = -floori(float(absi(amount)) * multiplier)
		counts[talent_id] = int(counts.get(talent_id, 0)) + 1
		_log.record("enemy_talent_triggered", {
			"talent_id": talent_id,
			"trigger": trigger.get("type", ""),
			"original_amount": original_amount,
			"resolved_amount": amount,
		})
		break
	return amount


func _try_trigger_enemy_initial_armor_broken() -> void:
	if int(_state.get("enemy_initial_armor", 0)) <= 0 or not bool(_state.get("enemy_initial_armor_active", false)):
		return
	var talent: Dictionary = _state.get("enemy_talent", {})
	var trigger: Dictionary = talent.get("trigger", {})
	if trigger.get("type", "") != "InitialArmorBroken":
		return
	var talent_id: String = talent.get("id", "")
	var counts: Dictionary = _state.get("enemy_talent_battle_triggers", {})
	if int(counts.get(talent_id, 0)) >= int(trigger.get("per_battle_limit", 1)):
		return
	_state.enemy_initial_armor_active = false
	counts[talent_id] = int(counts.get(talent_id, 0)) + 1
	for effect in talent.get("effects", []):
		if effect.get("type", "") != "SuppressIntentTypeNextTurn":
			continue
		var intent_type: String = effect.get("intent_type", "")
		var duration := maxi(int(effect.get("duration", 1)), 1)
		_state.enemy_intent_suppression[intent_type] = maxi(
			int(_state.enemy_intent_suppression.get(intent_type, 0)),
			duration
		)
	_log.record("enemy_talent_triggered", {
		"talent_id": talent_id,
		"trigger": trigger.get("type", ""),
		"initial_armor": _state.enemy_initial_armor,
	})


func _active_enemy_intent_suppressions() -> Array:
	var active: Array = []
	for intent_type in _state.enemy_intent_suppression:
		if int(_state.enemy_intent_suppression[intent_type]) > 0:
			active.append(intent_type)
	return active


func _consume_enemy_intent_suppressions(intent_types: Array) -> void:
	for intent_type in intent_types:
		var remaining := maxi(int(_state.enemy_intent_suppression.get(intent_type, 0)) - 1, 0)
		if remaining == 0:
			_state.enemy_intent_suppression.erase(intent_type)
		else:
			_state.enemy_intent_suppression[intent_type] = remaining
		_log.record("enemy_intent_type_suppressed", {
			"intent_type": intent_type,
			"remaining_selections": remaining,
		})


func _try_trigger_pre_card_talent(card: Dictionary) -> void:
	var talent: Dictionary = _state.get("player_talent", {})
	if talent.is_empty() or not _talent_has_room(talent):
		return
	var trigger: Dictionary = talent.get("trigger", {})
	if trigger.get("type", "") != "FirstTaggedAttackCard":
		return
	var tags: Array = card.get("tags", [])
	if tags.has("attack") and tags.has(trigger.get("tag", "")):
		_trigger_player_talent(talent)


func _try_trigger_post_card_talent(card: Dictionary) -> void:
	var talent: Dictionary = _state.get("player_talent", {})
	if talent.is_empty() or not _talent_has_room(talent):
		return
	var trigger: Dictionary = talent.get("trigger", {})
	if trigger.get("type", "") == "NthAttackCardPlayed" and card.get("tags", []).has("attack"):
		if int(_state.turn_stats.attack_cards_played) == int(trigger.get("count", 0)):
			_trigger_player_talent(talent)


func _try_trigger_armor_talent() -> void:
	var talent: Dictionary = _state.get("player_talent", {})
	if talent.is_empty() or not _talent_has_room(talent):
		return
	if talent.get("trigger", {}).get("type", "") == "FirstArmorGainedFromCard":
		_trigger_player_talent(talent)


func _talent_has_room(talent: Dictionary) -> bool:
	var talent_id: String = talent.get("id", "")
	var counts: Dictionary = _state.turn_stats.get("talent_triggers", {})
	return int(counts.get(talent_id, 0)) < int(talent.get("trigger", {}).get("per_turn_limit", 1))


func _trigger_player_talent(talent: Dictionary) -> void:
	if not is_active():
		return
	var talent_id: String = talent.get("id", "")
	var counts: Dictionary = _state.turn_stats.talent_triggers
	counts[talent_id] = int(counts.get(talent_id, 0)) + 1
	_log.record("talent_triggered", {"talent_id": talent_id, "count": counts[talent_id]})
	for effect in talent.get("effects", []):
		_resolve_effect(effect, "player")
		if not is_active():
			break


func _with_active_damage_multiplier(effect: Dictionary, source_side: String) -> Dictionary:
	var resolved := effect.duplicate(true)
	if source_side == "player" and not _active_player_card.is_empty():
		resolved.multiplier = float(effect.get("multiplier", 1.0)) * _active_card_damage_multiplier
	return resolved


func _armor_damage_effect(effect: Dictionary, source: Dictionary) -> Dictionary:
	var resolved := effect.duplicate(true)
	resolved.base_power = float(source.armor) * float(effect.get("ratio", 1.0))
	return resolved


func _peek_prepared_attack_multiplier(card: Dictionary) -> float:
	var index := _prepared_attack_index(card)
	if index < 0:
		return 1.0
	return float(_state.player.prepared_attacks[index].get("multiplier", 1.0))


func _consume_prepared_attack_multiplier(card: Dictionary) -> float:
	var index := _prepared_attack_index(card)
	if index < 0:
		return 1.0
	var prepared: Dictionary = _state.player.prepared_attacks[index]
	var multiplier := float(prepared.get("multiplier", 1.0))
	prepared.uses = int(prepared.get("uses", 1)) - 1
	var status_id := "m3.prepared_attack.%s" % prepared.get("tag", "")
	var remaining_status := maxi(int(_state.player.statuses.get(status_id, 1)) - 1, 0)
	if remaining_status == 0:
		_state.player.statuses.erase(status_id)
	else:
		_state.player.statuses[status_id] = remaining_status
	if int(prepared.uses) <= 0:
		_state.player.prepared_attacks.remove_at(index)
	else:
		_state.player.prepared_attacks[index] = prepared
	_log.record("tagged_attack_consumed", {"tag": prepared.get("tag", ""), "multiplier": multiplier, "remaining_uses": maxi(int(prepared.uses), 0)})
	return multiplier


func _prepared_attack_index(card: Dictionary) -> int:
	if not card.get("tags", []).has("attack"):
		return -1
	for index in _state.player.prepared_attacks.size():
		if card.get("tags", []).has(_state.player.prepared_attacks[index].get("tag", "")):
			return index
	return -1


func _trigger_retaliation() -> void:
	if _state.player.retaliations.is_empty():
		return
	var reaction: Dictionary = _state.player.retaliations[0]
	reaction.uses = int(reaction.get("uses", 1)) - 1
	if int(reaction.uses) <= 0:
		_state.player.retaliations.remove_at(0)
	else:
		_state.player.retaliations[0] = reaction
	var remaining := maxi(int(_state.player.statuses.get("m3.counter_stance", 1)) - 1, 0)
	if remaining == 0:
		_state.player.statuses.erase("m3.counter_stance")
	else:
		_state.player.statuses["m3.counter_stance"] = remaining
	_log.record("retaliation_triggered", {"base_power": reaction.get("base_power", 0.0), "remaining_uses": maxi(int(reaction.uses), 0)})
	_apply_damage("player", "enemy", {"base_power": reaction.get("base_power", 0.0), "multiplier": 1.0})


func _preview_pre_card_talent(card: Dictionary, source: Dictionary, target: Dictionary) -> void:
	var talent: Dictionary = _state.get("player_talent", {})
	if talent.is_empty() or not _talent_has_room(talent):
		return
	var trigger: Dictionary = talent.get("trigger", {})
	var tags: Array = card.get("tags", [])
	if trigger.get("type", "") != "FirstTaggedAttackCard" or not tags.has("attack") or not tags.has(trigger.get("tag", "")):
		return
	for effect in talent.get("effects", []):
		if effect.get("type", "") == "ModifyDefense":
			if effect.get("target", "opponent") == "self":
				source.defense = maxf(float(source.defense) + float(effect.get("amount", 0)), 0.0)
			else:
				target.defense = maxf(float(target.defense) + float(effect.get("amount", 0)), 0.0)


func _preview_effect_list(effects: Array, source: Dictionary, target: Dictionary, card_multiplier: float) -> int:
	var total := 0
	for effect in effects:
		var effect_type: String = effect.get("type", "")
		match effect_type:
			"DealDamage":
				total += _preview_troop_damage(_preview_damage_effect(effect, card_multiplier), source, target)
			"RepeatAttack":
				for index in maxi(int(effect.get("times", 1)), 0):
					total += _preview_troop_damage(_preview_damage_effect(effect, card_multiplier), source, target)
			"ModifyDefense":
				if effect.get("target", "opponent") == "self":
					source.defense = maxf(float(source.defense) + float(effect.get("amount", 0)), 0.0)
				else:
					target.defense = maxf(float(target.defense) + float(effect.get("amount", 0)), 0.0)
			"GainArmor":
				if effect.get("target", "self") == "self":
					source.armor += maxi(int(effect.get("amount", 0)), 0)
			"ModifyMorale":
				if effect.get("target", "opponent") == "self":
					source.morale = clampi(int(source.morale) + int(effect.get("amount", 0)), 0, int(source.max_morale))
				else:
					target.morale = clampi(int(target.morale) + int(effect.get("amount", 0)), 0, int(target.max_morale))
			"ConditionalEffect":
				var evaluated := ConditionEvaluatorScript.evaluate_all(effect.get("conditions", []), {"actor": source, "target": target, "turn_stats": _state.turn_stats})
				if evaluated.passed:
					total += _preview_effect_list(effect.get("effects", []), source, target, card_multiplier)
			"DealDamageFromArmor":
				var armor_effect: Dictionary = _armor_damage_effect(effect, source)
				total += _preview_troop_damage(_preview_damage_effect(armor_effect, card_multiplier), source, target)
				if bool(effect.get("clear_armor_after", false)):
					source.armor = 0
			"ConvertArmorToDamage":
				var consume_ratio := clampf(float(effect.get("consume_ratio", 1.0)), 0.0, 1.0)
				var consumed := mini(roundi(float(source.armor) * consume_ratio), int(source.armor))
				var armor_effect: Dictionary = effect.duplicate(true)
				armor_effect.base_power = float(consumed) * float(effect.get("ratio", 1.0))
				source.armor -= consumed
				total += _preview_troop_damage(_preview_damage_effect(armor_effect, card_multiplier), source, target)
	return total


func _preview_damage_effect(effect: Dictionary, card_multiplier: float) -> Dictionary:
	var resolved := effect.duplicate(true)
	resolved.multiplier = float(effect.get("multiplier", 1.0)) * card_multiplier
	return resolved


func _preview_troop_damage(effect: Dictionary, source: Dictionary, target: Dictionary) -> int:
	var calculated := DamageCalculatorScript.preview(effect, source, target)
	var absorbed := mini(int(target.armor), calculated)
	target.armor -= absorbed
	return calculated - absorbed


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
		var enemy_id: String = request.enemy.get("id", "")
		var enemy_talent_id: String = request.enemy.get("talent_id", "")
		if enemy_talent_id.is_empty() and content_registry.has_enemy(enemy_id):
			enemy_talent_id = content_registry.get_enemy(enemy_id).get("talent_id", "")
		if not enemy_talent_id.is_empty():
			if not content_registry.has_talent(enemy_talent_id):
				errors.append("combat request references unknown enemy talent '%s'" % enemy_talent_id)
			elif content_registry.get_talent(enemy_talent_id).get("owner_enemy_id", "") != enemy_id:
				errors.append("combat request enemy talent '%s' does not belong to '%s'" % [enemy_talent_id, enemy_id])
	if request.has("player") and request.player is Dictionary:
		var player_id: String = request.player.get("id", "")
		var talent_id: String = request.player.get("talent_id", "")
		if talent_id.is_empty() and content_registry.has_general(player_id):
			talent_id = content_registry.get_general(player_id).get("talent_id", "")
		if not talent_id.is_empty():
			if not content_registry.has_talent(talent_id):
				errors.append("combat request references unknown talent '%s'" % talent_id)
			elif content_registry.get_talent(talent_id).get("owner_general_id", "") != player_id:
				errors.append("combat request talent '%s' does not belong to '%s'" % [talent_id, player_id])
	return errors


func _failure(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
