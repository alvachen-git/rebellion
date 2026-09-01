extends RefCounted
class_name BossModifierApplier

const MODIFIER_IDS := ["armory_destroyed", "beacon_destroyed", "granary_destroyed"]


static func validate(enemy: Dictionary, modifiers) -> PackedStringArray:
	var errors := PackedStringArray()
	if not modifiers is Dictionary:
		errors.append("boss_modifiers must be an object")
		return errors
	if modifiers.is_empty():
		return errors
	if enemy.get("tier", "") != "boss":
		errors.append("boss_modifiers can only be applied to a boss enemy")
		return errors
	if not enemy.get("boss_modifier_rules", null) is Dictionary:
		errors.append("boss enemy is missing boss_modifier_rules")
	for modifier_id in modifiers:
		if not MODIFIER_IDS.has(modifier_id):
			errors.append("unsupported boss modifier '%s'" % modifier_id)
		elif not modifiers[modifier_id] is bool:
			errors.append("boss modifier '%s' must be boolean" % modifier_id)
	return errors


static func apply(enemy_definition: Dictionary, talent_definition: Dictionary, modifiers: Dictionary) -> Dictionary:
	var enemy := enemy_definition.duplicate(true)
	var talent := talent_definition.duplicate(true)
	var applied := {}
	var rules: Dictionary = enemy.get("boss_modifier_rules", {})
	for modifier_id in MODIFIER_IDS:
		if not bool(modifiers.get(modifier_id, false)):
			continue
		var rule: Dictionary = rules.get(modifier_id, {})
		match modifier_id:
			"armory_destroyed":
				enemy.defense = rule.get("defense", enemy.get("defense", 0))
				_apply_skill_armor_overrides(enemy.skills, rule.get("armor_by_skill_id", {}))
				_apply_talent_armor_override(talent, int(rule.get("talent_armor", 0)))
			"beacon_destroyed":
				enemy.morale = rule.get("morale", enemy.get("morale", 0))
				_remove_skills(enemy.skills, rule.get("remove_skill_ids", []))
			"granary_destroyed":
				_remove_skills(enemy.skills, rule.get("remove_skill_ids", []))
		applied[modifier_id] = true
	return {"enemy": enemy, "talent": talent, "applied": applied}


static func _apply_skill_armor_overrides(skills: Array, amounts: Dictionary) -> void:
	for skill in skills:
		var skill_id: String = skill.get("id", "")
		if not amounts.has(skill_id):
			continue
		for effect in skill.get("effects", []):
			if effect.get("type", "") == "GainArmor":
				effect.amount = int(amounts[skill_id])


static func _apply_talent_armor_override(talent: Dictionary, amount: int) -> void:
	for effect in talent.get("effects", []):
		if effect.get("type", "") == "GainArmor":
			effect.amount = amount


static func _remove_skills(skills: Array, removed_ids: Array) -> void:
	for index in range(skills.size() - 1, -1, -1):
		if removed_ids.has(skills[index].get("id", "")):
			skills.remove_at(index)
