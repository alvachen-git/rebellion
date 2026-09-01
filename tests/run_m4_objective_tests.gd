extends SceneTree

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")
const CombatControllerScript := preload("res://src/domain/combat/combat_controller.gd")
const MapGeneratorScript := preload("res://src/domain/expedition/expedition_map_generator.gd")
const ExpeditionRunStateScript := preload("res://src/domain/expedition/expedition_run_state.gd")

const ROUTES := {
	"official_road": {
		"nodes": ["heyuan.official.approach", "heyuan.official.checkpoint", "heyuan.official.armory"],
		"modifier": "armory_destroyed",
	},
	"village_path": {
		"nodes": ["heyuan.village.approach", "heyuan.village.contact", "heyuan.village.beacon"],
		"modifier": "beacon_destroyed",
	},
	"grain_route": {
		"nodes": ["heyuan.grain.approach", "heyuan.grain.cache", "heyuan.grain.granary"],
		"modifier": "granary_destroyed",
	},
}

var _passed := 0
var _failed := 0
var _registry
var _map: Dictionary


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_registry = ContentRegistryScript.new()
	_assert_true(_registry.load_all(), "M4 objective content registry loads")
	_map = MapGeneratorScript.generate(_registry.get_expedition("expedition.capture_heyuan_county"), 4601).map
	_test_each_route_applies_only_its_boss_modifier()
	_test_objective_transaction_boundary()
	_test_boss_enemy_binding()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_each_route_applies_only_its_boss_modifier() -> void:
	for route_id in ROUTES:
		var spec: Dictionary = ROUTES[route_id]
		var run = _new_run("run.objective.%s" % route_id)
		for node_id in spec.nodes:
			_assert_true(run.advance_to(node_id).ok, "%s advances to %s" % [route_id, node_id])
			_settle_current_node(run, 1000, 75)
		var after_objective: Dictionary = run.snapshot()
		_assert_equal(after_objective.boss_modifiers, {spec.modifier: true}, "%s records only its strategic objective" % route_id)
		_assert_true(run.advance_to("heyuan.merge.elite").ok, "%s reaches the merge elite" % route_id)
		var elite: Dictionary = run.begin_combat(_registry.get_enemy("enemy.elite.gao_wu"), 4610)
		_assert_true(elite.ok, "%s starts the merge elite battle" % route_id)
		_assert_true(elite.request.boss_modifiers.is_empty(), "Boss modifier is not attached to the merge elite request")
		_assert_true(run.apply_victory_result(_victory_result(900, 70)).ok, "%s completes the merge elite" % route_id)
		_assert_true(run.advance_to("heyuan.late.supply").ok, "%s reaches the late supply route" % route_id)
		_assert_true(run.complete_noncombat_node().ok, "%s completes late supply" % route_id)
		_assert_true(run.advance_to("heyuan.county_seat").ok, "%s reaches Yan Cheng" % route_id)
		var boss: Dictionary = run.begin_combat(_registry.get_enemy("enemy.boss.yan_cheng"), 4620)
		_assert_true(boss.ok, "%s creates the Boss CombatRequest" % route_id)
		_assert_equal(boss.request.boss_modifiers, {spec.modifier: true}, "%s passes only its modifier to Yan Cheng" % route_id)
		var controller = CombatControllerScript.new()
		_assert_true(controller.setup(boss.request, _registry).is_empty(), "%s Boss request passes the real combat contract" % route_id)
		_assert_equal(controller.snapshot().boss_modifiers, {spec.modifier: true}, "%s modifier reaches CombatController" % route_id)


func _test_objective_transaction_boundary() -> void:
	var run = _new_run("run.objective.transaction")
	run.advance_to("heyuan.official.approach")
	_settle_current_node(run, 1000, 75)
	run.advance_to("heyuan.official.checkpoint")
	_settle_current_node(run, 950, 72)
	run.advance_to("heyuan.official.armory")
	var begun: Dictionary = run.begin_combat(_registry.get_enemy("enemy.normal.overseer_unit"), 4630)
	_assert_true(begun.ok, "armory combat begins")
	_assert_true(run.snapshot().boss_modifiers.is_empty(), "starting an objective battle does not complete the objective")
	_assert_true(not run.apply_victory_result({"status": "defeat"}).ok, "invalid objective result is rejected")
	_assert_true(run.snapshot().boss_modifiers.is_empty(), "rejected objective result cannot apply a Boss modifier")
	_assert_true(run.apply_victory_result(_victory_result(850, 65)).ok, "valid armory victory settles")
	_assert_equal(run.snapshot().boss_modifiers, {"armory_destroyed": true}, "modifier applies exactly at valid objective settlement")


func _test_boss_enemy_binding() -> void:
	var run = _new_run("run.boss.binding")
	for node_id in ROUTES.official_road.nodes:
		run.advance_to(node_id)
		_settle_current_node(run, 1000, 75)
	run.advance_to("heyuan.merge.elite")
	_settle_current_node(run, 900, 70)
	run.advance_to("heyuan.late.intel")
	run.complete_noncombat_node()
	run.advance_to("heyuan.county_seat")
	_assert_true(not run.begin_combat(_registry.get_enemy("enemy.normal.patrol_inspector"), 4640).ok, "Boss node rejects a substituted normal enemy")
	_assert_true(run.begin_combat(_registry.get_enemy("enemy.boss.yan_cheng"), 4640).ok, "Boss node accepts its configured Yan Cheng definition")


func _settle_current_node(run, troops: int, morale: int) -> void:
	var current: Dictionary = _current_visible_node(run)
	if current.node_type in ["normal_combat", "elite_combat", "military_objective", "wealth_risk", "boss"]:
		var enemy_id := "enemy.normal.patrol_inspector"
		if current.node_type == "elite_combat":
			enemy_id = "enemy.elite.gao_wu"
		elif current.node_type == "boss":
			enemy_id = "enemy.boss.yan_cheng"
		_assert_true(run.begin_combat(_registry.get_enemy(enemy_id), 4690).ok, "%s starts its required battle" % current.id)
		_assert_true(run.apply_victory_result(_victory_result(troops, morale)).ok, "%s victory settles" % current.id)
	else:
		_assert_true(run.complete_noncombat_node().ok, "%s noncombat node settles" % current.id)


func _current_visible_node(run) -> Dictionary:
	var state: Dictionary = run.snapshot()
	for node in state.visible_nodes:
		if node.id == state.route.current_node_id:
			return node
	return {}


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


func _assert_true(condition: bool, label: String) -> void:
	if condition:
		_passed += 1
		print("TEST PASS: %s" % label)
	else:
		_failed += 1
		push_error("TEST FAIL: %s" % label)


func _assert_equal(actual, expected, label: String) -> void:
	_assert_true(actual == expected, "%s (expected=%s actual=%s)" % [label, expected, actual])
