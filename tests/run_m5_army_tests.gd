extends SceneTree

const ArmyManagementServiceScript := preload("res://src/domain/campaign/army_management_service.gd")
const CampaignStateScript := preload("res://src/domain/campaign/campaign_state.gd")
const CampaignControllerScript := preload("res://src/domain/campaign/campaign_controller.gd")
const SaveEnvelopeScript := preload("res://src/domain/campaign/save_envelope.gd")
const SaveGameCodecScript := preload("res://src/infrastructure/persistence/save_game_codec.gd")

const ECONOMY_PATH := "res://data/config/prototype_army_economy.json"

var _passed := 0
var _failed := 0
var _economy: Dictionary = {}


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_economy = _load_json(ECONOMY_PATH)
	_test_inventory_contract_and_old_save_normalization()
	_test_prototype_economy_contract_and_quotes()
	_test_replenishment_transaction_and_idempotency()
	_test_replenishment_rollbacks_and_failures()
	_test_casualty_allocation()
	_test_settlement_applies_real_inventory_losses()
	_test_retreat_applies_losses_without_rewards()
	_test_settlement_loss_rollback_and_legacy_boundary()
	_test_army_state_save_round_trip()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_inventory_contract_and_old_save_normalization() -> void:
	var state: Dictionary = CampaignStateScript.create("campaign.army")
	_assert_equal(state.army_inventory, {"infantry": 0, "archer": 0, "cavalry": 0}, "new CampaignState exposes the three Vertical Slice army stocks")
	_assert_true(ArmyManagementServiceScript.validate_inventory(state.army_inventory).is_empty(), "new army inventory satisfies its contract")
	_assert_true(state.applied_army_action_ids.is_empty() and state.army_history.is_empty(), "new campaign starts with empty army transaction ledgers")
	var old_state := state.duplicate(true)
	old_state.army_inventory = {}
	old_state.erase("applied_army_action_ids")
	old_state.erase("army_history")
	var controller = CampaignControllerScript.new()
	_assert_true(controller.setup(old_state).is_empty(), "old V1 army inventory receives additive defaults")
	_assert_equal(controller.snapshot().army_inventory, {"infantry": 0, "archer": 0, "cavalry": 0}, "old V1 save normalizes all three army stocks to zero")
	var invalid := state.duplicate(true)
	invalid.army_inventory.cavalry = -1
	_assert_error_contains(CampaignStateScript.validate(invalid), "non-negative", "CampaignState rejects negative army inventory")


func _test_prototype_economy_contract_and_quotes() -> void:
	_assert_true(not _economy.is_empty(), "prototype army economy config loads")
	_assert_true(ArmyManagementServiceScript.validate_economy_definition(_economy).is_empty(), "prototype army economy config satisfies its contract")
	_assert_equal(_economy.balance_status, "prototype_temporary", "army costs remain explicitly marked prototype-only")
	var infantry: Dictionary = ArmyManagementServiceScript.quote_replenishment(_economy, "infantry", 1)
	_assert_true(infantry.ok, "infantry replenishment can be quoted")
	_assert_equal(infantry.troops_added, 100, "one prototype batch adds one hundred infantry")
	_assert_equal(infantry.main_costs, {"recruits": 100, "silver": 10, "food": 10}, "infantry quote uses centralized prototype costs")
	var cavalry: Dictionary = ArmyManagementServiceScript.quote_replenishment(_economy, "cavalry", 2)
	_assert_equal(cavalry.troops_added, 200, "quote scales troop output by batch count")
	_assert_equal(cavalry.special_costs, {"resource.warhorse": 200}, "cavalry quote scales its warhorse requirement")
	var unlocked := _economy.duplicate(true)
	unlocked.balance_status = "final"
	_assert_error_contains(ArmyManagementServiceScript.validate_economy_definition(unlocked), "prototype_temporary", "economy cannot silently present prototype costs as final balance")
	var free_training := _economy.duplicate(true)
	free_training.army_types.archer.main_costs.erase("recruits")
	_assert_error_contains(ArmyManagementServiceScript.validate_economy_definition(free_training), "consume recruits", "every basic army type must consume recruits")


