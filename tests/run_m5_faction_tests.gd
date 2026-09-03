extends SceneTree

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")
const FactionCycleServiceScript := preload("res://src/domain/campaign/faction_cycle_service.gd")
const GeneralManagementServiceScript := preload("res://src/domain/campaign/general_management_service.gd")
const CampaignStateScript := preload("res://src/domain/campaign/campaign_state.gd")
const CampaignControllerScript := preload("res://src/domain/campaign/campaign_controller.gd")
const SaveEnvelopeScript := preload("res://src/domain/campaign/save_envelope.gd")
const SaveGameCodecScript := preload("res://src/infrastructure/persistence/save_game_codec.gd")

const CYCLE_CONFIG_PATH := "res://data/config/prototype_faction_cycle.json"
const HEYUAN_ID := "territory.heyuan_county"

var _passed := 0
var _failed := 0
var _registry
var _cycle_config: Dictionary = {}
var _heyuan: Dictionary = {}


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_registry = ContentRegistryScript.new()
	_assert_true(_registry.load_all(), "M5 faction content registry loads")
	_cycle_config = _load_json(CYCLE_CONFIG_PATH)
	# Keep this historical M5 suite scoped to the original Heyuan slice. M6
	# validates the expanded three-target catalog independently.
	_cycle_config.cycle_advancing_expedition_ids = ["expedition.capture_heyuan_county"]
	_heyuan = _registry.get_territory(HEYUAN_ID)
	_test_territory_and_cycle_contracts()
	_test_campaign_state_and_old_save_defaults()
	_test_first_capture_and_delayed_income()
	_test_recurring_income_and_idempotency()
	_test_success_cycle_advances_injury_recovery()
	_test_retreat_and_failure_do_not_advance_cycle()
	_test_faction_transaction_failures_and_rollback()
	_test_faction_save_round_trip()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_territory_and_cycle_contracts() -> void:
	_assert_equal(_registry.territory_count(), 3, "Rogue Vertical Slice registers three territories")
	_assert_true(_registry.has_territory(HEYUAN_ID), "Heyuan County is addressable by stable territory id")
	_assert_true(not _heyuan.is_empty(), "Heyuan territory definition loads")
	_assert_true(FactionCycleServiceScript.validate_territory_definition(_heyuan).is_empty(), "Heyuan territory definition satisfies its contract")
	_assert_equal(_heyuan.source_expedition_id, "expedition.capture_heyuan_county", "Heyuan capture references the authored expedition")
	_assert_true(not _heyuan.independent_city_management, "Heyuan is an asset rather than a separately managed city")
	_assert_equal(_heyuan.cycle_income.main_resources, {"silver": 180.0, "food": 260.0, "recruits": 60.0}, "Heyuan main-resource income matches the prototype design table")
	_assert_equal(_heyuan.cycle_income.special_resources, {"resource.refined_iron": 8.0}, "Heyuan special income keeps refined iron separate")
	_assert_true(not _cycle_config.is_empty(), "prototype faction cycle config loads")
	_assert_true(FactionCycleServiceScript.validate_cycle_definition(_cycle_config).is_empty(), "prototype faction cycle config satisfies its contract")
	_assert_true(FactionCycleServiceScript.validate_catalog(_cycle_config, [_heyuan]).is_empty(), "faction cycle and territory form a valid catalog")
	_assert_equal(_cycle_config.balance_status, "prototype_temporary", "territory income and timing remain explicitly prototype-only")
	_assert_equal(_cycle_config.cycle_advancing_outcomes, ["success"], "Vertical Slice cycle policy is explicitly success-only")
	_assert_equal(_cycle_config.new_territory_income_delay_cycles, 1, "new territory waits one cycle before paying income")
	_assert_equal(_cycle_config.deferred_systems, ["recruitment_refresh", "world_stage_change"], "unimplemented cycle consumers remain explicit")
	var independent_city := _heyuan.duplicate(true)
	independent_city.independent_city_management = true
	_assert_error_contains(FactionCycleServiceScript.validate_territory_definition(independent_city), "cannot enable", "territory contract rejects per-city management")
	var unstable_resource := _heyuan.duplicate(true)
	unstable_resource.cycle_income.special_resources = {"refined_iron": 8}
	_assert_error_contains(FactionCycleServiceScript.validate_territory_definition(unstable_resource), "stable 'resource.'", "territory contract rejects unstable special-resource ids")
	var false_final := _cycle_config.duplicate(true)
	false_final.balance_status = "final"
	_assert_error_contains(FactionCycleServiceScript.validate_cycle_definition(false_final), "prototype_temporary", "prototype cycle parameters cannot silently become final")
	var retreat_policy := _cycle_config.duplicate(true)
	retreat_policy.cycle_advancing_outcomes = ["success", "retreated"]
	_assert_error_contains(FactionCycleServiceScript.validate_cycle_definition(retreat_policy), "success-only", "unconfirmed retreat timing cannot silently enter the cycle policy")
	var duplicate_territory := _heyuan.duplicate(true)
	_assert_error_contains(FactionCycleServiceScript.validate_catalog(_cycle_config, [_heyuan, duplicate_territory]), "duplicate territory", "faction catalog rejects duplicate territory ids")


