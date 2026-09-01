extends RefCounted
class_name FixedStrategyCombatRunner

const CombatControllerScript := preload("res://src/domain/combat/combat_controller.gd")
const GeneralRequestBuilderScript := preload("res://src/domain/combat/general_combat_request_builder.gd")

const DEFAULT_MAX_TURNS := 20
const MAX_CARD_PLAYS_PER_TURN := 30


static func run_battle(
	general_id: String,
	enemy_id: String,
	seed: int,
	content_registry,
	max_turns: int = DEFAULT_MAX_TURNS,
	boss_modifiers: Dictionary = {}
) -> Dictionary:
	if max_turns < 1:
		return _failure("max_turns must be at least 1", general_id, enemy_id, seed)
	if not content_registry.has_general(general_id):
		return _failure("unknown general '%s'" % general_id, general_id, enemy_id, seed)
	if not content_registry.has_enemy(enemy_id):
		return _failure("unknown enemy '%s'" % enemy_id, general_id, enemy_id, seed)
	var enemy: Dictionary = content_registry.get_enemy(enemy_id)
	var built: Dictionary = GeneralRequestBuilderScript.build(
		general_id,
		enemy,
		seed,
		content_registry,
		"m3-balance-%s-%s-%d" % [general_id, enemy_id, seed]
	)
	if not built.ok:
		return _failure(built.error, general_id, enemy_id, seed)
	built.request.boss_modifiers = boss_modifiers.duplicate(true)
	var controller = CombatControllerScript.new()
	var setup_errors: PackedStringArray = controller.setup(built.request, content_registry)
	if not setup_errors.is_empty():
		return _failure("; ".join(setup_errors), general_id, enemy_id, seed)

	var initial: Dictionary = controller.snapshot()
	var cards_played := 0
	while controller.is_active():
		cards_played += _play_fixed_strategy_turn(controller, content_registry, general_id)
		if not controller.is_active():
			break
		if int(controller.snapshot().turn) >= max_turns:
			return _build_timeout(controller, initial, general_id, enemy_id, seed, cards_played)
		var ended: Dictionary = controller.end_player_turn()
		if not ended.ok:
			return _failure(ended.reason, general_id, enemy_id, seed)
	return _build_completed(controller, initial, general_id, enemy_id, seed, cards_played)


static func run_matrix(
	general_ids: Array,
	enemy_ids: Array,
	seeds: Array,
	content_registry,
	max_turns: int = DEFAULT_MAX_TURNS
) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for general_id in general_ids:
		for enemy_id in enemy_ids:
			for seed in seeds:
				rows.append(run_battle(general_id, enemy_id, int(seed), content_registry, max_turns))
	return rows


static func _play_fixed_strategy_turn(controller, content_registry, general_id: String) -> int:
	var played := 0
	while controller.is_active() and played < MAX_CARD_PLAYS_PER_TURN:
		var state: Dictionary = controller.snapshot()
		var hand: Array = state.get("deck", {}).get("hand", [])
		var best_index := -1
		var best_score := 0
		for index in hand.size():
			var availability: Dictionary = controller.card_availability(index)
			if not availability.ok:
				continue
			var card: Dictionary = content_registry.get_card(hand[index])
			var score := _score_card(general_id, card, state, controller.preview_card_damage(index))
			if score > best_score:
				best_score = score
				best_index = index
		if best_index < 0:
			break
		var result: Dictionary = controller.play_card(best_index)
		if not result.ok:
			break
		played += 1
	return played


static func _score_card(
	general_id: String,
	card: Dictionary,
	state: Dictionary,
	preview_damage: int
) -> int:
	var card_id: String = card.get("id", "")
	if preview_damage >= int(state.enemy.troops) and preview_damage > 0:
		return 100000 + preview_damage
	var score := 0
	match general_id:
		"general.zhao_lie":
			score = _score_zhao_lie(card_id, state)
		"general.zhou_jing":
			score = _score_zhou_jing(card_id, state)
		"general.han_yue":
			score = _score_han_yue(card_id, state)
	if card.get("tags", []).has("attack"):
		score += preview_damage
	return score


static func _score_zhao_lie(card_id: String, state: Dictionary) -> int:
	var priorities := {
		"card.public.general.change_orders": 1200,
		"card.public.cavalry.harass": 1100,
		"card.public.morale.feint": 1050,
		"card.general.zhao_lie.lone_breakthrough": 1000,
		"card.public.morale.press_advantage": 950,
		"card.public.morale.war_cry": 900,
		"card.public.cavalry.charge": 850,
		"card.public.general.assault": 800,
		"card.public.general.guard": 520 if _enemy_intends_damage(state) else 180,
		"card.public.general.inspire": 650 if int(state.player.morale) <= 60 else 80,
	}
	return int(priorities.get(card_id, 0))


