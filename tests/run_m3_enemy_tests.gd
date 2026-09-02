extends SceneTree

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")
const CombatControllerScript := preload("res://src/domain/combat/combat_controller.gd")
const GeneralRequestBuilderScript := preload("res://src/domain/combat/general_combat_request_builder.gd")
const ConditionEvaluatorScript := preload("res://src/domain/combat/condition_evaluator.gd")

const PRODUCTION_ENEMIES := [
	"enemy.normal.patrol_inspector",
	"enemy.normal.local_militia",
	"enemy.normal.city_defenders",
	"enemy.normal.crossbow_company",
	"enemy.normal.overseer_unit",
	"enemy.elite.gao_wu",
	"enemy.elite.he_wei",
]
const ELITE_TALENTS := {
	"enemy.elite.gao_wu": "talent.gao_wu.discipline",
	"enemy.elite.he_wei": "talent.he_wei.black_armor",
}

var _passed := 0
var _failed := 0
var _registry


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_registry = ContentRegistryScript.new()
	_assert_true(_registry.load_all(), "M3 enemy content registry loads")
	_test_enemy_content_contracts()
	_test_enemy_intents_are_seeded_and_visible()
	_test_normal_enemy_effect_families_execute()
	_test_gao_wu_first_morale_loss_is_halved_each_turn()
	_test_he_wei_armor_break_opens_one_selection_window()
	_test_he_wei_natural_armor_clear_does_not_trigger()
	_test_enemy_talent_ownership_failure()
	_test_invalid_enemy_contract_fails_readably()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_enemy_content_contracts() -> void:
	_assert_equal(_registry.enemy_count(), 18, "M3 enemies coexist with the nine M6 Rogue enemies")
	for enemy_id in PRODUCTION_ENEMIES:
		_assert_true(_registry.has_enemy(enemy_id), "%s is registered" % enemy_id)
		var enemy: Dictionary = _registry.get_enemy(enemy_id)
		_assert_true(_registry.validate_enemy_definition(enemy, enemy_id).is_empty(), "%s satisfies the production enemy contract" % enemy_id)
		_assert_true(enemy.skills.size() >= 3, "%s exposes at least three readable intentions" % enemy_id)
		_assert_true(_all_skill_conditions_have_a_valid_path(enemy), "%s skill conditions have a supported path" % enemy_id)
		_assert_true(_all_effects_avoid_hard_immunity(enemy), "%s uses soft counters rather than Build immunity" % enemy_id)
	for enemy_id in ELITE_TALENTS:
		var enemy: Dictionary = _registry.get_enemy(enemy_id)
		var talent_id: String = ELITE_TALENTS[enemy_id]
		_assert_equal(enemy.talent_id, talent_id, "%s references its approved elite talent" % enemy_id)
		var talent: Dictionary = _registry.get_talent(talent_id)
		_assert_equal(talent.owner_enemy_id, enemy_id, "%s talent ownership resolves" % enemy_id)
		_assert_true(_registry.validate_talent_definition(talent, talent_id).is_empty(), "%s satisfies the enemy talent contract" % talent_id)


func _test_enemy_intents_are_seeded_and_visible() -> void:
	for enemy_id in PRODUCTION_ENEMIES:
		var first = _controller(enemy_id, ["card.public.general.guard"], 2301, 3, 1)
		var second = _controller(enemy_id, ["card.public.general.guard"], 2301, 3, 1)
		var first_intent: Dictionary = first.snapshot().enemy_intent
		var second_intent: Dictionary = second.snapshot().enemy_intent
		_assert_true(not first_intent.is_empty(), "%s reveals an eligible opening intent" % enemy_id)
		_assert_equal(first_intent.get("id", ""), second_intent.get("id", ""), "%s intent selection is deterministic for a fixed seed" % enemy_id)
		_assert_true(["attack", "defend", "disrupt", "recover"].has(first_intent.get("intent_type", "")), "%s exposes a recognized intent type" % enemy_id)


