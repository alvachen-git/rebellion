extends RefCounted
class_name ResearchManagementService

const ALLOWED_RARITIES := ["basic", "advanced", "rare", "secret"]
const RESEARCH_MAIN_RESOURCE_IDS := ["silver", "military_knowledge"]


static func normalize_research_state(source: Dictionary) -> Dictionary:
	var result := source.duplicate(true)
	if not result.has("applied_action_ids"):
		result.applied_action_ids = []
	if not result.has("history"):
		result.history = []
	return result


static func validate_research_state(state: Variant, source: String = "research") -> PackedStringArray:
	var errors := PackedStringArray()
	if not state is Dictionary:
		errors.append("%s must be an object" % source)
		return errors
	for field in ["applied_action_ids", "history"]:
		if not state.get(field, null) is Array:
			errors.append("%s.%s must be an array" % [source, field])
	if state.get("applied_action_ids", null) is Array:
		var seen := {}
		for action_id in state.applied_action_ids:
			if not action_id is String or action_id.strip_edges().is_empty():
				errors.append("%s.applied_action_ids requires non-empty strings" % source)
			elif seen.has(action_id):
				errors.append("%s.applied_action_ids contains duplicate '%s'" % [source, action_id])
			else:
				seen[action_id] = true
	return errors


static func validate_card_progress(unlocked_cards: Variant, upgrade_branches: Variant, source: String = "campaign") -> PackedStringArray:
	var errors := PackedStringArray()
	if not unlocked_cards is Array:
		errors.append("%s.unlocked_public_cards must be an array" % source)
		return errors
	if not upgrade_branches is Dictionary:
		errors.append("%s.card_upgrade_branches must be an object" % source)
		return errors
	var seen := {}
	for card_id in unlocked_cards:
		if not card_id is String or card_id.strip_edges().is_empty():
			errors.append("%s.unlocked_public_cards requires non-empty string ids" % source)
		elif seen.has(card_id):
			errors.append("%s.unlocked_public_cards contains duplicate '%s'" % [source, card_id])
		else:
			seen[card_id] = true
	for card_id in upgrade_branches:
		if not card_id is String or card_id.strip_edges().is_empty():
			errors.append("%s.card_upgrade_branches requires non-empty card ids" % source)
		elif not seen.has(card_id):
			errors.append("%s.card_upgrade_branches references locked card '%s'" % [source, card_id])
		var branch_id = upgrade_branches[card_id]
		if not branch_id is String or branch_id.strip_edges().is_empty():
			errors.append("%s.card_upgrade_branches requires non-empty branch ids" % source)
	return errors


static func validate_economy_definition(definition: Variant, source: String = "research_economy") -> PackedStringArray:
	var errors := PackedStringArray()
	if not definition is Dictionary:
		errors.append("%s must be an object" % source)
		return errors
	for field in ["id", "balance_status", "eligible_public_card_ids", "unlock_costs_by_rarity", "upgrade_costs_by_rarity", "special_unlock_costs"]:
		if not definition.has(field):
			errors.append("%s missing field '%s'" % [source, field])
	if not errors.is_empty():
		return errors
	if not definition.id is String or definition.id.strip_edges().is_empty():
		errors.append("%s id must be a non-empty string" % source)
	if definition.balance_status != "prototype_temporary":
		errors.append("%s must explicitly remain prototype_temporary" % source)
	if not definition.eligible_public_card_ids is Array or definition.eligible_public_card_ids.is_empty():
		errors.append("%s eligible_public_card_ids must be a non-empty array" % source)
	else:
		var seen_cards := {}
		for card_id in definition.eligible_public_card_ids:
			if not card_id is String or card_id.strip_edges().is_empty() or seen_cards.has(card_id):
				errors.append("%s eligible card ids must be non-empty and unique" % source)
			else:
				seen_cards[card_id] = true
	_validate_rarity_cost_table(definition.unlock_costs_by_rarity, source, "unlock_costs_by_rarity", errors)
	_validate_rarity_cost_table(definition.upgrade_costs_by_rarity, source, "upgrade_costs_by_rarity", errors)
	if not definition.special_unlock_costs is Dictionary:
		errors.append("%s special_unlock_costs must be an object" % source)
	else:
		for card_id in definition.special_unlock_costs:
			if not definition.eligible_public_card_ids.has(card_id):
				errors.append("%s special cost references ineligible card '%s'" % [source, card_id])
			_validate_costs(definition.special_unlock_costs[card_id], source, "special_unlock_costs.%s" % card_id, [], true, errors)
	return errors


static func validate_card_catalog(definition: Dictionary, cards: Array, source: String = "research_catalog") -> PackedStringArray:
	var errors := validate_economy_definition(definition)
	if not errors.is_empty():
		return errors
	var card_by_id := {}
	for card in cards:
		if not card is Dictionary:
			errors.append("%s entries must be objects" % source)
			continue
		var card_id: String = String(card.get("id", ""))
		if card_id.is_empty() or card_by_id.has(card_id):
			errors.append("%s card ids must be non-empty and unique" % source)
		else:
			card_by_id[card_id] = card
	for card_id in definition.eligible_public_card_ids:
		if not card_by_id.has(card_id):
			errors.append("%s missing eligible card '%s'" % [source, card_id])
			continue
		var card: Dictionary = card_by_id[card_id]
		if card.get("owner_scope", "") != "public":
			errors.append("%s card '%s' is not a public card" % [source, card_id])
		if not card.get("rarity", "") in ALLOWED_RARITIES:
			errors.append("%s card '%s' has unsupported rarity" % [source, card_id])
		var branches = card.get("upgrade_branches", null)
		if not branches is Array or branches.size() != 2:
			errors.append("%s card '%s' must expose exactly two upgrade branches" % [source, card_id])
		else:
			var branch_ids := {}
			for branch in branches:
				if not branch is Dictionary:
					errors.append("%s card '%s' upgrade branches must be objects" % [source, card_id])
					continue
				var branch_id: String = String(branch.get("id", ""))
				if branch_id.is_empty() or branch_ids.has(branch_id):
					errors.append("%s card '%s' upgrade branch ids must be non-empty and unique" % [source, card_id])
				else:
					branch_ids[branch_id] = true
				if not branch.get("overrides", null) is Dictionary or branch.overrides.is_empty():
					errors.append("%s card '%s' upgrade branch requires overrides" % [source, card_id])
	return errors


