extends RefCounted
class_name SaveEnvelope

const CURRENT_SAVE_VERSION := 1
const CURRENT_CONTENT_VERSION := "0.1.0-m0"


static func create_empty(campaign_id: String, timestamp: String) -> Dictionary:
	return {
		"save_version": CURRENT_SAVE_VERSION,
		"content_version": CURRENT_CONTENT_VERSION,
		"created_at": timestamp,
		"updated_at": timestamp,
		"campaign": {
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
			"general_system": {
				"applied_initialization_ids": [],
				"applied_effect_ids": [],
				"applied_recovery_ids": [],
				"history": [],
			},
			"campaign_status": "active",
			"game_over_record": null,
			"unlocked_public_cards": [],
			"card_upgrade_branches": {},
			"territories": [],
			"faction": {"applied_effect_ids": [], "history": []},
			"research": {"applied_action_ids": [], "history": []},
			"applied_settlement_ids": [],
			"settlement_history": [],
			"pending_long_term_effects": [],
			"applied_army_action_ids": [],
			"army_history": [],
		},
		"expedition": null,
	}


static func validate(data: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	for field in ["save_version", "content_version", "created_at", "updated_at", "campaign", "expedition"]:
		if not data.has(field):
			errors.append("save: missing field '%s'" % field)
	if data.has("save_version") and data.save_version != CURRENT_SAVE_VERSION:
		errors.append("save: unsupported save_version '%s'" % str(data.save_version))
	if data.has("content_version") and not data.content_version is String:
		errors.append("save: content_version must be a string")
	if data.has("campaign"):
		if not data.campaign is Dictionary:
			errors.append("save: campaign must be an object")
		else:
			_validate_campaign(data.campaign, errors)
	if data.has("expedition") and data.expedition != null and not data.expedition is Dictionary:
		errors.append("save: expedition must be null or an object")
	return errors


static func _validate_campaign(campaign: Dictionary, errors: PackedStringArray) -> void:
	for field in [
		"campaign_id",
		"cycle",
		"main_city_stage",
		"resources",
		"army_inventory",
		"generals",
		"unlocked_public_cards",
		"card_upgrade_branches",
		"territories",
		"research",
	]:
		if not campaign.has(field):
			errors.append("save.campaign: missing field '%s'" % field)
	if campaign.has("resources") and not campaign.resources is Dictionary:
		errors.append("save.campaign.resources must be an object")
