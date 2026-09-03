extends RefCounted
class_name DeploymentAssembler

const LoadoutServiceScript := preload("res://src/domain/campaign/loadout_service.gd")
const ResearchManagementServiceScript := preload("res://src/domain/campaign/research_management_service.gd")

const ARMY_TYPES := ["infantry", "archer", "cavalry"]

var _registry
var _rules: Dictionary = {}
var _card_by_id: Dictionary = {}


func setup(registry, rules: Dictionary, card_definitions: Array) -> PackedStringArray:
	_registry = registry
	_rules = rules.duplicate(true)
	_card_by_id = {}
	var errors := PackedStringArray()
	if rules.get("balance_status", "") != "prototype_temporary":
		errors.append("deployment rules must remain prototype_temporary")
	var minimum_size := int(rules.get("base_deck_min_size", 0))
	var maximum_size := int(rules.get("base_deck_max_size", 0))
	if minimum_size <= 0 or maximum_size < minimum_size:
		errors.append("deployment rules base deck size range is invalid")
	var conversions = rules.get("attribute_delta_conversions", null)
	if not conversions is Dictionary:
		errors.append("deployment rules require attribute_delta_conversions")
	for card in card_definitions:
		if card is Dictionary:
			_card_by_id[String(card.get("id", ""))] = card.duplicate(true)
	return errors


func readiness(campaign: Dictionary, expedition_present: bool, request: Dictionary) -> Dictionary:
	if expedition_present:
		return _failure("deployment: an expedition is already active")
	if campaign.get("campaign_status", "") != "active":
		return _failure("deployment: campaign is not active")
	for field in ["expedition_id", "general_id"]:
		if String(request.get(field, "")).strip_edges().is_empty():
			return _failure("deployment: %s must be non-empty" % field)
	if not _registry.has_expedition(String(request.expedition_id)):
		return _failure("deployment: unknown expedition '%s'" % request.expedition_id)
	var general := _find_general(campaign.get("generals", []), String(request.general_id))
	if general.is_empty():
		return _failure("deployment: unknown campaign general '%s'" % request.general_id)
	if not bool(general.get("vertical_slice_deployment_enabled", false)):
		return _failure("deployment: general '%s' is not enabled for expedition" % request.general_id)
	if general.get("status", "") != "active":
		return _failure("deployment: general '%s' is deceased" % request.general_id)
	if general.get("injury", {}).get("status", "") != "healthy":
		return _failure("deployment: general '%s' is injured" % request.general_id)
	if bool(campaign.get("loadout_system", {}).get("requires_legacy_recovery", false)):
		var missing := _failure("deployment: requires_legacy_loadout_recovery")
		missing.requires_legacy_loadout_recovery = true
		return missing
	var base_deck = campaign.get("base_loadout", null)
	var loadout_errors := LoadoutServiceScript.validate_base_loadout(
		base_deck,
		campaign,
		_card_by_id,
		int(_rules.base_deck_min_size),
		int(_rules.base_deck_max_size)
	)
	if not loadout_errors.is_empty():
		return {"ok": false, "errors": loadout_errors, "requires_legacy_loadout_recovery": false}
	var composed: Dictionary = LoadoutServiceScript.compose_deployment_deck(base_deck, general, _card_by_id)
	if not composed.ok:
		return {"ok": false, "errors": composed.errors, "requires_legacy_loadout_recovery": false}
	var definition: Dictionary = _registry.get_general(String(request.general_id))
	if definition.is_empty():
		return _failure("deployment: missing general definition '%s'" % request.general_id)
	var troop_cap := _troop_cap(general, definition)
	var army_counts = request.get("army_counts", null)
	if army_counts == null:
		army_counts = default_army_counts(definition.get("army_composition", {}), troop_cap)
	var count_errors := _validate_army_counts(army_counts, campaign.get("army_inventory", {}), troop_cap)
	if not count_errors.is_empty():
		return {"ok": false, "errors": count_errors, "requires_legacy_loadout_recovery": false}
	return {
		"ok": true,
		"errors": PackedStringArray(),
		"requires_legacy_loadout_recovery": false,
		"troop_cap": troop_cap,
		"army_counts": army_counts.duplicate(true),
		"base_deck": composed.base_deck,
		"exclusive_cards": composed.exclusive_cards,
		"deck": composed.deck,
	}


