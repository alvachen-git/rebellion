extends SceneTree

const CampaignStateScript := preload("res://src/domain/campaign/campaign_state.gd")
const CampaignControllerScript := preload("res://src/domain/campaign/campaign_controller.gd")
const SaveEnvelopeScript := preload("res://src/domain/campaign/save_envelope.gd")
const SaveGameCodecScript := preload("res://src/infrastructure/persistence/save_game_codec.gd")

var _passed := 0
var _failed := 0


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_test_campaign_state_contract()
	_test_old_v1_campaign_normalizes_additive_fields()
	_test_campaign_setup_failures()
	_test_success_banks_main_and_special_resources()
	_test_settlement_is_idempotent()
	_test_invalid_settlement_rolls_back_fully()
	_test_retreat_and_failure_queue_losses_without_rewards()
	_test_settlement_failure_contracts()
	_test_extended_campaign_save_round_trip()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_campaign_state_contract() -> void:
	var state: Dictionary = CampaignStateScript.create("campaign.m5")
	_assert_true(CampaignStateScript.validate(state).is_empty(), "new M5 CampaignState satisfies its contract")
	_assert_equal(state.resources.keys().size(), 4, "CampaignState exposes exactly four main resources")
	_assert_equal(state.resources, {"silver": 0, "food": 0, "recruits": 0, "military_knowledge": 0}, "four main resources start at zero")
	_assert_true(state.special_resources.is_empty(), "special resources remain in a separate collection")
	_assert_true(state.applied_settlement_ids.is_empty(), "new campaign has no applied settlement ids")
	_assert_true(state.pending_long_term_effects.is_empty(), "new campaign has no deferred long-term effects")


func _test_old_v1_campaign_normalizes_additive_fields() -> void:
	var envelope: Dictionary = SaveEnvelopeScript.create_empty("campaign.old-v1", "2026-09-01T00:00:00Z")
	envelope.campaign.erase("applied_settlement_ids")
	envelope.campaign.erase("settlement_history")
	envelope.campaign.erase("pending_long_term_effects")
	var controller = CampaignControllerScript.new()
	_assert_true(controller.setup(envelope.campaign).is_empty(), "old v1 campaign loads without the additive M5 fields")
	var normalized: Dictionary = controller.snapshot()
	_assert_true(normalized.applied_settlement_ids.is_empty(), "old campaign receives an empty settlement id list")
	_assert_true(normalized.settlement_history.is_empty(), "old campaign receives empty settlement history")
	_assert_true(normalized.pending_long_term_effects.is_empty(), "old campaign receives an empty deferred-effect queue")


func _test_campaign_setup_failures() -> void:
	var empty_id: Dictionary = CampaignStateScript.create("")
	_assert_error_contains(CampaignStateScript.validate(empty_id), "campaign_id", "CampaignState rejects an empty campaign id")
	var negative: Dictionary = CampaignStateScript.create("campaign.negative")
	negative.resources.food = -1
	_assert_error_contains(CampaignStateScript.validate(negative), "cannot be negative", "CampaignState rejects a negative main resource")
	var wrong_shape: Dictionary = CampaignStateScript.create("campaign.shape")
	wrong_shape.pending_long_term_effects = {}
	_assert_error_contains(CampaignStateScript.validate(wrong_shape), "must be an array", "CampaignState rejects a malformed deferred queue")
	var bad_special: Dictionary = CampaignStateScript.create("campaign.bad-special")
	bad_special.special_resources["resource.refined_iron"] = -1
	_assert_error_contains(CampaignStateScript.validate(bad_special), "cannot be negative", "CampaignState rejects a negative special resource")
	var controller = CampaignControllerScript.new()
	controller.setup(CampaignStateScript.create("campaign.previous"))
	var setup_errors: PackedStringArray = controller.setup(CampaignStateScript.create(""))
	_assert_true(not setup_errors.is_empty() and controller.snapshot().is_empty(), "failed setup cannot retain a previously loaded campaign")