func _test_campaign_state_and_old_save_defaults() -> void:
	var state: Dictionary = CampaignStateScript.create("campaign.faction-state")
	_assert_equal(state.cycle, 0, "new campaign starts before the first faction cycle")
	_assert_equal(state.main_city_stage, "ruined_camp", "new campaign starts at the ruined camp stage")
	_assert_true(state.territories.is_empty(), "new campaign owns no territory")
	_assert_equal(state.faction, FactionCycleServiceScript.create_faction_state(), "new campaign exposes faction transaction state")
	_assert_true(CampaignStateScript.validate(state).is_empty(), "new faction CampaignState satisfies its contract")
	var old_state := state.duplicate(true)
	old_state.erase("faction")
	old_state.pending_long_term_effects.append(_pending_effect("settlement:old-faction", "success"))
	old_state.pending_long_term_effects[0].erase("faction_effect_applied")
	var normalized: Dictionary = CampaignStateScript.normalize(old_state)
	_assert_equal(normalized.faction, FactionCycleServiceScript.create_faction_state(), "old V1 save receives empty faction ledgers")
	_assert_true(not normalized.pending_long_term_effects[0].faction_effect_applied, "old deferred effect defaults to unapplied faction state")
	_assert_true(CampaignStateScript.validate(normalized).is_empty(), "normalized old V1 faction state remains valid")
	var duplicate_ledger := state.duplicate(true)
	duplicate_ledger.faction.applied_effect_ids = ["same", "same"]
	_assert_error_contains(CampaignStateScript.validate(duplicate_ledger), "duplicate", "CampaignState rejects duplicate faction effect ids")
	var duplicate_roster := state.duplicate(true)
	duplicate_roster.territories = [
		FactionCycleServiceScript.create_territory_instance(_heyuan, 1, "capture:one"),
		FactionCycleServiceScript.create_territory_instance(_heyuan, 2, "capture:two"),
	]
	_assert_error_contains(CampaignStateScript.validate(duplicate_roster), "unique", "CampaignState rejects duplicate controlled territories")


func _test_first_capture_and_delayed_income() -> void:
	var controller = _configured_controller("campaign.first-capture")
	var request := _settlement("settlement:first-capture", "success")
	var request_before := request.duplicate(true)
	_assert_true(controller.apply_expedition_settlement(request).ok, "successful Heyuan expedition queues faction effect")
	var applied: Dictionary = controller.apply_pending_faction_effect("settlement:first-capture")
	_assert_true(applied.ok and not applied.duplicate and not applied.skipped, "first successful major expedition advances faction state")
	_assert_equal(request, request_before, "faction processing does not mutate the settlement request")
	_assert_equal(applied.cycle_advanced, 1, "one major success advances exactly one cycle")
	_assert_equal(applied.captured_territory_ids, [HEYUAN_ID], "first success captures Heyuan exactly once")
	_assert_true(applied.main_income.is_empty() and applied.special_income.is_empty(), "new territory does not pay income in its capture cycle")
	var state: Dictionary = controller.snapshot()
	_assert_equal(state.cycle, 1, "capture commits faction cycle one")
	_assert_equal(state.territories.size(), 1, "campaign now controls one territory")
	_assert_equal(state.territories[0].territory_id, HEYUAN_ID, "controlled territory stores stable id")
	_assert_equal(state.territories[0].acquired_cycle, 1, "territory records its acquisition cycle")
	_assert_equal(state.territories[0].source_request_id, "settlement:first-capture", "territory records capture transaction provenance")
	_assert_equal(state.main_city_stage, "rebel_camp", "capturing Heyuan advances the main-city stage")
	_assert_equal(state.resources, {"silver": 0, "food": 0, "recruits": 0, "military_knowledge": 0}, "capture-cycle territory income is not paid early")
	_assert_true(state.special_resources.is_empty(), "capture cycle does not pay refined iron early")
	_assert_true(state.pending_long_term_effects[0].faction_effect_applied, "shared deferred effect marks faction consumption")
	_assert_equal(state.faction.history[0].contributing_territory_ids, [], "capture-cycle audit names no income contributor")


