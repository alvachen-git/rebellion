extends RefCounted
class_name CampaignState

const ArmyManagementServiceScript := preload("res://src/domain/campaign/army_management_service.gd")
const ResearchManagementServiceScript := preload("res://src/domain/campaign/research_management_service.gd")
const GeneralManagementServiceScript := preload("res://src/domain/campaign/general_management_service.gd")
const FactionCycleServiceScript := preload("res://src/domain/campaign/faction_cycle_service.gd")
const LoadoutServiceScript := preload("res://src/domain/campaign/loadout_service.gd")
const MAIN_RESOURCE_IDS := ["silver", "food", "recruits", "military_knowledge"]


static func create(campaign_id: String) -> Dictionary:
	return {
		"campaign_id": campaign_id,
		"cycle": 0,
		"main_city_stage": "ruined_camp",
		"resources": {
			"silver": 0,
			"food": 0,
			"recruits": 0,
			"military_knowledge": 0,
		},
		"special_resources": {},
		"army_inventory": {"infantry": 0, "archer": 0, "cavalry": 0},
		"generals": [],
		"general_system": GeneralManagementServiceScript.create_system_state(),
		"campaign_status": "active",
		"game_over_record": null,
		"unlocked_public_cards": [],
		"card_upgrade_branches": {},
		"base_loadout": [],
		"loadout_system": LoadoutServiceScript.create_system_state(),
		"territories": [],
		"faction": FactionCycleServiceScript.create_faction_state(),
		"rebellion_state": {
			"value": 0,
			"suppression_threshold": 60,
			"suppression_forecast": false,
			"applied_effect_ids": [],
			"history": [],
		},
		"popular_support_state": {
			"value": 20,
			"applied_effect_ids": [],
			"history": [],
		},
		"research": {"applied_action_ids": [], "history": []},
		"applied_settlement_ids": [],
		"settlement_history": [],
		"pending_long_term_effects": [],
		"applied_finalization_ids": [],
		"finalization_history": [],
		"applied_army_action_ids": [],
		"army_history": [],
	}


static func normalize(source: Dictionary) -> Dictionary:
	var result := source.duplicate(true)
	var defaults := create(String(source.get("campaign_id", "")))
	for field in defaults:
		if not result.has(field):
			result[field] = defaults[field].duplicate(true) if defaults[field] is Array or defaults[field] is Dictionary else defaults[field]
	if result.get("resources", null) is Dictionary:
		for resource_id in MAIN_RESOURCE_IDS:
			if not result.resources.has(resource_id):
				result.resources[resource_id] = 0
	if result.get("army_inventory", null) is Dictionary:
		result.army_inventory = ArmyManagementServiceScript.normalize_inventory(result.army_inventory)
	if result.get("research", null) is Dictionary:
		result.research = ResearchManagementServiceScript.normalize_research_state(result.research)
	if result.get("general_system", null) is Dictionary:
		result.general_system = GeneralManagementServiceScript.normalize_system_state(result.general_system)
	if result.get("faction", null) is Dictionary:
		result.faction = FactionCycleServiceScript.normalize_faction_state(result.faction)
	if result.get("rebellion_state", null) is Dictionary:
		var rebellion_defaults: Dictionary = defaults.rebellion_state
		for field in rebellion_defaults:
			if not result.rebellion_state.has(field):
				result.rebellion_state[field] = rebellion_defaults[field].duplicate(true) if rebellion_defaults[field] is Array else rebellion_defaults[field]
		result.rebellion_state.value = clampi(int(result.rebellion_state.value), 0, 100)
		result.rebellion_state.suppression_forecast = int(result.rebellion_state.value) >= int(result.rebellion_state.suppression_threshold)
	if result.get("popular_support_state", null) is Dictionary:
		var support_defaults: Dictionary = defaults.popular_support_state
		for field in support_defaults:
			if not result.popular_support_state.has(field):
				result.popular_support_state[field] = support_defaults[field].duplicate(true) if support_defaults[field] is Array else support_defaults[field]
		result.popular_support_state.value = clampi(int(result.popular_support_state.value), 0, 100)
	if result.get("loadout_system", null) is Dictionary:
		result.loadout_system = LoadoutServiceScript.normalize_system_state(result.loadout_system)
	if result.get("pending_long_term_effects", null) is Array:
		for effect in result.pending_long_term_effects:
			if effect is Dictionary and not effect.has("army_losses"):
				effect.army_losses = {"infantry": 0, "archer": 0, "cavalry": 0}
			if effect is Dictionary and not effect.has("army_losses_applied"):
				effect.army_losses_applied = false
			if effect is Dictionary and not effect.has("general_effect_applied"):
				effect.general_effect_applied = false
			if effect is Dictionary and not effect.has("faction_effect_applied"):
				effect.faction_effect_applied = false
			if effect is Dictionary and not effect.has("army_loss_recovery"):
				effect.army_loss_recovery = null
			if effect is Dictionary and not effect.has("long_term_effects_finalized"):
				effect.long_term_effects_finalized = false
	return result