func _test_normal_enemy_effect_families_execute() -> void:
	var crossbow: Dictionary = _registry.get_enemy("enemy.normal.crossbow_company")
	crossbow.skills = [crossbow.skills[1]]
	var attacker = _controller_from_enemy(crossbow, ["card.public.general.guard"], 2310, 3, 1)
	var troops_before := int(attacker.snapshot().player.troops)
	attacker.end_player_turn()
	_assert_true(int(attacker.snapshot().player.troops) < troops_before, "crossbow company executes its revealed attack against the player")
	_assert_equal(_event_count(attacker, "damage_dealt"), 2, "crossbow barrage resolves as two visible damage events")

	var patrol: Dictionary = _registry.get_enemy("enemy.normal.patrol_inspector")
	patrol.skills = [patrol.skills[2]]
	var disruptor = _controller_from_enemy(patrol, ["card.public.general.guard"], 2311, 3, 1)
	disruptor.end_player_turn()
	_assert_equal(disruptor.snapshot().player.morale, 71, "patrol inspector executes its seven-point morale disruption")

	var defender: Dictionary = _registry.get_enemy("enemy.normal.city_defenders")
	defender.skills = [defender.skills[1]]
	var guard = _controller_from_enemy(defender, ["card.public.general.guard"], 2312, 3, 1)
	guard.end_player_turn()
	_assert_equal(guard.snapshot().enemy.armor, 70, "city defenders execute their visible defense intent")

	var overseer: Dictionary = _registry.get_enemy("enemy.normal.overseer_unit")
	overseer.morale = 50
	overseer.skills = [overseer.skills[2]]
	var recovery = _controller_from_enemy(overseer, ["card.public.general.guard"], 2313, 3, 1)
	recovery.end_player_turn()
	_assert_equal(recovery.snapshot().enemy.morale, 64, "overseer recovery restores fourteen morale when its condition is met")
	_assert_equal(recovery.snapshot().enemy.armor, 25, "overseer recovery also grants its configured armor")


func _test_gao_wu_first_morale_loss_is_halved_each_turn() -> void:
	var deck := [
		"card.public.morale.feint",
		"card.public.morale.feint",
		"card.public.morale.feint",
		"card.public.morale.feint",
	]
	var controller = _controller("enemy.elite.gao_wu", deck, 2302, 3, 2)
	_play(controller, "card.public.morale.feint")
	_assert_equal(controller.snapshot().enemy.morale, 87, "Gao Wu floors the first seven-point morale loss to three")
	_play(controller, "card.public.morale.feint")
	_assert_equal(controller.snapshot().enemy.morale, 80, "Gao Wu takes subsequent morale loss normally in the same turn")
	_assert_equal(_event_count(controller, "enemy_talent_triggered"), 1, "Gao Wu discipline triggers once in one player turn")
	controller.end_player_turn()
	_play(controller, "card.public.morale.feint")
	_assert_equal(controller.snapshot().enemy.morale, 77, "Gao Wu discipline resets on the next player turn")
	_assert_equal(_event_count(controller, "enemy_talent_triggered"), 2, "Gao Wu reset produces a second logged trigger")


func _test_he_wei_armor_break_opens_one_selection_window() -> void:
	var deck := ["card.public.general.assault", "card.public.general.assault", "card.public.general.assault"]
	var controller = _controller("enemy.elite.he_wei", deck, 2303, 3, 3)
	var opening_intent: Dictionary = controller.snapshot().enemy_intent.duplicate(true)
	for index in 3:
		_play(controller, "card.public.general.assault")
	var broken: Dictionary = controller.snapshot()
	_assert_equal(broken.enemy.armor, 0, "three sixty-damage assaults break He Wei's initial black armor")
	_assert_equal(broken.enemy_intent.get("id", ""), opening_intent.get("id", ""), "breaking armor does not rewrite the already revealed intent")
	_assert_equal(_event_count(controller, "enemy_talent_triggered"), 1, "He Wei black armor triggers once when the initial armor breaks")
	controller.end_player_turn()
	var next_turn: Dictionary = controller.snapshot()
	_assert_true(next_turn.enemy_intent.get("intent_type", "") != "defend", "He Wei next selected intent excludes defense")
	_assert_equal(_event_count(controller, "enemy_intent_type_suppressed"), 1, "the one-selection defense suppression is logged")
	_assert_true(next_turn.enemy_intent_suppression.is_empty(), "He Wei suppression is consumed after one intent selection")
	_assert_true(_skill_pool_has_intent(next_turn.enemy_skills, "defend"), "He Wei defense skill remains in the restored skill pool")


func _test_he_wei_natural_armor_clear_does_not_trigger() -> void:
	var he_wei: Dictionary = _registry.get_enemy("enemy.elite.he_wei")
	he_wei.skills = [he_wei.skills[1]]
	var deck := ["card.public.general.assault", "card.public.general.assault", "card.public.general.assault"]
	var controller = _controller_from_enemy(he_wei, deck, 2304, 3, 3)
	controller.end_player_turn()
	_assert_equal(_event_count(controller, "enemy_talent_triggered"), 0, "enemy-turn armor reset does not fake a black armor break")
	_assert_equal(_event_count(controller, "enemy_intent_type_suppressed"), 0, "natural armor reset does not suppress an intent")
	_assert_equal(controller.snapshot().enemy.armor, 90, "He Wei can gain ordinary defense armor after the initial armor expires")
	_play(controller, "card.public.general.assault")
	_play(controller, "card.public.general.assault")
	_assert_equal(controller.snapshot().enemy.armor, 0, "later defense armor can still be broken normally")
	_assert_equal(_event_count(controller, "enemy_talent_triggered"), 0, "breaking later defense armor cannot reactivate black armor")


