extends SceneTree

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")
const GeneralManagementServiceScript := preload("res://src/domain/campaign/general_management_service.gd")
const CampaignStateScript := preload("res://src/domain/campaign/campaign_state.gd")
const CampaignControllerScript := preload("res://src/domain/campaign/campaign_controller.gd")
const SaveEnvelopeScript := preload("res://src/domain/campaign/save_envelope.gd")
const SaveGameCodecScript := preload("res://src/infrastructure/persistence/save_game_codec.gd")
const SaveFileStoreScript := preload("res://src/infrastructure/persistence/save_file_store.gd")
const SaveContentReferenceValidatorScript := preload("res://src/infrastructure/persistence/save_content_reference_validator.gd")

const PROGRESSION_PATH := "res://data/config/prototype_general_progression.json"
const FACTION_PATH := "res://data/config/prototype_faction_cycle.json"
const TEST_SAVE_PATH := "/tmp/dynasty-rebellion-m5-07/save.json"

var _passed := 0
var _failed := 0
var _registry
var _progression: Dictionary = {}
var _faction: Dictionary = {}
var _zhao: Dictionary = {}
var _territory: Dictionary = {}


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_registry = ContentRegistryScript.new()
	_assert_true(_registry.load_all(), "M5-07 content registry loads")
	_progression = _load_json(PROGRESSION_PATH)
	_faction = _load_json(FACTION_PATH)
	# Preserve the original M5 single-Heyuan fixture; M6 owns the expanded catalog.
	_faction.cycle_advancing_expedition_ids = ["expedition.capture_heyuan_county"]
	_zhao = _registry.get_general("general.zhao_lie")
	_territory = _registry.get_territory("territory.heyuan_county")
	_test_v2_envelope_and_sequential_v1_migration()
	_test_migration_failures()
	_test_atomic_save_backup_and_recovery()
	_test_content_reference_validation()
	_test_atomic_long_term_finalization()
	_test_partial_consumer_resume_and_rollback()
	_test_explicit_legacy_army_recovery()
	_test_game_over_interruption_resume()
	_cleanup_save_files(TEST_SAVE_PATH)
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_v2_envelope_and_sequential_v1_migration() -> void:
	var current: Dictionary = SaveEnvelopeScript.create_empty("campaign.v2", "2026-09-02T00:00:00Z")
	_assert_equal(current.save_version, 7, "new saves use explicit Save V7")
	_assert_equal(current.content_version, "0.7.3-m6-battle-report", "new save content version matches the battle-report flow")
	_assert_true(SaveEnvelopeScript.validate(current).is_empty(), "new Save V7 envelope satisfies the full CampaignState contract")
	var legacy := current.duplicate(true)
	legacy.save_version = 1
	legacy.content_version = "0.1.0-m0"
	for field in ["general_system", "campaign_status", "game_over_record", "faction", "applied_finalization_ids", "finalization_history"]:
		legacy.campaign.erase(field)
	legacy.campaign.army_inventory = {}
	legacy.campaign.pending_long_term_effects.append(_legacy_effect("settlement:legacy-migration"))
	var untouched := legacy.duplicate(true)
	var decoded: Dictionary = SaveGameCodecScript.new().decode(JSON.stringify(legacy))
	_assert_true(decoded.ok and decoded.migrated, "Save V1 decodes through the registered migration chain")
	_assert_equal(decoded.from_version, 1, "migration reports its source version")
	_assert_equal(decoded.to_version, 7, "migration reports its target version")
	_assert_equal(decoded.value.save_version, 7, "migration upgrades the envelope through Save V7")
	_assert_equal(decoded.value.content_version, "0.1.0-m0", "migration preserves the source content version for audit")
	_assert_equal(decoded.value.campaign.army_inventory, {"infantry": 0, "archer": 0, "cavalry": 0}, "migration adds all missing army stocks")
	_assert_true(not decoded.value.campaign.pending_long_term_effects[0].army_losses_applied, "migration preserves unresolved legacy casualties explicitly")
	_assert_true(not decoded.value.campaign.pending_long_term_effects[0].long_term_effects_finalized, "legacy effect remains unfinished after structural migration")
	_assert_true(decoded.value.campaign.applied_finalization_ids.is_empty(), "migration adds an empty finalization ledger")
	_assert_equal(legacy, untouched, "migration never mutates the caller's old-save DTO")
	_assert_true(SaveEnvelopeScript.validate(decoded.value).is_empty(), "migrated Save V1 satisfies the current Save V7 schema")


