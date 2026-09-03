extends SceneTree

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")
const GameFlowCoordinatorScript := preload("res://src/application/game_flow_coordinator.gd")
const SaveFileStoreScript := preload("res://src/infrastructure/persistence/save_file_store.gd")
const SaveGameCodecScript := preload("res://src/infrastructure/persistence/save_game_codec.gd")

const SAVE_ROOT := "/tmp/dynasty-rebellion-m6-battle-report"
const EXPEDITION_ID := "expedition.capture_heyuan_county"

class ToggleSaveStore:
	extends RefCounted
	var delegate = SaveFileStoreScript.new()
	var fail_next := false

	func save(path: String, envelope: Dictionary, timestamp: String = "") -> Dictionary:
		if fail_next:
			fail_next = false
			return {"ok": false, "errors": PackedStringArray(["injected save failure"])}
		return delegate.save(path, envelope, timestamp)

	func load(path: String, registry = null) -> Dictionary:
		return delegate.load(path, registry)


var _passed := 0
var _failed := 0
var _registry
var _bundle: Dictionary = {}
var _sequence := 0


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_registry = ContentRegistryScript.new()
	_assert_true(_registry.load_all(), "M6-04G content registry loads")
	_bundle = _load_bundle()
	_test_experience_configuration()
	_test_report_checkpoint_and_transaction()
	_test_report_precedes_card_reward()
	_test_success_route_totals_one_hundred()
	_test_retreat_failure_and_death_experience()
	_test_v6_active_run_migration()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_experience_configuration() -> void:
	var values: Dictionary = _bundle.general_progression.victory_experience
	_assert_equal([
		int(values.normal_combat), int(values.military_objective), int(values.wealth_risk),
		int(values.merchant_combat), int(values.elite_combat), int(values.boss),
	], [15, 15, 15, 15, 25, 30], "all six victory classes use the approved prototype experience")
	_assert_equal(15 * 3 + 25 + 30, 100, "the fixed five-battle route remains worth one hundred experience")
	_assert_equal(100 + 15 * 2, 130, "two optional merchant attacks raise the maximum to one hundred thirty")


func _test_report_checkpoint_and_transaction() -> void:
	var root_path := "%s/checkpoint" % SAVE_ROOT
	_cleanup_root(root_path)
	var store = ToggleSaveStore.new()
	var flow = _new_flow(store, root_path)
	_assert_true(flow.new_campaign("campaign.report-checkpoint", _timestamp()).ok, "report checkpoint campaign starts")
	_assert_true(_start(flow, "run.report-checkpoint", 20260902).ok, "report checkpoint expedition starts")
	var first_node := String(flow.snapshot().expedition.route.available_next_node_ids[0])
	_assert_true(flow.advance_to_node(first_node, _timestamp()).ok and flow.phase() == "combat_checkpoint", "first hostile node creates a combat checkpoint")
	var request: Dictionary = flow.pending_combat_request()
	var result := {
		"battle_id": request.battle_id,
		"status": "victory",
		"player_remaining_troops": 1000,
		"player_remaining_morale": 70,
		"general_died": false,
		"general_injured": false,
	}
	_assert_true(flow.submit_combat_result(result, _timestamp()).ok and flow.phase() == "combat_report", "victory atomically enters the combat-report phase")
	var report: Dictionary = flow.pending_combat_report()
	_assert_equal(report.experience_gained, 15, "normal victory report grants fifteen experience")
	_assert_equal(report.pending_experience_total, 15, "report shows the accumulated run experience")
	_assert_equal(report.troops_delta, -50, "report records the exact battle troop loss")
	_assert_equal(report.morale_delta, -8, "report records the exact battle morale change")
	_assert_equal([int(report.loot_gained.get("resource.silver", 0)), int(report.loot_gained.get("resource.food", 0))], [25, 20], "report records this battle's unbanked reward")
	_assert_equal(report.unbanked_loot_total, flow.snapshot().expedition.unbanked_loot, "report total matches authoritative unbanked loot")
	_assert_true(not flow.advance_to_node(first_node, _timestamp()).ok and not flow.finalize_expedition(_timestamp()).ok, "report phase blocks map movement and final settlement")
	var duplicate_result: Dictionary = flow.submit_combat_result(result, _timestamp())
	_assert_true(duplicate_result.ok and duplicate_result.duplicate and flow.snapshot().expedition.pending_battle_experience == 15, "replayed CombatResult cannot duplicate experience or loot")

	var reloaded_store = ToggleSaveStore.new()
	var reloaded = _new_flow(reloaded_store, root_path)
	_assert_true(reloaded.load_campaign("%s/autosave.json" % root_path).ok and reloaded.phase() == "combat_report", "pending combat report restores from autosave")
	_assert_equal(reloaded.pending_combat_report(), _json_normalize(report), "restored report is byte-stable after JSON normalization")
	_assert_true(not reloaded.acknowledge_combat_report({"action_id": "report.stale", "report_id": "combat-report:stale"}, _timestamp()).ok, "stale report id is rejected")
	var before_failed_ack: Dictionary = reloaded.snapshot()
	reloaded_store.fail_next = true
	var failed_ack: Dictionary = reloaded.acknowledge_combat_report({"action_id": "report.ack", "report_id": report.report_id}, _timestamp())
	_assert_true(not failed_ack.ok and failed_ack.get("save_failed", false), "report acknowledgement exposes autosave failure")
	_assert_equal(reloaded.snapshot(), before_failed_ack, "failed acknowledgement restores the unacknowledged report")
	var acknowledged: Dictionary = reloaded.acknowledge_combat_report({"action_id": "report.ack", "report_id": report.report_id}, _timestamp())
	_assert_true(acknowledged.ok and reloaded.phase() == "expedition_map", "successful acknowledgement returns to the map")
	var after_ack: Dictionary = reloaded.snapshot()
	var duplicate_ack: Dictionary = reloaded.acknowledge_combat_report({"action_id": "report.ack", "report_id": report.report_id}, _timestamp())
	_assert_true(duplicate_ack.ok and duplicate_ack.duplicate and reloaded.snapshot() == after_ack, "replayed acknowledgement is idempotent")


