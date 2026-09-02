extends RefCounted
class_name LoadoutService


static func create_system_state() -> Dictionary:
	return {
		"applied_action_ids": [],
		"history": [],
		"requires_legacy_recovery": false,
		"legacy_general_loadouts": {},
	}


static func normalize_system_state(source: Dictionary) -> Dictionary:
	var result := source.duplicate(true)
	var defaults := create_system_state()
	for field in defaults:
		if not result.has(field):
			result[field] = defaults[field].duplicate(true) if defaults[field] is Array or defaults[field] is Dictionary else defaults[field]
	return result


static func validate_system_state(value: Variant, source: String = "loadout_system") -> PackedStringArray:
	var errors := PackedStringArray()
	if not value is Dictionary:
		errors.append("%s must be an object" % source)
		return errors
	for field in ["applied_action_ids", "history"]:
		if not value.get(field, null) is Array:
			errors.append("%s.%s must be an array" % [source, field])
	if not value.get("requires_legacy_recovery", null) is bool:
		errors.append("%s.requires_legacy_recovery must be a boolean" % source)
	if not value.get("legacy_general_loadouts", null) is Dictionary:
		errors.append("%s.legacy_general_loadouts must be an object" % source)
	else:
		for general_id in value.legacy_general_loadouts:
			if not general_id is String or general_id.strip_edges().is_empty():
				errors.append("%s.legacy_general_loadouts keys must be non-empty general ids" % source)
				continue
			errors.append_array(validate_base_loadout_shape(
				value.legacy_general_loadouts[general_id],
				"%s.legacy_general_loadouts.%s" % [source, general_id]
			))
	if value.get("applied_action_ids", null) is Array:
		var seen := {}
		for action_id in value.applied_action_ids:
			if not action_id is String or action_id.strip_edges().is_empty():
				errors.append("%s.applied_action_ids must contain non-empty strings" % source)
			elif seen.has(action_id):
				errors.append("%s.applied_action_ids contains duplicate '%s'" % [source, action_id])
			else:
				seen[action_id] = true
	return errors


static func validate_base_loadout_shape(value: Variant, source: String = "base_loadout") -> PackedStringArray:
	var errors := PackedStringArray()
	if not value is Array:
		errors.append("%s must be an array" % source)
		return errors
	for card_id in value:
		if not card_id is String or card_id.strip_edges().is_empty():
			errors.append("%s must contain non-empty card ids" % source)
	return errors


static func validate_base_loadout(
	deck: Variant,
	campaign: Dictionary,
	card_by_id: Dictionary,
	minimum_size: int = 15,
	maximum_size: int = 25
) -> PackedStringArray:
	var errors := PackedStringArray()
	if not deck is Array:
		errors.append("base loadout: cards must be an array")
		return errors
	if deck.size() < minimum_size or deck.size() > maximum_size:
		errors.append("base loadout: must contain between %d and %d cards" % [minimum_size, maximum_size])
	var counts := {}
	for value in deck:
		if not value is String or value.strip_edges().is_empty():
			errors.append("base loadout: card ids must be non-empty strings")
			continue
		var card_id: String = value
		if not card_by_id.has(card_id):
			errors.append("base loadout: unknown card '%s'" % card_id)
			continue
		var card: Dictionary = card_by_id[card_id]
		if card.get("owner_scope", "") != "public":
			errors.append("base loadout: card '%s' is not public" % card_id)
		elif not campaign.get("unlocked_public_cards", []).has(card_id):
			errors.append("base loadout: public card '%s' is locked" % card_id)
		counts[card_id] = int(counts.get(card_id, 0)) + 1
		if int(counts[card_id]) > int(card.get("copy_limit", 0)):
			errors.append("base loadout: card '%s' exceeds copy limit %d" % [card_id, int(card.get("copy_limit", 0))])
	return errors


static func compose_deployment_deck(base_deck: Array, general: Dictionary, card_by_id: Dictionary) -> Dictionary:
	var errors := PackedStringArray()
	var general_id := String(general.get("general_id", ""))
	var exclusive_cards: Array = general.get("unlocked_exclusive_cards", []).duplicate()
	var seen := {}
	for card_id in exclusive_cards:
		if not card_id is String or card_id.strip_edges().is_empty():
			errors.append("deployment deck: exclusive card ids must be non-empty strings")
			continue
		if seen.has(card_id):
			errors.append("deployment deck: duplicate exclusive card '%s'" % card_id)
			continue
		seen[card_id] = true
		if not card_by_id.has(card_id):
			errors.append("deployment deck: unknown exclusive card '%s'" % card_id)
			continue
		var card: Dictionary = card_by_id[card_id]
		if card.get("owner_scope", "") != "general:%s" % general_id:
			errors.append("deployment deck: exclusive card '%s' does not belong to '%s'" % [card_id, general_id])
		elif int(card.get("copy_limit", 0)) < 1:
			errors.append("deployment deck: exclusive card '%s' cannot be added" % card_id)
	if not errors.is_empty():
		return {"ok": false, "errors": errors, "base_deck": [], "exclusive_cards": [], "deck": []}
	var deck := base_deck.duplicate()
	deck.append_array(exclusive_cards)
	return {"ok": true, "errors": PackedStringArray(), "base_deck": base_deck.duplicate(), "exclusive_cards": exclusive_cards, "deck": deck}


static func _find_general(generals: Variant, general_id: String) -> Dictionary:
	if not generals is Array:
		return {}
	for general in generals:
		if general is Dictionary and general.get("general_id", "") == general_id:
			return general
	return {}