func _test_migration_failures() -> void:
	var future := SaveEnvelopeScript.create_empty("campaign.future", "2026-09-02T00:00:00Z")
	future.save_version = 99
	_assert_error_contains(SaveGameCodecScript.new().decode(JSON.stringify(future)).errors, "future", "future save versions are rejected readably")
	var missing_version := future.duplicate(true)
	missing_version.erase("save_version")
	_assert_error_contains(SaveGameCodecScript.new().decode(JSON.stringify(missing_version)).errors, "missing save_version", "save without a version cannot bypass migration")
	var malformed := SaveEnvelopeScript.create_empty("campaign.bad-v1", "2026-09-02T00:00:00Z")
	malformed.save_version = 1
	malformed.campaign = []
	_assert_error_contains(SaveGameCodecScript.new().decode(JSON.stringify(malformed)).errors, "campaign must be an object", "malformed V1 campaign fails before migration commits")
	var ghost_finalization := SaveEnvelopeScript.create_empty("campaign.ghost-finalization", "2026-09-02T00:00:00Z")
	ghost_finalization.campaign.applied_finalization_ids.append("settlement:missing")
	_assert_error_contains(SaveEnvelopeScript.validate(ghost_finalization), "unknown request", "finalization ledger cannot reference a missing settlement")
	var missing_ledger := SaveEnvelopeScript.create_empty("campaign.missing-ledger", "2026-09-02T00:00:00Z")
	var completed_effect := CampaignStateScript.normalize({"campaign_id": "scratch", "pending_long_term_effects": [_legacy_effect("settlement:completed")]})
	completed_effect.pending_long_term_effects[0].army_losses_applied = true
	completed_effect.pending_long_term_effects[0].general_effect_applied = true
	completed_effect.pending_long_term_effects[0].faction_effect_applied = true
	completed_effect.pending_long_term_effects[0].long_term_effects_finalized = true
	missing_ledger.campaign.pending_long_term_effects = completed_effect.pending_long_term_effects
	_assert_error_contains(SaveEnvelopeScript.validate(missing_ledger), "missing from applied_finalization_ids", "finalized effect must be backed by its idempotency ledger")


func _test_atomic_save_backup_and_recovery() -> void:
	_cleanup_save_files(TEST_SAVE_PATH)
	var store = SaveFileStoreScript.new()
	var first := SaveEnvelopeScript.create_empty("campaign.atomic", "2026-09-02T00:00:00Z")
	first.campaign.resources.silver = 10
	var first_save: Dictionary = store.save(TEST_SAVE_PATH, first, "2026-09-02T00:01:00Z")
	_assert_true(first_save.ok and not first_save.backup_created, "first atomic save promotes a validated temporary file")
	_assert_true(FileAccess.file_exists(TEST_SAVE_PATH), "first atomic save creates the primary file")
	_assert_true(not FileAccess.file_exists(TEST_SAVE_PATH + ".tmp"), "successful save leaves no temporary file")
	var second := first.duplicate(true)
	second.campaign.resources.silver = 20
	var second_save: Dictionary = store.save(TEST_SAVE_PATH, second, "2026-09-02T00:02:00Z")
	_assert_true(second_save.ok and second_save.backup_created, "second atomic save rotates one recent backup")
	_assert_true(FileAccess.file_exists(TEST_SAVE_PATH + ".bak"), "recent backup exists after replacement")
	var loaded: Dictionary = store.load(TEST_SAVE_PATH)
	_assert_true(loaded.ok and loaded.source == "primary" and not loaded.recovered, "healthy primary save loads directly")
	_assert_equal(int(loaded.value.campaign.resources.silver), 20, "primary contains the newest committed value")
	_assert_equal(loaded.value.updated_at, "2026-09-02T00:02:00Z", "save service updates the deterministic timestamp")
	var backup_loaded: Dictionary = store.load(TEST_SAVE_PATH + ".bak")
	_assert_equal(int(backup_loaded.value.campaign.resources.silver), 10, "single backup preserves the previous valid commit")
	var invalid := second.duplicate(true)
	invalid.campaign.resources.silver = -1
	_assert_true(not store.save(TEST_SAVE_PATH, invalid).ok, "invalid envelope is rejected before primary rotation")
	_assert_equal(int(store.load(TEST_SAVE_PATH).value.campaign.resources.silver), 20, "rejected save cannot overwrite the primary")
	_write_text(TEST_SAVE_PATH, "{broken-json")
	var recovered: Dictionary = store.load(TEST_SAVE_PATH)
	_assert_true(recovered.ok and recovered.recovered and recovered.source == "backup", "corrupt primary falls back to the recent backup")
	_assert_equal(int(recovered.value.campaign.resources.silver), 10, "backup recovery returns the last previous commit")
	_assert_true(not recovered.primary_errors.is_empty(), "backup recovery exposes the primary failure for diagnosis")
	_write_text(TEST_SAVE_PATH + ".tmp", JSON.stringify(second))
	var interrupted: Dictionary = store.load(TEST_SAVE_PATH)
	_assert_true(interrupted.ok and interrupted.source == "backup", "orphan temporary file is never mistaken for a committed save")
	var third := second.duplicate(true)
	third.campaign.resources.silver = 30
	var repaired: Dictionary = store.save(TEST_SAVE_PATH, third, "2026-09-02T00:03:00Z")
	_assert_true(repaired.ok and repaired.backup_preserved, "replacing a corrupt primary preserves the existing valid backup")
	_assert_equal(int(store.load(TEST_SAVE_PATH).value.campaign.resources.silver), 30, "validated replacement becomes the new primary")
	_assert_equal(int(store.load(TEST_SAVE_PATH + ".bak").value.campaign.resources.silver), 10, "corrupt primary never overwrites the valid recent backup")
	_cleanup_save_files(TEST_SAVE_PATH)
	_assert_true(not store.load(TEST_SAVE_PATH).ok, "missing primary and backup report a load failure")


