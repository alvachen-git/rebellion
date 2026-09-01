extends RefCounted
class_name DamageCalculator


static func calculate(
	base_power: float,
	attacker_attack: float,
	defender_defense: float,
	condition_multiplier: float = 1.0
) -> int:
	var safe_power := maxf(base_power, 0.0)
	var safe_attack := maxf(attacker_attack, 0.0)
	var safe_defense := maxf(defender_defense, 0.0)
	var safe_multiplier := maxf(condition_multiplier, 0.0)
	var attack_scaled := safe_power * (1.0 + safe_attack / 100.0)
	var condition_scaled := attack_scaled * safe_multiplier
	var defense_scaled := condition_scaled * 100.0 / (100.0 + safe_defense)
	return maxi(roundi(defense_scaled), 0)


static func preview(effect: Dictionary, attacker: Dictionary, defender: Dictionary) -> int:
	return calculate(
		float(effect.get("base_power", 0.0)),
		float(attacker.get("attack", 0.0)),
		float(defender.get("defense", 0.0)),
		float(effect.get("multiplier", 1.0))
	)