func _test_success_banks_main_and_special_resources() -> void:
	var controller = _controller("campaign.success")
	var request := _settlement("settlement:success", "success")
	request.loot_to_bank = {
		"resource.silver": 180,
		"resource.food": 260,
		"resource.recruits": 60,
		"resource.military_knowledge": 25,
		"resource.refined_iron": 8,
	}
	var request_before := request.duplicate(true)
	var applied: Dictionary = controller.apply_expedition_settlement(request)
	_assert_true(applied.ok and not applied.duplicate, "valid success settlement commits once")
	_assert_equal(request, request_before, "Campaign transaction does not mutate the settlement DTO")
	var state: Dictionary = controller.snapshot()
	_assert_equal(state.resources.silver, 180, "success banks silver")
	_assert_equal(state.resources.food, 260, "success banks food")
	_assert_equal(state.resources.recruits, 60, "success banks recruits")
	_assert_equal(state.resources.military_knowledge, 25, "success banks military knowledge")
	_assert_equal(state.special_resources["resource.refined_iron"], 8, "success banks special resources separately")
	_assert_equal(state.applied_settlement_ids, ["settlement:success"], "success records its stable request id")
	_assert_equal(state.settlement_history.size(), 1, "success appends one settlement audit record")
	_assert_equal(state.pending_long_term_effects.size(), 1, "success queues general and expedition effects for later M5 systems")
	_assert_equal(state.pending_long_term_effects[0].remaining_troops, 500, "deferred effect preserves remaining troops")
	_assert_true(not state.has("expedition_runtime"), "Campaign stores settlement results rather than Expedition runtime objects")


func _test_settlement_is_idempotent() -> void:
	var controller = _controller("campaign.idempotent")
	var request := _settlement("settlement:same", "success")
	request.loot_to_bank = {"resource.silver": 50}
	var first: Dictionary = controller.apply_expedition_settlement(request)
	var state_after_first: Dictionary = controller.snapshot()
	var second: Dictionary = controller.apply_expedition_settlement(request)
	_assert_true(first.ok and second.ok and second.duplicate, "same settlement request is reported as an idempotent duplicate")
	_assert_equal(controller.snapshot(), state_after_first, "duplicate settlement cannot add resources or history twice")
	_assert_equal(controller.snapshot().resources.silver, 50, "duplicate settlement leaves the resource total unchanged")


func _test_invalid_settlement_rolls_back_fully() -> void:
	var controller = _controller("campaign.rollback")
	var before: Dictionary = controller.snapshot()
	var invalid := _settlement("settlement:invalid-loot", "success")
	invalid.loot_to_bank = {"resource.silver": 100, "resource.food": -1}
	var result: Dictionary = controller.apply_expedition_settlement(invalid)
	_assert_true(not result.ok, "settlement with one invalid loot entry is rejected")
	_assert_equal(controller.snapshot(), before, "invalid settlement cannot partially add earlier loot entries")


func _test_retreat_and_failure_queue_losses_without_rewards() -> void:
	var retreat_controller = _controller("campaign.retreat")
	var retreat := _settlement("settlement:retreat", "retreated")
	retreat.remaining_troops = 880
	retreat.remaining_morale = 61
	retreat.lost_unbanked_loot = {"resource.silver": 90}
	_assert_true(retreat_controller.apply_expedition_settlement(retreat).ok, "retreat settlement commits its loss record")
	var retreat_state: Dictionary = retreat_controller.snapshot()
	_assert_equal(retreat_state.resources.silver, 0, "retreat adds no resources")
	_assert_equal(retreat_state.pending_long_term_effects[0].outcome, "retreated", "retreat queues its distinct long-term outcome")
	_assert_equal(retreat_state.pending_long_term_effects[0].remaining_troops, 880, "retreat queues preserved troop losses")

	var failure_controller = _controller("campaign.failure")
	var failure := _settlement("settlement:failure", "failed")
	failure.remaining_troops = 0
	failure.general_died = true
	failure.lost_unbanked_loot = {"resource.food": 75}
	_assert_true(failure_controller.apply_expedition_settlement(failure).ok, "failure settlement commits its loss record")
	var failure_state: Dictionary = failure_controller.snapshot()
	_assert_equal(failure_state.resources.food, 0, "failure adds no resources")
	_assert_true(failure_state.pending_long_term_effects[0].general_died, "failure queues the Combat death result for M5 general handling")