static func validate(state: Dictionary, source: String = "campaign") -> PackedStringArray:
	var errors := PackedStringArray()
	for field in create("").keys():
		if not state.has(field):
			errors.append("%s: missing field '%s'" % [source, field])
	if String(state.get("campaign_id", "")).strip_edges().is_empty():
		errors.append("%s: campaign_id must be non-empty" % source)
	if not _is_non_negative_whole_number(state.get("cycle", null)):
		errors.append("%s: cycle must be non-negative" % source)
	var resources = state.get("resources", null)
	if not resources is Dictionary:
		errors.append("%s: resources must be an object" % source)
	else:
		for resource_id in MAIN_RESOURCE_IDS:
			if not resources.has(resource_id):
				errors.append("%s: resources missing '%s'" % [source, resource_id])
			elif not _is_non_negative_whole_number(resources[resource_id]):
				errors.append("%s: resource '%s' cannot be negative" % [source, resource_id])
	for field in ["special_resources", "army_inventory", "card_upgrade_branches", "loadout_system", "research", "general_system", "faction", "rebellion_state", "popular_support_state"]:
		if not state.get(field, null) is Dictionary:
			errors.append("%s: %s must be an object" % [source, field])
	var special_resources = state.get("special_resources", null)
	if special_resources is Dictionary:
		for resource_id in special_resources:
			if not resource_id is String or resource_id.strip_edges().is_empty():
				errors.append("%s: special resource id must be a non-empty string" % source)
			elif not _is_non_negative_whole_number(special_resources[resource_id]):
				errors.append("%s: special resource '%s' cannot be negative" % [source, resource_id])
	errors.append_array(ArmyManagementServiceScript.validate_inventory(state.get("army_inventory", null), "%s.army_inventory" % source))
	errors.append_array(ResearchManagementServiceScript.validate_research_state(state.get("research", null), "%s.research" % source))
	errors.append_array(ResearchManagementServiceScript.validate_card_progress(state.get("unlocked_public_cards", null), state.get("card_upgrade_branches", null), source))
	errors.append_array(LoadoutServiceScript.validate_base_loadout_shape(state.get("base_loadout", null), "%s.base_loadout" % source))
	errors.append_array(LoadoutServiceScript.validate_system_state(state.get("loadout_system", null), "%s.loadout_system" % source))
	errors.append_array(GeneralManagementServiceScript.validate_system_state(state.get("general_system", null), "%s.general_system" % source))
	errors.append_array(GeneralManagementServiceScript.validate_roster(state.get("generals", null), "%s.generals" % source))
	errors.append_array(FactionCycleServiceScript.validate_faction_state(state.get("faction", null), "%s.faction" % source))
	_validate_rebellion_state(state.get("rebellion_state", null), source, errors)
	_validate_popular_support_state(state.get("popular_support_state", null), source, errors)
	errors.append_array(FactionCycleServiceScript.validate_territory_instances(state.get("territories", null), "%s.territories" % source))
	if String(state.get("main_city_stage", "")).strip_edges().is_empty():
		errors.append("%s: main_city_stage must be non-empty" % source)
	if not state.get("campaign_status", "") in ["active", "game_over"]:
		errors.append("%s: campaign_status must be active or game_over" % source)
	if state.get("campaign_status", "") == "game_over" and not state.get("game_over_record", null) is Dictionary:
		errors.append("%s: game_over campaign requires game_over_record" % source)
	elif state.get("campaign_status", "") == "active" and state.get("game_over_record", null) != null:
		errors.append("%s: active campaign cannot have game_over_record" % source)
	for field in ["generals", "unlocked_public_cards", "base_loadout", "territories", "applied_settlement_ids", "settlement_history", "pending_long_term_effects", "applied_finalization_ids", "finalization_history", "applied_army_action_ids", "army_history"]:
		if not state.get(field, null) is Array:
			errors.append("%s: %s must be an array" % [source, field])
	_validate_pending_effects(state.get("pending_long_term_effects", null), source, errors)
	_validate_unique_string_ids(state.get("applied_finalization_ids", null), "%s.applied_finalization_ids" % source, errors)
	_validate_finalization_consistency(state, source, errors)
	return errors