func _test_recurring_income_and_idempotency() -> void:
	var controller = _captured_controller("campaign.recurring-income")
	var before_duplicate: Dictionary = controller.snapshot()
	var duplicate: Dictionary = controller.apply_pending_faction_effect("settlement:capture:campaign.recurring-income")
	_assert_true(duplicate.ok and duplicate.duplicate, "same faction effect is idempotent")
	_assert_equal(controller.snapshot(), before_duplicate, "duplicate faction effect cannot recapture territory or advance time")
	controller.apply_expedition_settlement(_settlement("settlement:income:2", "success"))
	var second: Dictionary = controller.apply_pending_faction_effect("settlement:income:2")
	_assert_equal(controller.snapshot().cycle, 2, "second major success advances to cycle two")
	_assert_true(second.captured_territory_ids.is_empty(), "replayed expedition cannot duplicate Heyuan")
	_assert_equal(second.main_income, {"silver": 180, "food": 260, "recruits": 60}, "cycle two pays Heyuan main income once")
	_assert_equal(second.special_income, {"resource.refined_iron": 8}, "cycle two pays Heyuan refined iron once")
	var cycle_two: Dictionary = controller.snapshot()
	_assert_equal(cycle_two.resources.silver, 180, "cycle income adds silver")
	_assert_equal(cycle_two.resources.food, 260, "cycle income adds food")
	_assert_equal(cycle_two.resources.recruits, 60, "cycle income adds recruits")
	_assert_equal(cycle_two.resources.military_knowledge, 0, "Heyuan does not invent military-knowledge income")
	_assert_equal(cycle_two.special_resources["resource.refined_iron"], 8, "cycle income stores refined iron separately")
	controller.apply_expedition_settlement(_settlement("settlement:income:3", "success"))
	var third: Dictionary = controller.apply_pending_faction_effect("settlement:income:3")
	_assert_equal(controller.snapshot().cycle, 3, "third success advances exactly one more cycle")
	_assert_equal(controller.snapshot().resources.silver, 360, "third cycle adds a second income payment")
	_assert_equal(controller.snapshot().special_resources["resource.refined_iron"], 16, "special income accumulates once per eligible cycle")
	_assert_equal(third.main_income.silver, 180, "per-cycle result reports only the current payment")
	_assert_equal(controller.snapshot().territories.size(), 1, "recurring income never duplicates the territory instance")


func _test_success_cycle_advances_injury_recovery() -> void:
	var state: Dictionary = CampaignStateScript.create("campaign.faction-recovery")
	var instance: Dictionary = GeneralManagementServiceScript.create_instance(_registry.get_general("general.zhao_lie"))
	instance.injury = {"status": "major_injury", "remaining_cycles": 2}
	state.generals.append(instance)
	var controller = CampaignControllerScript.new()
	_assert_true(controller.setup(state).is_empty(), "injured general enters faction recovery campaign")
	_assert_true(controller.configure_faction(_cycle_config, [_heyuan]).is_empty(), "faction recovery catalog configures")
	controller.apply_expedition_settlement(_settlement("settlement:recovery:1", "success"))
	var first: Dictionary = controller.apply_pending_faction_effect("settlement:recovery:1")
	_assert_equal(first.changed_general_ids, ["general.zhao_lie"], "successful faction cycle advances major injury once")
	_assert_true(first.recovered_general_ids.is_empty(), "first faction cycle does not finish a two-cycle injury")
	_assert_equal(controller.snapshot().generals[0].injury.remaining_cycles, 1, "first integrated cycle leaves one recovery cycle")
	controller.apply_expedition_settlement(_settlement("settlement:recovery:2", "success"))
	var second: Dictionary = controller.apply_pending_faction_effect("settlement:recovery:2")
	_assert_equal(second.recovered_general_ids, ["general.zhao_lie"], "second successful faction cycle completes recovery")
	_assert_equal(controller.snapshot().generals[0].injury, {"status": "healthy", "remaining_cycles": 0}, "integrated recovery restores healthy state")
	_assert_equal(controller.snapshot().general_system.applied_recovery_ids.size(), 2, "each advanced faction cycle records one recovery action")
	_assert_true(controller.snapshot().general_system.applied_recovery_ids[0].begins_with("faction-recovery:"), "faction recovery uses a stable derived action id")


