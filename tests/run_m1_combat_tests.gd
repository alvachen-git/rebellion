extends SceneTree

const ContentRegistryScript = preload("res://src/domain/content/content_registry.gd")
const DeterministicRngScript = preload("res://src/domain/random/deterministic_rng.gd")
const DamageCalculatorScript = preload("res://src/domain/combat/damage_calculator.gd")
const DeckStateScript = preload("res://src/domain/combat/deck_state.gd")
const CombatControllerScript = preload("res://src/domain/combat/combat_controller.gd")

var _passed = 0
var _failed = 0
var _registry


func _init() -> void:
	_registry = ContentRegistryScript.new()
	_assert_true(_registry.load_all(), "M1 content registry loads")
	_run_all()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _run_all() -> void:
	_test_damage_formula_and_armor_order()
	_test_deck_draw_discard_reshuffle_and_exhaust()
	_test_combat_setup_reveals_intent()
	_test_card_condition_reports_reason()
	_test_attack_card_spends_ap_and_deals_previewed_damage()
	_test_morale_does_not_passively_change_damage()
	_test_armor_absorbs_after_defense_and_clears_next_turn()
	_test_morale_victory()
	_test_troops_zero_always_kills_general()
	_test_morale_zero_has_death_and_injury_branches()
	_test_retreat_guarantees_survival()
	_test_tactical_cycle_effects()
	_test_composite_effects_and_exhaust()
	_test_ai_intent_is_independent_from_future_hand()
	_test_same_seed_reproduces_event_log()


func _test_damage_formula_and_armor_order() -> void:
	_assert_equal(DamageCalculatorScript.calculate(100, 50, 50), 100, "damage uses attack scaling then diminishing defense")
	_assert_equal(DamageCalculatorScript.calculate(100, 0, -50), 100, "defense is clamped at zero")


func _test_deck_draw_discard_reshuffle_and_exhaust() -> void:
	var deck = DeckStateScript.new()
	deck.setup(["a", "b"], DeterministicRngScript.new(5))
	_assert_equal(deck.draw(5).size(), 2, "draw stops when all piles are empty")
	deck.play_from_hand(0, true)
	deck.discard_hand()
	_assert_equal(deck.exhaust_pile.size(), 1, "exhausted card leaves the discard cycle")
	_assert_equal(deck.draw(2).size(), 1, "discard pile reshuffles when draw pile is empty")


func _test_combat_setup_reveals_intent() -> void:
	var controller = _new_controller(_base_request(_standard_deck(), 101))
	var state = controller.snapshot()
	_assert_equal(state.phase, "player_action", "battle enters player action phase")
	_assert_equal(state.turn, 1, "battle begins on turn one")
	_assert_equal(state.deck.hand.size(), 5, "battle draws five opening cards")
	_assert_true(not state.enemy_intent.is_empty(), "enemy intent is revealed before player acts")


func _test_card_condition_reports_reason() -> void:
	var request = _base_request(["dev.m0_validation_sample"], 13)
	request.player.army_composition.cavalry = 0.1
	var controller = _new_controller(request)
	var availability = controller.card_availability(0)
	_assert_true(not availability.ok, "army threshold blocks an ineligible card")
	_assert_true("20%" in availability.reason, "blocked card reports its army threshold")


func _test_attack_card_spends_ap_and_deals_previewed_damage() -> void:
	var controller = _new_controller(_base_request(["dev.basic_attack"], 3))
	var preview = controller.preview_card_damage(0)
	var before = controller.snapshot().enemy.troops
	var before_morale = controller.snapshot().enemy.morale
	var played = controller.play_card(0)
	var after = controller.snapshot()
	_assert_true(played.ok, "valid attack card can be played")
	_assert_equal(before - after.enemy.troops, preview, "preview and actual troop damage share one calculator")
	_assert_equal(after.enemy.morale, before_morale, "ordinary troop damage does not reduce morale")
	_assert_equal(after.action_points, 2, "card cost is deducted from action points")


func _test_morale_does_not_passively_change_damage() -> void:
	var high_request = _base_request(["dev.basic_attack"], 4)
	var low_request = _base_request(["dev.basic_attack"], 4)
	low_request.player.morale = 10
	var high_preview = _new_controller(high_request).preview_card_damage(0)
	var low_preview = _new_controller(low_request).preview_card_damage(0)
	_assert_equal(low_preview, high_preview, "morale level does not automatically modify attack damage")


func _test_armor_absorbs_after_defense_and_clears_next_turn() -> void:
	var request = _base_request(["dev.guard"], 9)
	request.enemy.skills = [_attack_skill(45)]
	var controller = _new_controller(request)
	controller.play_card(0)
	var before_troops = controller.snapshot().player.troops
	controller.end_player_turn()
	var after = controller.snapshot()
	_assert_equal(before_troops - after.player.troops, 5, "armor absorbs damage after defense calculation")
	_assert_equal(after.player.armor, 0, "player armor clears at next player turn start")


func _test_morale_victory() -> void:
	var request = _base_request(["dev.demoralize", "dev.demoralize"], 18)
	request.enemy.morale = 50
	var controller = _new_controller(request)
	controller.play_card(_hand_index(controller, "dev.demoralize"))
	controller.play_card(_hand_index(controller, "dev.demoralize"))
	_assert_equal(controller.result().status, "victory", "enemy morale zero produces victory")
	_assert_equal(controller.result().reason, "enemy_morale_zero", "morale victory has an explicit reason")