func _test_report_precedes_card_reward() -> void:
	var root_path := "%s/reward-order" % SAVE_ROOT
	_cleanup_root(root_path)
	var flow = _new_flow(ToggleSaveStore.new(), root_path)
	_assert_true(flow.new_campaign("campaign.report-reward", _timestamp()).ok, "reward-order campaign starts")
	_assert_true(_start(flow, "run.report-reward", 5150).ok, "reward-order expedition starts")
	_assert_true(_advance_until_combat(flow), "reward-order route reaches its opening combat")
	_submit_current_victory(flow)
	_ack_report(flow)
	_assert_true(_advance_until_combat(flow), "reward-order route reaches the layer-three combat")
	_submit_current_victory(flow)
	var report: Dictionary = flow.pending_combat_report()
	_assert_true(flow.phase() == "combat_report" and bool(report.post_battle_reward_pending), "combat report takes priority while the card reward remains pending")
	_assert_true(not flow.pending_encounter().is_empty(), "card choices are frozen behind the report checkpoint")
	_ack_report(flow)
	_assert_equal(flow.phase(), "reward_choice", "acknowledging the report reveals the frozen card reward")


func _test_success_route_totals_one_hundred() -> void:
	var root_path := "%s/success" % SAVE_ROOT
	_cleanup_root(root_path)
	var flow = _new_flow(ToggleSaveStore.new(), root_path)
	_assert_true(flow.new_campaign("campaign.report-success", _timestamp()).ok, "success-total campaign starts")
	_assert_true(_start(flow, "run.report-success", 9001).ok, "success-total expedition starts")
	var terminal_report: Dictionary = {}
	for step in 48:
		match flow.phase():
			"expedition_map":
				var available: Array = flow.snapshot().expedition.route.available_next_node_ids
				if not available.is_empty():
					flow.advance_to_node(String(available[0]), _timestamp())
			"encounter_choice", "reward_choice":
				_submit_safe_choice(flow)
			"combat_checkpoint":
				_submit_current_victory(flow)
			"combat_report":
				if bool(flow.pending_combat_report().get("expedition_terminal", false)):
					terminal_report = flow.pending_combat_report()
				_ack_report(flow)
			"settlement_pending":
				break
		if flow.phase() == "settlement_pending":
			break
	var expedition: Dictionary = flow.snapshot().expedition
	_assert_equal(expedition.battle_experience_ledger.map(func(entry): return int(entry.amount)), [15, 15, 25, 15, 30], "mandatory V4 battles award normal, normal, elite, normal and Boss experience")
	_assert_equal(expedition.pending_battle_experience, 100, "successful mandatory route accumulates exactly one hundred experience")
	_assert_equal(terminal_report.experience_gained, 30, "Boss large-victory report grants thirty experience")
	_assert_true(bool(terminal_report.expedition_terminal), "Boss report points to the final expedition report")
	_assert_true(flow.finalize_expedition(_timestamp()).ok, "one-hundred-experience expedition finalizes")
	_assert_equal(flow.snapshot().campaign.generals[0].experience, 100, "Campaign receives the actual accumulated battle experience")
	_assert_equal(flow.snapshot().campaign.generals[0].level, 2, "return-time settlement applies the projected single level up")


