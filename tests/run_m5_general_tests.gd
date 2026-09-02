extends SceneTree

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")
const GeneralManagementServiceScript := preload("res://src/domain/campaign/general_management_service.gd")
const CampaignStateScript := preload("res://src/domain/campaign/campaign_state.gd")
const CampaignControllerScript := preload("res://src/domain/campaign/campaign_controller.gd")
const SaveEnvelopeScript := preload("res://src/domain/campaign/save_envelope.gd")
const SaveGameCodecScript := preload("res://src/infrastructure/persistence/save_game_codec.gd")

const PROGRESSION_PATH := "res://data/config/prototype_general_progression.json"
const TEST_GENERAL_IDS := ["general.zhao_lie", "general.zhou_jing", "general.han_yue"]

var _passed := 0
var _failed := 0
var _registry
var _progression: Dictionary = {}
var _generals: Array = []


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_registry = ContentRegistryScript.new()
	_assert_true(_registry.load_all(), "M5 general content registry loads")
	_progression = _load_json(PROGRESSION_PATH)
	for general_id in TEST_GENERAL_IDS:
		_generals.append(_registry.get_general(general_id))
	_test_progression_and_instance_contracts()
	_test_roster_initialization_and_idempotency()
	_test_expedition_growth_and_milestones()
	_test_one_level_per_expedition_boundary()
	_test_upper_level_milestones()
	_test_major_injury_and_recovery()
	_test_permanent_death()
	_test_player_death_game_over()
	_test_transaction_failures_and_old_save_normalization()
	_test_general_save_round_trip()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_progression_and_instance_contracts() -> void:
	_assert_true(not _progression.is_empty(), "prototype general progression config loads")
	_assert_true(GeneralManagementServiceScript.validate_progression_definition(_progression).is_empty(), "prototype progression satisfies its contract")
	_assert_equal(_progression.balance_status, "prototype_temporary", "general growth numbers remain explicitly prototype-only")
	_assert_equal(_progression.max_level, 6, "Vertical Slice progression stops at Lv6")
	_assert_equal(_progression.max_levels_per_expedition, 1, "one expedition can grant at most one level")
	_assert_true(GeneralManagementServiceScript.validate_general_catalog(_generals).is_empty(), "three test general definitions form a valid long-term catalog")
	var zhao: Dictionary = GeneralManagementServiceScript.create_instance(_generals[0])
	_assert_true(GeneralManagementServiceScript.validate_instance(zhao).is_empty(), "GeneralInstance satisfies the runtime contract")
	_assert_equal(zhao.attributes, {"martial": 84, "leadership": 72, "administration": 24}, "GeneralInstance keeps only the three locked attributes")
	_assert_equal(zhao.active_talent_id, "talent.zhao_lie.break_formation", "GeneralInstance starts with its fixed core talent active")
	_assert_equal(zhao.unlocked_exclusive_cards, ["card.general.zhao_lie.lone_breakthrough"], "existing M3 exclusive card starts on its owner only")
	_assert_true(zhao.pending_growth_milestones.is_empty(), "Lv1 does not invent future growth choices")
	var false_final := _progression.duplicate(true)
	false_final.balance_status = "final"
	_assert_error_contains(GeneralManagementServiceScript.validate_progression_definition(false_final), "prototype_temporary", "prototype progression cannot silently become final balance")
	var multiple_levels := _progression.duplicate(true)
	multiple_levels.max_levels_per_expedition = 2
	_assert_error_contains(GeneralManagementServiceScript.validate_progression_definition(multiple_levels), "remain 1", "config cannot permit multi-level expedition growth")
	var extra_attribute: Dictionary = _generals[0].duplicate(true)
	extra_attribute.erase("leadership")
	_assert_error_contains(GeneralManagementServiceScript.validate_general_catalog([extra_attribute]), "leadership", "catalog rejects a missing locked attribute")


