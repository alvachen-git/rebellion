extends SceneTree

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")
const FixedStrategyRunnerScript := preload("res://src/domain/combat/fixed_strategy_combat_runner.gd")

const GENERAL_IDS := ["general.zhao_lie", "general.zhou_jing", "general.han_yue"]
const ENEMY_IDS := [
	"enemy.normal.patrol_inspector",
	"enemy.normal.local_militia",
	"enemy.normal.city_defenders",
	"enemy.normal.crossbow_company",
	"enemy.normal.overseer_unit",
	"enemy.elite.gao_wu",
	"enemy.elite.he_wei",
	"enemy.boss.yan_cheng",
]
const TARGET_TURNS := {
	"normal": Vector2i(3, 5),
	"elite": Vector2i(4, 7),
	"boss": Vector2i(6, 10),
}

var _passed := 0
var _failed := 0
var _registry


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_registry = ContentRegistryScript.new()
	_assert_true(_registry.load_all(), "M3 balance content registry loads")
	_test_invalid_runner_inputs()
	_test_fixed_strategy_is_deterministic()
	_test_matrix_and_print_report()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_invalid_runner_inputs() -> void:
	var unknown_general: Dictionary = FixedStrategyRunnerScript.run_battle("general.missing", ENEMY_IDS[0], 1, _registry)
	_assert_equal(unknown_general.status, "setup_error", "fixed strategy rejects an unknown general")
	var unknown_enemy: Dictionary = FixedStrategyRunnerScript.run_battle(GENERAL_IDS[0], "enemy.missing", 1, _registry)
	_assert_equal(unknown_enemy.status, "setup_error", "fixed strategy rejects an unknown enemy")
	var invalid_limit: Dictionary = FixedStrategyRunnerScript.run_battle(GENERAL_IDS[0], ENEMY_IDS[0], 1, _registry, 0)
	_assert_equal(invalid_limit.status, "setup_error", "fixed strategy rejects a non-positive turn limit")
	var timeout: Dictionary = FixedStrategyRunnerScript.run_battle(GENERAL_IDS[0], "enemy.boss.yan_cheng", 1, _registry, 1)
	_assert_true(timeout.timed_out and timeout.turns == 1, "fixed strategy reports the exact turn-limit boundary")
	var invalid_modifier: Dictionary = FixedStrategyRunnerScript.run_battle(
		GENERAL_IDS[0], ENEMY_IDS[0], 1, _registry, 20, {"armory_destroyed": true}
	)
	_assert_equal(invalid_modifier.status, "setup_error", "fixed strategy preserves boss modifier request validation")


func _test_fixed_strategy_is_deterministic() -> void:
	var first: Dictionary = FixedStrategyRunnerScript.run_battle("general.han_yue", "enemy.elite.he_wei", 7, _registry)
	var second: Dictionary = FixedStrategyRunnerScript.run_battle("general.han_yue", "enemy.elite.he_wei", 7, _registry)
	_assert_equal(first, second, "same matchup, strategy, and seed reproduce the full statistics row")


func _test_matrix_and_print_report() -> void:
	var seeds: Array = range(1, 21)
	var rows: Array[Dictionary] = FixedStrategyRunnerScript.run_matrix(GENERAL_IDS, ENEMY_IDS, seeds, _registry)
	_assert_equal(rows.size(), GENERAL_IDS.size() * ENEMY_IDS.size() * seeds.size(), "balance matrix runs three builds against eight enemies over twenty seeds")
	var setup_errors := 0
	var invalid_turns := 0
	var invalid_statuses := 0
	var troop_victories := 0
	var morale_victories := 0
	var talent_seen := {"general.zhao_lie": false, "general.zhou_jing": false, "general.han_yue": false}
	for row in rows:
		if row.status == "setup_error":
			setup_errors += 1
		if not row.status in ["victory", "defeat", "timeout"]:
			invalid_statuses += 1
		if int(row.get("turns", 0)) < 1 or int(row.get("turns", 0)) > 20:
			invalid_turns += 1
		if row.get("reason", "") == "enemy_troops_zero":
			troop_victories += 1
		elif row.get("reason", "") == "enemy_morale_zero":
			morale_victories += 1
		if int(row.get("player_talent_triggers", 0)) > 0:
			talent_seen[row.general_id] = true
	_assert_equal(setup_errors, 0, "all balance matrix battles satisfy runtime contracts")
	_assert_equal(invalid_statuses, 0, "all balance matrix battles end or report the explicit timeout state")
	_assert_equal(invalid_turns, 0, "all balance rows stay inside the declared turn boundary")
	_assert_true(troop_victories > 0, "fixed strategy matrix demonstrates troop victory")
	_assert_true(morale_victories > 0, "fixed strategy matrix demonstrates morale victory")
	for general_id in GENERAL_IDS:
		_assert_true(talent_seen[general_id], "%s fixed strategy demonstrates its general talent" % general_id)
	_print_matchup_rows(rows)
	_print_tier_rows(rows)


