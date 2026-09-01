extends SceneTree

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")
const CombatControllerScript := preload("res://src/domain/combat/combat_controller.gd")
const GeneralRequestBuilderScript := preload("res://src/domain/combat/general_combat_request_builder.gd")

var _passed := 0
var _failed := 0
var _registry


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_registry = ContentRegistryScript.new()
	_assert_true(_registry.load_all(), "M3 runtime content registry loads")
	_test_general_request_builder()
	_test_zhao_lie_talent_boundary_and_turn_limit()
	_test_zhou_jing_talent_boundary_and_turn_reset()
	_test_han_yue_talent_boundary_and_turn_reset()
	_test_counter_stance_retaliates_after_enemy_attack()
	_test_armor_conversion_preview_matches_resolution()
	_test_armor_damage_can_retain_armor()
	_test_prepared_volley_buffs_every_hit_and_consumes_once()
	_test_restore_troops_caps_at_maximum()
	_test_talent_ownership_is_validated()
	_test_fixed_seed_zhao_lie_identity_turn()
	_test_fixed_seed_zhou_jing_identity_turn()
	_test_fixed_seed_han_yue_identity_turn()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_general_request_builder() -> void:
	var built: Dictionary = GeneralRequestBuilderScript.build("general.zhao_lie", _enemy(), 1501, _registry)
	_assert_true(built.ok, "general request builder accepts a registered general")
	_assert_equal(built.request.player.talent_id, "talent.zhao_lie.break_formation", "builder carries the general talent into combat")
	_assert_equal(built.request.deck.size(), 20, "builder carries the approved twenty-card deck")
	var missing: Dictionary = GeneralRequestBuilderScript.build("general.missing", _enemy(), 1501, _registry)
	_assert_true(not missing.ok and "找不到武将" in missing.error, "builder rejects an unknown general readably")


func _test_zhao_lie_talent_boundary_and_turn_limit() -> void:
	var deck: Array = []
	for index in 6:
		deck.append("card.public.general.assault")
	var controller = _controller("general.zhao_lie", deck, 1510, _enemy(0), 10, 6)
	_play(controller, "card.public.general.assault")
	_play(controller, "card.public.general.assault")
	_assert_equal(controller.snapshot().action_points, 8, "Zhao Lie does not refund action before the third attack")
	_assert_equal(_event_count(controller, "talent_triggered"), 0, "Zhao Lie talent has not triggered after two attacks")
	_play(controller, "card.public.general.assault")
	_assert_equal(controller.snapshot().action_points, 8, "Zhao Lie third attack refunds exactly one action point")
	for index in 3:
		_play(controller, "card.public.general.assault")
	_assert_equal(controller.snapshot().action_points, 5, "Zhao Lie cannot refund again on the sixth attack in one turn")
	_assert_equal(_event_count(controller, "talent_triggered"), 1, "Zhao Lie talent triggers at most once per turn")
	controller.end_player_turn()
	for index in 3:
		_play(controller, "card.public.general.assault")
	_assert_equal(_event_count(controller, "talent_triggered"), 2, "Zhao Lie talent limit resets next turn")


func _test_zhou_jing_talent_boundary_and_turn_reset() -> void:
	var deck := ["card.public.general.guard", "card.public.general.guard"]
	var controller = _controller("general.zhou_jing", deck, 1511, _enemy(0), 4, 2)
	_assert_equal(controller.snapshot().player.armor, 0, "Zhou Jing has no passive armor before playing a card")
	_play(controller, "card.public.general.guard")
	_assert_equal(controller.snapshot().player.armor, 95, "Zhou Jing first armor card gains the extra forty armor")
	_play(controller, "card.public.general.guard")
	_assert_equal(controller.snapshot().player.armor, 150, "Zhou Jing second armor card does not gain the talent bonus again")
	_assert_equal(_event_count(controller, "talent_triggered"), 1, "Zhou Jing talent triggers once in the turn")
	controller.end_player_turn()
	_play(controller, "card.public.general.guard")
	_assert_equal(controller.snapshot().player.armor, 95, "Zhou Jing first armor card triggers again next turn")
	_assert_equal(_event_count(controller, "talent_triggered"), 2, "Zhou Jing talent reset is logged")


func _test_han_yue_talent_boundary_and_turn_reset() -> void:
	var deck := ["card.public.archery.armor_piercing_arrow", "card.public.archery.armor_piercing_arrow"]
	var controller = _controller("general.han_yue", deck, 1512, _enemy(0, 50), 4, 2)
	var before: Dictionary = controller.snapshot()
	var first_index := _hand_index(controller, "card.public.archery.armor_piercing_arrow")
	var first_preview: int = controller.preview_card_damage(first_index)
	_play(controller, "card.public.archery.armor_piercing_arrow")
	var after_first: Dictionary = controller.snapshot()
	_assert_equal(after_first.enemy.defense, 40.0, "Han Yue first archery attack applies talent break and card break before damage")
	_assert_equal(int(before.enemy.troops) - int(after_first.enemy.troops), first_preview, "Han Yue preview includes talent and card defense reduction")
	_play(controller, "card.public.archery.armor_piercing_arrow")
	_assert_equal(controller.snapshot().enemy.defense, 34.0, "Han Yue second archery card only applies its own defense reduction")
	_assert_equal(_event_count(controller, "talent_triggered"), 1, "Han Yue talent triggers once in the turn")
	controller.end_player_turn()
	_play(controller, "card.public.archery.armor_piercing_arrow")
	_assert_equal(controller.snapshot().enemy.defense, 24.0, "Han Yue talent resets and remains persistent next turn")


