extends RefCounted
class_name ArmyManagementService

const ARMY_TYPE_IDS := ["infantry", "archer", "cavalry"]
const TRAINING_MAIN_RESOURCE_IDS := ["silver", "food", "recruits"]


static func normalize_inventory(source: Dictionary) -> Dictionary:
	var result := source.duplicate(true)
	for army_type in ARMY_TYPE_IDS:
		if not result.has(army_type):
			result[army_type] = 0
	return result


static func validate_inventory(inventory: Variant, source: String = "army_inventory") -> PackedStringArray:
	var errors := PackedStringArray()
	if not inventory is Dictionary:
		errors.append("%s must be an object" % source)
		return errors
	for army_type in ARMY_TYPE_IDS:
		if not inventory.has(army_type):
			errors.append("%s missing '%s'" % [source, army_type])
		elif not _is_non_negative_whole_number(inventory[army_type]):
			errors.append("%s '%s' must be a non-negative whole number" % [source, army_type])
	for army_type in inventory:
		if not army_type in ARMY_TYPE_IDS:
			errors.append("%s contains unsupported army type '%s'" % [source, army_type])
	return errors


static func validate_economy_definition(definition: Variant, source: String = "army_economy") -> PackedStringArray:
	var errors := PackedStringArray()
	if not definition is Dictionary:
		errors.append("%s must be an object" % source)
		return errors
	for field in ["id", "balance_status", "batch_size", "army_types"]:
		if not definition.has(field):
			errors.append("%s missing field '%s'" % [source, field])
	if not errors.is_empty():
		return errors
	if not definition.id is String or definition.id.strip_edges().is_empty():
		errors.append("%s id must be a non-empty string" % source)
	if definition.balance_status != "prototype_temporary":
		errors.append("%s must explicitly remain prototype_temporary" % source)
	if not _is_positive_whole_number(definition.batch_size):
		errors.append("%s batch_size must be a positive whole number" % source)
	if not definition.army_types is Dictionary:
		errors.append("%s army_types must be an object" % source)
		return errors
	for army_type in ARMY_TYPE_IDS:
		if not definition.army_types.has(army_type):
			errors.append("%s missing army type '%s'" % [source, army_type])
			continue
		_validate_recipe(definition.army_types[army_type], source, army_type, errors)
	for army_type in definition.army_types:
		if not army_type in ARMY_TYPE_IDS:
			errors.append("%s contains unsupported army type '%s'" % [source, army_type])
	return errors


static func quote_replenishment(definition: Dictionary, army_type: String, batches: Variant) -> Dictionary:
	var errors := validate_economy_definition(definition)
	if not army_type in ARMY_TYPE_IDS:
		errors.append("army training: unsupported army type '%s'" % army_type)
	if not _is_positive_whole_number(batches):
		errors.append("army training: batches must be a positive whole number")
	if not errors.is_empty():
		return {"ok": false, "errors": errors, "troops_added": 0, "main_costs": {}, "special_costs": {}}
	var recipe: Dictionary = definition.army_types[army_type]
	var batch_count := int(batches)
	return {
		"ok": true,
		"errors": PackedStringArray(),
		"troops_added": int(definition.batch_size) * batch_count,
		"main_costs": _scaled_costs(recipe.main_costs, batch_count),
		"special_costs": _scaled_costs(recipe.special_costs, batch_count),
	}