func _test_roster_initialization_and_idempotency() -> void:
	var controller = _configured_controller("campaign.general-init")
	var request := {"action_id": "general:init:zhao", "general_id": "general.zhao_lie"}
	var request_before := request.duplicate(true)
	var first: Dictionary = controller.initialize_general(request)
	_assert_true(first.ok and not first.duplicate, "valid general initialization commits once")
	_assert_equal(request, request_before, "general initialization does not mutate its request")
	_assert_equal(controller.snapshot().generals.size(), 1, "initialization appends one GeneralInstance")
	_assert_equal(first.general.level, 1, "new long-term general starts at Lv1")
	var after_first: Dictionary = controller.snapshot()
	var duplicate: Dictionary = controller.initialize_general(request)
	_assert_true(duplicate.ok and duplicate.duplicate, "same general initialization action is idempotent")
	_assert_equal(controller.snapshot(), after_first, "duplicate initialization cannot append a second instance")
	_assert_true(not controller.initialize_general({"action_id": "general:init:zhao:again", "general_id": "general.zhao_lie"}).ok, "distinct action cannot initialize the same general twice")
	_assert_equal(controller.snapshot(), after_first, "rejected duplicate general leaves the roster unchanged")
	_assert_true(not controller.initialize_general({"action_id": "general:init:unknown", "general_id": "general.unknown"}).ok, "initialization rejects a general outside the configured catalog")


func _test_expedition_growth_and_milestones() -> void:
	var controller = _controller_with_zhao("campaign.general-growth")
	_assert_true(controller.apply_expedition_settlement(_settlement("settlement:growth:1", "success")).ok, "first growth settlement queues")
	var first: Dictionary = controller.apply_pending_general_effect("settlement:growth:1")
	_assert_true(first.ok and first.level_gained == 1, "first successful expedition reaches Lv2")
	_assert_equal(first.experience_gained, 100, "success grants centralized prototype experience")
	_assert_equal(first.general.attributes, {"martial": 85, "leadership": 73, "administration": 25}, "Lv2 applies only the centralized small attribute growth")
	_assert_true(first.general.pending_growth_milestones.is_empty(), "Lv2 has no content-choice milestone")
	var after_first: Dictionary = controller.snapshot()
	var duplicate: Dictionary = controller.apply_pending_general_effect("settlement:growth:1")
	_assert_true(duplicate.ok and duplicate.duplicate, "same settlement general effect is idempotent")
	_assert_equal(controller.snapshot(), after_first, "duplicate general effect cannot grant experience twice")
	controller.apply_expedition_settlement(_settlement("settlement:growth:2", "success"))
	var second: Dictionary = controller.apply_pending_general_effect("settlement:growth:2")
	_assert_equal(second.level_gained, 0, "experience below the next threshold does not level")
	controller.apply_expedition_settlement(_settlement("settlement:growth:3", "success"))
	var third: Dictionary = controller.apply_pending_general_effect("settlement:growth:3")
	_assert_equal(third.general.level, 3, "third prototype success reaches Lv3")
	_assert_equal(third.general.pending_growth_milestones.size(), 1, "Lv3 records one unresolved growth milestone")
	_assert_equal(third.general.pending_growth_milestones[0].type, "talent_branch_choice", "Lv3 preserves the locked talent-choice boundary")
	_assert_equal(third.general.pending_growth_milestones[0].status, "content_pending", "undefined talent branches remain explicitly content-pending")
	controller.apply_expedition_settlement(_settlement("settlement:growth:4", "success"))
	controller.apply_pending_general_effect("settlement:growth:4")
	controller.apply_expedition_settlement(_settlement("settlement:growth:5", "success"))
	var fifth: Dictionary = controller.apply_pending_general_effect("settlement:growth:5")
	_assert_equal(fifth.general.level, 4, "cumulative prototype experience reaches Lv4")
	_assert_equal(fifth.general.pending_growth_milestones[1].type, "exclusive_card_unlock", "Lv4 records the additional exclusive-card boundary")
	_assert_equal(fifth.general.pending_growth_milestones[1].status, "content_pending", "Lv4 does not invent an undefined exclusive card")


func _test_one_level_per_expedition_boundary() -> void:
	var instance: Dictionary = GeneralManagementServiceScript.create_instance(_generals[0])
	instance.experience = 1000
	var effect := _effect("settlement:level-cap", "success")
	var result: Dictionary = GeneralManagementServiceScript.apply_expedition_effect(instance, effect, _progression)
	_assert_equal(result.level_gained, 1, "one effect reports exactly one gained level despite excess experience")
	_assert_equal(result.instance.level, 2, "one expedition cannot jump from Lv1 through multiple thresholds")
	_assert_equal(result.instance.experience, 1100, "excess experience remains stored rather than discarded")
	var second: Dictionary = GeneralManagementServiceScript.apply_expedition_effect(result.instance, _effect("settlement:level-cap:2", "failed"), _progression)
	_assert_equal(second.instance.level, 3, "a later expedition may consume the next stored threshold")
	_assert_equal(second.instance.pending_growth_milestones[0].type, "talent_branch_choice", "stored experience still produces the correct Lv3 milestone")