func _test_replenishment_transaction_and_idempotency() -> void:
	var controller = _funded_controller("campaign.replenish")
	var request := {"action_id": "army-action:cavalry:1", "army_type": "cavalry", "batches": 2}
	var before_request := request.duplicate(true)
	var first: Dictionary = controller.replenish_troops(request)
	_assert_true(first.ok and not first.duplicate, "valid cavalry replenishment commits once")
	_assert_equal(request, before_request, "army transaction does not mutate its request DTO")
	var state: Dictionary = controller.snapshot()
	_assert_equal(state.army_inventory.cavalry, 200, "replenishment adds trained cavalry to the unified inventory")
	_assert_equal(state.resources.recruits, 800, "replenishment consumes recruits")
	_assert_equal(state.resources.silver, 920, "replenishment consumes silver")
	_assert_equal(state.resources.food, 960, "replenishment consumes food")
	_assert_equal(state.special_resources["resource.warhorse"], 300, "cavalry replenishment consumes warhorses")
	_assert_equal(state.army_history.size(), 1, "replenishment appends one army audit record")
	var after_first := state.duplicate(true)
	var duplicate: Dictionary = controller.replenish_troops(request)
	_assert_true(duplicate.ok and duplicate.duplicate, "same army action id is idempotent")
	_assert_equal(controller.snapshot(), after_first, "duplicate army action cannot consume costs or add troops twice")


func _test_replenishment_rollbacks_and_failures() -> void:
	var uninitialized = CampaignControllerScript.new()
	_assert_true(not uninitialized.replenish_troops({"action_id": "army:no-setup", "army_type": "infantry", "batches": 1}).ok, "army action rejects an uninitialized controller")
	var unconfigured = CampaignControllerScript.new()
	unconfigured.setup(CampaignStateScript.create("campaign.no-economy"))
	_assert_true(not unconfigured.replenish_troops({"action_id": "army:no-config", "army_type": "infantry", "batches": 1}).ok, "army action rejects a missing economy definition")
	var controller = _funded_controller("campaign.army-failures")
	_assert_true(not controller.replenish_troops({}).ok, "army action rejects missing fields")
	_assert_true(not controller.replenish_troops({"action_id": "army:unknown", "army_type": "elephant", "batches": 1}).ok, "army action rejects unsupported troop types")
	_assert_true(not controller.replenish_troops({"action_id": "army:fraction", "army_type": "infantry", "batches": 0.5}).ok, "army action rejects fractional batches")
	var poor: Dictionary = CampaignStateScript.create("campaign.poor")
	poor.resources.recruits = 1000
	poor.resources.silver = 1000
	poor.resources.food = 1000
	poor.special_resources["resource.warhorse"] = 50
	var poor_controller = CampaignControllerScript.new()
	poor_controller.setup(poor)
	poor_controller.configure_army_economy(_economy)
	var before := poor_controller.snapshot()
	_assert_true(not poor_controller.replenish_troops({"action_id": "army:no-horses", "army_type": "cavalry", "batches": 1}).ok, "cavalry training rejects insufficient warhorses")
	_assert_equal(poor_controller.snapshot(), before, "failed special-resource training rolls back every cost")
	poor.resources.recruits = 50
	var recruits_controller = CampaignControllerScript.new()
	recruits_controller.setup(poor)
	recruits_controller.configure_army_economy(_economy)
	var recruits_before := recruits_controller.snapshot()
	_assert_true(not recruits_controller.replenish_troops({"action_id": "army:no-recruits", "army_type": "infantry", "batches": 1}).ok, "training rejects insufficient recruits")
	_assert_equal(recruits_controller.snapshot(), recruits_before, "failed main-resource training cannot partially spend silver or food")