func _test_retreat_failure_and_death_experience() -> void:
	for outcome in ["retreated", "defeat", "death"]:
		var root_path := "%s/%s" % [SAVE_ROOT, outcome]
		_cleanup_root(root_path)
		var flow = _new_flow(ToggleSaveStore.new(), root_path)
		_assert_true(flow.new_campaign("campaign.report-%s" % outcome, _timestamp()).ok, "%s campaign starts" % outcome)
		_assert_true(_start(flow, "run.report-%s" % outcome, 6100 + _sequence).ok, "%s expedition starts" % outcome)
		_assert_true(_advance_until_combat(flow), "%s route reaches the first combat" % outcome)
		_submit_current_victory(flow)
		_ack_report(flow)
		_assert_true(_advance_until_combat(flow), "%s route reaches a later combat" % outcome)
		var request: Dictionary = flow.pending_combat_request()
		var terminal := {
			"battle_id": request.battle_id,
			"status": "retreated" if outcome == "retreated" else "defeat",
			"player_remaining_troops": 900 if outcome != "death" else 0,
			"player_remaining_morale": 60 if outcome != "defeat" else 0,
			"general_died": outcome == "death",
			"general_injured": outcome == "defeat",
		}
		if outcome == "death":
			terminal.player_remaining_morale = 40
		_assert_true(flow.submit_combat_result(terminal, _timestamp()).ok and flow.phase() == "settlement_pending", "%s does not create a false victory report" % outcome)
		_assert_true(flow.finalize_expedition(_timestamp()).ok, "%s settlement finalizes" % outcome)
		var general: Dictionary = flow.snapshot().campaign.generals[0]
		_assert_equal(general.experience, 0 if outcome == "death" else 15, "%s applies the correct retained battle experience" % outcome)


func _test_v6_active_run_migration() -> void:
	var root_path := "%s/migration" % SAVE_ROOT
	_cleanup_root(root_path)
	var flow = _new_flow(ToggleSaveStore.new(), root_path)
	_assert_true(flow.new_campaign("campaign.report-migration", _timestamp()).ok, "V6 migration campaign starts")
	_assert_true(_start(flow, "run.report-migration", 7007).ok and _advance_until_combat(flow), "V6 migration expedition reaches combat")
	_submit_current_victory(flow)
	_ack_report(flow)
	var source: Dictionary = flow.snapshot()
	source.erase("phase")
	source.save_version = 6
	source.content_version = "0.7.2-m6-route-variety"
	source.campaign.generals[0].experience = 75
	for field in ["initial_general_level", "initial_general_experience", "pending_battle_experience", "battle_experience_ledger", "pending_combat_report", "acknowledged_combat_report_action_ids", "combat_report_history", "experience_migration"]:
		source.expedition.erase(field)
	var decoded: Dictionary = SaveGameCodecScript.new().decode(JSON.stringify(source))
	_assert_true(decoded.ok and decoded.to_version == 7, "V6 active expedition migrates to Save V7")
	_assert_equal(decoded.value.expedition.initial_general_experience, 75, "migration derives initial experience from the Campaign general")
	_assert_true(decoded.value.expedition.pending_combat_report.is_empty(), "historical victories do not synthesize a pending report")
	var path := "%s/autosave.json" % root_path
	_assert_true(SaveFileStoreScript.new().save(path, decoded.value, _timestamp()).ok, "migrated active expedition persists")
	var restored = _new_flow(ToggleSaveStore.new(), root_path)
	_assert_true(restored.load_campaign(path).ok, "migrated active expedition restores through the coordinator")
	_assert_equal(restored.snapshot().expedition.pending_battle_experience, 15, "restore reconstructs won-battle experience from resolution history")
	_assert_equal(restored.snapshot().expedition.battle_experience_ledger.size(), 1, "restore reconstructs one stable ledger entry")
	_assert_true(restored.phase() != "combat_report", "migration never replays a report for an old victory")


