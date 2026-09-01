extends RefCounted
class_name ContentRegistry

const DEFAULT_MANIFEST_PATH := "res://data/content/manifest.json"
const REQUIRED_CARD_FIELDS := [
	"id",
	"name",
	"rarity",
	"cost",
	"tags",
	"owner_scope",
	"copy_limit",
	"exhaust",
	"conditions",
	"effects",
	"upgrade_branches",
	"presentation",
]
const REQUIRED_TALENT_FIELDS := ["id", "name", "trigger", "effects", "presentation"]
const REQUIRED_GENERAL_FIELDS := [
	"id",
	"name",
	"martial",
	"leadership",
	"administration",
	"talent_id",
	"combat",
	"army_composition",
	"starting_deck",
	"presentation",
]
const ALLOWED_EFFECT_TYPES := {
	"DealDamage": true,
	"GainArmor": true,
	"ModifyMorale": true,
	"DrawCards": true,
	"GainActionPoint": true,
	"ModifyDefense": true,
	"ApplyStatus": true,
	"RepeatAttack": true,
	"ConsumeOwnMorale": true,
	"ConditionalEffect": true,
	"DealDamageFromArmor": true,
	"ConvertArmorToDamage": true,
	"RetaliateOnDamage": true,
	"PrepareTaggedAttack": true,
	"RestoreTroops": true,
	"ScaleIncomingMorale": true,
	"SuppressIntentTypeNextTurn": true,
}
const ALLOWED_CONDITION_TYPES := {
	"ArmyRatioAtLeast": true,
	"OwnMoraleAtLeast": true,
	"EnemyMoraleAtMost": true,
	"ArmorAtLeast": true,
	"CardsPlayedThisTurnAtLeast": true,
	"AttackCardsPlayedThisTurnAtLeast": true,
	"EnemyMoraleLostThisTurnAtLeast": true,
	"EnemyDefenseAtMost": true,
	"HasStatus": true,
	"OwnMoraleAtMost": true,
	"OwnTroopRatioAtMost": true,
}
const ALLOWED_TALENT_TRIGGER_TYPES := {
	"NthAttackCardPlayed": true,
	"FirstArmorGainedFromCard": true,
	"FirstTaggedAttackCard": true,
	"FirstMoraleLossEachPlayerTurn": true,
	"InitialArmorBroken": true,
}
const ALLOWED_ENEMY_TIERS := {"normal": true, "elite": true, "boss": true}
const ALLOWED_INTENT_TYPES := {"attack": true, "defend": true, "disrupt": true, "recover": true}

var _cards: Dictionary = {}
var _enemies: Dictionary = {}
var _talents: Dictionary = {}
var _generals: Dictionary = {}
var _errors: PackedStringArray = []


func load_all(manifest_path: String = DEFAULT_MANIFEST_PATH) -> bool:
	_cards.clear()
	_enemies.clear()
	_talents.clear()
	_generals.clear()
	_errors.clear()
	var manifest_result := _load_json_object(manifest_path)
	if not manifest_result.ok:
		_errors.append(manifest_result.error)
		return false

	var manifest: Dictionary = manifest_result.value
	if not manifest.has("content_version") or not manifest.get("content_version") is String:
		_errors.append("%s: missing string content_version" % manifest_path)
	var card_paths = manifest.get("cards", null)
	if not card_paths is Array:
		_errors.append("%s: cards must be an array" % manifest_path)
		return false

	for raw_path in card_paths:
		if not raw_path is String:
			_errors.append("%s: card path must be a string" % manifest_path)
			continue
		_load_card(raw_path)
	var enemy_paths = manifest.get("enemies", [])
	if not enemy_paths is Array:
		_errors.append("%s: enemies must be an array" % manifest_path)
		return false
	for raw_path in enemy_paths:
		if not raw_path is String:
			_errors.append("%s: enemy path must be a string" % manifest_path)
			continue
		_load_enemy(raw_path)
	var talent_paths = manifest.get("talents", [])
	if not talent_paths is Array:
		_errors.append("%s: talents must be an array" % manifest_path)
		return false
	for raw_path in talent_paths:
		if not raw_path is String:
			_errors.append("%s: talent path must be a string" % manifest_path)
			continue
		_load_talent(raw_path)
	var general_paths = manifest.get("generals", [])
	if not general_paths is Array:
		_errors.append("%s: generals must be an array" % manifest_path)
		return false
	for raw_path in general_paths:
		if not raw_path is String:
			_errors.append("%s: general path must be a string" % manifest_path)
			continue
		_load_general(raw_path)
	_validate_content_references()

	return _errors.is_empty()