func _test_settlement_failure_contracts() -> void:
	var uninitialized = CampaignControllerScript.new()
	_assert_true(not uninitialized.apply_expedition_settlement(_settlement("settlement:no-setup", "success")).ok, "settlement rejects calls before controller setup")
	var controller = _controller("campaign.failures")
	_assert_true(not controller.apply_expedition_settlement({}).ok, "settlement rejects missing fields")
	var bad_outcome := _settlement("settlement:bad-outcome", "future")
	_assert_true(not controller.apply_expedition_settlement(bad_outcome).ok, "settlement rejects an unsupported outcome")
	var rewarded_retreat := _settlement("settlement:rewarded-retreat", "retreated")
	rewarded_retreat.loot_to_bank = {"resource.silver": 1}
	_assert_true(not controller.apply_expedition_settlement(rewarded_retreat).ok, "retreat cannot smuggle banked loot")
	var lost_success := _settlement("settlement:lost-success", "success")
	lost_success.lost_unbanked_loot = {"resource.food": 1}
	_assert_true(not controller.apply_expedition_settlement(lost_success).ok, "success cannot report lost loot")
	var non_boolean := _settlement("settlement:flags", "failed")
	non_boolean.general_died = 1
	_assert_true(not controller.apply_expedition_settlement(non_boolean).ok, "settlement requires boolean general flags")
	var non_numeric := _settlement("settlement:non-numeric", "success")
	non_numeric.loot_to_bank = {"resource.silver": "many"}
	_assert_true(not controller.apply_expedition_settlement(non_numeric).ok, "settlement rejects non-numeric loot amounts")
	var fractional := _settlement("settlement:fractional", "failed")
	fractional.remaining_troops = 499.5
	_assert_true(not controller.apply_expedition_settlement(fractional).ok, "settlement rejects fractional troop state")
	_assert_true(controller.snapshot().applied_settlement_ids.is_empty(), "rejected settlements leave the idempotency ledger untouched")


func _test_extended_campaign_save_round_trip() -> void:
	var controller = _controller("campaign.save")
	var request := _settlement("settlement:save", "success")
	request.loot_to_bank = {"resource.silver": 25}
	controller.apply_expedition_settlement(request)
	var envelope: Dictionary = SaveEnvelopeScript.create_empty("campaign.save", "2026-09-01T00:00:00Z")
	envelope.campaign = controller.snapshot()
	var codec = SaveGameCodecScript.new()
	var encoded: Dictionary = codec.encode(envelope)
	_assert_true(encoded.ok, "extended CampaignState encodes through the v2 save envelope")
	var decoded: Dictionary = codec.decode(encoded.text)
	_assert_true(decoded.ok, "extended CampaignState decodes through the v2 save envelope")
	var restored: Dictionary = CampaignStateScript.normalize(decoded.value.campaign)
	_assert_true(CampaignStateScript.validate(restored).is_empty(), "decoded campaign remains a valid CampaignState")
	_assert_equal(int(restored.resources.silver), 25, "save round-trip preserves banked resources")
	_assert_equal(restored.applied_settlement_ids, ["settlement:save"], "save round-trip preserves settlement idempotency")
	_assert_equal(restored.settlement_history[0].outcome, "success", "save round-trip preserves settlement history")
	_assert_equal(int(restored.pending_long_term_effects[0].remaining_troops), 500, "save round-trip preserves deferred expedition effects")


func _controller(campaign_id: String):
	var controller = CampaignControllerScript.new()
	_assert_true(controller.setup(CampaignStateScript.create(campaign_id)).is_empty(), "%s controller setup succeeds" % campaign_id)
	return controller


func _settlement(request_id: String, outcome: String) -> Dictionary:
	return {
		"request_id": request_id,
		"run_id": "run.m5",
		"expedition_id": "expedition.capture_heyuan_county",
		"outcome": outcome,
		"general_id": "general.zhao_lie",
		"remaining_troops": 500,
		"remaining_morale": 48,
		"general_died": false,
		"general_injured": false,
		"loot_to_bank": {},
		"lost_unbanked_loot": {},
		"boss_modifiers": {"armory_destroyed": true},
		"completed_battles": 5,
	}


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
