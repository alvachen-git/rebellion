extends SceneTree

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")
const CombatControllerScript := preload("res://src/domain/combat/combat_controller.gd")
const MapGeneratorScript := preload("res://src/domain/expedition/expedition_map_generator.gd")
const ExpeditionRunStateScript := preload("res://src/domain/expedition/expedition_run_state.gd")

var _passed := 0
var _failed := 0
var _registry
var _generated_map: Dictionary


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_registry = ContentRegistryScript.new()
	_assert_true(_registry.load_all(), "M4 expedition content registry loads")
	_generated_map = MapGeneratorScript.generate(_registry.get_expedition("expedition.capture_heyuan_county"), 4101).map
	_test_setup_contract_and_failures()
	_test_noncombat_node_and_reveal()
	_test_loot_and_temporary_buff_contracts()
	_test_cross_battle_state_and_pending_transaction()
	_test_complete_route_reaches_settlement_boundary()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_setup_contract_and_failures() -> void:
	var missing_id = ExpeditionRunStateScript.new()
	_assert_error_contains(missing_id.setup("", _generated_map, _general_snapshot(), _deck()), "run id", "expedition setup rejects an empty run id")
	var missing_general = ExpeditionRunStateScript.new()
	_assert_error_contains(missing_general.setup("run.bad-general", _generated_map, {}, _deck()), "general snapshot missing", "expedition setup rejects an incomplete general snapshot")
	var no_troops := _general_snapshot()
	no_troops.troops = 0
	var dead_start = ExpeditionRunStateScript.new()
	_assert_error_contains(dead_start.setup("run.no-troops", _generated_map, no_troops, _deck()), "positive troops", "expedition cannot start without troops")
	var no_deck = ExpeditionRunStateScript.new()
	_assert_error_contains(no_deck.setup("run.no-deck", _generated_map, _general_snapshot(), []), "deck must not be empty", "expedition cannot start without a deck")
	var invalid_map = ExpeditionRunStateScript.new()
	_assert_true(not invalid_map.setup("run.bad-map", {}, _general_snapshot(), _deck()).is_empty(), "expedition setup rejects a malformed map")
	var valid = _new_run("run.valid")
	var state: Dictionary = valid.snapshot()
	_assert_equal(state.status, "active", "valid expedition starts active")
	_assert_equal(state.general.armor, 0, "expedition starts without carrying single-battle armor")
	_assert_equal(state.route.available_next_node_ids.size(), 3, "valid expedition exposes the three front routes")
	_assert_true(not state.has("campaign"), "expedition runtime does not embed or mutate Campaign state")


func _test_noncombat_node_and_reveal() -> void:
	var run = _new_run("run.noncombat")
	_assert_true(run.advance_to("heyuan.village.approach").ok, "run can enter the generated village node")
	_assert_equal(run.snapshot().route.current_node_id, "heyuan.village.approach", "run route tracks the current node")
	_assert_equal(_visible_node(run, "heyuan.merge.elite").node_type, "unknown", "unreached elite begins hidden")
	_assert_true(run.reveal_map_node("heyuan.merge.elite").ok, "intel-style effect can reveal a known map node")
	_assert_equal(_visible_node(run, "heyuan.merge.elite").node_type, "elite_combat", "explicit reveal exposes the node type")
	_assert_true(not run.reveal_map_node("heyuan.missing").ok, "reveal rejects an unknown node")
	_assert_equal(_visible_node(run, "heyuan.village.approach").node_type, "event", "fixed seed resolves the village approach as an event")
	_assert_true(run.complete_noncombat_node().ok, "event node completes without a CombatResult")
	_assert_equal(run.snapshot().route.available_next_node_ids, ["heyuan.village.contact"], "noncombat completion unlocks the next authored node")
	_assert_true(not run.complete_noncombat_node().ok, "noncombat node cannot settle twice")