func _test_content_reference_validation() -> void:
	var validator = SaveContentReferenceValidatorScript.new()
	var envelope := SaveEnvelopeScript.create_empty("campaign.references", "2026-09-02T00:00:00Z")
	envelope.campaign.generals.append(GeneralManagementServiceScript.create_instance(_zhao, false))
	_assert_true(validator.validate(envelope, _registry).is_empty(), "registered general, talent and exclusive card references validate")
	var invalid := envelope.duplicate(true)
	invalid.campaign.unlocked_public_cards.append("card.missing")
	invalid.campaign.generals[0].active_talent_id = "talent.missing"
	invalid.campaign.territories.append({
		"territory_id": "territory.missing", "name": "失效领地", "status": "controlled",
		"income_enabled": true, "acquired_cycle": 0, "source_request_id": "legacy",
	})
	var effect := _legacy_effect("settlement:missing-references")
	effect.expedition_id = "expedition.missing"
	effect.general_id = "general.missing"
	invalid.campaign.pending_long_term_effects.append(effect)
	invalid.campaign = CampaignStateScript.normalize(invalid.campaign)
	invalid.expedition = {
		"expedition_id": "expedition.capture_heyuan_county",
		"general": {"id": "general.zhao_lie", "talent_id": "talent.zhao_lie.break_formation"},
		"deck": ["card.expedition.missing"],
		"route": {"current_node_id": "node.missing", "visited_node_ids": [], "completed_node_ids": [], "revealed_node_ids": [], "available_next_node_ids": []},
		"pending_combat": {
			"player": {"id": "general.zhao_lie", "talent_id": "talent.zhao_lie.break_formation"},
			"enemy": {"id": "enemy.missing", "talent_id": ""},
			"deck": [],
		},
	}
	var errors: PackedStringArray = validator.validate(invalid, _registry)
	_assert_error_contains(errors, "card.missing", "load reference validation names a missing public card")
	_assert_error_contains(errors, "talent.missing", "load reference validation names a missing talent")
	_assert_error_contains(errors, "territory.missing", "load reference validation names a missing territory")
	_assert_error_contains(errors, "expedition.missing", "load reference validation names a missing expedition")
	_assert_error_contains(errors, "outside campaign roster", "load reference validation rejects a pending general outside the roster")
	_assert_error_contains(errors, "card.expedition.missing", "load reference validation checks the active expedition deck")
	_assert_error_contains(errors, "enemy.missing", "load reference validation checks the pending combat enemy")
	_assert_error_contains(errors, "node.missing", "load reference validation checks active expedition node ids")
	_cleanup_save_files(TEST_SAVE_PATH)
	var store = SaveFileStoreScript.new()
	_assert_true(store.save(TEST_SAVE_PATH, envelope).ok, "reference-valid envelope becomes the backup candidate")
	_assert_true(store.save(TEST_SAVE_PATH, invalid).ok, "structurally valid save can still contain stale content ids")
	var structurally_loaded: Dictionary = store.load(TEST_SAVE_PATH)
	_assert_true(structurally_loaded.ok and structurally_loaded.source == "primary", "structural load remains available without a content registry")
	var reference_recovered: Dictionary = store.load(TEST_SAVE_PATH, _registry)
	_assert_true(reference_recovered.ok and reference_recovered.source == "backup", "content-aware load rejects stale primary ids and recovers the valid backup")
	_cleanup_save_files(TEST_SAVE_PATH)