static func _validate_rebellion_state(value: Variant, source: String, errors: PackedStringArray) -> void:
	if not value is Dictionary:
		return
	for field in ["value", "suppression_threshold", "suppression_forecast", "applied_effect_ids", "history"]:
		if not value.has(field):
			errors.append("%s.rebellion_state missing field '%s'" % [source, field])
	if not _is_non_negative_whole_number(value.get("value", null)) or int(value.get("value", -1)) > 100:
		errors.append("%s.rebellion_state.value must be between 0 and 100" % source)
	if not _is_non_negative_whole_number(value.get("suppression_threshold", null)) or int(value.get("suppression_threshold", 0)) != 60:
		errors.append("%s.rebellion_state.suppression_threshold must remain 60 for this prototype" % source)
	if not value.get("suppression_forecast", null) is bool:
		errors.append("%s.rebellion_state.suppression_forecast must be boolean" % source)
	elif bool(value.suppression_forecast) != (int(value.get("value", 0)) >= int(value.get("suppression_threshold", 60))):
		errors.append("%s.rebellion_state.suppression_forecast does not match value" % source)
	for field in ["applied_effect_ids", "history"]:
		if not value.get(field, null) is Array:
			errors.append("%s.rebellion_state.%s must be an array" % [source, field])
	var seen := {}
	for action_id in value.get("applied_effect_ids", []):
		if not action_id is String or action_id.strip_edges().is_empty() or seen.has(action_id):
			errors.append("%s.rebellion_state.applied_effect_ids requires unique non-empty strings" % source)
		else:
			seen[action_id] = true


static func _validate_popular_support_state(value: Variant, source: String, errors: PackedStringArray) -> void:
	if not value is Dictionary:
		return
	for field in ["value", "applied_effect_ids", "history"]:
		if not value.has(field):
			errors.append("%s.popular_support_state missing field '%s'" % [source, field])
	if not _is_non_negative_whole_number(value.get("value", null)) or int(value.get("value", -1)) > 100:
		errors.append("%s.popular_support_state.value must be between 0 and 100" % source)
	for field in ["applied_effect_ids", "history"]:
		if not value.get(field, null) is Array:
			errors.append("%s.popular_support_state.%s must be an array" % [source, field])
	var seen := {}
	for action_id in value.get("applied_effect_ids", []):
		if not action_id is String or action_id.strip_edges().is_empty() or seen.has(action_id):
			errors.append("%s.popular_support_state.applied_effect_ids requires unique non-empty strings" % source)
		else:
			seen[action_id] = true


