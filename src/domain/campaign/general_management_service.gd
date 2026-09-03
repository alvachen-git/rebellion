extends RefCounted
class_name GeneralManagementService

const ATTRIBUTE_IDS := ["martial", "leadership", "administration"]
const OUTCOME_IDS := ["success", "retreated", "failed"]
const VICTORY_TYPES := ["normal_combat", "military_objective", "wealth_risk", "merchant_combat", "elite_combat", "boss"]
const MILESTONE_TYPES := ["talent_branch_choice", "exclusive_card_unlock"]


static func create_system_state() -> Dictionary:
	return {
		"applied_initialization_ids": [],
		"applied_effect_ids": [],
		"applied_recovery_ids": [],
		"history": [],
	}


static func normalize_system_state(source: Dictionary) -> Dictionary:
	var result := source.duplicate(true)
	var defaults := create_system_state()
	for field in defaults:
		if not result.has(field):
			result[field] = defaults[field].duplicate(true)
	return result


static func validate_system_state(state: Variant, source: String = "general_system") -> PackedStringArray:
	var errors := PackedStringArray()
	if not state is Dictionary:
		errors.append("%s must be an object" % source)
		return errors
	for field in ["applied_initialization_ids", "applied_effect_ids", "applied_recovery_ids", "history"]:
		if not state.get(field, null) is Array:
			errors.append("%s.%s must be an array" % [source, field])
	for field in ["applied_initialization_ids", "applied_effect_ids", "applied_recovery_ids"]:
		if state.get(field, null) is Array:
			errors.append_array(_validate_unique_ids(state[field], "%s.%s" % [source, field]))
	return errors


static func validate_progression_definition(definition: Variant, source: String = "general_progression") -> PackedStringArray:
	var errors := PackedStringArray()
	if not definition is Dictionary:
		errors.append("%s must be an object" % source)
		return errors
	for field in ["id", "balance_status", "max_level", "max_levels_per_expedition", "experience_thresholds", "experience_by_outcome", "victory_experience", "major_injury_recovery_cycles", "attribute_growth", "milestone_types"]:
		if not definition.has(field):
			errors.append("%s missing field '%s'" % [source, field])
	if not errors.is_empty():
		return errors
	if not definition.id is String or definition.id.strip_edges().is_empty():
		errors.append("%s id must be a non-empty string" % source)
	if definition.balance_status != "prototype_temporary":
		errors.append("%s must explicitly remain prototype_temporary" % source)
	if not _is_positive_whole_number(definition.max_level) or int(definition.max_level) != 6:
		errors.append("%s max_level must remain the Vertical Slice boundary of 6" % source)
	if not _is_positive_whole_number(definition.max_levels_per_expedition) or int(definition.max_levels_per_expedition) != 1:
		errors.append("%s max_levels_per_expedition must remain 1" % source)
	if not _is_positive_whole_number(definition.major_injury_recovery_cycles):
		errors.append("%s major_injury_recovery_cycles must be positive" % source)
	_validate_experience_thresholds(definition.experience_thresholds, int(definition.max_level), source, errors)
	if not definition.experience_by_outcome is Dictionary:
		errors.append("%s experience_by_outcome must be an object" % source)
	else:
		for outcome in OUTCOME_IDS:
			if not definition.experience_by_outcome.has(outcome) or not _is_non_negative_whole_number(definition.experience_by_outcome.get(outcome)):
				errors.append("%s experience_by_outcome requires non-negative '%s'" % [source, outcome])
	if not definition.victory_experience is Dictionary:
		errors.append("%s victory_experience must be an object" % source)
	else:
		for victory_type in VICTORY_TYPES:
			if not definition.victory_experience.has(victory_type) or not _is_non_negative_whole_number(definition.victory_experience.get(victory_type)):
				errors.append("%s victory_experience requires non-negative '%s'" % [source, victory_type])
	_validate_attribute_growth(definition.attribute_growth, int(definition.max_level), source, errors)
	_validate_milestones(definition.milestone_types, int(definition.max_level), source, errors)
	return errors