func _test_casualty_allocation() -> void:
	var result: Dictionary = ArmyManagementServiceScript.calculate_casualties(1000, 550, {"infantry": 0.2, "archer": 0.3, "cavalry": 0.5})
	_assert_true(result.ok, "valid expedition loss can be allocated")
	_assert_equal(result.total, 450, "casualty total is initial minus remaining troops")
	_assert_equal(result.losses, {"infantry": 90, "archer": 135, "cavalry": 225}, "casualties follow the locked starting composition")
	var rounded: Dictionary = ArmyManagementServiceScript.calculate_casualties(100, 90, {"infantry": 0.33, "archer": 0.33, "cavalry": 0.34})
	_assert_equal(rounded.losses, {"infantry": 3, "archer": 3, "cavalry": 4}, "largest remainder allocation preserves the exact casualty total")
	var zero: Dictionary = ArmyManagementServiceScript.calculate_casualties(100, 100, {"infantry": 1.0, "archer": 0.0, "cavalry": 0.0})
	_assert_equal(zero.losses, {"infantry": 0, "archer": 0, "cavalry": 0}, "no troop loss produces no inventory loss")
	_assert_true(not ArmyManagementServiceScript.calculate_casualties(100, 101, {"infantry": 1.0, "archer": 0.0, "cavalry": 0.0}).ok, "casualties reject remaining troops above deployment")
	_assert_true(not ArmyManagementServiceScript.calculate_casualties(100, 50, {"infantry": 0.5, "archer": 0.2, "cavalry": 0.2}).ok, "casualties reject a composition that does not sum to one")


func _test_settlement_applies_real_inventory_losses() -> void:
	var state: Dictionary = CampaignStateScript.create("campaign.losses")
	state.army_inventory = {"infantry": 300, "archer": 300, "cavalry": 300}
	var controller = CampaignControllerScript.new()
	controller.setup(state)
	var request := _settlement("settlement:army-loss", "success")
	request.initial_troops = 1000
	request.remaining_troops = 550
	request.army_composition = {"infantry": 0.2, "archer": 0.3, "cavalry": 0.5}
	request.loot_to_bank = {"resource.silver": 25}
	var applied: Dictionary = controller.apply_expedition_settlement(request)
	_assert_true(applied.ok, "settlement with a deployment snapshot commits")
	var settled: Dictionary = controller.snapshot()
	_assert_equal(settled.army_inventory, {"infantry": 210, "archer": 165, "cavalry": 75}, "settlement deducts real losses from the unified army inventory")
	_assert_equal(settled.settlement_history[0].army_losses, {"infantry": 90, "archer": 135, "cavalry": 225}, "settlement audit records losses by army type")
	_assert_true(settled.pending_long_term_effects[0].army_losses_applied, "deferred result marks army losses as already consumed")
	_assert_equal(settled.resources.silver, 25, "success reward and casualties commit in the same transaction")


func _test_retreat_applies_losses_without_rewards() -> void:
	var state: Dictionary = CampaignStateScript.create("campaign.retreat-losses")
	state.resources.silver = 10
	state.army_inventory = {"infantry": 100, "archer": 100, "cavalry": 100}
	var controller = CampaignControllerScript.new()
	controller.setup(state)
	var request := _settlement("settlement:retreat-losses", "retreated")
	request.initial_troops = 100
	request.remaining_troops = 90
	request.army_composition = {"infantry": 0.2, "archer": 0.3, "cavalry": 0.5}
	request.lost_unbanked_loot = {"resource.silver": 50}
	_assert_true(controller.apply_expedition_settlement(request).ok, "retreat with a deployment snapshot commits its real losses")
	var settled: Dictionary = controller.snapshot()
	_assert_equal(settled.army_inventory, {"infantry": 98, "archer": 97, "cavalry": 95}, "retreat deducts casualties using the same locked composition")
	_assert_equal(settled.resources.silver, 10, "retreat receives no unbanked reward while preserving existing resources")
	_assert_equal(settled.settlement_history[0].outcome, "retreated", "retreat loss audit remains distinct from success")