func _test_enemy_talent_ownership_failure() -> void:
	var enemy: Dictionary = _registry.get_enemy("enemy.elite.gao_wu")
	enemy.talent_id = "talent.he_wei.black_armor"
	var built: Dictionary = GeneralRequestBuilderScript.build("general.zhao_lie", enemy, 2305, _registry, "m3-enemy-owner-test")
	var controller = CombatControllerScript.new()
	var errors := controller.setup(built.request, _registry)
	_assert_true(_contains_text(errors, "does not belong"), "combat rejects an elite talent owned by another enemy")


func _test_invalid_enemy_contract_fails_readably() -> void:
	var enemy: Dictionary = _registry.get_enemy("enemy.normal.patrol_inspector")
	enemy.presentation.description = ""
	enemy.skills[0].intent_type = "immune_to_build"
	var errors: PackedStringArray = _registry.validate_enemy_definition(enemy, "invalid.enemy")
	_assert_true(_contains_text(errors, "presentation.description"), "production enemy without readable presentation is rejected")
	_assert_true(_contains_text(errors, "unsupported intent_type"), "unsupported enemy intent is rejected")


func _controller(enemy_id: String, deck: Array, seed: int, action_points: int, draw_count: int):
	var enemy: Dictionary = _registry.get_enemy(enemy_id)
	return _controller_from_enemy(enemy, deck, seed, action_points, draw_count)


func _controller_from_enemy(enemy: Dictionary, deck: Array, seed: int, action_points: int, draw_count: int):
	var built: Dictionary = GeneralRequestBuilderScript.build("general.zhao_lie", enemy, seed, _registry, "m3-enemy-test")
	var request: Dictionary = built.request
	request.deck = deck.duplicate()
	request.starting_action_points = action_points
	request.draw_count = draw_count
	var controller = CombatControllerScript.new()
	var errors := controller.setup(request, _registry)
	_assert_true(errors.is_empty(), "%s runtime request passes validation" % enemy.get("id", "unknown"))
	return controller


func _play(controller, card_id: String) -> void:
	var index: int = controller.snapshot().deck.hand.find(card_id)
	_assert_true(index >= 0, "%s is present in hand" % card_id)
	if index < 0:
		return
	var result: Dictionary = controller.play_card(index)
	_assert_true(result.ok, "%s plays successfully" % card_id)


func _all_skill_conditions_have_a_valid_path(enemy: Dictionary) -> bool:
	var context := {
		"actor": {"morale": 0, "troops": 1, "max_troops": 100, "armor": 999, "defense": 0, "army_composition": {"infantry": 1.0, "archer": 1.0, "cavalry": 1.0}, "statuses": {}},
		"target": {"morale": 0, "defense": 0, "statuses": {}},
		"turn_stats": {"cards_played": 99, "attack_cards_played": 99, "enemy_morale_lost": 99},
	}
	for skill in enemy.skills:
		if not ConditionEvaluatorScript.evaluate_all(skill.get("conditions", []), context).passed:
			return false
	return true


func _all_effects_avoid_hard_immunity(enemy: Dictionary) -> bool:
	for skill in enemy.skills:
		for effect in skill.get("effects", []):
			if "Immune" in String(effect.get("type", "")) or effect.has("immune_build"):
				return false
	return true


func _skill_pool_has_intent(skills: Array, intent_type: String) -> bool:
	for skill in skills:
		if skill.get("intent_type", "") == intent_type:
			return true
	return false


func _event_count(controller, event_type: String) -> int:
	var count := 0
	for event in controller.event_log():
		if event.get("type", "") == event_type:
			count += 1
	return count


func _contains_text(values: PackedStringArray, needle: String) -> bool:
	for value in values:
		if needle in value:
			return true
	return false


func _assert_true(value: bool, message: String) -> void:
	if value:
		_passed += 1
		print("TEST PASS: %s" % message)
	else:
		_failed += 1
		push_error("TEST FAIL: %s" % message)


func _assert_equal(actual, expected, message: String) -> void:
	if actual == expected:
		_passed += 1
		print("TEST PASS: %s" % message)
	else:
		_failed += 1
		push_error("TEST FAIL: %s (expected=%s, actual=%s)" % [message, str(expected), str(actual)])