func _test_retreat_and_failure_do_not_advance_cycle() -> void:
	for outcome in ["retreated", "failed"]:
		var controller = _configured_controller("campaign.no-cycle.%s" % outcome)
		var request_id := "settlement:no-cycle:%s" % outcome
		controller.apply_expedition_settlement(_settlement(request_id, outcome))
		var result: Dictionary = controller.apply_pending_faction_effect(request_id)
		_assert_true(result.ok and result.skipped, "%s faction effect is consumed without advancing" % outcome)
		_assert_equal(result.cycle_advanced, 0, "%s advances zero cycles" % outcome)
		_assert_equal(controller.snapshot().cycle, 0, "%s leaves campaign cycle unchanged" % outcome)
		_assert_true(controller.snapshot().territories.is_empty(), "%s cannot capture Heyuan" % outcome)
		_assert_true(controller.snapshot().resources.values().all(func(value): return int(value) == 0), "%s cannot generate territory income" % outcome)
		_assert_true(controller.snapshot().pending_long_term_effects[0].faction_effect_applied, "%s marks its faction effect consumed" % outcome)
		_assert_equal(controller.snapshot().faction.history[0].reason, "outcome_not_configured", "%s audit preserves the success-only policy reason" % outcome)
	var non_major = _configured_controller("campaign.non-major")
	var non_major_request := _settlement("settlement:non-major", "success")
	non_major_request.expedition_id = "expedition.side_patrol"
	non_major.apply_expedition_settlement(non_major_request)
	var skipped: Dictionary = non_major.apply_pending_faction_effect("settlement:non-major")
	_assert_true(skipped.ok and skipped.skipped, "non-major success is consumed without advancing faction time")
	_assert_equal(non_major.snapshot().faction.history[0].reason, "not_major_expedition", "non-major audit records why cycle did not advance")


func _test_faction_transaction_failures_and_rollback() -> void:
	var empty_controller = CampaignControllerScript.new()
	_assert_true(not empty_controller.apply_pending_faction_effect("missing").ok, "faction effect rejects an uninitialized controller")
	var unconfigured = CampaignControllerScript.new()
	unconfigured.setup(CampaignStateScript.create("campaign.unconfigured-faction"))
	_assert_true(not unconfigured.apply_pending_faction_effect("missing").ok, "faction effect rejects a missing catalog")
	var controller = _configured_controller("campaign.faction-failures")
	var before: Dictionary = controller.snapshot()
	_assert_true(not controller.apply_pending_faction_effect("").ok, "faction effect rejects an empty request id")
	_assert_true(not controller.apply_pending_faction_effect("settlement:missing").ok, "faction effect rejects an unknown request")
	_assert_equal(controller.snapshot(), before, "rejected faction effects leave campaign unchanged")
	var unknown_instance := {
		"territory_id": "territory.unknown",
		"name": "未知领地",
		"status": "controlled",
		"income_enabled": true,
		"acquired_cycle": 0,
		"source_request_id": "legacy:capture",
	}
	var unknown_state: Dictionary = CampaignStateScript.create("campaign.unknown-territory")
	unknown_state.territories.append(unknown_instance)
	var rollback_controller = CampaignControllerScript.new()
	_assert_true(rollback_controller.setup(unknown_state).is_empty(), "structurally valid legacy territory enters CampaignState")
	rollback_controller.configure_faction(_cycle_config, [_heyuan])
	rollback_controller.apply_expedition_settlement(_settlement("settlement:unknown-territory", "success"))
	var queued: Dictionary = rollback_controller.snapshot()
	var failed: Dictionary = rollback_controller.apply_pending_faction_effect("settlement:unknown-territory")
	_assert_true(not failed.ok, "cycle rejects a controlled territory absent from configured content")
	_assert_equal(rollback_controller.snapshot(), queued, "income-resolution failure rolls back capture, cycle, recovery and resources")
	var game_over_state: Dictionary = CampaignStateScript.create("campaign.faction-game-over")
	game_over_state.campaign_status = "game_over"
	game_over_state.game_over_record = {"reason": "player_character_died"}
	game_over_state.pending_long_term_effects.append(_pending_effect("settlement:after-game-over", "success"))
	var game_over_controller = CampaignControllerScript.new()
	game_over_controller.setup(game_over_state)
	game_over_controller.configure_faction(_cycle_config, [_heyuan])
	_assert_true(not game_over_controller.apply_pending_faction_effect("settlement:after-game-over").ok, "Game Over rejects faction cycle advancement")


