extends RefCounted
class_name TerritoryDefinitionValidator

const MAIN_RESOURCE_IDS := ["silver", "food", "recruits", "military_knowledge"]


static func validate(definition: Variant, source: String = "territory") -> PackedStringArray:
	var errors := PackedStringArray()
	if not definition is Dictionary:
		errors.append("%s must be an object" % source)
		return errors
	for field in ["id", "name", "balance_status", "source_expedition_id", "main_city_stage_on_capture", "independent_city_management", "cycle_income", "presentation"]:
		if not definition.has(field):
			errors.append("%s missing field '%s'" % [source, field])
	if not errors.is_empty():
		return errors
	for field in ["id", "name", "source_expedition_id", "main_city_stage_on_capture"]:
		if not definition[field] is String or definition[field].strip_edges().is_empty():
			errors.append("%s %s must be a non-empty string" % [source, field])
	if definition.balance_status != "prototype_temporary":
		errors.append("%s must explicitly remain prototype_temporary" % source)
	if not definition.independent_city_management is bool or definition.independent_city_management:
		errors.append("%s cannot enable independent city management" % source)
	var income = definition.cycle_income
	if not income is Dictionary:
		errors.append("%s cycle_income must be an object" % source)
	else:
		_validate_income_map(income.get("main_resources", null), MAIN_RESOURCE_IDS, "%s.cycle_income.main_resources" % source, errors)
		_validate_income_map(income.get("special_resources", null), [], "%s.cycle_income.special_resources" % source, errors)
	var presentation = definition.presentation
	if not presentation is Dictionary or String(presentation.get("description", "")).strip_edges().is_empty():
		errors.append("%s presentation requires a description" % source)
	return errors


static func _validate_income_map(income: Variant, allowed_ids: Array, source: String, errors: PackedStringArray) -> void:
	if not income is Dictionary:
		errors.append("%s must be an object" % source)
		return
	for resource_id in income:
		if not resource_id is String or resource_id.strip_edges().is_empty():
			errors.append("%s has an invalid resource id" % source)
		elif not allowed_ids.is_empty() and not resource_id in allowed_ids:
			errors.append("%s has unsupported resource '%s'" % [source, resource_id])
		elif allowed_ids.is_empty() and not resource_id.begins_with("resource."):
			errors.append("%s special resources require stable 'resource.' ids" % source)
		elif not _is_non_negative_whole_number(income[resource_id]) or int(income[resource_id]) <= 0:
			errors.append("%s resource '%s' must be a positive integer" % [source, resource_id])


static func _is_non_negative_whole_number(value: Variant) -> bool:
	if value is int:
		return value >= 0
	if value is float:
		return is_finite(value) and value >= 0.0 and value == floor(value)
	return false
