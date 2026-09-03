extends RefCounted
class_name SaveContentReferenceValidator

const ExpeditionMapGeneratorScript := preload("res://src/domain/expedition/expedition_map_generator.gd")


func validate(envelope: Dictionary, registry: RefCounted) -> PackedStringArray:
	var errors := PackedStringArray()
	var campaign = envelope.get("campaign", null)
	if not campaign is Dictionary:
		errors.append("save references: campaign must be an object")
		return errors
	var roster_ids := {}
	for index in campaign.get("generals", []).size():
		var general = campaign.generals[index]
		if not general is Dictionary:
			continue
		var general_id := String(general.get("general_id", ""))
		roster_ids[general_id] = true
		if not bool(general.get("is_player_character", false)) and not registry.has_general(general_id):
			errors.append("save references: general[%d] references missing general '%s'" % [index, general_id])
		_validate_talent_id(String(general.get("core_talent_id", "")), "general[%d].core_talent_id" % index, registry, errors)
		_validate_talent_id(String(general.get("active_talent_id", "")), "general[%d].active_talent_id" % index, registry, errors)
		for card_id in general.get("unlocked_exclusive_cards", []):
			_validate_card_id(String(card_id), "general[%d].unlocked_exclusive_cards" % index, registry, errors)
	for card_id in campaign.get("unlocked_public_cards", []):
		_validate_card_id(String(card_id), "unlocked_public_cards", registry, errors)
	for card_id in campaign.get("card_upgrade_branches", {}).keys():
		_validate_card_id(String(card_id), "card_upgrade_branches", registry, errors)
	_validate_card_ids(campaign.get("base_loadout", []), "base_loadout", registry, errors)
	for index in campaign.get("territories", []).size():
		var territory = campaign.territories[index]
		if territory is Dictionary:
			var territory_id := String(territory.get("territory_id", ""))
			if not registry.has_territory(territory_id):
				errors.append("save references: territory[%d] references missing territory '%s'" % [index, territory_id])
	for index in campaign.get("pending_long_term_effects", []).size():
		var effect = campaign.pending_long_term_effects[index]
		if not effect is Dictionary:
			continue
		_validate_expedition_id(String(effect.get("expedition_id", "")), "pending_long_term_effects[%d]" % index, registry, errors)
		var effect_general_id := String(effect.get("general_id", ""))
		if not roster_ids.has(effect_general_id):
			errors.append("save references: pending_long_term_effects[%d] references general '%s' outside campaign roster" % [index, effect_general_id])
	for index in campaign.get("settlement_history", []).size():
		var record = campaign.settlement_history[index]
		if record is Dictionary:
			_validate_expedition_id(String(record.get("expedition_id", "")), "settlement_history[%d]" % index, registry, errors)
	var expedition = envelope.get("expedition", null)
	if expedition is Dictionary:
		if expedition.has("expedition_id"):
			_validate_expedition_id(String(expedition.expedition_id), "expedition", registry, errors)
		_validate_expedition_nodes(expedition, registry, errors)
		_validate_expedition_actor(expedition.get("general", null), "expedition.general", roster_ids, registry, errors)
		_validate_card_ids(expedition.get("deck", []), "expedition.deck", registry, errors)
		_validate_card_ids(expedition.get("temporary_cards", []), "expedition.temporary_cards", registry, errors)
		_validate_card_ids(expedition.get("pending_card_unlocks", []), "expedition.pending_card_unlocks", registry, errors)
		_validate_card_overrides(expedition.get("card_overrides", {}), "expedition.card_overrides", registry, errors)
		var pending_combat = expedition.get("pending_combat", null)
		if pending_combat is Dictionary and not pending_combat.is_empty():
			_validate_expedition_actor(pending_combat.get("player", null), "expedition.pending_combat.player", roster_ids, registry, errors)
			_validate_card_ids(pending_combat.get("deck", []), "expedition.pending_combat.deck", registry, errors)
			_validate_card_overrides(pending_combat.get("card_overrides", {}), "expedition.pending_combat.card_overrides", registry, errors)
			var enemy = pending_combat.get("enemy", null)
			if enemy is Dictionary:
				var enemy_id := String(enemy.get("id", ""))
				if not registry.has_enemy(enemy_id):
					errors.append("save references: expedition.pending_combat.enemy references missing enemy '%s'" % enemy_id)
				_validate_talent_id(String(enemy.get("talent_id", "")), "expedition.pending_combat.enemy.talent_id", registry, errors)
		var pending_encounter = expedition.get("pending_encounter", null)
		if pending_encounter is Dictionary:
			for choice in pending_encounter.get("choices", []):
				if not choice is Dictionary:
					continue
				var card_id := String(choice.get("card_id", choice.get("effects", {}).get("add_temporary_card", "")))
				if not card_id.is_empty(): _validate_card_id(card_id, "expedition.pending_encounter", registry, errors)
				var enemy_id := String(choice.get("combat_enemy_id", ""))
				if not enemy_id.is_empty() and not registry.has_enemy(enemy_id):
					errors.append("save references: expedition.pending_encounter references missing enemy '%s'" % enemy_id)
		var pending_report = expedition.get("pending_combat_report", null)
		if pending_report is Dictionary and not pending_report.is_empty():
			var report_enemy_id := String(pending_report.get("enemy_id", ""))
			if not registry.has_enemy(report_enemy_id):
				errors.append("save references: expedition.pending_combat_report references missing enemy '%s'" % report_enemy_id)
			var gained_item_id := String(pending_report.get("item_gained", ""))
			if not gained_item_id.is_empty():
				var item_found := false
				for item in expedition.get("temporary_items", []):
					if item is Dictionary and item.get("item_id", "") == gained_item_id:
						item_found = true
						break
				if not item_found:
					errors.append("save references: expedition.pending_combat_report item '%s' is not present in the expedition inventory" % gained_item_id)
	return errors