func validate_card_definition(data: Dictionary, source: String = "<memory>") -> PackedStringArray:
	var errors := PackedStringArray()
	for field in REQUIRED_CARD_FIELDS:
		if not data.has(field):
			errors.append("%s: missing card field '%s'" % [source, field])

	if data.has("id") and (not data.id is String or data.id.strip_edges().is_empty()):
		errors.append("%s: card id must be a non-empty string" % source)
	if data.has("cost") and (not data.cost is float and not data.cost is int or data.cost < 0):
		errors.append("%s: card cost must be a non-negative number" % source)
	if data.has("copy_limit") and (not data.copy_limit is float and not data.copy_limit is int or data.copy_limit < 1):
		errors.append("%s: card copy_limit must be at least 1" % source)
	if data.has("tags") and not data.tags is Array:
		errors.append("%s: card tags must be an array" % source)
	if data.has("conditions"):
		if not data.conditions is Array:
			errors.append("%s: card conditions must be an array" % source)
		else:
			for index in data.conditions.size():
				_validate_typed_entry(data.conditions[index], source, "condition", index, ALLOWED_CONDITION_TYPES, errors)
	if data.has("effects"):
		if not data.effects is Array or data.effects.is_empty():
			errors.append("%s: card effects must be a non-empty array" % source)
		else:
			for index in data.effects.size():
				_validate_effect_entry(data.effects[index], source, "effect", index, errors)
	if not bool(data.get("development_only", false)):
		var copy_limits := {"basic": 3, "advanced": 2, "rare": 1, "secret": 1}
		var rarity: String = data.get("rarity", "")
		if not copy_limits.has(rarity):
			errors.append("%s: production card has unsupported rarity '%s'" % [source, rarity])
		elif int(data.get("copy_limit", 0)) != int(copy_limits[rarity]):
			errors.append("%s: production card copy_limit does not match rarity '%s'" % [source, rarity])
		_validate_upgrade_branches(data.get("upgrade_branches", null), source, errors)
		var presentation = data.get("presentation", null)
		if not presentation is Dictionary or String(presentation.get("description", "")).strip_edges().is_empty():
			errors.append("%s: production card requires presentation.description" % source)
	return errors


func validate_talent_definition(data: Dictionary, source: String = "<memory>") -> PackedStringArray:
	var errors := PackedStringArray()
	for field in REQUIRED_TALENT_FIELDS:
		if not data.has(field):
			errors.append("%s: missing talent field '%s'" % [source, field])
	if data.has("id") and (not data.id is String or data.id.strip_edges().is_empty()):
		errors.append("%s: talent id must be a non-empty string" % source)
	var has_general_owner := not String(data.get("owner_general_id", "")).is_empty()
	var has_enemy_owner := not String(data.get("owner_enemy_id", "")).is_empty()
	if has_general_owner == has_enemy_owner:
		errors.append("%s: talent requires exactly one owner_general_id or owner_enemy_id" % source)
	var trigger = data.get("trigger", null)
	if not trigger is Dictionary:
		errors.append("%s: talent trigger must be an object" % source)
	elif not ALLOWED_TALENT_TRIGGER_TYPES.has(trigger.get("type", "")):
		errors.append("%s: unsupported talent trigger '%s'" % [source, trigger.get("type", "")])
	else:
		if trigger.type == "InitialArmorBroken":
			if int(trigger.get("per_battle_limit", 0)) < 1:
				errors.append("%s: InitialArmorBroken requires per_battle_limit of at least 1" % source)
		elif int(trigger.get("per_turn_limit", 0)) < 1:
			errors.append("%s: talent trigger requires per_turn_limit of at least 1" % source)
		if trigger.type == "NthAttackCardPlayed" and int(trigger.get("count", 0)) < 1:
			errors.append("%s: NthAttackCardPlayed requires a positive count" % source)
		if trigger.type == "FirstTaggedAttackCard" and String(trigger.get("tag", "")).is_empty():
			errors.append("%s: FirstTaggedAttackCard requires a tag" % source)
	var effects = data.get("effects", null)
	if not effects is Array or effects.is_empty():
		errors.append("%s: talent effects must be a non-empty array" % source)
	else:
		for index in effects.size():
			_validate_effect_entry(effects[index], source, "talent effect", index, errors)
	return errors


