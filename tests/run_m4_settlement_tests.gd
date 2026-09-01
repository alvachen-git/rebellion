extends SceneTree

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")
const MapGeneratorScript := preload("res://src/domain/expedition/expedition_map_generator.gd")
const ExpeditionRunStateScript := preload("res://src/domain/expedition/expedition_run_state.gd")

var _passed := 0
var _failed := 0
var _registry
var _map: Dictionary


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_registry = ContentRegistryScript.new()
	_assert_true(_registry.load_all(), "M4 settlement content registry loads")
	_map = MapGeneratorScript.generate(_registry.get_expedition("expedition.capture_heyuan_county"), 4701).map
	_test_active_run_cannot_settle()
	_test_success_settlement_request()
	_test_retreat_discards_loot_and_preserves_losses()
	_test_troop_defeat_preserves_death_result()
	_test_morale_defeat_preserves_injury_result()
	_test_terminal_result_validation()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_active_run_cannot_settle() -> void:
	var run = _new_run("run.active")
	_assert_true(not run.create_settlement_request().ok, "active expedition cannot create a settlement request")
	_assert_true(not run.apply_terminal_combat_result(_retreat_result(1000, 70)).ok, "terminal result requires a pending combat")


func _test_success_settlement_request() -> void:
	var run = _new_run("run.success")
	run.add_unbanked_loot("resource.silver", 180)
	run.add_unbanked_loot("resource.food", 260)
	_complete_official_route(run)
	var state: Dictionary = run.snapshot()
	_assert_equal(state.status, "awaiting_settlement", "Boss victory enters the success settlement boundary")
	_assert_equal(state.unbanked_loot, {"resource.silver": 180, "resource.food": 260}, "successful run keeps loot unbanked before Campaign settlement")
	var first: Dictionary = run.create_settlement_request()
	var replay: Dictionary = run.create_settlement_request()
	_assert_true(first.ok, "successful run creates a settlement request")
	_assert_true(first == replay, "success settlement request is idempotent")
	_assert_equal(first.request.outcome, "success", "success request has an explicit outcome")
	_assert_equal(first.request.loot_to_bank, {"resource.silver": 180, "resource.food": 260}, "success request is the only path that carries loot to bank")
	_assert_true(first.request.lost_unbanked_loot.is_empty(), "success request reports no lost loot")
	_assert_equal(first.request.remaining_troops, 500, "success request carries final troop state")
	_assert_equal(first.request.initial_troops, 1050, "settlement preserves expedition starting troops for Campaign casualties")
	_assert_equal(first.request.army_composition, {"infantry": 0.2, "archer": 0.1, "cavalry": 0.7}, "settlement preserves locked starting composition for Campaign casualties")
	_assert_equal(first.request.remaining_morale, 48, "success request carries final morale state")
	_assert_equal(first.request.boss_modifiers, {"armory_destroyed": true}, "success request preserves the completed strategic objective for audit")
	_assert_true(not state.has("campaign"), "success boundary still does not contain Campaign state")


func _test_retreat_discards_loot_and_preserves_losses() -> void:
	var run = _new_run("run.retreat")
	run.add_unbanked_loot("resource.silver", 90)
	run.add_temporary_buff({"id": "buff.attack", "type": "ModifyNextBattleAttack", "amount": 5})
	run.advance_to("heyuan.official.approach")
	run.begin_combat(_registry.get_enemy("enemy.normal.patrol_inspector"), 4710)
	var applied: Dictionary = run.apply_terminal_combat_result(_retreat_result(880, 61))
	_assert_true(applied.ok, "valid active retreat terminates the expedition")
	var state: Dictionary = run.snapshot()
	_assert_equal(state.status, "retreated", "retreat uses a distinct run status")
	_assert_equal(state.general.troops, 880, "retreat preserves existing troop loss")
	_assert_equal(state.general.morale, 61, "retreat preserves existing morale loss")
	_assert_true(state.unbanked_loot.is_empty(), "retreat removes unbanked loot")
	_assert_equal(state.lost_unbanked_loot, {"resource.silver": 90}, "retreat records lost loot for audit")
	_assert_true(state.temporary_buffs.is_empty(), "retreat clears expedition-only buffs")
	_assert_true(state.pending_combat.is_empty(), "retreat closes the pending combat")
	_assert_true(not run.advance_to("heyuan.official.checkpoint").ok, "retreated expedition cannot continue moving")
	var settlement: Dictionary = run.create_settlement_request()
	_assert_equal(settlement.request.outcome, "retreated", "retreat settlement outcome is distinct")
	_assert_true(settlement.request.loot_to_bank.is_empty(), "retreat cannot bank loot")
	_assert_equal(settlement.request.lost_unbanked_loot, {"resource.silver": 90}, "retreat settlement reports lost loot")
	_assert_true(not settlement.request.general_died and not settlement.request.general_injured, "retreat guarantees the general survives without new injury")


