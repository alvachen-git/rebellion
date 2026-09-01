extends RefCounted
class_name FactionCycleService

const TerritoryDefinitionValidatorScript := preload("res://src/domain/content/territory_definition_validator.gd")


static func create_faction_state() -> Dictionary:
	return {
		"applied_effect_ids": [],
		"history": [],
	}


static func normalize_faction_state(source: Dictionary) -> Dictionary:
	var result := source.duplicate(true)
	var defaults := create_faction_state()
	for field in defaults:
		if not result.has(field):
			result[field] = defaults[field].duplicate(true)
	return result


static func validate_faction_state(state: Variant, source: String = "faction") -> PackedStringArray:
	var errors := PackedStringArray()
	if not state is Dictionary:
		errors.append("%s must be an object" % source)
		return errors
	for field in ["applied_effect_ids", "history"]:
		if not state.get(field, null) is Array:
			errors.append("%s.%s must be an array" % [source, field])
	if state.get("applied_effect_ids", null) is Array:
		var seen := {}
		for action_id in state.applied_effect_ids:
			if not action_id is String or action_id.strip_edges().is_empty():
				errors.append("%s.applied_effect_ids requires non-empty strings" % source)
			elif seen.has(action_id):
				errors.append("%s.applied_effect_ids contains duplicate '%s'" % [source, action_id])
			else:
				seen[action_id] = true
	return errors


static func validate_cycle_definition(definition: Variant, source: String = "faction_cycle") -> PackedStringArray:
	var errors := PackedStringArray()
	if not definition is Dictionary:
		errors.append("%s must be an object" % source)
		return errors
	for field in ["id", "balance_status", "cycle_advancing_outcomes", "cycle_advancing_expedition_ids", "new_territory_income_delay_cycles", "deferred_systems"]:
		if not definition.has(field):
			errors.append("%s missing field '%s'" % [source, field])
	if not errors.is_empty():
		return errors
	if not definition.id is String or definition.id.strip_edges().is_empty():
		errors.append("%s id must be a non-empty string" % source)
	if definition.balance_status != "prototype_temporary":
		errors.append("%s must explicitly remain prototype_temporary" % source)
	if definition.cycle_advancing_outcomes != ["success"]:
		errors.append("%s Vertical Slice policy must remain success-only until retreat/failure timing is confirmed" % source)
	errors.append_array(_validate_unique_ids(definition.cycle_advancing_expedition_ids, "%s.cycle_advancing_expedition_ids" % source))
	if definition.cycle_advancing_expedition_ids is Array and definition.cycle_advancing_expedition_ids.is_empty():
		errors.append("%s cycle_advancing_expedition_ids must not be empty" % source)
	if not _is_non_negative_whole_number(definition.new_territory_income_delay_cycles) or int(definition.new_territory_income_delay_cycles) != 1:
		errors.append("%s new territory income delay must remain one prototype cycle" % source)
	if not definition.deferred_systems is Array:
		errors.append("%s deferred_systems must be an array" % source)
	elif definition.deferred_systems != ["recruitment_refresh", "world_stage_change"]:
		errors.append("%s must keep recruitment and world stage explicitly deferred" % source)
	return errors


static func validate_territory_definition(definition: Variant, source: String = "territory") -> PackedStringArray:
	return TerritoryDefinitionValidatorScript.validate(definition, source)


static func validate_catalog(cycle_definition: Dictionary, territory_definitions: Array, source: String = "faction_catalog") -> PackedStringArray:
	var errors := validate_cycle_definition(cycle_definition)
	var territory_ids := {}
	var source_expeditions := {}
	for definition in territory_definitions:
		errors.append_array(validate_territory_definition(definition, source))
		if not definition is Dictionary:
			continue
		var territory_id: String = String(definition.get("id", ""))
		var expedition_id: String = String(definition.get("source_expedition_id", ""))
		if not territory_id.is_empty() and territory_ids.has(territory_id):
			errors.append("%s contains duplicate territory '%s'" % [source, territory_id])
		territory_ids[territory_id] = true
		if not expedition_id.is_empty() and source_expeditions.has(expedition_id):
			errors.append("%s has multiple territories for expedition '%s'" % [source, expedition_id])
		source_expeditions[expedition_id] = true
	if territory_definitions.is_empty():
		errors.append("%s requires at least one territory" % source)
	for expedition_id in cycle_definition.get("cycle_advancing_expedition_ids", []):
		if not source_expeditions.has(expedition_id):
			errors.append("%s missing territory for major expedition '%s'" % [source, expedition_id])
	return errors