func validate_enemy_definition(data: Dictionary, source: String = "<memory>") -> PackedStringArray:
	var errors := PackedStringArray()
	for field in ["id", "name", "troops", "morale", "attack", "defense", "army_composition", "skills"]:
		if not data.has(field):
			errors.append("%s: missing enemy field '%s'" % [source, field])
	if data.has("id") and (not data.id is String or data.id.strip_edges().is_empty()):
		errors.append("%s: enemy id must be a non-empty string" % source)
	for attribute in ["troops", "morale", "attack", "defense"]:
		if data.has(attribute) and (not data[attribute] is float and not data[attribute] is int or data[attribute] < 0):
			errors.append("%s: enemy %s must be a non-negative number" % [source, attribute])
	var composition = data.get("army_composition", null)
	if not composition is Dictionary:
		errors.append("%s: enemy army_composition must be an object" % source)
	else:
		var total := 0.0
		for army_type in ["infantry", "archer", "cavalry"]:
			if not composition.has(army_type):
				errors.append("%s: enemy army_composition missing '%s'" % [source, army_type])
			total += float(composition.get(army_type, 0.0))
		if not is_equal_approx(total, 1.0):
			errors.append("%s: enemy army_composition must sum to 1.0" % source)
	var skills = data.get("skills", null)
	if not skills is Array or skills.is_empty():
		errors.append("%s: enemy skills must be a non-empty array" % source)
	else:
		var skill_ids := {}
		for index in skills.size():
			var skill = skills[index]
			if not skill is Dictionary:
				errors.append("%s: skill[%d] must be an object" % [source, index])
				continue
			for field in ["id", "intent_type", "weight", "effects"]:
				if not skill.has(field):
					errors.append("%s: skill[%d] missing field '%s'" % [source, index, field])
			var skill_id := String(skill.get("id", ""))
			if skill_id.is_empty() or skill_ids.has(skill_id):
				errors.append("%s: skill[%d] id must be non-empty and unique" % [source, index])
			skill_ids[skill_id] = true
			if not ALLOWED_INTENT_TYPES.has(skill.get("intent_type", "")):
				errors.append("%s: skill[%d] has unsupported intent_type '%s'" % [source, index, skill.get("intent_type", "")])
			if int(skill.get("weight", 0)) < 1:
				errors.append("%s: skill[%d] weight must be at least 1" % [source, index])
			if int(skill.get("cooldown", 0)) < 0:
				errors.append("%s: skill[%d] cooldown cannot be negative" % [source, index])
			var conditions = skill.get("conditions", [])
			if not conditions is Array:
				errors.append("%s: skill[%d] conditions must be an array" % [source, index])
			else:
				for condition_index in conditions.size():
					_validate_typed_entry(conditions[condition_index], source, "skill[%d] condition" % index, condition_index, ALLOWED_CONDITION_TYPES, errors)
			var effects = skill.get("effects", null)
			if not effects is Array or effects.is_empty():
				errors.append("%s: skill[%d] effects must be a non-empty array" % [source, index])
			else:
				for effect_index in effects.size():
					_validate_effect_entry(effects[effect_index], source, "skill[%d] effect" % index, effect_index, errors)
	if not bool(data.get("development_only", false)):
		for field in ["tier", "max_troops", "max_morale", "presentation"]:
			if not data.has(field):
				errors.append("%s: production enemy missing field '%s'" % [source, field])
		if not ALLOWED_ENEMY_TIERS.has(data.get("tier", "")):
			errors.append("%s: production enemy has unsupported tier '%s'" % [source, data.get("tier", "")])
		var presentation = data.get("presentation", null)
		if not presentation is Dictionary or String(presentation.get("description", "")).strip_edges().is_empty():
			errors.append("%s: production enemy requires presentation.description" % source)
		if skills is Array:
			for index in skills.size():
				if not skills[index] is Dictionary:
					continue
				for field in ["name", "cooldown", "conditions"]:
					if not skills[index].has(field):
						errors.append("%s: production skill[%d] missing field '%s'" % [source, index, field])
				if String(skills[index].get("name", "")).strip_edges().is_empty():
					errors.append("%s: production skill[%d] requires a name" % [source, index])
	return errors


