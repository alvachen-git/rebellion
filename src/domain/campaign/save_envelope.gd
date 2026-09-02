extends RefCounted
class_name SaveEnvelope

const CampaignStateScript := preload("res://src/domain/campaign/campaign_state.gd")

const CURRENT_SAVE_VERSION := 4
const CURRENT_CONTENT_VERSION := "0.6.1-m6-deck-editor"


static func create_empty(campaign_id: String, timestamp: String) -> Dictionary:
	return {
		"save_version": CURRENT_SAVE_VERSION,
		"content_version": CURRENT_CONTENT_VERSION,
		"created_at": timestamp,
		"updated_at": timestamp,
		"campaign": CampaignStateScript.create(campaign_id),
		"expedition": null,
	}


static func validate(data: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	for field in ["save_version", "content_version", "created_at", "updated_at", "campaign", "expedition"]:
		if not data.has(field):
			errors.append("save: missing field '%s'" % field)
	if data.has("save_version") and data.save_version != CURRENT_SAVE_VERSION:
		errors.append("save: unsupported save_version '%s'" % str(data.save_version))
	if data.has("content_version") and (not data.content_version is String or data.content_version.strip_edges().is_empty()):
		errors.append("save: content_version must be a non-empty string")
	for field in ["created_at", "updated_at"]:
		if data.has(field) and (not data[field] is String or data[field].strip_edges().is_empty()):
			errors.append("save: %s must be a non-empty string" % field)
	if data.has("campaign"):
		if not data.campaign is Dictionary:
			errors.append("save: campaign must be an object")
		else:
			errors.append_array(CampaignStateScript.validate(data.campaign, "save.campaign"))
	if data.has("expedition") and data.expedition != null and not data.expedition is Dictionary:
		errors.append("save: expedition must be null or an object")
	return errors