func _test_upper_level_milestones() -> void:
	var instance: Dictionary = GeneralManagementServiceScript.create_instance(_generals[1])
	instance.level = 4
	instance.experience = 700
	var level_five: Dictionary = GeneralManagementServiceScript.apply_expedition_effect(instance, _effect("settlement:level-five", "success"), _progression)
	_assert_equal(level_five.instance.level, 5, "Lv5 threshold advances to the second attribute-growth level")
	_assert_equal(level_five.instance.attributes, {"martial": 59, "leadership": 89, "administration": 48}, "Lv5 applies the centralized small attribute growth")
	level_five.instance.experience = 1000
	var level_six: Dictionary = GeneralManagementServiceScript.apply_expedition_effect(level_five.instance, _effect("settlement:level-six", "failed"), _progression)
	_assert_equal(level_six.instance.level, 6, "Vertical Slice progression reaches Lv6")
	_assert_equal(level_six.instance.pending_growth_milestones.size(), 1, "Lv6 records one second talent milestone")
	_assert_equal(level_six.instance.pending_growth_milestones[0].type, "talent_branch_choice", "Lv6 preserves the second talent-choice boundary")
	_assert_equal(level_six.instance.pending_growth_milestones[0].level, 6, "Lv6 milestone keeps its source level")
	var at_max: Dictionary = GeneralManagementServiceScript.apply_expedition_effect(level_six.instance, _effect("settlement:at-max", "success"), _progression)
	_assert_equal(at_max.level_gained, 0, "expeditions cannot level beyond the Vertical Slice cap")
	_assert_equal(at_max.instance.level, 6, "maximum level remains Lv6")


func _test_major_injury_and_recovery() -> void:
	var controller = _controller_with_zhao("campaign.general-injury")
	var injury_request := _settlement("settlement:injury", "failed")
	injury_request.remaining_morale = 0
	injury_request.general_injured = true
	_assert_true(controller.apply_expedition_settlement(injury_request).ok, "major injury settlement queues")
	var injured: Dictionary = controller.apply_pending_general_effect("settlement:injury")
	_assert_true(injured.ok and injured.injured and not injured.died, "morale injury applies without rerolling Combat outcome")
	_assert_equal(injured.general.injury, {"status": "major_injury", "remaining_cycles": 2}, "major injury uses centralized prototype recovery cycles")
	_assert_equal(controller.general_availability("general.zhao_lie").reason, "major_injury", "major injury blocks deployment")
	var first: Dictionary = controller.apply_general_recovery_cycle("cycle:recovery:1")
	_assert_equal(first.changed_general_ids, ["general.zhao_lie"], "first faction cycle advances the injured general")
	_assert_true(first.recovered_general_ids.is_empty(), "first cycle does not recover a two-cycle injury")
	_assert_equal(controller.snapshot().generals[0].injury.remaining_cycles, 1, "first cycle leaves one recovery cycle")
	var after_first: Dictionary = controller.snapshot()
	var duplicate: Dictionary = controller.apply_general_recovery_cycle("cycle:recovery:1")
	_assert_true(duplicate.ok and duplicate.duplicate, "same recovery cycle action is idempotent")
	_assert_equal(controller.snapshot(), after_first, "duplicate cycle cannot shorten injury twice")
	var second: Dictionary = controller.apply_general_recovery_cycle("cycle:recovery:2")
	_assert_equal(second.recovered_general_ids, ["general.zhao_lie"], "second faction cycle completes recovery")
	_assert_true(controller.general_availability("general.zhao_lie").available, "recovered general becomes deployable")
	var retreat_controller = _controller_with_zhao("campaign.general-retreat")
	retreat_controller.apply_expedition_settlement(_settlement("settlement:retreat-safe", "retreated"))
	var retreated: Dictionary = retreat_controller.apply_pending_general_effect("settlement:retreat-safe")
	_assert_true(not retreated.injured and not retreated.died, "retreat preserves the general risk result")
	_assert_equal(retreated.experience_gained, 25, "retreat experience remains a centralized prototype parameter")