static func quote_unlock(definition: Dictionary, card: Dictionary) -> Dictionary:
	var errors := _validate_eligible_card(definition, card)
	if not errors.is_empty():
		return _quote_failure(errors)
	var rarity: String = card.rarity
	return {
		"ok": true,
		"errors": PackedStringArray(),
		"main_costs": _integer_costs(definition.unlock_costs_by_rarity[rarity]),
		"special_costs": _integer_costs(definition.special_unlock_costs.get(card.id, {})),
	}


static func quote_upgrade(definition: Dictionary, card: Dictionary, branch_id: String) -> Dictionary:
	var errors := _validate_eligible_card(definition, card)
	var branch := _find_branch(card.get("upgrade_branches", []), branch_id)
	if branch.is_empty():
		errors.append("research: unknown upgrade branch '%s' for '%s'" % [branch_id, card.get("id", "")])
	if not errors.is_empty():
		return _quote_failure(errors)
	return {
		"ok": true,
		"errors": PackedStringArray(),
		"main_costs": _integer_costs(definition.upgrade_costs_by_rarity[card.rarity]),
		"special_costs": {},
	}


static func resolve_card_definition(card: Dictionary, branch_id: String) -> Dictionary:
	if branch_id.strip_edges().is_empty():
		return {"ok": true, "errors": PackedStringArray(), "card": card.duplicate(true)}
	var branch := _find_branch(card.get("upgrade_branches", []), branch_id)
	if branch.is_empty():
		return {"ok": false, "errors": PackedStringArray(["research: unknown upgrade branch '%s' for '%s'" % [branch_id, card.get("id", "")]]), "card": {}}
	var resolved := card.duplicate(true)
	for field in branch.overrides:
		resolved[field] = branch.overrides[field].duplicate(true) if branch.overrides[field] is Array or branch.overrides[field] is Dictionary else branch.overrides[field]
	resolved.applied_upgrade_branch = branch_id
	return {"ok": true, "errors": PackedStringArray(), "card": resolved}


static func _validate_eligible_card(definition: Dictionary, card: Dictionary) -> PackedStringArray:
	var errors := validate_economy_definition(definition)
	var card_id: String = String(card.get("id", ""))
	if card_id.is_empty() or not definition.get("eligible_public_card_ids", []).has(card_id):
		errors.append("research: card '%s' is not an eligible public card" % card_id)
	if card.get("owner_scope", "") != "public":
		errors.append("research: card '%s' is not public" % card_id)
	if not card.get("rarity", "") in ALLOWED_RARITIES:
		errors.append("research: card '%s' has unsupported rarity" % card_id)
	return errors


static func _validate_rarity_cost_table(table: Variant, source: String, label: String, errors: PackedStringArray) -> void:
	if not table is Dictionary:
		errors.append("%s %s must be an object" % [source, label])
		return
	for rarity in ALLOWED_RARITIES:
		if not table.has(rarity):
			errors.append("%s %s missing rarity '%s'" % [source, label, rarity])
			continue
		_validate_costs(table[rarity], source, "%s.%s" % [label, rarity], RESEARCH_MAIN_RESOURCE_IDS, false, errors)
	for rarity in table:
		if not rarity in ALLOWED_RARITIES:
			errors.append("%s %s has unsupported rarity '%s'" % [source, label, rarity])


static func _validate_costs(costs: Variant, source: String, label: String, allowed_ids: Array, _require_positive: bool, errors: PackedStringArray) -> void:
	if not costs is Dictionary:
		errors.append("%s %s must be an object" % [source, label])
		return
	if costs.is_empty():
		errors.append("%s %s must not be empty" % [source, label])
	for resource_id in costs:
		if not resource_id is String or resource_id.strip_edges().is_empty():
			errors.append("%s %s has an invalid resource id" % [source, label])
		elif not allowed_ids.is_empty() and not resource_id in allowed_ids:
			errors.append("%s %s has unsupported resource '%s'" % [source, label, resource_id])
		elif not _is_positive_whole_number(costs[resource_id]):
			errors.append("%s %s cost '%s' must be positive" % [source, label, resource_id])


static func _find_branch(branches: Variant, branch_id: String) -> Dictionary:
	if not branches is Array or branch_id.strip_edges().is_empty():
		return {}
	for branch in branches:
		if branch is Dictionary and branch.get("id", "") == branch_id:
			return branch
	return {}


static func _quote_failure(errors: PackedStringArray) -> Dictionary:
	return {"ok": false, "errors": errors, "main_costs": {}, "special_costs": {}}


static func _integer_costs(costs: Dictionary) -> Dictionary:
	var result := {}
	for resource_id in costs:
		result[resource_id] = int(costs[resource_id])
	return result


static func _is_positive_whole_number(value: Variant) -> bool:
	if value is int:
		return value > 0
	if value is float:
		return is_finite(value) and value > 0.0 and value == floor(value)
	return false
