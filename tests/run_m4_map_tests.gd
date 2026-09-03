extends SceneTree

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")
const DefinitionValidatorScript := preload("res://src/domain/expedition/expedition_definition_validator.gd")
const MapGeneratorScript := preload("res://src/domain/expedition/expedition_map_generator.gd")
const RouteStateScript := preload("res://src/domain/expedition/expedition_route_state.gd")

const EXPEDITION_ID := "expedition.capture_heyuan_county"

var _passed := 0
var _failed := 0
var _registry
var _definition: Dictionary


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_registry = ContentRegistryScript.new()
	_assert_true(_registry.load_all(), "M4 map content registry loads")
	_definition = _registry.get_expedition(EXPEDITION_ID)
	_test_heyuan_definition_contract()
	_test_definition_failure_paths()
	_test_seeded_generation()
	_test_route_progression_and_fog()
	_test_route_failure_paths()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_heyuan_definition_contract() -> void:
	_assert_equal(_registry.expedition_count(), 3, "registry contains all three Rogue Vertical Slice expeditions")
	_assert_true(_registry.has_expedition(EXPEDITION_ID), "Heyuan expedition is addressable by stable id")
	_assert_equal(_definition.nodes.size(), 15, "Heyuan authored skeleton contains fifteen nodes")
	_assert_true(DefinitionValidatorScript.validate(_definition, "heyuan-test").is_empty(), "Heyuan definition satisfies the expedition contract")
	_assert_equal(_definition.entry_node_id, "heyuan.start", "Heyuan entry node is stable")
	_assert_equal(_definition.boss_node_id, "heyuan.county_seat", "Heyuan boss node is stable")
	_assert_equal(_definition.strategic_objectives.size(), 3, "Heyuan defines exactly three strategic objectives")
	_assert_equal(_definition.strategic_objectives.official_road.boss_modifier_id, "armory_destroyed", "official road targets the armory modifier")
	_assert_equal(_definition.strategic_objectives.village_path.boss_modifier_id, "beacon_destroyed", "village path targets the beacon modifier")
	_assert_equal(_definition.strategic_objectives.grain_route.boss_modifier_id, "granary_destroyed", "grain route targets the granary modifier")


func _test_definition_failure_paths() -> void:
	var duplicate := _definition.duplicate(true)
	duplicate.nodes.append(duplicate.nodes[0].duplicate(true))
	_assert_error_contains(DefinitionValidatorScript.validate(duplicate, "duplicate"), "duplicate expedition node id", "duplicate expedition node id is rejected")
	var backward := _definition.duplicate(true)
	backward.edges.append({"from": "heyuan.county_seat", "to": "heyuan.start"})
	_assert_error_contains(DefinitionValidatorScript.validate(backward, "backward"), "must advance to a higher column", "backward map edge is rejected")
	var unknown_edge := _definition.duplicate(true)
	unknown_edge.edges[0].to = "heyuan.missing"
	_assert_error_contains(DefinitionValidatorScript.validate(unknown_edge, "unknown-edge"), "references unknown node", "edge to an unknown node is rejected")
	var bad_option := _definition.duplicate(true)
	bad_option.nodes[1].node_type_options = ["unlocked_future_type"]
	_assert_error_contains(DefinitionValidatorScript.validate(bad_option, "bad-option"), "unsupported node type option", "unsupported random node type is rejected")
	var boss_without_enemy := _definition.duplicate(true)
	boss_without_enemy.nodes[14].erase("enemy_id")
	_assert_error_contains(DefinitionValidatorScript.validate(boss_without_enemy, "boss-without-enemy"), "requires enemy_id", "boss node without an enemy reference is rejected")
	var missing_objective := _definition.duplicate(true)
	missing_objective.strategic_objectives.erase("grain_route")
	_assert_error_contains(DefinitionValidatorScript.validate(missing_objective, "missing-objective"), "missing strategic objective", "missing strategic route objective is rejected")
	var too_short := _definition.duplicate(true)
	too_short.nodes.resize(11)
	_assert_error_contains(DefinitionValidatorScript.validate(too_short, "too-short"), "node count must be between", "expedition below twelve nodes is rejected")
	var invalid_generation: Dictionary = MapGeneratorScript.generate(backward, 10)
	_assert_true(not invalid_generation.ok and invalid_generation.map.is_empty(), "generator refuses an invalid authored skeleton")


func _test_seeded_generation() -> void:
	var source_before := _definition.duplicate(true)
	var first: Dictionary = MapGeneratorScript.generate(_definition, 4101)
	var replay: Dictionary = MapGeneratorScript.generate(_definition, 4101)
	_assert_true(first.ok, "valid Heyuan definition generates a map")
	_assert_true(first.map == replay.map, "same expedition seed reproduces the complete generated map")
	_assert_true(_definition == source_before, "map generation does not mutate the shared expedition definition")
	_assert_equal(first.map.nodes.size(), 15, "generated map retains the authored node count")
	_assert_equal(first.map.node_by_id["heyuan.official.armory"].node_type, "military_objective", "seed cannot replace the armory strategic node")
	_assert_equal(first.map.node_by_id["heyuan.merge.elite"].node_type, "elite_combat", "seed cannot replace the merge elite node")
	_assert_equal(first.map.node_by_id["heyuan.county_seat"].node_type, "boss", "seed cannot replace the boss node")
	for node in first.map.nodes:
		_assert_true(not node.has("node_type_options"), "generated node %s resolves its public type" % node.id)
	var first_signature := _random_node_signature(first.map)
	var found_variant := false
	for seed in range(4102, 4121):
		var candidate: Dictionary = MapGeneratorScript.generate(_definition, seed)
		if candidate.ok and _random_node_signature(candidate.map) != first_signature:
			found_variant = true
			break
	_assert_true(found_variant, "different seeds can vary ordinary nodes without moving the strategic skeleton")