static func validate_general_catalog(definitions: Array, source: String = "general_catalog") -> PackedStringArray:
	var errors := PackedStringArray()
	var seen := {}
	for definition in definitions:
		if not definition is Dictionary:
			errors.append("%s entries must be objects" % source)
			continue
		var general_id: String = String(definition.get("id", ""))
		if general_id.is_empty() or seen.has(general_id):
			errors.append("%s general ids must be non-empty and unique" % source)
		else:
			seen[general_id] = true
		if String(definition.get("name", "")).strip_edges().is_empty():
			errors.append("%s general '%s' requires a name" % [source, general_id])
		for attribute in ATTRIBUTE_IDS:
			if not _is_non_negative_whole_number(definition.get(attribute)):
				errors.append("%s general '%s' requires non-negative integer %s" % [source, general_id, attribute])
		if String(definition.get("talent_id", "")).strip_edges().is_empty():
			errors.append("%s general '%s' requires a core talent" % [source, general_id])
		if not definition.get("starting_deck", null) is Array:
			errors.append("%s general '%s' starting_deck must be an array" % [source, general_id])
	return errors


static func create_instance(definition: Dictionary, is_player_character: bool = false) -> Dictionary:
	var exclusive_cards := []
	for card_id in definition.get("starting_deck", []):
		if card_id is String and card_id.begins_with("card.general.") and not exclusive_cards.has(card_id):
			exclusive_cards.append(card_id)
	return {
		"general_id": String(definition.get("id", "")),
		"name": String(definition.get("name", "")),
		"is_player_character": is_player_character,
		"vertical_slice_deployment_enabled": not is_player_character,
		"level": 1,
		"experience": 0,
		"attributes": {
			"martial": int(definition.get("martial", 0)),
			"leadership": int(definition.get("leadership", 0)),
			"administration": int(definition.get("administration", 0)),
		},
		"core_talent_id": String(definition.get("talent_id", "")),
		"active_talent_id": String(definition.get("talent_id", "")),
		"unlocked_exclusive_cards": exclusive_cards,
		"pending_growth_milestones": [],
		"completed_growth_milestones": [],
		"injury": {"status": "healthy", "remaining_cycles": 0},
		"status": "active",
		"death_record": null,
	}


static func validate_instance(instance: Variant, source: String = "general") -> PackedStringArray:
	var errors := PackedStringArray()
	if not instance is Dictionary:
		errors.append("%s must be an object" % source)
		return errors
	for field in ["general_id", "name", "is_player_character", "vertical_slice_deployment_enabled", "level", "experience", "attributes", "core_talent_id", "active_talent_id", "unlocked_exclusive_cards", "pending_growth_milestones", "completed_growth_milestones", "injury", "status", "death_record"]:
		if not instance.has(field):
			errors.append("%s missing field '%s'" % [source, field])
	if not errors.is_empty():
		return errors
	if not instance.general_id is String or instance.general_id.strip_edges().is_empty():
		errors.append("%s general_id must be non-empty" % source)
	if not instance.name is String or instance.name.strip_edges().is_empty():
		errors.append("%s name must be non-empty" % source)
	if not instance.is_player_character is bool:
		errors.append("%s is_player_character must be boolean" % source)
	if not instance.vertical_slice_deployment_enabled is bool:
		errors.append("%s vertical_slice_deployment_enabled must be boolean" % source)
	elif instance.is_player_character and instance.vertical_slice_deployment_enabled:
		errors.append("%s player placeholder cannot deploy in the Vertical Slice" % source)
	if not _is_positive_whole_number(instance.level) or int(instance.level) > 6:
		errors.append("%s level must be between 1 and 6" % source)
	if not _is_non_negative_whole_number(instance.experience):
		errors.append("%s experience must be non-negative" % source)
	if not instance.attributes is Dictionary:
		errors.append("%s attributes must be an object" % source)
	else:
		for attribute in ATTRIBUTE_IDS:
			if not _is_non_negative_whole_number(instance.attributes.get(attribute)):
				errors.append("%s attributes requires non-negative integer %s" % [source, attribute])
	for field in ["unlocked_exclusive_cards", "pending_growth_milestones", "completed_growth_milestones"]:
		if not instance[field] is Array:
			errors.append("%s %s must be an array" % [source, field])
	if instance.unlocked_exclusive_cards is Array:
		errors.append_array(_validate_unique_ids(instance.unlocked_exclusive_cards, "%s.unlocked_exclusive_cards" % source))
	if not instance.status in ["active", "deceased"]:
		errors.append("%s has unsupported status '%s'" % [source, instance.status])
	if not instance.injury is Dictionary:
		errors.append("%s injury must be an object" % source)
	else:
		var injury_status = instance.injury.get("status", "")
		var remaining = instance.injury.get("remaining_cycles", null)
		if not injury_status in ["healthy", "major_injury"]:
			errors.append("%s injury status is invalid" % source)
		if not _is_non_negative_whole_number(remaining):
			errors.append("%s injury remaining_cycles must be non-negative" % source)
		elif injury_status == "healthy" and int(remaining) != 0:
			errors.append("%s healthy injury state must have zero remaining cycles" % source)
		elif injury_status == "major_injury" and int(remaining) <= 0:
			errors.append("%s major injury must have positive remaining cycles" % source)
	if instance.status == "deceased":
		if not instance.death_record is Dictionary:
			errors.append("%s deceased general requires a death_record" % source)
		if not String(instance.active_talent_id).is_empty() or not instance.unlocked_exclusive_cards.is_empty():
			errors.append("%s deceased general cannot retain active talent or exclusive cards" % source)
	elif instance.death_record != null:
		errors.append("%s active general cannot have a death_record" % source)
	return errors