func _test_permanent_death() -> void:
	var controller = _controller_with_zhao("campaign.general-death")
	var death_request := _settlement("settlement:death", "failed")
	death_request.remaining_troops = 0
	death_request.general_died = true
	_assert_true(controller.apply_expedition_settlement(death_request).ok, "troop-zero death settlement queues")
	var death: Dictionary = controller.apply_pending_general_effect("settlement:death")
	_assert_true(death.ok and death.died and not death.game_over, "non-player permanent death commits without ending campaign")
	_assert_equal(death.general.status, "deceased", "dead general remains as an auditable deceased record")
	_assert_equal(death.general.active_talent_id, "", "death removes the active talent from play")
	_assert_true(death.general.unlocked_exclusive_cards.is_empty(), "death removes exclusive cards from play")
	_assert_equal(death.general.death_record.lost_talent_id, "talent.zhao_lie.break_formation", "death audit preserves the lost talent id")
	_assert_equal(death.general.death_record.lost_exclusive_cards, ["card.general.zhao_lie.lone_breakthrough"], "death audit preserves lost exclusive card ids")
	_assert_equal(death.general.death_record.cause, "troops_zero", "troop-zero cause is preserved")
	_assert_equal(controller.general_availability("general.zhao_lie").reason, "deceased", "deceased general cannot deploy")
	_assert_equal(controller.snapshot().campaign_status, "active", "non-player death leaves campaign active")


func _test_player_death_game_over() -> void:
	var player_definition: Dictionary = _generals[0].duplicate(true)
	player_definition.id = "general.player.placeholder"
	player_definition.name = "自创角色（占位）"
	var state: Dictionary = CampaignStateScript.create("campaign.player-death")
	state.generals.append(GeneralManagementServiceScript.create_instance(player_definition, true))
	var controller = CampaignControllerScript.new()
	_assert_true(controller.setup(state).is_empty(), "player placeholder GeneralInstance enters CampaignState")
	_assert_true(controller.configure_generals(_progression, [player_definition]).is_empty(), "player placeholder uses the same progression contract")
	_assert_equal(controller.general_availability("general.player.placeholder").reason, "vertical_slice_player_placeholder", "player character remains a non-deployable Vertical Slice placeholder")
	var death_request := _settlement("settlement:player-death", "failed", "general.player.placeholder")
	death_request.remaining_troops = 0
	death_request.general_died = true
	controller.apply_expedition_settlement(death_request)
	var result: Dictionary = controller.apply_pending_general_effect("settlement:player-death")
	_assert_true(result.ok and result.game_over, "player character death immediately commits Game Over")
	_assert_equal(controller.snapshot().campaign_status, "game_over", "campaign status becomes game_over")
	_assert_equal(controller.snapshot().game_over_record.reason, "player_character_died", "Game Over keeps a stable reason")
	_assert_equal(controller.general_availability("general.player.placeholder").reason, "campaign_game_over", "no general is deployable after Game Over")
	_assert_true(not controller.apply_expedition_settlement(_settlement("settlement:after-game-over", "success", "general.player.placeholder")).ok, "Game Over rejects later settlements")
	_assert_true(not controller.apply_general_recovery_cycle("cycle:after-game-over").ok, "Game Over rejects later recovery cycles")


