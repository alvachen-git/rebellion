extends RefCounted
class_name CampaignController

const CampaignStateScript := preload("res://src/domain/campaign/campaign_state.gd")
const ArmyManagementServiceScript := preload("res://src/domain/campaign/army_management_service.gd")

const RESOURCE_KEY_BY_LOOT_ID := {
	"resource.silver": "silver",
	"resource.food": "food",
	"resource.recruits": "recruits",
	"resource.military_knowledge": "military_knowledge",
}

var _state: Dictionary = {}
var _army_economy: Dictionary = {}


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
	var army_losses := {"infantry": 0, "archer": 0, "cavalry": 0}
	if request.has("initial_troops") and request.has("army_composition"):
		var casualty_result: Dictionary = ArmyManagementServiceScript.calculate_casualties(request.initial_troops, request.remaining_troops, request.army_composition)
		if not casualty_result.ok:
			return {"ok": false, "duplicate": false, "errors": casualty_result.errors, "resource_changes": {}}
		army_losses = casualty_result.losses
		for army_type in ArmyManagementServiceScript.ARMY_TYPE_IDS:
			if int(next_state.army_inventory[army_type]) < int(army_losses[army_type]):
				return {"ok": false, "duplicate": false, "errors": PackedStringArray(["campaign: insufficient '%s' inventory for expedition casualties" % army_type]), "resource_changes": {}}
		for army_type in ArmyManagementServiceScript.ARMY_TYPE_IDS:
			next_state.army_inventory[army_type] = int(next_state.army_inventory[army_type]) - int(army_losses[army_type])
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
		"army_losses": army_losses.duplicate(true),
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
		"army_losses": army_losses.duplicate(true),
		"army_losses_applied": request.has("initial_troops") and request.has("army_composition"),
	})
	_state = next_state
	return {"ok": true, "duplicate": false, "errors": PackedStringArray(), "resource_changes": resource_changes}


func snapshot() -> Dictionary:
	return _state.duplicate(true)


func configure_army_economy(definition: Dictionary) -> PackedStringArray:
	_army_economy = {}
	var errors := ArmyManagementServiceScript.validate_economy_definition(definition)
	if errors.is_empty():
		_army_economy = definition.duplicate(true)
	return errors


func replenish_troops(request: Dictionary) -> Dictionary:
	if _state.is_empty():
		return _army_action_failure("campaign: controller is not initialized")
	if _army_economy.is_empty():
		return _army_action_failure("campaign: army economy is not configured")
	for field in ["action_id", "army_type", "batches"]:
		if not request.has(field):
			return _army_action_failure("army training: missing field '%s'" % field)
	if not request.action_id is String or request.action_id.strip_edges().is_empty():
		return _army_action_failure("army training: action_id must be a non-empty string")
	if _state.applied_army_action_ids.has(request.action_id):
		return {"ok": true, "duplicate": true, "errors": PackedStringArray(), "troops_added": 0, "main_costs": {}, "special_costs": {}}
	var quote: Dictionary = ArmyManagementServiceScript.quote_replenishment(_army_economy, String(request.army_type), request.batches)
	if not quote.ok:
		return {"ok": false, "duplicate": false, "errors": quote.errors, "troops_added": 0, "main_costs": {}, "special_costs": {}}
	for resource_id in quote.main_costs:
		if int(_state.resources.get(resource_id, 0)) < int(quote.main_costs[resource_id]):
			return _army_action_failure("army training: insufficient main resource '%s'" % resource_id)
	for resource_id in quote.special_costs:
		if int(_state.special_resources.get(resource_id, 0)) < int(quote.special_costs[resource_id]):
			return _army_action_failure("army training: insufficient special resource '%s'" % resource_id)
	var next_state := _state.duplicate(true)
	for resource_id in quote.main_costs:
		next_state.resources[resource_id] = int(next_state.resources[resource_id]) - int(quote.main_costs[resource_id])
	for resource_id in quote.special_costs:
		next_state.special_resources[resource_id] = int(next_state.special_resources[resource_id]) - int(quote.special_costs[resource_id])
	next_state.army_inventory[request.army_type] = int(next_state.army_inventory[request.army_type]) + int(quote.troops_added)
	next_state.applied_army_action_ids.append(request.action_id)
	next_state.army_history.append({
		"action_id": request.action_id,
		"action": "replenish_troops",
		"army_type": request.army_type,
		"batches": int(request.batches),
		"troops_added": int(quote.troops_added),
		"main_costs": quote.main_costs.duplicate(true),
		"special_costs": quote.special_costs.duplicate(true),
	})
	_state = next_state
	return {
		"ok": true,
		"duplicate": false,
		"errors": PackedStringArray(),
		"troops_added": quote.troops_added,
		"main_costs": quote.main_costs,
		"special_costs": quote.special_costs,
	}


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
	var has_initial_troops := request.has("initial_troops")
	var has_composition := request.has("army_composition")
	if has_initial_troops != has_composition:
		errors.append("settlement: initial_troops and army_composition must be provided together")
	elif has_initial_troops:
		var casualty_result: Dictionary = ArmyManagementServiceScript.calculate_casualties(request.initial_troops, request.remaining_troops, request.army_composition)
		errors.append_array(casualty_result.errors)
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


func _army_action_failure(error: String) -> Dictionary:
	return {"ok": false, "duplicate": false, "errors": PackedStringArray([error]), "troops_added": 0, "main_costs": {}, "special_costs": {}}