static func validate_roster(generals: Variant, source: String = "generals") -> PackedStringArray:
	var errors := PackedStringArray()
	if not generals is Array:
		errors.append("%s must be an array" % source)
		return errors
	var seen := {}
	for index in generals.size():
		errors.append_array(validate_instance(generals[index], "%s[%d]" % [source, index]))
		if generals[index] is Dictionary:
			var general_id: String = String(generals[index].get("general_id", ""))
			if not general_id.is_empty() and seen.has(general_id):
				errors.append("%s contains duplicate general '%s'" % [source, general_id])
			seen[general_id] = true
	return errors


static func apply_expedition_effect(instance: Dictionary, effect: Dictionary, progression: Dictionary) -> Dictionary:
	var result := instance.duplicate(true)
	if bool(effect.get("general_died", false)):
		var lost_cards: Array = result.unlocked_exclusive_cards.duplicate(true)
		var lost_talent: String = String(result.active_talent_id)
		result.status = "deceased"
		result.injury = {"status": "healthy", "remaining_cycles": 0}
		result.active_talent_id = ""
		result.unlocked_exclusive_cards = []
		result.pending_growth_milestones = []
		result.death_record = {
			"request_id": String(effect.get("request_id", "")),
			"expedition_id": String(effect.get("expedition_id", "")),
			"cause": "troops_zero" if int(effect.get("remaining_troops", 1)) == 0 else "morale_collapse",
			"lost_talent_id": lost_talent,
			"lost_exclusive_cards": lost_cards,
		}
		return {"instance": result, "experience_gained": 0, "level_gained": 0, "died": true, "injured": false}
	if bool(effect.get("general_injured", false)):
		result.injury = {"status": "major_injury", "remaining_cycles": int(progression.major_injury_recovery_cycles)}
	var experience_gained := int(effect.get("experience_gained", progression.experience_by_outcome.get(String(effect.get("outcome", "")), 0)))
	result.experience = int(result.experience) + experience_gained
	var level_gained := 0
	if int(result.level) < int(progression.max_level):
		var next_level := int(result.level) + 1
		if int(result.experience) >= int(progression.experience_thresholds[str(next_level)]):
			result.level = next_level
			level_gained = 1
			_apply_level_reward(result, next_level, progression)
	return {"instance": result, "experience_gained": experience_gained, "level_gained": level_gained, "died": false, "injured": bool(effect.get("general_injured", false))}


static func project_experience(level: int, experience: int, gained: int, progression: Dictionary) -> Dictionary:
	var projected_experience := maxi(0, experience + gained)
	var projected_level := level
	if level < int(progression.get("max_level", level)):
		var next_level := level + 1
		if projected_experience >= int(progression.get("experience_thresholds", {}).get(str(next_level), 2147483647)):
			projected_level = next_level
	var attribute_growth := {}
	if projected_level > level:
		attribute_growth = progression.get("attribute_growth", {}).get(str(projected_level), {}).duplicate(true)
	return {
		"experience": projected_experience,
		"level": projected_level,
		"level_gained": projected_level - level,
		"attribute_growth": attribute_growth,
	}


