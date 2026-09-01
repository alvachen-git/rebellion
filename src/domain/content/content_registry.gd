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
}

var _cards: Dictionary = {}
var _enemies: Dictionary = {}
var _errors: PackedStringArray = []


func load_all(manifest_path: String = DEFAULT_MANIFEST_PATH) -> bool:
	_cards.clear()
	_enemies.clear()
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
				_validate_typed_entry(data.effects[index], source, "effect", index, ALLOWED_EFFECT_TYPES, errors)
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
	var required_fields := ["id", "name", "troops", "morale", "attack", "defense", "army_composition", "skills"]
	for field in required_fields:
		if not enemy.has(field):
			_errors.append("%s: missing enemy field '%s'" % [path, field])
	if not enemy.get("skills", null) is Array or enemy.get("skills", []).is_empty():
		_errors.append("%s: enemy skills must be a non-empty array" % path)
	else:
		for index in enemy.skills.size():
			var skill = enemy.skills[index]
			if not skill is Dictionary:
				_errors.append("%s: skill[%d] must be an object" % [path, index])
				continue
			for field in ["id", "intent_type", "weight", "effects"]:
				if not skill.has(field):
					_errors.append("%s: skill[%d] missing field '%s'" % [path, index, field])
			if skill.get("effects", null) is Array:
				for effect_index in skill.effects.size():
					_validate_typed_entry(skill.effects[effect_index], path, "skill effect", effect_index, ALLOWED_EFFECT_TYPES, _errors)
	if not _errors.is_empty():
		return
	var enemy_id: String = enemy.get("id", "")
	if enemy_id.is_empty():
		_errors.append("%s: enemy id must be a non-empty string" % path)
		return
	if _enemies.has(enemy_id):
		_errors.append("%s: duplicate enemy id '%s'" % [path, enemy_id])
		return
	_enemies[enemy_id] = enemy


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
