extends RefCounted
class_name EnemyIntentPlanner

const ConditionEvaluatorScript := preload("res://src/domain/combat/condition_evaluator.gd")


static func choose_intent(
	skills: Array,
	enemy_public: Dictionary,
	player_public: Dictionary,
	turn_stats: Dictionary,
	cooldowns: Dictionary,
	rng,
	excluded_intent_types: Array = []
) -> Dictionary:
	var eligible: Array[Dictionary] = []
	var total_weight := 0
	for raw_skill in skills:
		if not raw_skill is Dictionary:
			continue
		var skill: Dictionary = raw_skill
		if bool(skill.get("queued_only", false)):
			continue
		if excluded_intent_types.has(skill.get("intent_type", "")):
			continue
		var skill_id: String = skill.get("id", "")
		if int(cooldowns.get(skill_id, 0)) > 0:
			continue
		var condition_result := ConditionEvaluatorScript.evaluate_all(
			skill.get("conditions", []),
			{"actor": enemy_public, "target": player_public, "turn_stats": turn_stats}
		)
		if not condition_result.passed:
			continue
		var weight := maxi(int(skill.get("weight", 1)), 0)
		if weight == 0:
			continue
		eligible.append(skill)
		total_weight += weight

	if eligible.is_empty():
		return {}
	var roll: int = rng.next_int(1, total_weight)
	var cursor := 0
	for skill in eligible:
		cursor += int(skill.get("weight", 1))
		if roll <= cursor:
			return skill.duplicate(true)
	return eligible.back().duplicate(true)