func _test_counter_stance_retaliates_after_enemy_attack() -> void:
	var controller = _controller("general.zhou_jing", ["card.public.defense.counter_stance"], 1513, _enemy(100), 3, 1)
	_play(controller, "card.public.defense.counter_stance")
	var before: Dictionary = controller.snapshot()
	_assert_equal(before.player.armor, 70, "counter stance includes Zhou Jing first-armor talent bonus")
	_assert_equal(before.player.retaliations.size(), 1, "counter stance arms one retaliation")
	controller.end_player_turn()
	var after: Dictionary = controller.snapshot()
	_assert_equal(int(before.player.troops) - int(after.player.troops), 5, "enemy attack resolves against defense and armor before retaliation")
	_assert_equal(int(before.enemy.troops) - int(after.enemy.troops), 67, "retaliation deals player-scaled damage after the enemy attack")
	_assert_true(after.player.retaliations.is_empty(), "one-use retaliation is consumed")
	_assert_true(not after.player.statuses.has("m3.counter_stance"), "retaliation status is removed after use")


func _test_armor_conversion_preview_matches_resolution() -> void:
	var deck := ["card.public.general.guard", "card.public.defense.turn_defense_to_offense"]
	var armored_enemy := _enemy(0)
	armored_enemy.armor = 50
	var controller = _controller("general.zhou_jing", deck, 1514, armored_enemy, 5, 2)
	_play(controller, "card.public.general.guard")
	var index := _hand_index(controller, "card.public.defense.turn_defense_to_offense")
	var preview: int = controller.preview_card_damage(index)
	var before: Dictionary = controller.snapshot()
	_play(controller, "card.public.defense.turn_defense_to_offense")
	var after: Dictionary = controller.snapshot()
	_assert_true(preview > 0, "armor conversion exposes a positive preview")
	_assert_equal(int(before.enemy.troops) - int(after.enemy.troops), preview, "armor conversion preview includes enemy armor and matches actual troop damage")
	_assert_equal(after.enemy.armor, 0, "enemy armor is absorbed in the same order used by preview")
	_assert_equal(after.player.armor, 0, "base armor conversion consumes all current armor")


func _test_armor_damage_can_retain_armor() -> void:
	var deck := ["card.public.general.guard", "card.general.zhou_jing.delayed_strike"]
	var controller = _controller("general.zhou_jing", deck, 1515, _enemy(0), 5, 2)
	_play(controller, "card.public.general.guard")
	var index := _hand_index(controller, "card.general.zhou_jing.delayed_strike")
	var preview: int = controller.preview_card_damage(index)
	var before: Dictionary = controller.snapshot()
	_play(controller, "card.general.zhou_jing.delayed_strike")
	var after: Dictionary = controller.snapshot()
	_assert_equal(int(before.enemy.troops) - int(after.enemy.troops), preview, "armor-based damage preview matches actual damage")
	_assert_equal(after.player.armor, before.player.armor, "base delayed strike retains current armor")


func _test_prepared_volley_buffs_every_hit_and_consumes_once() -> void:
	var deck := ["card.public.archery.prepared_volley", "card.public.general.assault", "card.public.archery.repeating_crossbow"]
	var controller = _controller("general.han_yue", deck, 1516, _enemy(0), 5, 3)
	_play(controller, "card.public.archery.prepared_volley")
	_assert_equal(controller.snapshot().player.prepared_attacks.size(), 1, "prepared volley stores one tagged attack modifier")
	_play(controller, "card.public.general.assault")
	_assert_equal(controller.snapshot().player.prepared_attacks.size(), 1, "non-archery attack does not consume prepared volley")
	var index := _hand_index(controller, "card.public.archery.repeating_crossbow")
	var preview: int = controller.preview_card_damage(index)
	var before: Dictionary = controller.snapshot()
	_play(controller, "card.public.archery.repeating_crossbow")
	var after: Dictionary = controller.snapshot()
	_assert_true(preview > 96, "prepared volley increases the three-hit crossbow preview")
	_assert_equal(int(before.enemy.troops) - int(after.enemy.troops), preview, "prepared multiplier applies equally to preview and every actual hit")
	_assert_true(after.player.prepared_attacks.is_empty(), "prepared volley is consumed by one matching attack card")
	_assert_true(not after.player.statuses.has("m3.prepared_attack.archery"), "prepared volley status is removed after consumption")


