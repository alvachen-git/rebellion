extends SceneTree

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")
const CombatControllerScript := preload("res://src/domain/combat/combat_controller.gd")
const GeneralRequestBuilderScript := preload("res://src/domain/combat/general_combat_request_builder.gd")
const BossModifierApplierScript := preload("res://src/domain/combat/boss_modifier_applier.gd")

const BOSS_ID := "enemy.boss.yan_cheng"
const TALENT_ID := "talent.yan_cheng.hold_isolated_city"
const ASSAULT := "card.public.general.assault"

var _passed := 0
var _failed := 0
var _registry


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_registry = ContentRegistryScript.new()
	_assert_true(_registry.load_all(), "M3 boss content registry loads")
	_test_boss_content_contract()
	_test_fixed_seed_boss_intent_is_deterministic()
	_test_phase_boundary_and_forced_hold_city()
	_test_phase_queue_precedes_reinforcement_queue()
	_test_reinforcement_signal_queues_pincer()
	_test_reorganize_restores_troops_and_morale()
	_test_armory_modifier_is_independent_and_pure()
	_test_beacon_modifier_is_independent_and_pure()
	_test_granary_modifier_is_independent_and_pure()
	_test_combined_modifiers_reach_runtime()
	_test_invalid_modifier_requests_fail_readably()
	_test_invalid_boss_contracts_fail_readably()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_boss_content_contract() -> void:
	_assert_equal(_registry.enemy_count(), 18, "registry contains the M3 roster and nine M6 Rogue enemies")
	_assert_true(_registry.has_enemy(BOSS_ID), "Yan Cheng is registered")
	var boss: Dictionary = _registry.get_enemy(BOSS_ID)
	_assert_true(_registry.validate_enemy_definition(boss, BOSS_ID).is_empty(), "Yan Cheng satisfies the boss enemy contract")
	_assert_equal(boss.tier, "boss", "Yan Cheng uses the boss tier")
	_assert_equal(boss.skills.size(), 7, "Yan Cheng exposes five selectable and two queued-only skills")
	_assert_equal(_selectable_skill_count(boss.skills), 5, "Yan Cheng AI pool excludes queued-only skills")
	_assert_true(_skill(boss.skills, "enemy.yan_cheng.reinforcement_pincer").queued_only, "reinforcement pincer is queue-only")
	_assert_true(_skill(boss.skills, "enemy.yan_cheng.hold_city").queued_only, "hold city is queue-only")
	var talent: Dictionary = _registry.get_talent(TALENT_ID)
	_assert_equal(talent.owner_enemy_id, BOSS_ID, "Yan Cheng talent ownership resolves")
	_assert_equal(talent.trigger.type, "FirstTroopRatioBelow", "Yan Cheng talent uses the approved threshold trigger")
	_assert_equal(float(talent.trigger.ratio), 0.5, "Yan Cheng threshold remains at fifty percent")
	_assert_true(_registry.validate_talent_definition(talent, TALENT_ID).is_empty(), "Yan Cheng talent satisfies its contract")


func _test_fixed_seed_boss_intent_is_deterministic() -> void:
	var first = _controller(_registry.get_enemy(BOSS_ID), [ASSAULT], 2401, 3, 1)
	var second = _controller(_registry.get_enemy(BOSS_ID), [ASSAULT], 2401, 3, 1)
	_assert_equal(first.snapshot().enemy_intent.id, second.snapshot().enemy_intent.id, "Yan Cheng opening intent is deterministic for a fixed seed")
	_assert_true(not bool(first.snapshot().enemy_intent.get("queued_only", false)), "Yan Cheng random AI never opens with a queued-only skill")