func validate_general_definition(data: Dictionary, source: String = "<memory>") -> PackedStringArray:
	var errors := PackedStringArray()
	for field in REQUIRED_GENERAL_FIELDS:
		if not data.has(field):
			errors.append("%s: missing general field '%s'" % [source, field])
	if data.has("id") and (not data.id is String or data.id.strip_edges().is_empty()):
		errors.append("%s: general id must be a non-empty string" % source)
	for attribute in ["martial", "leadership", "administration"]:
		if data.has(attribute) and (not data[attribute] is float and not data[attribute] is int or data[attribute] < 0):
			errors.append("%s: general %s must be a non-negative number" % [source, attribute])
	var combat = data.get("combat", null)
	if not combat is Dictionary:
		errors.append("%s: general combat must be an object" % source)
	else:
		for field in ["troops", "morale", "attack", "defense"]:
			if not combat.has(field):
				errors.append("%s: general combat missing field '%s'" % [source, field])
	var composition = data.get("army_composition", null)
	if not composition is Dictionary:
		errors.append("%s: general army_composition must be an object" % source)
	else:
		var total := 0.0
		for army_type in ["infantry", "archer", "cavalry"]:
			if not composition.has(army_type):
				errors.append("%s: army_composition missing '%s'" % [source, army_type])
			total += float(composition.get(army_type, 0.0))
		if not is_equal_approx(total, 1.0):
			errors.append("%s: army_composition must sum to 1.0" % source)
	if not data.get("starting_deck", null) is Array:
		errors.append("%s: general starting_deck must be an array" % source)
	elif data.starting_deck.size() != 20:
		errors.append("%s: Vertical Slice general starting_deck must contain exactly 20 cards" % source)
	return errors


func has_card(card_id: String) -> bool:
	return _cards.has(card_id)


func get_card(card_id: String) -> Dictionary:
	return _cards.get(card_id, {}).duplicate(true)


func card_count() -> int:
	return _cards.size()


func has_enemy(enemy_id: String) -> bool:
	return _enemies.has(enemy_id)


func get_enemy(enemy_id: String) -> Dictionary:
	return _enemies.get(enemy_id, {}).duplicate(true)


func enemy_count() -> int:
	return _enemies.size()


func has_talent(talent_id: String) -> bool:
	return _talents.has(talent_id)


func get_talent(talent_id: String) -> Dictionary:
	return _talents.get(talent_id, {}).duplicate(true)


func talent_count() -> int:
	return _talents.size()


func has_general(general_id: String) -> bool:
	return _generals.has(general_id)


func get_general(general_id: String) -> Dictionary:
	return _generals.get(general_id, {}).duplicate(true)


func general_count() -> int:
	return _generals.size()


func get_errors() -> PackedStringArray:
	return _errors.duplicate()


func _load_card(path: String) -> void:
	var card_result := _load_json_object(path)
	if not card_result.ok:
		_errors.append(card_result.error)
		return
	var card: Dictionary = card_result.value
	var validation_errors := validate_card_definition(card, path)
	if not validation_errors.is_empty():
		_errors.append_array(validation_errors)
		return
	var card_id: String = card.id
	if _cards.has(card_id):
		_errors.append("%s: duplicate card id '%s'" % [path, card_id])
		return
	_cards[card_id] = card


func _load_enemy(path: String) -> void:
	var enemy_result := _load_json_object(path)
	if not enemy_result.ok:
		_errors.append(enemy_result.error)
		return
	var enemy: Dictionary = enemy_result.value
	var validation_errors := validate_enemy_definition(enemy, path)
	if not validation_errors.is_empty():
		_errors.append_array(validation_errors)
		return
	var enemy_id: String = enemy.get("id", "")
	if enemy_id.is_empty():
		_errors.append("%s: enemy id must be a non-empty string" % path)
		return
	if _enemies.has(enemy_id):
		_errors.append("%s: duplicate enemy id '%s'" % [path, enemy_id])
		return
	_enemies[enemy_id] = enemy


func _load_talent(path: String) -> void:
	var result := _load_json_object(path)
	if not result.ok:
		_errors.append(result.error)
		return
	var talent: Dictionary = result.value
	var validation_errors := validate_talent_definition(talent, path)
	if not validation_errors.is_empty():
		_errors.append_array(validation_errors)
		return
	var talent_id: String = talent.id
	if _talents.has(talent_id):
		_errors.append("%s: duplicate talent id '%s'" % [path, talent_id])
		return
	_talents[talent_id] = talent