static func create_territory_instance(definition: Dictionary, acquired_cycle: int, source_request_id: String) -> Dictionary:
	return {
		"territory_id": String(definition.id),
		"name": String(definition.name),
		"status": "controlled",
		"income_enabled": true,
		"acquired_cycle": acquired_cycle,
		"source_request_id": source_request_id,
	}


static func validate_territory_instances(instances: Variant, source: String = "territories") -> PackedStringArray:
	var errors := PackedStringArray()
	if not instances is Array:
		errors.append("%s must be an array" % source)
		return errors
	var seen := {}
	for index in instances.size():
		var instance = instances[index]
		if not instance is Dictionary:
			errors.append("%s[%d] must be an object" % [source, index])
			continue
		for field in ["territory_id", "name", "status", "income_enabled", "acquired_cycle", "source_request_id"]:
			if not instance.has(field):
				errors.append("%s[%d] missing field '%s'" % [source, index, field])
		if not instance.has("territory_id"):
			continue
		var territory_id: String = String(instance.territory_id)
		if territory_id.is_empty() or seen.has(territory_id):
			errors.append("%s territory ids must be non-empty and unique" % source)
		seen[territory_id] = true
		if String(instance.get("name", "")).strip_edges().is_empty():
			errors.append("%s[%d] name must be non-empty" % [source, index])
		if instance.get("status", "") != "controlled":
			errors.append("%s[%d] status must be controlled" % [source, index])
		if not instance.get("income_enabled", null) is bool:
			errors.append("%s[%d] income_enabled must be boolean" % [source, index])
		if not _is_non_negative_whole_number(instance.get("acquired_cycle", null)):
			errors.append("%s[%d] acquired_cycle must be non-negative" % [source, index])
		if not instance.get("source_request_id", null) is String or String(instance.get("source_request_id", "")).strip_edges().is_empty():
			errors.append("%s[%d] source_request_id must be non-empty" % [source, index])
	return errors


static func calculate_cycle_income(instances: Array, definitions_by_id: Dictionary, target_cycle: int, income_delay: int) -> Dictionary:
	var main_income := {}
	var special_income := {}
	var contributing_territory_ids := []
	var errors := PackedStringArray()
	for instance in instances:
		if not bool(instance.get("income_enabled", false)):
			continue
		var territory_id: String = String(instance.get("territory_id", ""))
		if not definitions_by_id.has(territory_id):
			errors.append("faction cycle: unknown controlled territory '%s'" % territory_id)
			continue
		if int(instance.get("acquired_cycle", 0)) + income_delay > target_cycle:
			continue
		var definition: Dictionary = definitions_by_id[territory_id]
		for resource_id in definition.cycle_income.main_resources:
			main_income[resource_id] = int(main_income.get(resource_id, 0)) + int(definition.cycle_income.main_resources[resource_id])
		for resource_id in definition.cycle_income.special_resources:
			special_income[resource_id] = int(special_income.get(resource_id, 0)) + int(definition.cycle_income.special_resources[resource_id])
		contributing_territory_ids.append(territory_id)
	return {
		"ok": errors.is_empty(),
		"errors": errors,
		"main_income": main_income,
		"special_income": special_income,
		"contributing_territory_ids": contributing_territory_ids,
	}


static func _validate_unique_ids(values: Variant, source: String) -> PackedStringArray:
	var errors := PackedStringArray()
	if not values is Array:
		errors.append("%s must be an array" % source)
		return errors
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