func _advance_until_combat(flow) -> bool:
	for step in 12:
		match flow.phase():
			"combat_checkpoint":
				return true
			"expedition_map":
				var available: Array = flow.snapshot().expedition.route.available_next_node_ids
				if available.is_empty():
					return false
				var advanced: Dictionary = flow.advance_to_node(String(available[0]), _timestamp())
				if not advanced.ok:
					return false
			"encounter_choice", "reward_choice":
				if not _submit_safe_choice(flow):
					return false
			"combat_report":
				_ack_report(flow)
	return flow.phase() == "combat_checkpoint"


func _submit_current_victory(flow) -> Dictionary:
	var request: Dictionary = flow.pending_combat_request()
	var expedition: Dictionary = flow.snapshot().expedition
	return flow.submit_combat_result({
		"battle_id": request.battle_id,
		"status": "victory",
		"player_remaining_troops": int(expedition.general.troops),
		"player_remaining_morale": int(expedition.general.morale),
		"general_died": false,
		"general_injured": false,
	}, _timestamp())


func _ack_report(flow) -> Dictionary:
	var report: Dictionary = flow.pending_combat_report()
	_sequence += 1
	return flow.acknowledge_combat_report({"action_id": "report.ack.%d" % _sequence, "report_id": report.get("report_id", "")}, _timestamp())


func _submit_safe_choice(flow) -> bool:
	var encounter: Dictionary = flow.pending_encounter()
	var selected := ""
	for preferred in ["leave", "skip", "observe", "mark", "avoid", "detour", "rest"]:
		for choice in encounter.get("choices", []):
			if choice.get("choice_id", "") == preferred and bool(choice.get("available", false)):
				selected = preferred
				break
		if not selected.is_empty():
			break
	if selected.is_empty():
		for choice in encounter.get("choices", []):
			if bool(choice.get("available", false)):
				selected = String(choice.choice_id)
				break
	if selected.is_empty():
		return false
	_sequence += 1
	return bool(flow.submit_encounter_choice({"action_id": "choice.safe.%d" % _sequence, "choice_id": selected}, _timestamp()).get("ok", false))


func _start(flow, run_id: String, seed: int) -> Dictionary:
	return flow.start_expedition({"run_id": run_id, "expedition_id": EXPEDITION_ID, "general_id": "general.zhao_lie", "map_seed": seed}, _timestamp())


func _new_flow(store, root_path: String):
	var flow = GameFlowCoordinatorScript.new()
	var errors: PackedStringArray = flow.setup(_registry, _bundle, store, root_path)
	_assert_true(errors.is_empty(), "battle-report flow configures at %s" % root_path.get_file())
	return flow


func _load_bundle() -> Dictionary:
	return {
		"bootstrap": _load_json("res://data/config/prototype_campaign_bootstrap.json"),
		"deployment_rules": _load_json("res://data/config/prototype_deployment_rules.json"),
		"encounters": _load_json("res://data/config/prototype_rogue_expeditions.json"),
		"legacy_encounters": _load_json("res://data/config/prototype_heyuan_encounters.json"),
		"army_economy": _load_json("res://data/config/prototype_army_economy.json"),
		"research_economy": _load_json("res://data/config/prototype_research_economy.json"),
		"general_progression": _load_json("res://data/config/prototype_general_progression.json"),
		"faction_cycle": _load_json("res://data/config/prototype_faction_cycle.json"),
	}


func _load_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	return JSON.parse_string(file.get_as_text())


func _json_normalize(value):
	return JSON.parse_string(JSON.stringify(value))


func _timestamp() -> String:
	_sequence += 1
	return "2026-09-02T20:%02d:%02dZ" % [(_sequence / 60) % 60, _sequence % 60]


func _cleanup_root(root_path: String) -> void:
	for name in ["autosave.json", "autosave.json.bak", "autosave.json.tmp", "manual_1.json", "manual_1.json.bak", "manual_1.json.tmp"]:
		var path := "%s/%s" % [root_path, name]
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func _assert_true(condition: bool, label: String) -> void:
	if condition:
		_passed += 1
		print("TEST PASS: %s" % label)
	else:
		_failed += 1
		push_error("TEST FAIL: %s" % label)


func _assert_equal(actual, expected, label: String) -> void:
	_assert_true(actual == expected, "%s (expected=%s actual=%s)" % [label, expected, actual])