func _load_general(path: String) -> void:
	var result := _load_json_object(path)
	if not result.ok:
		_errors.append(result.error)
		return
	var general: Dictionary = result.value
	var validation_errors := validate_general_definition(general, path)
	if not validation_errors.is_empty():
		_errors.append_array(validation_errors)
		return
	var general_id: String = general.id
	if _generals.has(general_id):
		_errors.append("%s: duplicate general id '%s'" % [path, general_id])
		return
	_generals[general_id] = general


func _validate_content_references() -> void:
	for talent_id in _talents:
		var talent: Dictionary = _talents[talent_id]
		var general_owner_id: String = talent.get("owner_general_id", "")
		var enemy_owner_id: String = talent.get("owner_enemy_id", "")
		if not general_owner_id.is_empty() and not _generals.has(general_owner_id):
			_errors.append("talent '%s' references unknown general '%s'" % [talent_id, general_owner_id])
		if not enemy_owner_id.is_empty() and not _enemies.has(enemy_owner_id):
			_errors.append("talent '%s' references unknown enemy '%s'" % [talent_id, enemy_owner_id])
	for enemy_id in _enemies:
		var enemy: Dictionary = _enemies[enemy_id]
		var enemy_talent_id: String = enemy.get("talent_id", "")
		if enemy_talent_id.is_empty():
			continue
		if not _talents.has(enemy_talent_id):
			_errors.append("enemy '%s' references unknown talent '%s'" % [enemy_id, enemy_talent_id])
		elif _talents[enemy_talent_id].get("owner_enemy_id", "") != enemy_id:
			_errors.append("enemy '%s' talent owner does not match" % enemy_id)
	for general_id in _generals:
		var general: Dictionary = _generals[general_id]
		var talent_id: String = general.get("talent_id", "")
		if not _talents.has(talent_id):
			_errors.append("general '%s' references unknown talent '%s'" % [general_id, talent_id])
		elif _talents[talent_id].get("owner_general_id", "") != general_id:
			_errors.append("general '%s' talent owner does not match" % general_id)
		var copies: Dictionary = {}
		for card_id in general.get("starting_deck", []):
			if not _cards.has(card_id):
				_errors.append("general '%s' references unknown card '%s'" % [general_id, card_id])
				continue
			copies[card_id] = int(copies.get(card_id, 0)) + 1
			var owner_scope: String = _cards[card_id].get("owner_scope", "")
			if owner_scope.begins_with("general:") and owner_scope != "general:%s" % general_id:
				_errors.append("general '%s' cannot use exclusive card '%s'" % [general_id, card_id])
		for card_id in copies:
			if int(copies[card_id]) > int(_cards[card_id].get("copy_limit", 1)):
				_errors.append("general '%s' exceeds copy limit for '%s'" % [general_id, card_id])
	for card_id in _cards:
		var owner_scope: String = _cards[card_id].get("owner_scope", "")
		if owner_scope == "public":
			continue
		if owner_scope.begins_with("general:"):
			var owner_id := owner_scope.trim_prefix("general:")
			if not _generals.has(owner_id):
				_errors.append("card '%s' references unknown owner general '%s'" % [card_id, owner_id])
		else:
			_errors.append("card '%s' has invalid owner_scope '%s'" % [card_id, owner_scope])


func _load_json_object(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "%s: file does not exist" % path}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "%s: unable to open file" % path}
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return {"ok": false, "error": "%s: root JSON value must be an object" % path}
	return {"ok": true, "value": parsed}


func _validate_typed_entry(
	entry,
	source: String,
	kind: String,
	index: int,
	allowed_types: Dictionary,
	errors: PackedStringArray
) -> void:
	if not entry is Dictionary:
		errors.append("%s: %s[%d] must be an object" % [source, kind, index])
		return
	var type_name = entry.get("type", null)
	if not type_name is String or not allowed_types.has(type_name):
		errors.append("%s: %s[%d] has unsupported type '%s'" % [source, kind, index, str(type_name)])


