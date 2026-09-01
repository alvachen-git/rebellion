extends RefCounted
class_name CampaignController

const CampaignStateScript := preload("res://src/domain/campaign/campaign_state.gd")

const RESOURCE_KEY_BY_LOOT_ID := {
	"resource.silver": "silver",
	"resource.food": "food",
	"resource.recruits": "recruits",
	"resource.military_knowledge": "military_knowledge",
}

var _state: Dictionary = {}


func setup(campaign_source: Dictionary) -> PackedStringArray:
	_state = {}
	var normalized := CampaignStateScript.normalize(campaign_source)
	var errors: PackedStringArray = CampaignStateScript.validate(normalized)
	if errors.is_empty():
		_state = normalized
	return errors


func apply_expedition_settlement(request: Dictionary) -> Dictionary:
	if _state.is_empty():
		return {"ok": false, "duplicate": false, "errors": PackedStringArray(["campaign: controller is not initialized"]), "resource_changes": {}}
	var errors := _validate_settlement(request)
	if not errors.is_empty():
		return {"ok": false, "duplicate": false, "errors": errors, "resource_changes": {}}
	var request_id: String = request.request_id
	if _state.applied_settlement_ids.has(request_id):
		return {"ok": true, "duplicate": true, "errors": PackedStringArray(), "resource_changes": {}}
	var next_state := _state.duplicate(true)
	var resource_changes := {}
	if request.outcome == "success":
		for loot_id in request.loot_to_bank:
			var amount := int(request.loot_to_bank[loot_id])
			if RESOURCE_KEY_BY_LOOT_ID.has(loot_id):
				var resource_key: String = RESOURCE_KEY_BY_LOOT_ID[loot_id]
				next_state.resources[resource_key] = int(next_state.resources[resource_key]) + amount
				resource_changes[resource_key] = int(resource_changes.get(resource_key, 0)) + amount
			else:
				next_state.special_resources[loot_id] = int(next_state.special_resources.get(loot_id, 0)) + amount
				resource_changes[loot_id] = int(resource_changes.get(loot_id, 0)) + amount
	next_state.applied_settlement_ids.append(request_id)
	next_state.settlement_history.append({
		"request_id": request_id,
		"run_id": request.run_id,
		"expedition_id": request.expedition_id,
		"outcome": request.outcome,
		"resource_changes": resource_changes.duplicate(true),
	})
	next_state.pending_long_term_effects.append({
		"request_id": request_id,
		"general_id": request.general_id,
		"remaining_troops": int(request.remaining_troops),
		"remaining_morale": int(request.remaining_morale),
		"general_died": bool(request.general_died),
		"general_injured": bool(request.general_injured),
		"expedition_id": request.expedition_id,
		"outcome": request.outcome,
	})
	_state = next_state
	return {"ok": true, "duplicate": false, "errors": PackedStringArray(), "resource_changes": resource_changes}


func snapshot() -> Dictionary:
	return _state.duplicate(true)


func _validate_settlement(request: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	for field in ["request_id", "run_id", "expedition_id", "outcome", "general_id", "remaining_troops", "remaining_morale", "general_died", "general_injured", "loot_to_bank", "lost_unbanked_loot"]:
		if not request.has(field):
			errors.append("settlement: missing field '%s'" % field)
	if not errors.is_empty():
		return errors
	for field in ["request_id", "run_id", "expedition_id", "general_id"]:
		if String(request[field]).strip_edges().is_empty():
			errors.append("settlement: %s must be non-empty" % field)
	if not request.outcome in ["success", "retreated", "failed"]:
		errors.append("settlement: unsupported outcome '%s'" % request.outcome)
	if not _is_non_negative_whole_number(request.remaining_troops) or not _is_non_negative_whole_number(request.remaining_morale):
		errors.append("settlement: remaining combat state cannot be negative")
	if not request.general_died is bool or not request.general_injured is bool:
		errors.append("settlement: general flags must be boolean")
	if not request.loot_to_bank is Dictionary or not request.lost_unbanked_loot is Dictionary:
		errors.append("settlement: loot fields must be objects")
		return errors
	if request.outcome != "success" and not request.loot_to_bank.is_empty():
		errors.append("settlement: only success may bank loot")
	if request.outcome == "success" and not request.lost_unbanked_loot.is_empty():
		errors.append("settlement: success cannot report lost loot")
	for loot_id in request.loot_to_bank:
		if String(loot_id).strip_edges().is_empty() or not _is_positive_whole_number(request.loot_to_bank[loot_id]):
			errors.append("settlement: banked loot entries require non-empty ids and positive amounts")
	for loot_id in request.lost_unbanked_loot:
		if String(loot_id).strip_edges().is_empty() or not _is_positive_whole_number(request.lost_unbanked_loot[loot_id]):
			errors.append("settlement: lost loot entries require non-empty ids and positive amounts")
	return errors


func _is_non_negative_whole_number(value: Variant) -> bool:
	if value is int:
		return value >= 0
	if value is float:
		return is_finite(value) and value >= 0.0 and value == floor(value)
	return false


func _is_positive_whole_number(value: Variant) -> bool:
	return _is_non_negative_whole_number(value) and float(value) > 0.0
