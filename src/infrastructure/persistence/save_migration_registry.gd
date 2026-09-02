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


func _failure(message: String) -> Dictionary:
	return {"ok": false, "errors": PackedStringArray([message])}


func _is_whole_number(value: Variant) -> bool:
	if value is int:
		return true
	return value is float and is_finite(value) and value == floor(value)