static func _validate_pending_effects(value: Variant, source: String, errors: PackedStringArray) -> void:
	if not value is Array:
		return
	var request_ids := {}
	for index in value.size():
		var effect = value[index]
		var effect_source := "%s.pending_long_term_effects[%d]" % [source, index]
		if not effect is Dictionary:
			errors.append("%s must be an object" % effect_source)
			continue
		var request_id = effect.get("request_id", null)
		if not request_id is String or request_id.strip_edges().is_empty():
			errors.append("%s.request_id must be a non-empty string" % effect_source)
		elif request_ids.has(request_id):
			errors.append("%s has duplicate request_id '%s'" % [source, request_id])
		else:
			request_ids[request_id] = true
		for string_field in ["general_id", "expedition_id"]:
			if not effect.get(string_field, null) is String or effect[string_field].strip_edges().is_empty():
				errors.append("%s.%s must be a non-empty string" % [effect_source, string_field])
		if not effect.get("outcome", null) in ["success", "retreated", "failed"]:
			errors.append("%s.outcome is unsupported" % effect_source)
		for numeric_field in ["remaining_troops", "remaining_morale"]:
			if not _is_non_negative_whole_number(effect.get(numeric_field, null)):
				errors.append("%s.%s must be non-negative" % [effect_source, numeric_field])
		for flag in ["general_died", "general_injured"]:
			if not effect.get(flag, null) is bool:
				errors.append("%s.%s must be boolean" % [effect_source, flag])
		if bool(effect.get("general_died", false)) and bool(effect.get("general_injured", false)):
			errors.append("%s cannot mark death and injury together" % effect_source)
		for flag in ["army_losses_applied", "general_effect_applied", "faction_effect_applied", "long_term_effects_finalized"]:
			if not effect.get(flag, null) is bool:
				errors.append("%s.%s must be boolean" % [effect_source, flag])
		errors.append_array(ArmyManagementServiceScript.validate_inventory(effect.get("army_losses", null), "%s.army_losses" % effect_source))
		var recovery = effect.get("army_loss_recovery", null)
		if recovery != null and not recovery is Dictionary:
			errors.append("%s.army_loss_recovery must be null or an object" % effect_source)
		elif recovery is Dictionary:
			if recovery.get("type", "") != "legacy_snapshot_unavailable":
				errors.append("%s.army_loss_recovery has unsupported type" % effect_source)
			if String(recovery.get("reason", "")).strip_edges().is_empty():
				errors.append("%s.army_loss_recovery requires a reason" % effect_source)
			errors.append_array(ArmyManagementServiceScript.validate_inventory(recovery.get("inventory_change", null), "%s.army_loss_recovery.inventory_change" % effect_source))
			for army_type in ArmyManagementServiceScript.ARMY_TYPE_IDS:
				if recovery.get("inventory_change", null) is Dictionary and int(recovery.inventory_change.get(army_type, -1)) != 0:
					errors.append("%s.army_loss_recovery cannot change inventory" % effect_source)
			if not bool(effect.get("army_losses_applied", false)):
				errors.append("%s.army_loss_recovery requires applied army losses" % effect_source)
		if bool(effect.get("long_term_effects_finalized", false)) and not (
			bool(effect.get("army_losses_applied", false))
			and bool(effect.get("general_effect_applied", false))
			and bool(effect.get("faction_effect_applied", false))
		):
			errors.append("%s cannot be finalized before all consumers are applied" % effect_source)


static func _validate_unique_string_ids(value: Variant, source: String, errors: PackedStringArray) -> void:
	if not value is Array:
		return
	var seen := {}
	for id in value:
		if not id is String or id.strip_edges().is_empty():
			errors.append("%s must contain non-empty strings" % source)
		elif seen.has(id):
			errors.append("%s contains duplicate id '%s'" % [source, id])
		else:
			seen[id] = true


static func _validate_finalization_consistency(state: Dictionary, source: String, errors: PackedStringArray) -> void:
	var effects = state.get("pending_long_term_effects", null)
	var applied_ids = state.get("applied_finalization_ids", null)
	if not effects is Array or not applied_ids is Array:
		return
	var effect_by_request := {}
	for effect in effects:
		if effect is Dictionary and effect.get("request_id", null) is String:
			effect_by_request[effect.request_id] = effect
	for request_id in applied_ids:
		if not request_id is String:
			continue
		if not effect_by_request.has(request_id):
			errors.append("%s.applied_finalization_ids references unknown request '%s'" % [source, request_id])
		elif not bool(effect_by_request[request_id].get("long_term_effects_finalized", false)):
			errors.append("%s.applied_finalization_ids references unfinished request '%s'" % [source, request_id])
	for request_id in effect_by_request:
		if bool(effect_by_request[request_id].get("long_term_effects_finalized", false)) and not applied_ids.has(request_id):
			errors.append("%s finalized request '%s' is missing from applied_finalization_ids" % [source, request_id])
	var history = state.get("finalization_history", null)
	if not history is Array:
		return
	var history_ids := {}
	for index in history.size():
		var record = history[index]
		if not record is Dictionary or not record.get("request_id", null) is String or record.request_id.strip_edges().is_empty():
			errors.append("%s.finalization_history[%d] requires a request_id" % [source, index])
			continue
		if history_ids.has(record.request_id):
			errors.append("%s.finalization_history contains duplicate request '%s'" % [source, record.request_id])
		else:
			history_ids[record.request_id] = true
		if not applied_ids.has(record.request_id):
			errors.append("%s.finalization_history references unapplied request '%s'" % [source, record.request_id])
	for request_id in applied_ids:
		if request_id is String and not history_ids.has(request_id):
			errors.append("%s applied finalization '%s' is missing history" % [source, request_id])


static func _is_non_negative_whole_number(value: Variant) -> bool:
	if value is int:
		return value >= 0
	if value is float:
		return is_finite(value) and value >= 0.0 and value == floor(value)
	return false
