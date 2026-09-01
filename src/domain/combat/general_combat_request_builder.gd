extends RefCounted
class_name GeneralCombatRequestBuilder


static func build(
	general_id: String,
	enemy: Dictionary,
	seed: int,
	content_registry,
	battle_id: String = "m3-general-battle"
) -> Dictionary:
	if not content_registry.has_general(general_id):
		return {"ok": false, "error": "找不到武将：%s" % general_id, "request": {}}
	if enemy.is_empty():
		return {"ok": false, "error": "敌军定义不能为空", "request": {}}
	var general: Dictionary = content_registry.get_general(general_id)
	var combat: Dictionary = general.combat
	var player := {
		"id": general.id,
		"name": general.name,
		"talent_id": general.talent_id,
		"is_player_character": false,
		"troops": int(combat.troops),
		"max_troops": int(combat.troops),
		"morale": int(combat.morale),
		"max_morale": 100,
		"attack": float(combat.attack),
		"defense": float(combat.defense),
		"army_composition": general.army_composition.duplicate(true),
	}
	return {
		"ok": true,
		"error": "",
		"request": {
			"battle_id": battle_id,
			"seed": seed,
			"player": player,
			"enemy": enemy.duplicate(true),
			"deck": general.starting_deck.duplicate(),
		},
	}
