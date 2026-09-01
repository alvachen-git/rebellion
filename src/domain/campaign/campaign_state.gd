extends RefCounted
class_name CampaignState

const ArmyManagementServiceScript := preload("res://src/domain/campaign/army_management_service.gd")
const ResearchManagementServiceScript := preload("res://src/domain/campaign/research_management_service.gd")
const GeneralManagementServiceScript := preload("res://src/domain/campaign/general_management_service.gd")
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
		"territories": [],
		"research": {"applied_action_ids": [], "history": []},
		"applied_settlement_ids": [],
		"settlement_history": [],
		"pending_long_term_effects": [],
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
	if result.get("pending_long_term_effects", null) is Array:
		for effect in result.pending_long_term_effects:
			if effect is Dictionary and not effect.has("general_effect_applied"):
				effect.general_effect_applied = false
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
	for field in ["special_resources", "army_inventory", "card_upgrade_branches", "research", "general_system"]:
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
	errors.append_array(GeneralManagementServiceScript.validate_system_state(state.get("general_system", null), "%s.general_system" % source))
	errors.append_array(GeneralManagementServiceScript.validate_roster(state.get("generals", null), "%s.generals" % source))
	if not state.get("campaign_status", "") in ["active", "game_over"]:
		errors.append("%s: campaign_status must be active or game_over" % source)
	if state.get("campaign_status", "") == "game_over" and not state.get("game_over_record", null) is Dictionary:
		errors.append("%s: game_over campaign requires game_over_record" % source)
	elif state.get("campaign_status", "") == "active" and state.get("game_over_record", null) != null:
		errors.append("%s: active campaign cannot have game_over_record" % source)
	for field in ["generals", "unlocked_public_cards", "territories", "applied_settlement_ids", "settlement_history", "pending_long_term_effects", "applied_army_action_ids", "army_history"]:
		if not state.get(field, null) is Array:
			errors.append("%s: %s must be an array" % [source, field])
	return errors


static func _is_non_negative_whole_number(value: Variant) -> bool:
	if value is int:
		return value >= 0
	if value is float:
		return is_finite(value) and value >= 0.0 and value == floor(value)
	return false