func _print_matchup_rows(rows: Array[Dictionary]) -> void:
	for general_id in GENERAL_IDS:
		for enemy_id in ENEMY_IDS:
			var selected := _select_rows(rows, general_id, enemy_id)
			var enemy: Dictionary = _registry.get_enemy(enemy_id)
			var summary := _summarize(selected)
			var target: Vector2i = TARGET_TURNS[enemy.tier]
			var range_status := "IN_RANGE" if summary.average_turns >= target.x and summary.average_turns <= target.y else "OUT_OF_RANGE"
			print("BALANCE MATCHUP | %s | %s | %s | W-D-T %d-%d-%d | troop/morale wins %d/%d | turns %.2f [%d,%d] | troop_loss %.1f | morale_loss %.1f | %s" % [
				general_id,
				enemy_id,
				enemy.tier,
				summary.victories,
				summary.defeats,
				summary.timeouts,
				summary.troop_victories,
				summary.morale_victories,
				summary.average_turns,
				summary.minimum_turns,
				summary.maximum_turns,
				summary.average_player_troops_lost,
				summary.average_player_morale_lost,
				range_status,
			])


func _print_tier_rows(rows: Array[Dictionary]) -> void:
	for tier in ["normal", "elite", "boss"]:
		var selected: Array[Dictionary] = []
		for row in rows:
			if _registry.get_enemy(row.enemy_id).tier == tier:
				selected.append(row)
		var summary := _summarize(selected)
		var target: Vector2i = TARGET_TURNS[tier]
		var range_status := "IN_RANGE" if summary.average_turns >= target.x and summary.average_turns <= target.y else "OUT_OF_RANGE"
		print("BALANCE TIER | %s | battles %d | W-D-T %d-%d-%d | troop/morale wins %d/%d | turns %.2f [%d,%d] | target %d-%d | %s" % [
			tier,
			selected.size(),
			summary.victories,
			summary.defeats,
			summary.timeouts,
			summary.troop_victories,
			summary.morale_victories,
			summary.average_turns,
			summary.minimum_turns,
			summary.maximum_turns,
			target.x,
			target.y,
			range_status,
		])


func _select_rows(rows: Array[Dictionary], general_id: String, enemy_id: String) -> Array[Dictionary]:
	var selected: Array[Dictionary] = []
	for row in rows:
		if row.general_id == general_id and row.enemy_id == enemy_id:
			selected.append(row)
	return selected


func _summarize(rows: Array[Dictionary]) -> Dictionary:
	var victories := 0
	var defeats := 0
	var timeouts := 0
	var troop_victories := 0
	var morale_victories := 0
	var turn_total := 0
	var troop_loss_total := 0
	var morale_loss_total := 0
	var minimum_turns := 999
	var maximum_turns := 0
	for row in rows:
		match row.status:
			"victory":
				victories += 1
				if row.reason == "enemy_troops_zero":
					troop_victories += 1
				elif row.reason == "enemy_morale_zero":
					morale_victories += 1
			"defeat": defeats += 1
			"timeout": timeouts += 1
		var turns := int(row.turns)
		turn_total += turns
		minimum_turns = mini(minimum_turns, turns)
		maximum_turns = maxi(maximum_turns, turns)
		troop_loss_total += int(row.player_troops_lost)
		morale_loss_total += int(row.player_morale_lost)
	var count := maxi(rows.size(), 1)
	return {
		"victories": victories,
		"defeats": defeats,
		"timeouts": timeouts,
		"troop_victories": troop_victories,
		"morale_victories": morale_victories,
		"average_turns": float(turn_total) / float(count),
		"minimum_turns": 0 if rows.is_empty() else minimum_turns,
		"maximum_turns": maximum_turns,
		"average_player_troops_lost": float(troop_loss_total) / float(count),
		"average_player_morale_lost": float(morale_loss_total) / float(count),
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
