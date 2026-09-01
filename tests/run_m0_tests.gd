extends SceneTree

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")
const DeterministicRngScript := preload("res://src/domain/random/deterministic_rng.gd")
const SaveEnvelopeScript := preload("res://src/domain/campaign/save_envelope.gd")
const SaveGameCodecScript := preload("res://src/infrastructure/persistence/save_game_codec.gd")
const SaveSlotPolicyScript := preload("res://src/infrastructure/persistence/save_slot_policy.gd")

var _passed := 0
var _failed := 0


func _init() -> void:
	_run_all()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _run_all() -> void:
	_test_project_baseline()
	_test_content_registry_loads_sample()
	_test_content_registry_rejects_invalid_card()
	_test_rng_is_deterministic()
	_test_rng_state_can_be_restored()
	_test_shuffle_is_deterministic_and_non_mutating()
	_test_save_envelope_is_valid()
	_test_save_codec_round_trip()
	_test_save_codec_rejects_unknown_version()
	_test_save_slot_policy()
	_test_main_scene_exists()


func _test_project_baseline() -> void:
	_assert_equal(ProjectSettings.get_setting("display/window/size/viewport_width"), 1600, "design width is 1600")
	_assert_equal(ProjectSettings.get_setting("display/window/size/viewport_height"), 900, "design height is 900")
	_assert_equal(ProjectSettings.get_setting("rendering/renderer/rendering_method"), "gl_compatibility", "desktop-safe renderer is configured")


func _test_content_registry_loads_sample() -> void:
	var registry := ContentRegistryScript.new()
	_assert_true(registry.load_all(), "content manifest loads without validation errors")
	_assert_equal(registry.card_count(), 6, "development card definitions are registered")
	_assert_true(registry.has_card("dev.m0_validation_sample"), "sample card is addressable by stable id")
	_assert_equal(registry.enemy_count(), 1, "one baseline enemy is registered")
	_assert_true(registry.has_enemy("dev.baseline_enemy"), "baseline enemy is addressable by stable id")
	var sample: Dictionary = registry.get_card("dev.m0_validation_sample")
	_assert_equal(sample.conditions[0].type, "ArmyRatioAtLeast", "sample condition type is retained")
	_assert_equal(sample.effects[0].type, "DealDamage", "sample effect type is retained")


func _test_content_registry_rejects_invalid_card() -> void:
	var registry := ContentRegistryScript.new()
	var invalid_card := {
		"id": "",
		"cost": -1,
		"effects": [{"type": "UnknownEffect"}],
		"conditions": [{"type": "UnknownCondition"}],
	}
	var errors := registry.validate_card_definition(invalid_card, "invalid-test-card")
	_assert_true(errors.size() >= 4, "invalid card reports missing and unsupported fields")


func _test_rng_is_deterministic() -> void:
	var first := DeterministicRngScript.new(22301)
	var second := DeterministicRngScript.new(22301)
	var first_values := []
	var second_values := []
	for index in 8:
		first_values.append(first.next_int(0, 100000))
		second_values.append(second.next_int(0, 100000))
	_assert_equal(first_values, second_values, "same seed produces the same sequence")


func _test_rng_state_can_be_restored() -> void:
	var rng := DeterministicRngScript.new(9917)
	rng.next_int(0, 100)
	var checkpoint: int = rng.state()
	var expected := rng.next_int(0, 100000)
	rng.restore_state(checkpoint)
	_assert_equal(rng.next_int(0, 100000), expected, "RNG state restores the next result")


func _test_shuffle_is_deterministic_and_non_mutating() -> void:
	var source := ["a", "b", "c", "d", "e"]
	var first := DeterministicRngScript.new(77).shuffled_copy(source)
	var second := DeterministicRngScript.new(77).shuffled_copy(source)
	_assert_equal(first, second, "shuffle is deterministic")
	_assert_equal(source, ["a", "b", "c", "d", "e"], "shuffle does not mutate source data")


func _test_save_envelope_is_valid() -> void:
	var envelope := SaveEnvelopeScript.create_empty("campaign-test", "2026-09-01T00:00:00Z")
	_assert_true(SaveEnvelopeScript.validate(envelope).is_empty(), "new save envelope satisfies version 1 schema")
	_assert_equal(envelope.campaign.resources.keys().size(), 4, "campaign starts with four main resources")


func _test_save_codec_round_trip() -> void:
	var codec := SaveGameCodecScript.new()
	var envelope := SaveEnvelopeScript.create_empty("round-trip", "2026-09-01T00:00:00Z")
	envelope.campaign.resources.silver = 180
	var encoded := codec.encode(envelope)
	_assert_true(encoded.ok, "valid save encodes")
	if not encoded.ok:
		return
	var decoded := codec.decode(encoded.text)
	_assert_true(decoded.ok, "encoded save decodes")
	if decoded.ok:
		_assert_equal(decoded.value.campaign.resources.silver, 180, "save round-trip preserves resource values")


func _test_save_codec_rejects_unknown_version() -> void:
	var codec := SaveGameCodecScript.new()
	var envelope := SaveEnvelopeScript.create_empty("future", "2026-09-01T00:00:00Z")
	envelope.save_version = 99
	var result := codec.decode(JSON.stringify(envelope))
	_assert_true(not result.ok, "unknown save version is rejected")


func _test_save_slot_policy() -> void:
	_assert_equal(SaveSlotPolicyScript.MANUAL_SLOT_COUNT, 3, "three manual slots are configured")
	_assert_equal(SaveSlotPolicyScript.manual_slot_id(1), "manual_1", "manual slot id is stable")
	_assert_equal(SaveSlotPolicyScript.manual_slot_id(4), "", "out-of-range manual slot is rejected")
	_assert_true(SaveSlotPolicyScript.can_manual_save("main_city"), "manual save is allowed in main city")
	_assert_true(SaveSlotPolicyScript.can_manual_save("expedition_map"), "manual save is allowed between nodes")
	_assert_true(not SaveSlotPolicyScript.can_manual_save("combat"), "manual save is disallowed during combat")
	_assert_equal(
		SaveSlotPolicyScript.recovery_mode_for_context("combat"),
		"restart_current_battle_from_checkpoint",
		"combat recovery restarts from deterministic checkpoint"
	)


func _test_main_scene_exists() -> void:
	var main_scene: String = ProjectSettings.get_setting("application/run/main_scene", "")
	_assert_equal(main_scene, "res://src/ui/bootstrap/bootstrap.tscn", "bootstrap is configured as main scene")
	_assert_true(ResourceLoader.exists(main_scene), "configured main scene exists")


func _assert_true(value: bool, message: String) -> void:
	if value:
		_passed += 1
		print("TEST PASS: %s" % message)
	else:
		_failed += 1
		push_error("TEST FAIL: %s" % message)


func _assert_equal(actual, expected, message: String) -> void:
	if actual == expected:
		_passed += 1
		print("TEST PASS: %s" % message)
	else:
		_failed += 1
		push_error("TEST FAIL: %s (expected=%s, actual=%s)" % [message, str(expected), str(actual)])