func _test_phase_boundary_and_forced_hold_city() -> void:
	var boss: Dictionary = _registry.get_enemy(BOSS_ID)
	boss.troops = 932
	boss.skills = [
		_skill(boss.skills, "enemy.yan_cheng.garrison_volley"),
		_skill(boss.skills, "enemy.yan_cheng.hold_city"),
	]
	var controller = _controller(boss, [ASSAULT, ASSAULT], 2402, 2, 2)
	var opening_intent: String = controller.snapshot().enemy_intent.id
	_play(controller, ASSAULT)
	var exact_half: Dictionary = controller.snapshot()
	_assert_equal(exact_half.enemy.troops, 875, "first assault lands Yan Cheng at exactly fifty percent")
	_assert_equal(exact_half.enemy_phase, 1, "exactly fifty percent remains phase one")
	_assert_equal(_event_count(controller, "enemy_talent_triggered"), 0, "threshold talent does not trigger at exactly fifty percent")
	_play(controller, ASSAULT)
	var below_half: Dictionary = controller.snapshot()
	_assert_equal(below_half.enemy.troops, 818, "second assault crosses below fifty percent")
	_assert_equal(below_half.enemy_phase, 2, "crossing below fifty percent enters phase two")
	_assert_equal(below_half.enemy.armor, 200, "deadlock talent immediately grants two hundred armor")
	_assert_equal(below_half.enemy_intent.id, opening_intent, "phase change does not rewrite the already revealed intent")
	_assert_equal(below_half.enemy_forced_intents, ["enemy.yan_cheng.hold_city"], "phase change queues hold city once")
	_assert_equal(_event_count(controller, "enemy_talent_triggered"), 1, "phase talent triggers once")
	controller.end_player_turn()
	var forced_turn: Dictionary = controller.snapshot()
	_assert_equal(forced_turn.enemy_intent.id, "enemy.yan_cheng.hold_city", "next selected intent is forced to hold city")
	_assert_equal(_event_count(controller, "enemy_forced_intent_revealed"), 1, "forced hold city reveal is logged")
	controller.end_player_turn()
	var restored_pool: Dictionary = controller.snapshot()
	_assert_equal(restored_pool.enemy.armor, 200, "executed hold city grants its configured armor")
	_assert_true(restored_pool.enemy_intent.id != "enemy.yan_cheng.hold_city", "AI returns to the public skill pool after forced hold city")
	_play(controller, ASSAULT)
	_assert_equal(_event_count(controller, "enemy_talent_triggered"), 1, "further damage below fifty percent cannot retrigger the phase talent")


func _test_reinforcement_signal_queues_pincer() -> void:
	var boss: Dictionary = _registry.get_enemy(BOSS_ID)
	boss.skills = [
		_skill(boss.skills, "enemy.yan_cheng.signal_reinforcements"),
		_skill(boss.skills, "enemy.yan_cheng.reinforcement_pincer"),
	]
	var controller = _controller(boss, ["card.public.general.guard"], 2403, 3, 1)
	_assert_equal(controller.snapshot().enemy_intent.id, "enemy.yan_cheng.signal_reinforcements", "signal is revealed before it executes")
	controller.end_player_turn()
	_assert_equal(controller.snapshot().enemy_intent.id, "enemy.yan_cheng.reinforcement_pincer", "executed signal forces the next pincer intent")
	_assert_equal(_event_count(controller, "enemy_forced_intent_queued"), 1, "reinforcement queue event is recorded")
	var before_pincer: Dictionary = controller.snapshot()
	controller.end_player_turn()
	var after_pincer: Dictionary = controller.snapshot()
	_assert_true(after_pincer.player.troops < before_pincer.player.troops, "reinforcement pincer deals troop damage")
	_assert_equal(after_pincer.player.morale, int(before_pincer.player.morale) - 10, "reinforcement pincer also removes ten morale")
	_assert_equal(_event_count(controller, "enemy_forced_intent_revealed"), 1, "pincer is revealed through the forced queue exactly once")


func _test_phase_queue_precedes_reinforcement_queue() -> void:
	var boss: Dictionary = _registry.get_enemy(BOSS_ID)
	boss.troops = 932
	boss.skills = [
		_skill(boss.skills, "enemy.yan_cheng.signal_reinforcements"),
		_skill(boss.skills, "enemy.yan_cheng.reinforcement_pincer"),
		_skill(boss.skills, "enemy.yan_cheng.hold_city"),
	]
	var controller = _controller(boss, [ASSAULT, ASSAULT], 2406, 2, 2)
	_play(controller, ASSAULT)
	_play(controller, ASSAULT)
	_assert_equal(controller.snapshot().enemy_forced_intents, ["enemy.yan_cheng.hold_city"], "phase queue starts with hold city")
	controller.end_player_turn()
	_assert_equal(controller.snapshot().enemy_intent.id, "enemy.yan_cheng.hold_city", "phase hold takes priority over reinforcement pincer")
	_assert_equal(controller.snapshot().enemy_forced_intents, ["enemy.yan_cheng.reinforcement_pincer"], "signal pincer waits behind the phase action")
	controller.end_player_turn()
	_assert_equal(controller.snapshot().enemy_intent.id, "enemy.yan_cheng.reinforcement_pincer", "reinforcement pincer follows after the forced phase action")