static func _score_zhou_jing(card_id: String, state: Dictionary) -> int:
	var hand: Array = state.get("deck", {}).get("hand", [])
	var has_armor_payoff: bool = (
		hand.has("card.general.zhou_jing.delayed_strike")
		or hand.has("card.public.defense.turn_defense_to_offense")
	)
	var building_combo: bool = int(state.player.armor) < 80 and has_armor_payoff
	var under_attack: bool = _enemy_intends_damage(state)
	var priorities := {
		"card.public.general.change_orders": 1200,
		"card.general.zhou_jing.delayed_strike": 1120,
		"card.public.defense.turn_defense_to_offense": 1080,
		"card.public.defense.shield_wall": 1040 if building_combo else (860 if under_attack else 180),
		"card.public.defense.counter_stance": 1000 if building_combo else (920 if under_attack else 220),
		"card.public.general.guard": 940 if building_combo else (820 if under_attack else 160),
		"card.public.general.assault": 700,
		"card.public.morale.feint": 650,
		"card.public.general.inspire": 620 if int(state.player.morale) <= 65 else 70,
	}
	return int(priorities.get(card_id, 0))


static func _score_han_yue(card_id: String, state: Dictionary) -> int:
	var already_prepared: bool = not state.player.get("prepared_attacks", []).is_empty()
	var priorities := {
		"card.public.general.change_orders": 1200,
		"card.public.archery.prepared_volley": 1140 if not already_prepared else 540,
		"card.general.han_yue.formation_breaking_crossbow": 1100,
		"card.public.archery.armor_piercing_arrow": 1050,
		"card.public.archery.repeating_crossbow": 1000,
		"card.public.morale.feint": 900,
		"card.public.morale.war_cry": 850,
		"card.public.general.assault": 800,
		"card.public.general.guard": 600 if _enemy_intends_damage(state) else 180,
		"card.public.general.inspire": 650 if int(state.player.morale) <= 60 else 80,
	}
	return int(priorities.get(card_id, 0))


static func _enemy_intends_damage(state: Dictionary) -> bool:
	for effect in state.get("enemy_intent", {}).get("effects", []):
		if effect.get("type", "") in ["DealDamage", "RepeatAttack"]:
			return true
	return false


static func _build_completed(
	controller,
	initial: Dictionary,
	general_id: String,
	enemy_id: String,
	seed: int,
	cards_played: int
) -> Dictionary:
	var result: Dictionary = controller.result()
	return _with_statistics(result, controller, initial, general_id, enemy_id, seed, cards_played, false)


static func _build_timeout(
	controller,
	initial: Dictionary,
	general_id: String,
	enemy_id: String,
	seed: int,
	cards_played: int
) -> Dictionary:
	var state: Dictionary = controller.snapshot()
	var result := {
		"status": "timeout",
		"reason": "turn_limit_reached",
		"turns": int(state.turn),
		"player_remaining_troops": int(state.player.troops),
		"player_remaining_morale": int(state.player.morale),
		"enemy_remaining_troops": int(state.enemy.troops),
		"enemy_remaining_morale": int(state.enemy.morale),
	}
	return _with_statistics(result, controller, initial, general_id, enemy_id, seed, cards_played, true)


static func _with_statistics(
	result: Dictionary,
	controller,
	initial: Dictionary,
	general_id: String,
	enemy_id: String,
	seed: int,
	cards_played: int,
	timed_out: bool
) -> Dictionary:
	var row := result.duplicate(true)
	row.general_id = general_id
	row.enemy_id = enemy_id
	row.seed = seed
	row.timed_out = timed_out
	row.cards_played = cards_played
	row.player_troops_lost = maxi(int(initial.player.troops) - int(row.player_remaining_troops), 0)
	row.player_morale_lost = maxi(int(initial.player.morale) - int(row.player_remaining_morale), 0)
	row.enemy_troops_lost = maxi(int(initial.enemy.troops) - int(row.enemy_remaining_troops), 0)
	row.enemy_morale_lost = maxi(int(initial.enemy.morale) - int(row.enemy_remaining_morale), 0)
	row.player_talent_triggers = _event_count(controller.event_log(), "talent_triggered")
	row.enemy_talent_triggers = _event_count(controller.event_log(), "enemy_talent_triggered")
	return row


static func _event_count(events: Array[Dictionary], event_type: String) -> int:
	var count := 0
	for event in events:
		if event.get("type", "") == event_type:
			count += 1
	return count


static func _failure(reason: String, general_id: String, enemy_id: String, seed: int) -> Dictionary:
	return {
		"status": "setup_error",
		"reason": reason,
		"general_id": general_id,
		"enemy_id": enemy_id,
		"seed": seed,
		"timed_out": false,
	}