func _test_loot_and_temporary_buff_contracts() -> void:
	var run = _new_run("run.rewards")
	_assert_true(run.add_unbanked_loot("resource.silver", 80).ok, "positive loot enters the expedition bag")
	_assert_true(run.add_unbanked_loot("resource.silver", 20).ok, "same loot resource accumulates")
	_assert_equal(run.snapshot().unbanked_loot["resource.silver"], 100, "loot bag records the accumulated unbanked amount")
	_assert_true(not run.add_unbanked_loot("", 10).ok, "loot rejects an empty resource id")
	_assert_true(not run.add_unbanked_loot("resource.food", 0).ok, "loot rejects a non-positive amount")
	_assert_true(run.add_temporary_buff({"id": "buff.morale", "type": "ModifyNextBattleMorale", "amount": 10}).ok, "next-battle morale buff is accepted")
	_assert_true(run.add_temporary_buff({"id": "buff.attack", "type": "ModifyNextBattleAttack", "amount": 6}).ok, "next-battle attack buff is accepted")
	_assert_equal(run.snapshot().temporary_buffs.size(), 2, "temporary buffs stay in Expedition state before battle")
	_assert_true(not run.add_temporary_buff({"id": "buff.future", "type": "FutureBuff", "amount": 1}).ok, "unsupported future buff is rejected")
	_assert_true(not run.add_temporary_buff({"id": "buff.zero", "type": "ModifyNextBattleMorale", "amount": 0}).ok, "temporary buff rejects a non-positive amount")
	_assert_true(not run.add_temporary_buff({"id": "buff.missing"}).ok, "temporary buff rejects missing fields")


func _test_cross_battle_state_and_pending_transaction() -> void:
	var run = _new_run("run.cross-battle")
	run.advance_to("heyuan.official.approach")
	run.add_unbanked_loot("resource.food", 40)
	run.add_temporary_buff({"id": "buff.morale", "type": "ModifyNextBattleMorale", "amount": 10})
	run.add_temporary_buff({"id": "buff.attack", "type": "ModifyNextBattleAttack", "amount": 6})
	var begun: Dictionary = run.begin_combat(_registry.get_enemy("enemy.normal.patrol_inspector"), 4401)
	_assert_true(begun.ok, "combat node creates a CombatRequest")
	_assert_equal(begun.request.player.troops, 1050, "first battle receives expedition troops")
	_assert_equal(begun.request.player.morale, 88, "next-battle morale buff applies to the request snapshot")
	_assert_equal(begun.request.player.attack, 40.0, "next-battle attack buff applies to the request snapshot")
	_assert_equal(begun.request.player.armor, 0, "CombatRequest never carries armor between battles")
	_assert_equal(begun.request.expedition_context.consumed_buff_ids.size(), 2, "request records consumed temporary buffs")
	_assert_true(run.snapshot().temporary_buffs.is_empty(), "next-battle buffs leave the expedition queue when battle starts")
	_assert_true(run.pending_combat_request() == begun.request, "pending request preserves the deterministic combat checkpoint")
	_assert_true(not run.begin_combat(_registry.get_enemy("enemy.normal.local_militia"), 4402).ok, "a pending battle blocks a second battle")
	_assert_true(not run.advance_to("heyuan.official.checkpoint").ok, "a pending battle blocks map movement")
	var combat = CombatControllerScript.new()
	_assert_true(combat.setup(begun.request, _registry).is_empty(), "expedition CombatRequest passes the real combat contract")
	_assert_true(not run.apply_victory_result({"status": "defeat"}).ok, "M4-03 does not invent defeat settlement rules")
	_assert_true(not run.apply_victory_result({"status": "victory"}).ok, "victory result missing carryover fields is rejected")
	_assert_true(not run.apply_victory_result(_victory_result(0, 70)).ok, "victory result with zero troops is rejected")
	_assert_true(not run.apply_victory_result(_victory_result(900, 101)).ok, "victory result above maximum morale is rejected")
	_assert_true(not run.pending_combat_request().is_empty(), "invalid result does not lose the pending combat checkpoint")
	_assert_true(run.apply_victory_result(_victory_result(900, 70)).ok, "valid victory result settles the current combat node")
	var after_first: Dictionary = run.snapshot()
	_assert_equal(after_first.general.troops, 900, "remaining troops persist after battle")
	_assert_equal(after_first.general.morale, 70, "remaining morale persists after battle")
	_assert_equal(after_first.general.armor, 0, "single-battle armor is cleared at expedition boundary")
	_assert_equal(after_first.completed_battles, 1, "expedition counts the settled battle")
	_assert_equal(after_first.unbanked_loot["resource.food"], 40, "unbanked loot survives a victorious battle without entering Campaign")
	_assert_true(after_first.pending_combat.is_empty(), "valid result closes the pending combat transaction")
	_assert_true(run.advance_to("heyuan.official.checkpoint").ok, "victory unlocks the next route node")
	var second: Dictionary = run.begin_combat(_registry.get_enemy("enemy.normal.city_defenders"), 4402)
	_assert_equal(second.request.player.troops, 900, "second battle inherits troop losses")
	_assert_equal(second.request.player.morale, 70, "second battle inherits morale losses")
	_assert_equal(second.request.player.attack, 34.0, "consumed attack buff does not persist into the second battle")
	_assert_true(second.request.expedition_context.consumed_buff_ids.is_empty(), "consumed buffs cannot apply twice")