func _test_reorganize_restores_troops_and_morale() -> void:
	var boss: Dictionary = _registry.get_enemy(BOSS_ID)
	boss.troops = 1000
	boss.morale = 50
	boss.skills = [_skill(boss.skills, "enemy.yan_cheng.reorganize")]
	var controller = _controller(boss, ["card.public.general.guard"], 2404, 3, 1)
	controller.end_player_turn()
	_assert_equal(controller.snapshot().enemy.troops, 1120, "reorganize restores one hundred twenty troops")
	_assert_equal(controller.snapshot().enemy.morale, 60, "reorganize restores ten morale")


func _test_armory_modifier_is_independent_and_pure() -> void:
	var base_enemy: Dictionary = _registry.get_enemy(BOSS_ID)
	var base_talent: Dictionary = _registry.get_talent(TALENT_ID)
	var result: Dictionary = BossModifierApplierScript.apply(base_enemy, base_talent, {"armory_destroyed": true})
	_assert_equal(result.enemy.defense, 30, "armory destruction lowers Yan Cheng defense to thirty")
	_assert_equal(_gain_armor(_skill(result.enemy.skills, "enemy.yan_cheng.fortify")), 75, "armory destruction lowers fortify armor to seventy-five")
	_assert_equal(_gain_armor(_skill(result.enemy.skills, "enemy.yan_cheng.hold_city")), 140, "armory destruction lowers hold city armor to one hundred forty")
	_assert_equal(_gain_armor(result.talent), 140, "armory destruction lowers immediate talent armor to one hundred forty")
	_assert_equal(result.enemy.morale, 75, "armory destruction does not alter morale")
	_assert_true(not _skill(result.enemy.skills, "enemy.yan_cheng.signal_reinforcements").is_empty(), "armory destruction keeps reinforcement skills")
	_assert_equal(base_enemy.defense, 42, "armory application does not mutate the source enemy")
	_assert_equal(_gain_armor(base_talent), 200, "armory application does not mutate the source talent")


func _test_beacon_modifier_is_independent_and_pure() -> void:
	var base_enemy: Dictionary = _registry.get_enemy(BOSS_ID)
	var result: Dictionary = BossModifierApplierScript.apply(base_enemy, _registry.get_talent(TALENT_ID), {"beacon_destroyed": true})
	_assert_equal(result.enemy.morale, 55, "beacon destruction lowers starting morale to fifty-five")
	_assert_true(_skill(result.enemy.skills, "enemy.yan_cheng.signal_reinforcements").is_empty(), "beacon destruction removes signal reinforcements")
	_assert_true(_skill(result.enemy.skills, "enemy.yan_cheng.reinforcement_pincer").is_empty(), "beacon destruction removes reinforcement pincer")
	_assert_equal(result.enemy.defense, 42, "beacon destruction does not alter defense")
	_assert_equal(_gain_armor(_skill(result.enemy.skills, "enemy.yan_cheng.fortify")), 110, "beacon destruction does not alter armor skills")
	_assert_true(not _skill(result.enemy.skills, "enemy.yan_cheng.reorganize").is_empty(), "beacon destruction keeps recovery")
	_assert_equal(base_enemy.morale, 75, "beacon application does not mutate the source enemy")


func _test_granary_modifier_is_independent_and_pure() -> void:
	var base_enemy: Dictionary = _registry.get_enemy(BOSS_ID)
	var result: Dictionary = BossModifierApplierScript.apply(base_enemy, _registry.get_talent(TALENT_ID), {"granary_destroyed": true})
	_assert_true(_skill(result.enemy.skills, "enemy.yan_cheng.reorganize").is_empty(), "granary destruction removes reorganize")
	_assert_true(not _skill(result.enemy.skills, "enemy.yan_cheng.signal_reinforcements").is_empty(), "granary destruction keeps reinforcements")
	_assert_equal(result.enemy.defense, 42, "granary destruction does not alter defense")
	_assert_equal(result.enemy.morale, 75, "granary destruction does not alter morale")
	_assert_true(not _skill(base_enemy.skills, "enemy.yan_cheng.reorganize").is_empty(), "granary application does not mutate the source enemy")