func _validate_expedition_actor(actor: Variant, source: String, roster_ids: Dictionary, registry: RefCounted, errors: PackedStringArray) -> void:
	if not actor is Dictionary:
		return
	var general_id := String(actor.get("id", ""))
	if not roster_ids.has(general_id) and not registry.has_general(general_id):
		errors.append("save references: %s references missing general '%s'" % [source, general_id])
	_validate_talent_id(String(actor.get("talent_id", "")), "%s.talent_id" % source, registry, errors)


func _validate_card_ids(card_ids: Variant, source: String, registry: RefCounted, errors: PackedStringArray) -> void:
	if not card_ids is Array:
		return
	for card_id in card_ids:
		_validate_card_id(String(card_id), source, registry, errors)


func _validate_card_id(card_id: String, source: String, registry: RefCounted, errors: PackedStringArray) -> void:
	if not registry.has_card(card_id):
		errors.append("save references: %s references missing card '%s'" % [source, card_id])


func _validate_card_overrides(value: Variant, source: String, registry: RefCounted, errors: PackedStringArray) -> void:
	if not value is Dictionary:
		return
	for card_id in value:
		_validate_card_id(String(card_id), source, registry, errors)
		var definition = value[card_id]
		if not definition is Dictionary or String(definition.get("id", "")) != String(card_id):
			errors.append("save references: %s override '%s' must contain the matching definition id" % [source, card_id])
		elif registry.has_method("validate_card_definition"):
			for error in registry.validate_card_definition(definition, "%s.%s" % [source, card_id]):
				errors.append("save references: %s" % error)


func _validate_talent_id(talent_id: String, source: String, registry: RefCounted, errors: PackedStringArray) -> void:
	if not talent_id.is_empty() and not registry.has_talent(talent_id):
		errors.append("save references: %s references missing talent '%s'" % [source, talent_id])


func _validate_expedition_id(expedition_id: String, source: String, registry: RefCounted, errors: PackedStringArray) -> void:
	if not registry.has_expedition(expedition_id):
		errors.append("save references: %s references missing expedition '%s'" % [source, expedition_id])


func _validate_expedition_nodes(expedition: Dictionary, registry: RefCounted, errors: PackedStringArray) -> void:
	var expedition_id := String(expedition.get("expedition_id", ""))
	if not registry.has_expedition(expedition_id):
		return
	var node_ids := {}
	var definition: Dictionary = registry.get_expedition(expedition_id)
	var nodes: Array = definition.get("nodes", [])
	if int(expedition.get("generator_version", 1)) >= 2:
		var generated: Dictionary = ExpeditionMapGeneratorScript.generate(definition, int(expedition.get("seed", 0)), int(expedition.get("generator_version", 2)))
		if not generated.ok:
			errors.append("save references: cannot regenerate expedition map")
		else:
			nodes = generated.map.nodes
	for node in nodes:
		if node is Dictionary:
			node_ids[String(node.get("id", ""))] = true
	var route = expedition.get("route", null)
	if route is Dictionary:
		_validate_node_id(String(route.get("current_node_id", "")), "expedition.route.current_node_id", node_ids, errors)
		for field in ["visited_node_ids", "completed_node_ids", "revealed_node_ids", "available_next_node_ids"]:
			for node_id in route.get(field, []):
				_validate_node_id(String(node_id), "expedition.route.%s" % field, node_ids, errors)
	for index in expedition.get("resolution_history", []).size():
		var resolution = expedition.resolution_history[index]
		if resolution is Dictionary:
			_validate_node_id(String(resolution.get("node_id", "")), "expedition.resolution_history[%d].node_id" % index, node_ids, errors)
	var pending_resolution = expedition.get("pending_node_resolution", null)
	if pending_resolution is Dictionary and not pending_resolution.is_empty():
		_validate_node_id(String(pending_resolution.get("node_id", "")), "expedition.pending_node_resolution.node_id", node_ids, errors)
	var pending = expedition.get("pending_combat", null)
	if pending is Dictionary:
		var context = pending.get("expedition_context", null)
		if context is Dictionary:
			_validate_node_id(String(context.get("node_id", "")), "expedition.pending_combat.expedition_context.node_id", node_ids, errors)
	var pending_report = expedition.get("pending_combat_report", null)
	if pending_report is Dictionary and not pending_report.is_empty():
		_validate_node_id(String(pending_report.get("node_id", "")), "expedition.pending_combat_report.node_id", node_ids, errors)


func _validate_node_id(node_id: String, source: String, node_ids: Dictionary, errors: PackedStringArray) -> void:
	if not node_ids.has(node_id):
		errors.append("save references: %s references missing expedition node '%s'" % [source, node_id])