func assemble(campaign: Dictionary, expedition_present: bool, request: Dictionary) -> Dictionary:
	for field in ["run_id", "expedition_id", "general_id", "map_seed"]:
		if not request.has(field):
			return _failure("deployment: missing field '%s'" % field)
	if String(request.run_id).strip_edges().is_empty():
		return _failure("deployment: run_id must be non-empty")
	if not _is_whole_number(request.map_seed):
		return _failure("deployment: map_seed must be an integer")
	var ready := readiness(campaign, expedition_present, request)
	if not ready.ok:
		return ready
	var general := _find_general(campaign.generals, String(request.general_id))
	var definition: Dictionary = _registry.get_general(String(request.general_id))
	var total := 0
	for army_type in ARMY_TYPES:
		total += int(ready.army_counts[army_type])
	var composition := {}
	for army_type in ARMY_TYPES:
		composition[army_type] = float(ready.army_counts[army_type]) / float(total)
	var conversions: Dictionary = _rules.attribute_delta_conversions
	var martial_delta := int(general.attributes.martial) - int(definition.martial)
	var leadership_delta := int(general.attributes.leadership) - int(definition.leadership)
	var player := {
		"id": definition.id,
		"name": definition.name,
		"level": int(general.level),
		"experience": int(general.experience),
		"talent_id": general.active_talent_id,
		"troops": total,
		"max_troops": total,
		"troop_cap": int(ready.troop_cap),
		"morale": int(definition.combat.morale),
		"max_morale": 100,
		"attack": float(definition.combat.attack) + float(martial_delta) * float(conversions.martial_attack_per_point),
		"defense": float(definition.combat.defense) + float(leadership_delta) * float(conversions.leadership_defense_per_point),
		"attributes": general.attributes.duplicate(true),
		"army_counts": ready.army_counts.duplicate(true),
		"army_composition": composition,
	}
	var card_overrides := {}
	for card_id in ready.deck:
		var branch_id := String(campaign.get("card_upgrade_branches", {}).get(card_id, ""))
		if not branch_id.is_empty() and not card_overrides.has(card_id):
			var resolved := ResearchManagementServiceScript.resolve_card_definition(_card_by_id[card_id], branch_id)
			if not resolved.ok:
				return {"ok": false, "errors": resolved.errors, "requires_legacy_loadout_recovery": false}
			card_overrides[card_id] = resolved.card
	return {
		"ok": true,
		"errors": PackedStringArray(),
		"run_id": request.run_id,
		"expedition_id": request.expedition_id,
		"map_seed": int(request.map_seed),
		"general": player,
		"army_counts": ready.army_counts.duplicate(true),
		"base_deck": ready.base_deck.duplicate(),
		"exclusive_cards": ready.exclusive_cards.duplicate(),
		"deck": ready.deck.duplicate(),
		"card_upgrade_branches": campaign.get("card_upgrade_branches", {}).duplicate(true),
		"card_overrides": card_overrides,
	}


func default_army_counts(composition: Dictionary, total: int) -> Dictionary:
	var result := {"infantry": 0, "archer": 0, "cavalry": 0}
	var remainders := []
	var assigned := 0
	for index in ARMY_TYPES.size():
		var army_type: String = ARMY_TYPES[index]
		var raw := float(composition.get(army_type, 0.0)) * float(total)
		var base := int(floor(raw))
		result[army_type] = base
		assigned += base
		remainders.append({"army_type": army_type, "remainder": raw - float(base), "order": index})
	remainders.sort_custom(func(a, b):
		if is_equal_approx(float(a.remainder), float(b.remainder)):
			return int(a.order) < int(b.order)
		return float(a.remainder) > float(b.remainder)
	)
	for index in total - assigned:
		var army_type: String = remainders[index % remainders.size()].army_type
		result[army_type] = int(result[army_type]) + 1
	return result


func _troop_cap(general: Dictionary, definition: Dictionary) -> int:
	var leadership_delta := int(general.attributes.leadership) - int(definition.leadership)
	return int(definition.combat.troops) + int(leadership_delta * int(_rules.attribute_delta_conversions.leadership_troop_cap_per_point))


func _validate_army_counts(value: Variant, inventory: Dictionary, troop_cap: int) -> PackedStringArray:
	var errors := PackedStringArray()
	if not value is Dictionary:
		errors.append("deployment: army_counts must be an object")
		return errors
	var total := 0
	for army_type in ARMY_TYPES:
		if not value.has(army_type) or not _is_non_negative_whole_number(value[army_type]):
			errors.append("deployment: army count '%s' must be a non-negative integer" % army_type)
			continue
		var count := int(value[army_type])
		total += count
		if count > int(inventory.get(army_type, 0)):
			errors.append("deployment: army count '%s' exceeds inventory" % army_type)
	if total <= 0:
		errors.append("deployment: total troops must be positive")
	if total > troop_cap:
		errors.append("deployment: total troops exceed general troop cap %d" % troop_cap)
	return errors


func _find_general(generals: Array, general_id: String) -> Dictionary:
	for general in generals:
		if general is Dictionary and general.get("general_id", "") == general_id:
			return general
	return {}


func _failure(message: String) -> Dictionary:
	return {"ok": false, "errors": PackedStringArray([message]), "requires_legacy_loadout_recovery": false}


func _is_whole_number(value: Variant) -> bool:
	return value is int or (value is float and is_finite(value) and value == floor(value))


func _is_non_negative_whole_number(value: Variant) -> bool:
	return _is_whole_number(value) and value >= 0