func _validate_effect_entry(entry, source: String, kind: String, index: int, errors: PackedStringArray) -> void:
	_validate_typed_entry(entry, source, kind, index, ALLOWED_EFFECT_TYPES, errors)
	if not entry is Dictionary or not ALLOWED_EFFECT_TYPES.has(entry.get("type", "")):
		return
	var effect_type: String = entry.type
	match effect_type:
		"DealDamage":
			_require_effect_fields(entry, ["base_power", "target"], source, kind, index, errors)
		"GainArmor", "ModifyMorale", "DrawCards", "GainActionPoint", "ModifyDefense", "ConsumeOwnMorale", "RestoreTroops":
			_require_effect_fields(entry, ["amount", "target"], source, kind, index, errors)
		"ApplyStatus":
			_require_effect_fields(entry, ["status_id", "target"], source, kind, index, errors)
		"RepeatAttack":
			_require_effect_fields(entry, ["base_power", "times", "target"], source, kind, index, errors)
		"DealDamageFromArmor":
			_require_effect_fields(entry, ["ratio", "clear_armor_after", "target"], source, kind, index, errors)
		"ConvertArmorToDamage":
			_require_effect_fields(entry, ["ratio", "consume_ratio", "target"], source, kind, index, errors)
		"RetaliateOnDamage":
			_require_effect_fields(entry, ["base_power", "uses", "target"], source, kind, index, errors)
		"PrepareTaggedAttack":
			_require_effect_fields(entry, ["tag", "multiplier", "uses", "target"], source, kind, index, errors)
		"ScaleIncomingMorale":
			_require_effect_fields(entry, ["multiplier", "target"], source, kind, index, errors)
		"SuppressIntentTypeNextTurn":
			_require_effect_fields(entry, ["intent_type", "duration"], source, kind, index, errors)
		"ConditionalEffect":
			var conditions = entry.get("conditions", null)
			var nested_effects = entry.get("effects", null)
			if not conditions is Array or conditions.is_empty():
				errors.append("%s: %s[%d] ConditionalEffect requires conditions" % [source, kind, index])
			else:
				for condition_index in conditions.size():
					_validate_typed_entry(conditions[condition_index], source, "%s[%d] condition" % [kind, index], condition_index, ALLOWED_CONDITION_TYPES, errors)
			if not nested_effects is Array or nested_effects.is_empty():
				errors.append("%s: %s[%d] ConditionalEffect requires effects" % [source, kind, index])
			else:
				for effect_index in nested_effects.size():
					_validate_effect_entry(nested_effects[effect_index], source, "%s[%d] effect" % [kind, index], effect_index, errors)


func _require_effect_fields(
	entry: Dictionary,
	fields: Array,
	source: String,
	kind: String,
	index: int,
	errors: PackedStringArray
) -> void:
	for field in fields:
		if not entry.has(field):
			errors.append("%s: %s[%d] '%s' missing field '%s'" % [source, kind, index, entry.get("type", ""), field])


func _validate_upgrade_branches(branches, source: String, errors: PackedStringArray) -> void:
	if not branches is Array or branches.size() != 2:
		errors.append("%s: production card must define exactly two upgrade branches" % source)
		return
	var ids: Dictionary = {}
	for index in branches.size():
		var branch = branches[index]
		if not branch is Dictionary:
			errors.append("%s: upgrade branch[%d] must be an object" % [source, index])
			continue
		for field in ["id", "name", "overrides"]:
			if not branch.has(field):
				errors.append("%s: upgrade branch[%d] missing field '%s'" % [source, index, field])
		var branch_id: String = branch.get("id", "")
		if branch_id.is_empty() or ids.has(branch_id):
			errors.append("%s: upgrade branch[%d] id must be non-empty and unique" % [source, index])
		if String(branch.get("name", "")).strip_edges().is_empty():
			errors.append("%s: upgrade branch[%d] name must be non-empty" % [source, index])
		ids[branch_id] = true
		var overrides = branch.get("overrides", null)
		if not overrides is Dictionary or overrides.is_empty():
			errors.append("%s: upgrade branch[%d] overrides must be a non-empty object" % [source, index])
		elif overrides.has("effects"):
			if not overrides.effects is Array or overrides.effects.is_empty():
				errors.append("%s: upgrade branch[%d] effects must be non-empty" % [source, index])
			else:
				for effect_index in overrides.effects.size():
					_validate_effect_entry(overrides.effects[effect_index], source, "upgrade branch[%d] effect" % index, effect_index, errors)
		if overrides is Dictionary and overrides.has("conditions"):
			if not overrides.conditions is Array:
				errors.append("%s: upgrade branch[%d] conditions must be an array" % [source, index])
			else:
				for condition_index in overrides.conditions.size():
					_validate_typed_entry(overrides.conditions[condition_index], source, "upgrade branch[%d] condition" % index, condition_index, ALLOWED_CONDITION_TYPES, errors)