func _test_settlement_loss_rollback_and_legacy_boundary() -> void:
	var scarce: Dictionary = CampaignStateScript.create("campaign.loss-rollback")
	scarce.army_inventory = {"infantry": 10, "archer": 10, "cavalry": 10}
	var controller = CampaignControllerScript.new()
	controller.setup(scarce)
	var request := _settlement("settlement:too-many-losses", "failed")
	request.initial_troops = 100
	request.remaining_troops = 0
	request.army_composition = {"infantry": 0.5, "archer": 0.3, "cavalry": 0.2}
	request.general_died = true
	var before := controller.snapshot()
	_assert_true(not controller.apply_expedition_settlement(request).ok, "settlement rejects casualties above unified inventory")
	_assert_equal(controller.snapshot(), before, "insufficient inventory rolls back the full expedition settlement")
	var legacy = CampaignControllerScript.new()
	legacy.setup(CampaignStateScript.create("campaign.legacy-settlement"))
	var legacy_request := _settlement("settlement:legacy", "retreated")
	legacy_request.lost_unbanked_loot = {"resource.food": 10}
	_assert_true(legacy.apply_expedition_settlement(legacy_request).ok, "older settlement DTO without deployment fields remains readable")
	_assert_true(not legacy.snapshot().pending_long_term_effects[0].army_losses_applied, "legacy settlement explicitly leaves army losses unapplied")
	var partial := _settlement("settlement:partial-deployment", "failed")
	partial.initial_troops = 100
	_assert_true(not legacy.apply_expedition_settlement(partial).ok, "settlement rejects a partial deployment snapshot")


func _test_army_state_save_round_trip() -> void:
	var controller = _funded_controller("campaign.army-save")
	controller.replenish_troops({"action_id": "army-action:save", "army_type": "archer", "batches": 1})
	var envelope: Dictionary = SaveEnvelopeScript.create_empty("campaign.army-save", "2026-09-01T00:00:00Z")
	envelope.campaign = controller.snapshot()
	var codec = SaveGameCodecScript.new()
	var encoded: Dictionary = codec.encode(envelope)
	_assert_true(encoded.ok, "army CampaignState encodes through Save V1")
	var decoded: Dictionary = codec.decode(encoded.text)
	_assert_true(decoded.ok, "army CampaignState decodes through Save V1")
	var restored: Dictionary = CampaignStateScript.normalize(decoded.value.campaign)
	_assert_true(CampaignStateScript.validate(restored).is_empty(), "restored army CampaignState remains valid")
	_assert_equal(int(restored.army_inventory.archer), 100, "save round-trip preserves trained army inventory")
	_assert_equal(restored.applied_army_action_ids, ["army-action:save"], "save round-trip preserves army action idempotency")


func _funded_controller(campaign_id: String):
	var state: Dictionary = CampaignStateScript.create(campaign_id)
	state.resources.silver = 1000
	state.resources.food = 1000
	state.resources.recruits = 1000
	state.special_resources["resource.warhorse"] = 500
	var controller = CampaignControllerScript.new()
	_assert_true(controller.setup(state).is_empty(), "%s controller setup succeeds" % campaign_id)
	_assert_true(controller.configure_army_economy(_economy).is_empty(), "%s army economy setup succeeds" % campaign_id)
	return controller


func _settlement(request_id: String, outcome: String) -> Dictionary:
	return {
		"request_id": request_id,
		"run_id": "run.m5-army",
		"expedition_id": "expedition.capture_heyuan_county",
		"outcome": outcome,
		"general_id": "general.zhao_lie",
		"remaining_troops": 500,
		"remaining_morale": 48,
		"general_died": false,
		"general_injured": false,
		"loot_to_bank": {},
		"lost_unbanked_loot": {},
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