func _test_restore_troops_caps_at_maximum() -> void:
	var healer := _enemy(0)
	healer.troops = 900
	healer.max_troops = 1000
	healer.skills = [{"id": "test.restore", "intent_type": "recover", "weight": 1, "conditions": [], "effects": [{"type": "RestoreTroops", "amount": 200, "target": "self"}]}]
	var controller = _controller("general.zhao_lie", ["card.public.general.guard"], 1517, healer, 3, 1)
	controller.end_player_turn()
	_assert_equal(controller.snapshot().enemy.troops, 1000, "troop restoration cannot exceed battle maximum")
	_assert_equal(_event_count(controller, "troops_restored"), 1, "troop restoration is recorded")


func _test_talent_ownership_is_validated() -> void:
	var built: Dictionary = GeneralRequestBuilderScript.build("general.zhao_lie", _enemy(), 1518, _registry)
	built.request.player.talent_id = "talent.han_yue.pierce_formation"
	var controller = CombatControllerScript.new()
	var errors = controller.setup(built.request, _registry)
	_assert_true(_contains_text(errors, "does not belong"), "combat rejects a talent owned by another general")


func _test_fixed_seed_zhao_lie_identity_turn() -> void:
	var controller = _controller("general.zhao_lie", [], 15, _enemy(0), 3, 5)
	_assert_true(controller.snapshot().deck.hand.has("card.general.zhao_lie.lone_breakthrough"), "Zhao Lie seed 15 reveals his identity hand")
	_play(controller, "card.public.cavalry.harass")
	_play(controller, "card.public.general.assault")
	_play(controller, "card.general.zhao_lie.lone_breakthrough")
	var state: Dictionary = controller.snapshot()
	_assert_equal(state.action_points, 1, "Zhao Lie fixed seed chains into a refunded action point")
	_assert_true(state.deck.exhaust_pile.has("card.general.zhao_lie.lone_breakthrough"), "Zhao Lie fixed seed resolves the exclusive finisher")


func _test_fixed_seed_zhou_jing_identity_turn() -> void:
	var controller = _controller("general.zhou_jing", [], 10, _enemy(0), 3, 5)
	_assert_true(controller.snapshot().deck.hand.has("card.general.zhou_jing.delayed_strike"), "Zhou Jing seed 10 reveals his identity hand")
	_play(controller, "card.public.defense.shield_wall")
	var index := _hand_index(controller, "card.general.zhou_jing.delayed_strike")
	var preview: int = controller.preview_card_damage(index)
	_play(controller, "card.general.zhou_jing.delayed_strike")
	_assert_true(preview > 0 and controller.snapshot().player.armor == 115, "Zhou Jing fixed seed turns Iron Wall armor into retained offense")


func _test_fixed_seed_han_yue_identity_turn() -> void:
	var controller = _controller("general.han_yue", [], 4, _enemy(0, 40), 3, 5)
	_assert_true(controller.snapshot().deck.hand.has("card.public.archery.prepared_volley"), "Han Yue seed 4 reveals her identity hand")
	_play(controller, "card.public.archery.prepared_volley")
	var index := _hand_index(controller, "card.public.archery.repeating_crossbow")
	var preview: int = controller.preview_card_damage(index)
	var before: Dictionary = controller.snapshot()
	_play(controller, "card.public.archery.repeating_crossbow")
	var after: Dictionary = controller.snapshot()
	_assert_equal(after.enemy.defense, 36.0, "Han Yue fixed seed applies the talent break before the volley")
	_assert_equal(int(before.enemy.troops) - int(after.enemy.troops), preview, "Han Yue fixed seed delivers the prepared multi-hit burst")


func _controller(
	general_id: String,
	deck_override: Array,
	seed: int,
	enemy: Dictionary,
	action_points: int,
	draw_count: int
):
	var built: Dictionary = GeneralRequestBuilderScript.build(general_id, enemy, seed, _registry, "m3-runtime-test")
	var request: Dictionary = built.request
	if not deck_override.is_empty():
		request.deck = deck_override.duplicate()
	request.starting_action_points = action_points
	request.draw_count = draw_count
	var controller = CombatControllerScript.new()
	var errors = controller.setup(request, _registry)
	_assert_true(errors.is_empty(), "%s runtime request passes validation" % general_id)
	return controller


func _enemy(base_power: int = 0, defense: int = 0) -> Dictionary:
	return {
		"id": "test.runtime_enemy",
		"troops": 10000,
		"max_troops": 10000,
		"morale": 100,
		"max_morale": 100,
		"attack": 0,
		"defense": defense,
		"army_composition": {"infantry": 1.0, "archer": 0.0, "cavalry": 0.0},
		"skills": [{"id": "test.attack", "intent_type": "attack", "weight": 1, "conditions": [], "effects": [{"type": "DealDamage", "base_power": base_power, "target": "opponent"}]}],
	}


func _play(controller, card_id: String) -> void:
	var index := _hand_index(controller, card_id)
	_assert_true(index >= 0, "%s is present in hand" % card_id)
	if index < 0:
		return
	var result: Dictionary = controller.play_card(index)
	_assert_true(result.ok, "%s plays successfully" % card_id)


func _hand_index(controller, card_id: String) -> int:
	return controller.snapshot().deck.hand.find(card_id)


func _event_count(controller, event_type: String) -> int:
	var count := 0
	for event in controller.event_log():
		if event.type == event_type:
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