func _test_atomic_long_term_finalization() -> void:
	var controller = _configured_controller("campaign.finalize")
	var request := _settlement("settlement:finalize", "success")
	_assert_true(controller.apply_expedition_settlement(request).ok, "complete settlement enters Campaign once")
	var finalized: Dictionary = controller.finalize_pending_settlement(request.request_id)
	_assert_true(finalized.ok and not finalized.duplicate, "one finalization consumes faction and general effects atomically")
	var state: Dictionary = controller.snapshot()
	_assert_equal(state.army_inventory, {"infantry": 95, "archer": 97, "cavalry": 98}, "initial settlement keeps exact classified army losses")
	_assert_equal(state.cycle, 1, "finalization advances the configured faction cycle")
	_assert_equal(state.territories[0].territory_id, "territory.heyuan_county", "finalization captures the configured territory")
	_assert_equal(state.generals[0].level, 2, "finalization applies general growth once")
	_assert_true(state.pending_long_term_effects[0].long_term_effects_finalized, "all three consumers mark the shared effect finalized")
	_assert_equal(state.applied_finalization_ids, [request.request_id], "finalization records its stable id")
	_assert_true(not controller.recover_legacy_army_losses(request.request_id).ok, "classified V2 losses cannot be mislabeled as legacy recovery")
	var committed := state.duplicate(true)
	var duplicate: Dictionary = controller.finalize_pending_settlement(request.request_id)
	_assert_true(duplicate.ok and duplicate.duplicate, "repeated finalization is idempotent")
	_assert_equal(controller.snapshot(), committed, "duplicate finalization cannot grant income, cycle or experience twice")


func _test_partial_consumer_resume_and_rollback() -> void:
	var controller = _configured_controller("campaign.partial-resume")
	var request := _settlement("settlement:partial-resume", "success")
	controller.apply_expedition_settlement(request)
	_assert_true(controller.apply_pending_general_effect(request.request_id).ok, "a pre-M5-07 partial general consumer state can exist")
	var experience_after_partial := int(controller.snapshot().generals[0].experience)
	_assert_true(controller.finalize_pending_settlement(request.request_id).ok, "finalizer resumes from an already-consumed general effect")
	_assert_equal(int(controller.snapshot().generals[0].experience), experience_after_partial, "resume cannot grant general experience twice")
	_assert_equal(controller.snapshot().cycle, 1, "resume consumes only the missing faction effect")
	var rollback = _configured_controller("campaign.finalize-rollback")
	var invalid_state: Dictionary = rollback.snapshot()
	invalid_state.territories.append({
		"territory_id": "territory.unknown", "name": "未知领地", "status": "controlled",
		"income_enabled": true, "acquired_cycle": 0, "source_request_id": "legacy",
	})
	rollback.setup(invalid_state)
	var bad_request := _settlement("settlement:unknown-territory", "success")
	rollback.apply_expedition_settlement(bad_request)
	var before: Dictionary = rollback.snapshot()
	var failed: Dictionary = rollback.finalize_pending_settlement(bad_request.request_id)
	_assert_true(not failed.ok, "unknown territory causes finalization failure after general staging")
	_assert_equal(rollback.snapshot(), before, "failed finalization rolls back general growth, territory, cycle and all consumer ledgers")


func _test_explicit_legacy_army_recovery() -> void:
	var controller = _configured_controller("campaign.legacy-recovery")
	var request := _settlement("settlement:legacy-recovery", "retreated")
	request.erase("initial_troops")
	request.erase("army_composition")
	controller.apply_expedition_settlement(request)
	var before: Dictionary = controller.snapshot()
	var blocked: Dictionary = controller.finalize_pending_settlement(request.request_id)
	_assert_true(not blocked.ok and blocked.requires_legacy_army_recovery, "legacy unclassified losses block silent finalization")
	_assert_equal(controller.snapshot(), before, "blocked legacy settlement does not guess or mutate army inventory")
	var recovered: Dictionary = controller.recover_legacy_army_losses(request.request_id)
	_assert_true(recovered.ok and recovered.resolution.type == "legacy_snapshot_unavailable", "explicit legacy recovery records why no classified loss can be applied")
	_assert_equal(controller.snapshot().army_inventory, before.army_inventory, "legacy recovery never fabricates an army composition")
	_assert_true(controller.finalize_pending_settlement(request.request_id).ok, "explicitly recovered old settlement can finish normally")
	_assert_true(controller.snapshot().pending_long_term_effects[0].long_term_effects_finalized, "recovered legacy effect reaches a stable finalized state")
	_assert_true(controller.recover_legacy_army_losses(request.request_id).duplicate, "legacy recovery itself is idempotent")