static func advance_recovery(instance: Dictionary) -> Dictionary:
	var result := instance.duplicate(true)
	if result.status != "active" or result.injury.status != "major_injury":
		return {"instance": result, "changed": false, "recovered": false}
	result.injury.remaining_cycles = int(result.injury.remaining_cycles) - 1
	var recovered := int(result.injury.remaining_cycles) <= 0
	if recovered:
		result.injury = {"status": "healthy", "remaining_cycles": 0}
	return {"instance": result, "changed": true, "recovered": recovered}


static func is_available(instance: Dictionary) -> bool:
	return bool(instance.get("vertical_slice_deployment_enabled", false)) and instance.get("status", "") == "active" and instance.get("injury", {}).get("status", "") == "healthy"


static func _apply_level_reward(instance: Dictionary, level: int, progression: Dictionary) -> void:
	var level_key := str(level)
	if progression.attribute_growth.has(level_key):
		for attribute in ATTRIBUTE_IDS:
			instance.attributes[attribute] = int(instance.attributes[attribute]) + int(progression.attribute_growth[level_key].get(attribute, 0))
	if progression.milestone_types.has(level_key):
		instance.pending_growth_milestones.append({
			"level": level,
			"type": String(progression.milestone_types[level_key]),
			"status": "content_pending",
		})


static func _validate_experience_thresholds(thresholds: Variant, max_level: int, source: String, errors: PackedStringArray) -> void:
	if not thresholds is Dictionary:
		errors.append("%s experience_thresholds must be an object" % source)
		return
	var previous := 0
	for level in range(2, max_level + 1):
		var key := str(level)
		if not thresholds.has(key) or not _is_positive_whole_number(thresholds.get(key)):
			errors.append("%s experience_thresholds requires positive level %d" % [source, level])
			continue
		var threshold := int(thresholds[key])
		if threshold <= previous:
			errors.append("%s experience thresholds must increase strictly" % source)
		previous = threshold


static func _validate_attribute_growth(growth: Variant, max_level: int, source: String, errors: PackedStringArray) -> void:
	if not growth is Dictionary:
		errors.append("%s attribute_growth must be an object" % source)
		return
	for level_key in growth:
		if not level_key in ["2", "5"] or int(level_key) > max_level:
			errors.append("%s attribute growth is only allowed at Lv2 and Lv5" % source)
		continue
		if not growth[level_key] is Dictionary:
			errors.append("%s attribute_growth.%s must be an object" % [source, level_key])
		continue
		for attribute in ATTRIBUTE_IDS:
			if not _is_non_negative_whole_number(growth[level_key].get(attribute)):
				errors.append("%s attribute_growth.%s requires non-negative %s" % [source, level_key, attribute])
	for required_level in ["2", "5"]:
		if not growth.has(required_level):
			errors.append("%s attribute_growth missing Lv%s" % [source, required_level])


static func _validate_milestones(milestones: Variant, max_level: int, source: String, errors: PackedStringArray) -> void:
	if not milestones is Dictionary:
		errors.append("%s milestone_types must be an object" % source)
		return
	var expected := {"3": "talent_branch_choice", "4": "exclusive_card_unlock", "6": "talent_branch_choice"}
	for level_key in expected:
		if int(level_key) > max_level or milestones.get(level_key, "") != expected[level_key]:
			errors.append("%s milestone_types must preserve the Lv%s Vertical Slice milestone" % [source, level_key])
	for level_key in milestones:
		if not milestones[level_key] in MILESTONE_TYPES:
			errors.append("%s milestone_types has unsupported value '%s'" % [source, milestones[level_key]])


static func _validate_unique_ids(values: Array, source: String) -> PackedStringArray:
	var errors := PackedStringArray()
	var seen := {}
	for value in values:
		if not value is String or value.strip_edges().is_empty():
			errors.append("%s requires non-empty string ids" % source)
		elif seen.has(value):
			errors.append("%s contains duplicate '%s'" % [source, value])
		else:
			seen[value] = true
	return errors


static func _is_non_negative_whole_number(value: Variant) -> bool:
	if value is int:
		return value >= 0
	if value is float:
		return is_finite(value) and value >= 0.0 and value == floor(value)
	return false


static func _is_positive_whole_number(value: Variant) -> bool:
	return _is_non_negative_whole_number(value) and float(value) > 0.0