func _test_troop_defeat_preserves_death_result() -> void:
	var run = _new_run("run.troop-defeat")
	run.add_unbanked_loot("resource.food", 75)
	run.advance_to("heyuan.grain.approach")
	run.begin_combat(_registry.get_enemy("enemy.normal.crossbow_company"), 4720)
	var result := _defeat_result(0, 55, true, false)
	_assert_true(run.apply_terminal_combat_result(result).ok, "troop-zero defeat terminates the expedition")
	var settlement: Dictionary = run.create_settlement_request()
	_assert_equal(settlement.request.outcome, "failed", "troop defeat produces failed settlement")
	_assert_equal(settlement.request.remaining_troops, 0, "troop defeat preserves zero troops")
	_assert_true(settlement.request.general_died, "troop defeat preserves Combat general death")
	_assert_true(not settlement.request.general_injured, "troop death does not invent an additional injury")
	_assert_true(settlement.request.loot_to_bank.is_empty(), "failed expedition cannot bank loot")
	_assert_equal(settlement.request.lost_unbanked_loot, {"resource.food": 75}, "failed expedition records discarded loot")


func _test_morale_defeat_preserves_injury_result() -> void:
	var run = _new_run("run.morale-defeat")
	run.advance_to("heyuan.official.approach")
	run.begin_combat(_registry.get_enemy("enemy.normal.overseer_unit"), 4730)
	_assert_true(run.apply_terminal_combat_result(_defeat_result(760, 0, false, true)).ok, "morale-zero injury defeat terminates the expedition")
	var settlement: Dictionary = run.create_settlement_request()
	_assert_equal(settlement.request.remaining_troops, 760, "morale defeat preserves remaining troops")
	_assert_equal(settlement.request.remaining_morale, 0, "morale defeat preserves zero morale")
	_assert_true(not settlement.request.general_died and settlement.request.general_injured, "morale defeat preserves the injury branch")


func _test_terminal_result_validation() -> void:
	var run = _new_run("run.validation")
	run.advance_to("heyuan.official.approach")
	run.begin_combat(_registry.get_enemy("enemy.normal.patrol_inspector"), 4740)
	_assert_true(not run.apply_terminal_combat_result({"status": "victory"}).ok, "terminal API rejects a victory result")
	_assert_true(not run.apply_terminal_combat_result({"status": "retreated"}).ok, "terminal result rejects missing carryover fields")
	_assert_true(not run.apply_terminal_combat_result(_retreat_result(0, 50)).ok, "retreat cannot report zero troops")
	_assert_true(not run.apply_terminal_combat_result(_retreat_result(900, 0)).ok, "retreat cannot report zero morale")
	var injured_retreat := _retreat_result(900, 50)
	injured_retreat.general_injured = true
	_assert_true(not run.apply_terminal_combat_result(injured_retreat).ok, "retreat cannot add a general injury")
	_assert_true(not run.apply_terminal_combat_result(_defeat_result(2000, 0, false, true)).ok, "defeat rejects troops above expedition maximum")
	_assert_true(not run.pending_combat_request().is_empty(), "invalid terminal results preserve the pending checkpoint")
	_assert_true(run.apply_terminal_combat_result(_retreat_result(900, 50)).ok, "valid terminal result remains applicable after rejected inputs")
	_assert_true(not run.apply_terminal_combat_result(_retreat_result(900, 50)).ok, "terminal combat cannot settle twice")


func _complete_official_route(run) -> void:
	_settle_combat(run, "heyuan.official.approach", "enemy.normal.patrol_inspector", 1000, 75)
	_settle_combat(run, "heyuan.official.checkpoint", "enemy.normal.city_defenders", 920, 70)
	_settle_combat(run, "heyuan.official.armory", "enemy.normal.overseer_unit", 850, 68)
	_settle_combat(run, "heyuan.merge.elite", "enemy.elite.gao_wu", 720, 60)
	run.advance_to("heyuan.late.supply")
	run.complete_noncombat_node()
	_settle_combat(run, "heyuan.county_seat", "enemy.boss.yan_cheng", 500, 48)


func _settle_combat(run, node_id: String, enemy_id: String, troops: int, morale: int) -> void:
	_assert_true(run.advance_to(node_id).ok, "settlement route advances to %s" % node_id)
	_assert_true(run.begin_combat(_registry.get_enemy(enemy_id), 4790).ok, "%s begins combat" % node_id)
	_assert_true(run.apply_victory_result(_victory_result(troops, morale)).ok, "%s records victory" % node_id)


func _new_run(run_id: String):
	var general: Dictionary = _registry.get_general("general.zhao_lie")
	var snapshot := {
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
	var run = ExpeditionRunStateScript.new()
	_assert_true(run.setup(run_id, _map, snapshot, general.starting_deck).is_empty(), "%s setup succeeds" % run_id)
	return run


func _victory_result(troops: int, morale: int) -> Dictionary:
	return {"status": "victory", "player_remaining_troops": troops, "player_remaining_morale": morale}


func _retreat_result(troops: int, morale: int) -> Dictionary:
	return {
		"status": "retreated",
		"player_remaining_troops": troops,
		"player_remaining_morale": morale,
		"general_died": false,
		"general_injured": false,
	}


func _defeat_result(troops: int, morale: int, died: bool, injured: bool) -> Dictionary:
	return {
		"status": "defeat",
		"player_remaining_troops": troops,
		"player_remaining_morale": morale,
		"general_died": died,
		"general_injured": injured,
	}


func _assert_true(condition: bool, label: String) -> void:
	if condition:
		_passed += 1
		print("TEST PASS: %s" % label)
	else:
		_failed += 1
		push_error("TEST FAIL: %s" % label)


func _assert_equal(actual, expected, label: String) -> void:
	_assert_true(actual == expected, "%s (expected=%s actual=%s)" % [label, expected, actual])