func _test_complete_route_reaches_settlement_boundary() -> void:
	var run = _new_run("run.full-route")
	run.add_unbanked_loot("resource.silver", 120)
	_run_victory_node(run, "heyuan.official.approach", "enemy.normal.patrol_inspector", 4501, 1000, 75)
	_run_victory_node(run, "heyuan.official.checkpoint", "enemy.normal.city_defenders", 4502, 920, 70)
	_run_victory_node(run, "heyuan.official.armory", "enemy.normal.overseer_unit", 4503, 850, 68)
	_run_victory_node(run, "heyuan.merge.elite", "enemy.elite.gao_wu", 4504, 720, 60)
	_assert_true(run.advance_to("heyuan.late.intel").ok, "full route can choose the late intel node")
	_assert_true(run.complete_noncombat_node().ok, "late intel node completes without combat")
	_run_victory_node(run, "heyuan.county_seat", "enemy.boss.yan_cheng", 4505, 500, 48)
	var final_state: Dictionary = run.snapshot()
	_assert_equal(final_state.route.status, "completed", "Boss victory completes the route graph")
	_assert_equal(final_state.status, "awaiting_settlement", "Boss victory stops at the Campaign settlement boundary")
	_assert_equal(final_state.completed_battles, 5, "full official route records five combat nodes")
	_assert_equal(final_state.general.troops, 500, "final troop loss remains in Expedition state")
	_assert_equal(final_state.unbanked_loot["resource.silver"], 120, "successful route still keeps loot unbanked before M4-05 settlement")
	_assert_true(not final_state.has("campaign"), "completed route still cannot write Campaign directly")
	_assert_true(not run.add_unbanked_loot("resource.food", 1).ok, "awaiting-settlement run cannot gain more loot")


func _run_victory_node(run, node_id: String, enemy_id: String, seed: int, troops: int, morale: int) -> void:
	_assert_true(run.advance_to(node_id).ok, "route advances to %s" % node_id)
	_assert_true(run.begin_combat(_registry.get_enemy(enemy_id), seed).ok, "%s starts a combat transaction" % node_id)
	_assert_true(run.apply_victory_result(_victory_result(troops, morale)).ok, "%s victory settles into Expedition state" % node_id)


func _new_run(run_id: String):
	var run = ExpeditionRunStateScript.new()
	var errors: PackedStringArray = run.setup(run_id, _generated_map, _general_snapshot(), _deck())
	_assert_true(errors.is_empty(), "%s setup succeeds" % run_id)
	return run


func _general_snapshot() -> Dictionary:
	var general: Dictionary = _registry.get_general("general.zhao_lie")
	return {
		"id": general.id,
		"name": general.name,
		"talent_id": general.talent_id,
		"troops": int(general.combat.troops),
		"max_troops": int(general.combat.troops),
		"morale": int(general.combat.morale),
		"max_morale": 100,
		"attack": float(general.combat.attack),
		"defense": float(general.combat.defense),
		"army_composition": general.army_composition.duplicate(true),
	}


func _deck() -> Array:
	return _registry.get_general("general.zhao_lie").starting_deck.duplicate()


func _victory_result(troops: int, morale: int) -> Dictionary:
	return {
		"status": "victory",
		"player_remaining_troops": troops,
		"player_remaining_morale": morale,
	}


func _visible_node(run, node_id: String) -> Dictionary:
	for node in run.snapshot().visible_nodes:
		if node.id == node_id:
			return node
	return {}


func _assert_error_contains(errors: PackedStringArray, fragment: String, label: String) -> void:
	var found := false
	for error in errors:
		if fragment in error:
			found = true
			break
	_assert_true(found, label)


func _assert_true(condition: bool, label: String) -> void:
	if condition:
		_passed += 1
		print("TEST PASS: %s" % label)
	else:
		_failed += 1
		push_error("TEST FAIL: %s" % label)


func _assert_equal(actual, expected, label: String) -> void:
	_assert_true(actual == expected, "%s (expected=%s actual=%s)" % [label, expected, actual])
