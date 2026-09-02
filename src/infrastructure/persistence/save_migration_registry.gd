extends RefCounted
class_name SaveMigrationRegistry

const CampaignStateScript := preload("res://src/domain/campaign/campaign_state.gd")
const SaveEnvelopeScript := preload("res://src/domain/campaign/save_envelope.gd")


func migrate(source: Dictionary) -> Dictionary:
	if not source.has("save_version"):
		return _failure("save migration: missing save_version")
	if not _is_whole_number(source.save_version):
		return _failure("save migration: save_version must be an integer")
	var from_version := int(source.save_version)
	if from_version < 1:
		return _failure("save migration: unsupported save_version '%d'" % from_version)
	if from_version > SaveEnvelopeScript.CURRENT_SAVE_VERSION:
		return _failure("save migration: future save_version '%d' is not supported" % from_version)
	var migrated := source.duplicate(true)
	var current_version := from_version
	while current_version < SaveEnvelopeScript.CURRENT_SAVE_VERSION:
		var step: Dictionary = _apply_step(current_version, migrated)
		if not step.ok:
			return step
		migrated = step.value
		current_version = int(migrated.save_version)
	return {
		"ok": true,
		"errors": PackedStringArray(),
		"value": migrated,
		"migrated": from_version != current_version,
		"from_version": from_version,
		"to_version": current_version,
	}


func _apply_step(version: int, source: Dictionary) -> Dictionary:
	if version == 1:
		return _migrate_v1_to_v2(source)
	if version == 2:
		return _migrate_v2_to_v3(source)
	if version == 3:
		return _migrate_v3_to_v4(source)
	if version == 4:
		return _migrate_v4_to_v5(source)
	if version == 5:
		return _migrate_v5_to_v6(source)
	return _failure("save migration: no migration registered from version %d" % version)


func _migrate_v1_to_v2(source: Dictionary) -> Dictionary:
	for field in ["content_version", "created_at", "updated_at", "campaign", "expedition"]:
		if not source.has(field):
			return _failure("save migration v1->v2: missing field '%s'" % field)
	if not source.campaign is Dictionary:
		return _failure("save migration v1->v2: campaign must be an object")
	var result := source.duplicate(true)
	result.campaign = CampaignStateScript.normalize(result.campaign)
	result.save_version = 2
	return {"ok": true, "errors": PackedStringArray(), "value": result}


func _migrate_v2_to_v3(source: Dictionary) -> Dictionary:
	for field in ["content_version", "created_at", "updated_at", "campaign", "expedition"]:
		if not source.has(field):
			return _failure("save migration v2->v3: missing field '%s'" % field)
	if not source.campaign is Dictionary:
		return _failure("save migration v2->v3: campaign must be an object")
	var result := source.duplicate(true)
	if not result.campaign.has("general_loadouts"):
		result.campaign.general_loadouts = {}
	if not result.campaign.has("loadout_system"):
		result.campaign.loadout_system = {"applied_action_ids": [], "history": []}
	result.campaign = CampaignStateScript.normalize(result.campaign)
	result.save_version = 3
	return {"ok": true, "errors": PackedStringArray(), "value": result}


func _migrate_v3_to_v4(source: Dictionary) -> Dictionary:
	for field in ["content_version", "created_at", "updated_at", "campaign", "expedition"]:
		if not source.has(field):
			return _failure("save migration v3->v4: missing field '%s'" % field)
	if not source.campaign is Dictionary:
		return _failure("save migration v3->v4: campaign must be an object")
	var result := source.duplicate(true)
	var legacy_loadouts := {}
	if result.campaign.get("general_loadouts", null) is Dictionary:
		legacy_loadouts = result.campaign.general_loadouts.duplicate(true)
	result.campaign.erase("general_loadouts")
	result.campaign.base_loadout = []
	if not result.campaign.get("loadout_system", null) is Dictionary:
		result.campaign.loadout_system = {}
	result.campaign.loadout_system.requires_legacy_recovery = true
	result.campaign.loadout_system.legacy_general_loadouts = legacy_loadouts
	result.campaign = CampaignStateScript.normalize(result.campaign)
	result.save_version = 4
	return {"ok": true, "errors": PackedStringArray(), "value": result}


func _migrate_v4_to_v5(source: Dictionary) -> Dictionary:
	for field in ["content_version", "created_at", "updated_at", "campaign", "expedition"]:
		if not source.has(field):
			return _failure("save migration v4->v5: missing field '%s'" % field)
	if not source.campaign is Dictionary:
		return _failure("save migration v4->v5: campaign must be an object")
	var result := source.duplicate(true)
	result.campaign = CampaignStateScript.normalize(result.campaign)
	var inferred_capture := false
	for territory in result.campaign.get("territories", []):
		if territory is Dictionary and territory.get("territory_id", "") == "territory.heyuan_county":
			inferred_capture = true
			break
	if inferred_capture and int(result.campaign.rebellion_state.value) == 0:
		result.campaign.rebellion_state.value = 30
		result.campaign.rebellion_state.suppression_forecast = false
		result.campaign.rebellion_state.applied_effect_ids.append("migration:v4:territory.heyuan_county")
		result.campaign.rebellion_state.history.append({
			"action_id": "migration:v4:territory.heyuan_county",
			"action": "infer_capture_rebellion",
			"delta": 30,
			"value": 30,
		})
	if result.expedition is Dictionary:
		if not result.expedition.has("generator_version"):
			result.expedition.generator_version = 1
		if not result.expedition.has("map_signature"):
			result.expedition.map_signature = "legacy-v1"
	result.save_version = 5
	return {"ok": true, "errors": PackedStringArray(), "value": result}


func _migrate_v5_to_v6(source: Dictionary) -> Dictionary:
	for field in ["content_version", "created_at", "updated_at", "campaign", "expedition"]:
		if not source.has(field):
			return _failure("save migration v5->v6: missing field '%s'" % field)
	if not source.campaign is Dictionary:
		return _failure("save migration v5->v6: campaign must be an object")
	var result := source.duplicate(true)
	result.campaign = CampaignStateScript.normalize(result.campaign)
	if result.expedition is Dictionary:
		result.expedition.initial_popular_support = int(result.campaign.popular_support_state.value)
		result.expedition.pending_popular_support_delta = int(result.expedition.get("pending_popular_support_delta", 0))
	result.save_version = 6
	return {"ok": true, "errors": PackedStringArray(), "value": result}


func _failure(message: String) -> Dictionary:
	return {"ok": false, "errors": PackedStringArray([message])}


func _is_whole_number(value: Variant) -> bool:
	if value is int:
		return true
	return value is float and is_finite(value) and value == floor(value)