func _test_route_progression_and_fog() -> void:
	var generated: Dictionary = MapGeneratorScript.generate(_definition, 4201)
	var route = RouteStateScript.new()
	_assert_true(route.setup(generated.map).is_empty(), "route state accepts a generated Heyuan map")
	var opening: Dictionary = route.snapshot()
	_assert_equal(opening.current_node_id, "heyuan.start", "route starts at the authored entry")
	_assert_equal(opening.available_next_node_ids.size(), 3, "opening exposes the three strategic routes")
	var visible := _nodes_by_id(route.visible_nodes())
	_assert_true(visible["heyuan.official.approach"].is_revealed, "first official-road node is revealed when reachable")
	_assert_equal(visible["heyuan.official.checkpoint"].node_type, "unknown", "deeper ordinary node remains under fog")
	_assert_equal(visible["heyuan.merge.elite"].node_type, "unknown", "merge elite remains under fog before approach")
	_assert_equal(visible["heyuan.official.armory"].node_type, "military_objective", "strategic route objective remains visible for planning")
	_assert_equal(visible["heyuan.county_seat"].node_type, "boss", "final mission objective remains visible")

	_assert_true(route.advance_to("heyuan.official.approach").ok, "player can choose the official road")
	_assert_true(route.available_next_node_ids().is_empty(), "unresolved current node blocks further movement")
	_assert_true(route.complete_current_node().ok, "current ordinary node can be marked complete")
	_assert_equal(route.available_next_node_ids(), ["heyuan.official.checkpoint"], "completion unlocks only the authored forward edge")
	visible = _nodes_by_id(route.visible_nodes())
	_assert_true(visible["heyuan.official.checkpoint"].is_revealed, "completing a node reveals its successor")
	_assert_true(route.advance_to("heyuan.official.checkpoint").ok, "route advances to the revealed successor")
	_assert_true(route.complete_current_node().ok, "second official-road node completes")
	_assert_true(route.advance_to("heyuan.official.armory").ok, "official road reaches the armory")
	_assert_true(route.complete_current_node().ok, "armory node completes")
	_assert_true(route.advance_to("heyuan.merge.elite").ok, "three front routes converge on the elite")
	_assert_true(route.complete_current_node().ok, "merge elite node completes")
	_assert_equal(route.available_next_node_ids().size(), 3, "elite completion exposes intel, supply, and wealth choices")
	_assert_true(route.advance_to("heyuan.late.intel").ok, "player can choose the late intel route")
	_assert_true(route.complete_current_node().ok, "late intel node completes")
	_assert_equal(route.available_next_node_ids(), ["heyuan.county_seat"], "late route must lead to the county-seat boss")
	_assert_true(route.advance_to("heyuan.county_seat").ok, "route reaches the mandatory boss")
	_assert_true(route.complete_current_node().ok, "boss completion closes the map route")
	var completed: Dictionary = route.snapshot()
	_assert_equal(completed.status, "completed", "boss completion marks the route complete")
	_assert_equal(completed.visited_node_ids.size(), 7, "one Heyuan route visits seven nodes including entry and boss")


func _test_route_failure_paths() -> void:
	var invalid_route = RouteStateScript.new()
	_assert_true(not invalid_route.setup({}).is_empty(), "route setup rejects a malformed generated map")
	var generated: Dictionary = MapGeneratorScript.generate(_definition, 4301)
	var route = RouteStateScript.new()
	route.setup(generated.map)
	_assert_true(not route.advance_to("heyuan.official.checkpoint").ok, "route cannot skip an authored node")
	route.advance_to("heyuan.village.approach")
	_assert_true(not route.advance_to("heyuan.village.contact").ok, "route cannot advance before current node completion")
	route.complete_current_node()
	_assert_true(not route.complete_current_node().ok, "route cannot settle the same node twice")
	_assert_true(not route.advance_to("heyuan.start").ok, "route cannot return to the entry node")
	_assert_true(not route.advance_to("heyuan.official.checkpoint").ok, "route cannot cross into another front route")


func _random_node_signature(generated_map: Dictionary) -> String:
	var values: Array[String] = []
	for node in generated_map.nodes:
		if bool(node.get("generated_from_options", false)):
			values.append("%s=%s" % [node.id, node.node_type])
	return "|".join(values)


func _nodes_by_id(nodes: Array[Dictionary]) -> Dictionary:
	var result := {}
	for node in nodes:
		result[node.id] = node
	return result


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