func _test_troops_zero_always_kills_general() -> void:
	var request = _base_request(["dev.guard"], 21)
	request.player.troops = 10
	request.player.is_player_character = true
	request.enemy.skills = [_attack_skill(1000)]
	var controller = _new_controller(request)
	controller.end_player_turn()
	var result = controller.result()
	_assert_true(result.general_died, "troops zero always kills the general")
	_assert_true(result.game_over, "player character death produces game over")


func _test_morale_zero_has_death_and_injury_branches() -> void:
	var found_death = false
	var found_injury = false
	for seed in 200:
		var request = _base_request(["dev.guard"], seed)
		request.enemy.skills = [_morale_skill(-100)]
		var controller = _new_controller(request)
		controller.end_player_turn()
		found_death = found_death or bool(controller.result().general_died)
		found_injury = found_injury or bool(controller.result().general_injured)
		if found_death and found_injury:
			break
	_assert_true(found_death, "morale collapse deterministic rolls include the 20% death branch")
	_assert_true(found_injury, "morale collapse deterministic rolls include the 80% injury branch")


func _test_retreat_guarantees_survival() -> void:
	var controller = _new_controller(_base_request(["dev.guard"], 32))
	var retreated = controller.retreat()
	_assert_true(retreated.ok, "retreat is accepted during player action")
	_assert_equal(retreated.result.status, "retreated", "retreat has a distinct result status")
	_assert_true(not retreated.result.general_died and not retreated.result.general_injured, "retreat guarantees general survival")


func _test_tactical_cycle_effects() -> void:
	var controller = _new_controller(_base_request(["dev.tactical_cycle", "dev.basic_attack"], 45))
	var index = _hand_index(controller, "dev.tactical_cycle")
	var before = controller.snapshot()
	controller.play_card(index)
	var after = controller.snapshot()
	_assert_equal(after.player.morale, before.player.morale - 5, "ConsumeOwnMorale reduces player morale")
	_assert_equal(after.action_points, before.action_points, "cycle refunds its spent action point")
	_assert_equal(after.deck.hand.size(), before.deck.hand.size(), "cycle draws a replacement card")


func _test_composite_effects_and_exhaust() -> void:
	var controller = _new_controller(_base_request(["dev.effect_matrix"], 55))
	var before = controller.snapshot()
	controller.play_card(0)
	var after = controller.snapshot()
	_assert_true(after.player.statuses.has("dev.prepared"), "ApplyStatus records the status")
	_assert_equal(after.enemy.defense, before.enemy.defense - 5, "conditional nested effect modifies defense")
	_assert_true(after.enemy.troops < before.enemy.troops, "RepeatAttack deals multiple troop hits")
	_assert_equal(after.deck.exhaust_pile, ["dev.effect_matrix"], "exhaust card leaves combat deck cycle")


func _test_ai_intent_is_independent_from_future_hand() -> void:
	var first_request = _base_request(["dev.basic_attack", "dev.basic_attack"], 88)
	var second_request = _base_request(["dev.guard", "dev.demoralize", "dev.tactical_cycle"], 88)
	var first = _new_controller(first_request).snapshot().enemy_intent.id
	var second = _new_controller(second_request).snapshot().enemy_intent.id
	_assert_equal(first, second, "AI intent RNG is isolated from deck shuffle and future hand")


func _test_same_seed_reproduces_event_log() -> void:
	var request = _base_request(_standard_deck(), 144)
	var first = _new_controller(request)
	var second = _new_controller(request)
	first.end_player_turn()
	second.end_player_turn()
	_assert_equal(first.event_log(), second.event_log(), "same request and seed reproduce the event log")


func _new_controller(request: Dictionary):
	var controller = CombatControllerScript.new()
	var errors = controller.setup(request, _registry)
	_assert_true(errors.is_empty(), "combat request passes validation")
	return controller


func _base_request(deck: Array, seed: int) -> Dictionary:
	var enemy: Dictionary = _registry.get_enemy("dev.baseline_enemy")
	return {
		"battle_id": "m1-test",
		"seed": seed,
		"player": {
			"id": "dev.player_general",
			"is_player_character": false,
			"troops": 1000,
			"max_troops": 1000,
			"morale": 100,
			"max_morale": 100,
			"attack": 25,
			"defense": 20,
			"army_composition": {"infantry": 0.4, "archer": 0.2, "cavalry": 0.4},
		},
		"enemy": enemy,
		"deck": deck,
	}


func _standard_deck() -> Array:
	return [
		"dev.basic_attack",
		"dev.guard",
		"dev.demoralize",
		"dev.tactical_cycle",
		"dev.effect_matrix",
	]


func _attack_skill(base_power: int) -> Dictionary:
	return {
		"id": "test.attack",
		"intent_type": "attack",
		"weight": 1,
		"conditions": [],
		"effects": [{"type": "DealDamage", "base_power": base_power, "target": "opponent"}],
	}


func _morale_skill(amount: int) -> Dictionary:
	return {
		"id": "test.morale",
		"intent_type": "disrupt",
		"weight": 1,
		"conditions": [],
		"effects": [{"type": "ModifyMorale", "amount": amount, "target": "opponent"}],
	}


func _hand_index(controller, card_id: String) -> int:
	return controller.snapshot().deck.hand.find(card_id)


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
