extends RefCounted
class_name ConditionEvaluator


static func evaluate_all(conditions: Array, context: Dictionary) -> Dictionary:
	for condition in conditions:
		var result := evaluate(condition, context)
		if not result.passed:
			return result
	return {"passed": true, "reason": ""}


static func evaluate(condition: Dictionary, context: Dictionary) -> Dictionary:
	var actor: Dictionary = context.get("actor", {})
	var target: Dictionary = context.get("target", {})
	var turn_stats: Dictionary = context.get("turn_stats", {})
	var condition_type: String = condition.get("type", "")
	match condition_type:
		"ArmyRatioAtLeast":
			var army_type: String = condition.get("army_type", "")
			var required_ratio := float(condition.get("ratio", 0.0))
			var actual_ratio := float(actor.get("army_composition", {}).get(army_type, 0.0))
			return _result(
				actual_ratio >= required_ratio,
				"需要%s比例至少%d%%" % [army_type, roundi(required_ratio * 100.0)]
			)
		"OwnMoraleAtLeast":
			var value := int(condition.get("value", 0))
			return _result(int(actor.get("morale", 0)) >= value, "我方士气需要至少%d" % value)
		"EnemyMoraleAtMost":
			var value := int(condition.get("value", 0))
			return _result(int(target.get("morale", 0)) <= value, "敌方士气需要不高于%d" % value)
		"ArmorAtLeast":
			var value := int(condition.get("value", 0))
			return _result(int(actor.get("armor", 0)) >= value, "我方护甲需要至少%d" % value)
		"CardsPlayedThisTurnAtLeast":
			var value := int(condition.get("value", 0))
			return _result(int(turn_stats.get("cards_played", 0)) >= value, "本回合需要先打出%d张牌" % value)
		"AttackCardsPlayedThisTurnAtLeast":
			var value := int(condition.get("value", 0))
			return _result(int(turn_stats.get("attack_cards_played", 0)) >= value, "本回合需要先打出%d张攻击牌" % value)
		"EnemyMoraleLostThisTurnAtLeast":
			var value := int(condition.get("value", 0))
			return _result(int(turn_stats.get("enemy_morale_lost", 0)) >= value, "本回合需要先使敌方损失%d士气" % value)
		"EnemyDefenseAtMost":
			var value := int(condition.get("value", 0))
			return _result(int(target.get("defense", 0)) <= value, "敌方防御需要不高于%d" % value)
		"HasStatus":
			var status_id: String = condition.get("status_id", "")
			return _result(actor.get("statuses", {}).has(status_id), "需要状态：%s" % status_id)
		_:
			return {"passed": false, "reason": "不支持的条件：%s" % condition_type}


static func _result(passed: bool, reason: String) -> Dictionary:
	return {"passed": passed, "reason": "" if passed else reason}