func _test_transaction_failures_and_old_save_normalization() -> void:
	var controller = _controller_with_zhao("campaign.general-failures")
	var before: Dictionary = controller.snapshot()
	_assert_true(not controller.apply_pending_general_effect("settlement:missing").ok, "unknown pending effect is rejected")
	_assert_equal(controller.snapshot(), before, "unknown pending effect cannot mutate general state")
	var unknown_general := _settlement("settlement:unknown-general", "success", "general.unknown")
	controller.apply_expedition_settlement(unknown_general)
	var queued: Dictionary = controller.snapshot()
	_assert_true(not controller.apply_pending_general_effect("settlement:unknown-general").ok, "effect for unknown campaign general is rejected")
	_assert_equal(controller.snapshot(), queued, "unknown general effect leaves queue and roster unchanged")
	var invalid_flags := _settlement("settlement:invalid-flags", "failed")
	invalid_flags.general_died = true
	invalid_flags.general_injured = true
	_assert_true(not controller.apply_expedition_settlement(invalid_flags).ok, "settlement rejects simultaneous death and injury")
	var old_state: Dictionary = CampaignStateScript.create("campaign.old-general")
	old_state.erase("general_system")
	old_state.erase("campaign_status")
	old_state.erase("game_over_record")
	old_state.pending_long_term_effects.append(_effect("settlement:legacy", "success"))
	old_state.pending_long_term_effects[0].erase("general_effect_applied")
	var normalized: Dictionary = CampaignStateScript.normalize(old_state)
	_assert_equal(normalized.general_system, GeneralManagementServiceScript.create_system_state(), "old V1 save receives empty general transaction ledgers")
	_assert_equal(normalized.campaign_status, "active", "old V1 save defaults to active campaign")
	_assert_true(not normalized.pending_long_term_effects[0].general_effect_applied, "old deferred effect defaults to unapplied general state")
	_assert_true(CampaignStateScript.validate(normalized).is_empty(), "normalized old V1 general state remains valid")
	var malformed := normalized.duplicate(true)
	malformed.general_system.applied_effect_ids = ["same", "same"]
	_assert_error_contains(CampaignStateScript.validate(malformed), "duplicate", "CampaignState rejects duplicate general effect ledger ids")


func _test_general_save_round_trip() -> void:
	var controller = _controller_with_zhao("campaign.general-save")
	var injury_request := _settlement("settlement:save-injury", "failed")
	injury_request.remaining_morale = 0
	injury_request.general_injured = true
	controller.apply_expedition_settlement(injury_request)
	controller.apply_pending_general_effect("settlement:save-injury")
	controller.apply_general_recovery_cycle("cycle:save:1")
	var envelope: Dictionary = SaveEnvelopeScript.create_empty("campaign.general-save", "2026-09-01T00:00:00Z")
	envelope.campaign = controller.snapshot()
	var codec = SaveGameCodecScript.new()
	var encoded: Dictionary = codec.encode(envelope)
	_assert_true(encoded.ok, "GeneralInstance CampaignState encodes through Save V2")
	var decoded: Dictionary = codec.decode(encoded.text)
	_assert_true(decoded.ok, "GeneralInstance CampaignState decodes through Save V2")
	var restored: Dictionary = CampaignStateScript.normalize(decoded.value.campaign)
	_assert_true(CampaignStateScript.validate(restored).is_empty(), "restored GeneralInstance CampaignState remains valid")
	_assert_equal(restored.generals[0].injury.remaining_cycles, 1, "save round-trip preserves partial major-injury recovery")
	_assert_equal(restored.general_system.applied_effect_ids, ["settlement:save-injury"], "save round-trip preserves general effect idempotency")
	_assert_equal(restored.general_system.applied_recovery_ids, ["cycle:save:1"], "save round-trip preserves recovery idempotency")


func _configured_controller(campaign_id: String):
	var controller = CampaignControllerScript.new()
	_assert_true(controller.setup(CampaignStateScript.create(campaign_id)).is_empty(), "%s controller setup succeeds" % campaign_id)
	_assert_true(controller.configure_generals(_progression, _generals).is_empty(), "%s general catalog setup succeeds" % campaign_id)
	return controller


func _controller_with_zhao(campaign_id: String):
	var controller = _configured_controller(campaign_id)
	_assert_true(controller.initialize_general({"action_id": "general:init:%s" % campaign_id, "general_id": "general.zhao_lie"}).ok, "%s initializes Zhao Lie" % campaign_id)
	return controller


func _settlement(request_id: String, outcome: String, general_id: String = "general.zhao_lie") -> Dictionary:
	return {
		"request_id": request_id,
		"run_id": "run.%s" % request_id,
		"expedition_id": "expedition.capture_heyuan_county",
		"outcome": outcome,
		"general_id": general_id,
		"remaining_troops": 500,
		"remaining_morale": 40,
		"general_died": false,
		"general_injured": false,
		"loot_to_bank": {} if outcome != "success" else {"resource.silver": 1},
		"lost_unbanked_loot": {} if outcome == "success" else {"resource.silver": 1},
	}


func _effect(request_id: String, outcome: String) -> Dictionary:
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