func _test_faction_save_round_trip() -> void:
	var controller = _captured_controller("campaign.faction-save")
	controller.apply_expedition_settlement(_settlement("settlement:save-income", "success"))
	controller.apply_pending_faction_effect("settlement:save-income")
	var envelope: Dictionary = SaveEnvelopeScript.create_empty("campaign.faction-save", "2026-09-01T00:00:00Z")
	envelope.campaign = controller.snapshot()
	var codec = SaveGameCodecScript.new()
	var encoded: Dictionary = codec.encode(envelope)
	_assert_true(encoded.ok, "faction CampaignState encodes through Save V2")
	var decoded: Dictionary = codec.decode(encoded.text)
	_assert_true(decoded.ok, "faction CampaignState decodes through Save V2")
	var restored: Dictionary = CampaignStateScript.normalize(decoded.value.campaign)
	_assert_true(CampaignStateScript.validate(restored).is_empty(), "restored faction CampaignState remains valid")
	_assert_equal(int(restored.cycle), 2, "save round-trip preserves faction cycle")
	_assert_equal(restored.main_city_stage, "rebel_camp", "save round-trip preserves main-city growth stage")
	_assert_equal(restored.territories[0].territory_id, HEYUAN_ID, "save round-trip preserves controlled territory")
	_assert_equal(int(restored.resources.silver), 180, "save round-trip preserves territory income")
	_assert_equal(restored.faction.applied_effect_ids.size(), 2, "save round-trip preserves faction idempotency ledger")


func _configured_controller(campaign_id: String):
	var controller = CampaignControllerScript.new()
	_assert_true(controller.setup(CampaignStateScript.create(campaign_id)).is_empty(), "%s controller setup succeeds" % campaign_id)
	_assert_true(controller.configure_faction(_cycle_config, [_heyuan]).is_empty(), "%s faction catalog setup succeeds" % campaign_id)
	return controller


func _captured_controller(campaign_id: String):
	var controller = _configured_controller(campaign_id)
	var request_id := "settlement:capture:%s" % campaign_id
	_assert_true(controller.apply_expedition_settlement(_settlement(request_id, "success")).ok, "%s capture settlement queues" % campaign_id)
	_assert_true(controller.apply_pending_faction_effect(request_id).ok, "%s capture faction effect commits" % campaign_id)
	return controller


func _settlement(request_id: String, outcome: String) -> Dictionary:
	return {
		"request_id": request_id,
		"run_id": "run.%s" % request_id,
		"expedition_id": "expedition.capture_heyuan_county",
		"outcome": outcome,
		"general_id": "general.zhao_lie",
		"remaining_troops": 500,
		"remaining_morale": 40,
		"general_died": false,
		"general_injured": false,
		"loot_to_bank": {},
		"lost_unbanked_loot": {},
	}


func _pending_effect(request_id: String, outcome: String) -> Dictionary:
	return {
		"request_id": request_id,
		"general_id": "general.zhao_lie",
		"remaining_troops": 500,
		"remaining_morale": 40,
		"general_died": false,
		"general_injured": false,
		"expedition_id": "expedition.capture_heyuan_county",
		"outcome": outcome,
		"army_losses": {"infantry": 0, "archer": 0, "cavalry": 0},
		"army_losses_applied": false,
		"general_effect_applied": false,
		"faction_effect_applied": false,
	}


func _load_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}


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