static func calculate_casualties(initial_troops: Variant, remaining_troops: Variant, composition: Variant) -> Dictionary:
	var errors := PackedStringArray()
	if not _is_positive_whole_number(initial_troops):
		errors.append("army casualties: initial_troops must be a positive whole number")
	if not _is_non_negative_whole_number(remaining_troops):
		errors.append("army casualties: remaining_troops must be a non-negative whole number")
	elif _is_positive_whole_number(initial_troops) and int(remaining_troops) > int(initial_troops):
		errors.append("army casualties: remaining_troops cannot exceed initial_troops")
	if not composition is Dictionary:
		errors.append("army casualties: composition must be an object")
	else:
		var total := 0.0
		for army_type in ARMY_TYPE_IDS:
			if not composition.has(army_type):
				errors.append("army casualties: composition missing '%s'" % army_type)
				continue
			var ratio = composition[army_type]
			if not ratio is int and not ratio is float or not is_finite(float(ratio)) or float(ratio) < 0.0:
				errors.append("army casualties: '%s' ratio must be a non-negative number" % army_type)
			else:
				total += float(ratio)
		for army_type in composition:
			if not army_type in ARMY_TYPE_IDS:
				errors.append("army casualties: unsupported army type '%s'" % army_type)
		if not is_equal_approx(total, 1.0):
			errors.append("army casualties: composition must sum to 1.0")
	if not errors.is_empty():
		return {"ok": false, "errors": errors, "total": 0, "losses": {}}
	var total_losses := int(initial_troops) - int(remaining_troops)
	var losses := {"infantry": 0, "archer": 0, "cavalry": 0}
	var remainders := {}
	var assigned := 0
	for army_type in ARMY_TYPE_IDS:
		var exact := float(total_losses) * float(composition[army_type])
		var base := int(floor(exact))
		losses[army_type] = base
		remainders[army_type] = exact - float(base)
		assigned += base
	var unassigned := total_losses - assigned
	while unassigned > 0:
		var selected: String = ARMY_TYPE_IDS[0]
		for army_type in ARMY_TYPE_IDS:
			if float(remainders[army_type]) > float(remainders[selected]):
				selected = army_type
		losses[selected] = int(losses[selected]) + 1
		remainders[selected] = -1.0
		unassigned -= 1
	return {"ok": true, "errors": PackedStringArray(), "total": total_losses, "losses": losses}


static func _validate_recipe(recipe: Variant, source: String, army_type: String, errors: PackedStringArray) -> void:
	if not recipe is Dictionary:
		errors.append("%s army type '%s' must be an object" % [source, army_type])
		return
	for field in ["name", "main_costs", "special_costs"]:
		if not recipe.has(field):
			errors.append("%s army type '%s' missing '%s'" % [source, army_type, field])
	if not recipe.get("name", null) is String or String(recipe.get("name", "")).strip_edges().is_empty():
		errors.append("%s army type '%s' requires a name" % [source, army_type])
	var main_costs = recipe.get("main_costs", null)
	var special_costs = recipe.get("special_costs", null)
	if not main_costs is Dictionary:
		errors.append("%s army type '%s' main_costs must be an object" % [source, army_type])
	else:
		for resource_id in main_costs:
			if not resource_id in TRAINING_MAIN_RESOURCE_IDS:
				errors.append("%s army type '%s' has unsupported main cost '%s'" % [source, army_type, resource_id])
			elif not _is_non_negative_whole_number(main_costs[resource_id]):
				errors.append("%s army type '%s' cost '%s' must be non-negative" % [source, army_type, resource_id])
		if not _is_positive_whole_number(main_costs.get("recruits", null)):
			errors.append("%s army type '%s' must consume recruits" % [source, army_type])
	if not special_costs is Dictionary:
		errors.append("%s army type '%s' special_costs must be an object" % [source, army_type])
	else:
		for resource_id in special_costs:
			if not resource_id is String or String(resource_id).strip_edges().is_empty():
				errors.append("%s army type '%s' has an invalid special resource id" % [source, army_type])
			elif not _is_positive_whole_number(special_costs[resource_id]):
				errors.append("%s army type '%s' special cost '%s' must be positive" % [source, army_type, resource_id])


static func _scaled_costs(costs: Dictionary, multiplier: int) -> Dictionary:
	var result := {}
	for resource_id in costs:
		result[resource_id] = int(costs[resource_id]) * multiplier
	return result


static func _is_non_negative_whole_number(value: Variant) -> bool:
	if value is int:
		return value >= 0
	if value is float:
		return is_finite(value) and value >= 0.0 and value == floor(value)
	return false


static func _is_positive_whole_number(value: Variant) -> bool:
	return _is_non_negative_whole_number(value) and float(value) > 0.0