func _test_game_over_interruption_resume() -> void:
	var player_definition := _zhao.duplicate(true)
	player_definition.id = "general.player.placeholder"
	player_definition.name = "自创角色（占位）"
	var state := CampaignStateScript.create("campaign.game-over-resume")
	state.army_inventory = {"infantry": 100, "archer": 100, "cavalry": 100}
	state.generals.append(GeneralManagementServiceScript.create_instance(player_definition, true))
	var controller = CampaignControllerScript.new()
	controller.setup(state)
	controller.configure_generals(_progression, [player_definition])
	controller.configure_faction(_faction, [_territory])
	var request := _settlement("settlement:game-over-resume", "failed", player_definition.id)
	request.remaining_troops = 0
	request.general_died = true
	controller.apply_expedition_settlement(request)
	_assert_true(controller.apply_pending_general_effect(request.request_id).game_over, "player death can be interrupted after Game Over consumer commits")
	_assert_true(controller.finalize_pending_settlement(request.request_id).ok, "finalizer resumes the same Game Over settlement without reopening campaign")
	var finished := controller.snapshot()
	_assert_equal(finished.campaign_status, "game_over", "resumed transaction preserves permanent Game Over")
	_assert_true(finished.pending_long_term_effects[0].faction_effect_applied, "same-settlement Game Over marks faction time explicitly skipped")
	_assert_equal(finished.faction.history[0].reason, "campaign_game_over_from_same_settlement", "Game Over resume keeps an auditable skip reason")
	_assert_true(finished.pending_long_term_effects[0].long_term_effects_finalized, "Game Over interruption reaches finalization")


func _configured_controller(campaign_id: String):
	var state := CampaignStateScript.create(campaign_id)
	state.army_inventory = {"infantry": 100, "archer": 100, "cavalry": 100}
	state.generals.append(GeneralManagementServiceScript.create_instance(_zhao, false))
	var controller = CampaignControllerScript.new()
	_assert_true(controller.setup(state).is_empty(), "%s controller setup succeeds" % campaign_id)
	_assert_true(controller.configure_generals(_progression, [_zhao]).is_empty(), "%s general catalog configures" % campaign_id)
	_assert_true(controller.configure_faction(_faction, [_territory]).is_empty(), "%s faction catalog configures" % campaign_id)
	return controller


func _settlement(request_id: String, outcome: String, general_id: String = "general.zhao_lie") -> Dictionary:
	return {
		"request_id": request_id,
		"run_id": "run.%s" % request_id,
		"expedition_id": "expedition.capture_heyuan_county",
		"outcome": outcome,
		"general_id": general_id,
		"initial_troops": 100,
		"remaining_troops": 90,
		"remaining_morale": 40,
		"army_composition": {"infantry": 0.5, "archer": 0.3, "cavalry": 0.2},
		"general_died": false,
		"general_injured": false,
		"loot_to_bank": {} if outcome != "success" else {"resource.silver": 1},
		"lost_unbanked_loot": {} if outcome == "success" else {"resource.silver": 1},
	}


func _legacy_effect(request_id: String) -> Dictionary:
	return {
		"request_id": request_id,
		"general_id": "general.zhao_lie",
		"remaining_troops": 90,
		"remaining_morale": 40,
		"general_died": false,
		"general_injured": false,
		"expedition_id": "expedition.capture_heyuan_county",
		"outcome": "retreated",
	}


func _load_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}


func _write_text(path: String, value: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_assert_true(false, "test fixture can write '%s'" % path)
		return
	file.store_string(value)
	file.close()


func _cleanup_save_files(path: String) -> void:
	for candidate in [path, path + ".bak", path + ".tmp", path + ".bak.bak", path + ".bak.tmp"]:
		if FileAccess.file_exists(candidate):
			DirAccess.remove_absolute(candidate)


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
