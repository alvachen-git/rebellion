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
var _errors: PackedStringArray = []


func load_all(manifest_path: String = DEFAULT_MANIFEST_PATH) -> bool:
	_cards.clear()
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