func _test_combined_modifiers_reach_runtime() -> void:
	var modifiers := {"armory_destroyed": true, "beacon_destroyed": true, "granary_destroyed": true}
	var controller = _controller(_registry.get_enemy(BOSS_ID), [ASSAULT], 2405, 3, 1, modifiers)
	var state: Dictionary = controller.snapshot()
	_assert_equal(state.enemy.defense, 30.0, "combined runtime request applies armory defense")
	_assert_equal(state.enemy.morale, 55, "combined runtime request applies beacon morale")
	_assert_true(_skill(state.enemy_skills, "enemy.yan_cheng.signal_reinforcements").is_empty(), "combined runtime removes reinforcement route")
	_assert_true(_skill(state.enemy_skills, "enemy.yan_cheng.reorganize").is_empty(), "combined runtime removes recovery route")
	_assert_equal(_gain_armor(state.enemy_talent), 140, "combined runtime carries modified phase armor")
	_assert_equal(state.boss_modifiers.size(), 3, "runtime snapshot records all three applied modifiers")
	_assert_equal(_event_count(controller, "boss_modifier_applied"), 3, "runtime logs each applied modifier independently")


func _test_invalid_modifier_requests_fail_readably() -> void:
	var boss: Dictionary = _registry.get_enemy(BOSS_ID)
	var unknown_errors := _setup_errors(boss, {"walls_destroyed": true})
	_assert_true(_contains_text(unknown_errors, "unsupported boss modifier"), "unknown boss modifier is rejected")
	var type_errors := _setup_errors(boss, {"armory_destroyed": "yes"})
	_assert_true(_contains_text(type_errors, "must be boolean"), "non-boolean boss modifier is rejected")
	var normal_enemy: Dictionary = _registry.get_enemy("enemy.normal.patrol_inspector")
	var scope_errors := _setup_errors(normal_enemy, {"armory_destroyed": true})
	_assert_true(_contains_text(scope_errors, "only be applied to a boss"), "boss modifiers cannot be attached to a normal enemy")


func _test_invalid_boss_contracts_fail_readably() -> void:
	var boss: Dictionary = _registry.get_enemy(BOSS_ID)
	boss.erase("boss_modifier_rules")
	var rule_errors: PackedStringArray = _registry.validate_enemy_definition(boss, "invalid.boss.rules")
	_assert_true(_contains_text(rule_errors, "boss requires boss_modifier_rules"), "boss without modifier rules is rejected")
	var queued: Dictionary = _registry.get_enemy(BOSS_ID)
	queued.skills[5].weight = 1
	var queue_errors: PackedStringArray = _registry.validate_enemy_definition(queued, "invalid.boss.queue")
	_assert_true(_contains_text(queue_errors, "queued-only"), "queued-only skill with random weight is rejected")
	var talent: Dictionary = _registry.get_talent(TALENT_ID)
	talent.trigger.ratio = 1.0
	var talent_errors: PackedStringArray = _registry.validate_talent_definition(talent, "invalid.boss.talent")
	_assert_true(_contains_text(talent_errors, "between 0 and 1"), "invalid phase threshold ratio is rejected")


func _controller(enemy: Dictionary, deck: Array, seed: int, action_points: int, draw_count: int, modifiers: Dictionary = {}):
	var built: Dictionary = GeneralRequestBuilderScript.build("general.zhao_lie", enemy, seed, _registry, "m3-boss-test")
	var request: Dictionary = built.request
	request.deck = deck.duplicate()
	request.starting_action_points = action_points
	request.draw_count = draw_count
	if not modifiers.is_empty():
		request.boss_modifiers = modifiers.duplicate(true)
	var controller = CombatControllerScript.new()
	var errors: PackedStringArray = controller.setup(request, _registry)
	_assert_true(errors.is_empty(), "%s runtime request passes validation" % enemy.get("id", "unknown"))
	return controller


func _setup_errors(enemy: Dictionary, modifiers) -> PackedStringArray:
	var built: Dictionary = GeneralRequestBuilderScript.build("general.zhao_lie", enemy, 2499, _registry, "m3-boss-invalid-test")
	var request: Dictionary = built.request
	request.deck = [ASSAULT]
	request.boss_modifiers = modifiers
	return CombatControllerScript.new().setup(request, _registry)


func _play(controller, card_id: String) -> void:
	var index: int = controller.snapshot().deck.hand.find(card_id)
	_assert_true(index >= 0, "%s is present in hand" % card_id)
	if index < 0:
		return
	var result: Dictionary = controller.play_card(index)
	_assert_true(result.ok, "%s plays successfully" % card_id)


func _skill(skills: Array, skill_id: String) -> Dictionary:
	for skill in skills:
		if skill.get("id", "") == skill_id:
			return skill
	return {}


func _gain_armor(definition: Dictionary) -> int:
	for effect in definition.get("effects", []):
		if effect.get("type", "") == "GainArmor":
			return int(effect.get("amount", 0))
	return 0


func _selectable_skill_count(skills: Array) -> int:
	var count := 0
	for skill in skills:
		if not bool(skill.get("queued_only", false)):
			count += 1
	return count


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
