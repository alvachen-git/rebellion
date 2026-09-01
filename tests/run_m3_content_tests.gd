extends SceneTree

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")
const ConditionEvaluatorScript := preload("res://src/domain/combat/condition_evaluator.gd")

const M3_CARD_EFFECT_TYPES := {
	"card.public.general.assault": "DealDamage",
	"card.public.general.guard": "GainArmor",
	"card.public.general.inspire": "ModifyMorale",
	"card.public.general.change_orders": "DrawCards",
	"card.public.morale.feint": "ModifyMorale",
	"card.public.morale.war_cry": "ModifyMorale",
	"card.public.morale.press_advantage": "GainActionPoint",
	"card.public.cavalry.harass": "ModifyMorale",
	"card.public.cavalry.charge": "DealDamage",
	"card.public.cavalry.pursue": "DrawCards",
	"card.public.defense.shield_wall": "GainArmor",
	"card.public.defense.counter_stance": "RetaliateOnDamage",
	"card.public.defense.turn_defense_to_offense": "ConvertArmorToDamage",
	"card.public.archery.armor_piercing_arrow": "ModifyDefense",
	"card.public.archery.repeating_crossbow": "RepeatAttack",
	"card.public.archery.prepared_volley": "PrepareTaggedAttack",
	"card.general.zhao_lie.lone_breakthrough": "RepeatAttack",
	"card.general.zhou_jing.delayed_strike": "DealDamageFromArmor",
	"card.general.han_yue.formation_breaking_crossbow": "RepeatAttack",
}
const GENERAL_EXPECTATIONS := {
	"general.zhao_lie": {"talent": "talent.zhao_lie.break_formation", "build": "骑兵低士气连击", "army": "cavalry"},
	"general.zhou_jing": {"talent": "talent.zhou_jing.iron_wall", "build": "重步防御反击", "army": "infantry"},
	"general.han_yue": {"talent": "talent.han_yue.pierce_formation", "build": "弓弩持续破甲", "army": "archer"},
}
const TALENT_TRIGGERS := {
	"talent.zhao_lie.break_formation": "NthAttackCardPlayed",
	"talent.zhou_jing.iron_wall": "FirstArmorGainedFromCard",
	"talent.han_yue.pierce_formation": "FirstTaggedAttackCard",
}

var _passed := 0
var _failed := 0
var _registry


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_registry = ContentRegistryScript.new()
	_assert_true(_registry.load_all(), "M3 content registry loads without contract errors")
	_assert_equal(_registry.general_count(), 3, "exactly three Vertical Slice generals are registered")
	_assert_equal(_registry.talent_count(), 5, "three general and two elite enemy talents are registered")
	_assert_equal(M3_CARD_EFFECT_TYPES.size(), 19, "M3 contract enumerates exactly nineteen cards")
	_test_card_contracts()
	_test_general_contracts()
	_test_talent_contracts()
	_test_invalid_contracts_fail_readably()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_card_contracts() -> void:
	var context := _all_conditions_pass_context()
	for card_id in M3_CARD_EFFECT_TYPES:
		_assert_true(_registry.has_card(card_id), "%s is registered" % card_id)
		var card: Dictionary = _registry.get_card(card_id)
		_assert_true(_registry.validate_card_definition(card, card_id).is_empty(), "%s satisfies the full card contract" % card_id)
		var branches: Array = card.get("upgrade_branches", [])
		var branch_ids := {}
		for branch in branches:
			branch_ids[branch.get("id", "")] = true
		_assert_true(branches.size() == 2 and branch_ids.size() == 2, "%s defines two distinct permanent upgrade branches" % card_id)
		var availability := ConditionEvaluatorScript.evaluate_all(card.get("conditions", []), context)
		_assert_true(availability.passed, "%s has a satisfiable availability path" % card_id)
		_assert_true(_top_level_effect_types(card).has(M3_CARD_EFFECT_TYPES[card_id]), "%s exposes its identity-defining core effect" % card_id)


func _test_general_contracts() -> void:
	for general_id in GENERAL_EXPECTATIONS:
		var expected: Dictionary = GENERAL_EXPECTATIONS[general_id]
		_assert_true(_registry.has_general(general_id), "%s is registered" % general_id)
		var general: Dictionary = _registry.get_general(general_id)
		_assert_true(_registry.validate_general_definition(general, general_id).is_empty(), "%s satisfies the full general contract" % general_id)
		_assert_equal(general.starting_deck.size(), 20, "%s starts with exactly twenty cards" % general_id)
		_assert_equal(general.talent_id, expected.talent, "%s references its approved identity talent" % general_id)
		_assert_equal(general.presentation.build_name, expected.build, "%s retains its approved Build identity" % general_id)
		_assert_true(float(general.army_composition[expected.army]) >= 0.5, "%s meets its primary army threshold" % general_id)
		_assert_true(_deck_respects_ownership_and_limits(general), "%s deck respects exclusive ownership and copy limits" % general_id)


func _test_talent_contracts() -> void:
	for talent_id in TALENT_TRIGGERS:
		_assert_true(_registry.has_talent(talent_id), "%s is registered" % talent_id)
		var talent: Dictionary = _registry.get_talent(talent_id)
		_assert_true(_registry.validate_talent_definition(talent, talent_id).is_empty(), "%s satisfies the full talent contract" % talent_id)
		_assert_equal(talent.trigger.type, TALENT_TRIGGERS[talent_id], "%s uses the approved trigger boundary" % talent_id)
		_assert_true(_registry.has_general(talent.owner_general_id), "%s owner general reference resolves" % talent_id)


func _test_invalid_contracts_fail_readably() -> void:
	var production_card: Dictionary = _registry.get_card("card.public.general.assault")
	production_card.upgrade_branches = []
	production_card.presentation.description = ""
	var card_errors = _registry.validate_card_definition(production_card, "invalid.production.card")
	_assert_true(_contains_text(card_errors, "exactly two upgrade branches"), "production card without two upgrades is rejected")
	_assert_true(_contains_text(card_errors, "presentation.description"), "production card without readable text is rejected")

	var general: Dictionary = _registry.get_general("general.zhao_lie")
	general.army_composition.cavalry = 0.6
	var general_errors = _registry.validate_general_definition(general, "invalid.general")
	_assert_true(_contains_text(general_errors, "sum to 1.0"), "invalid general army composition is rejected")

	var talent: Dictionary = _registry.get_talent("talent.zhao_lie.break_formation")
	talent.trigger.type = "ReadFutureHand"
	var talent_errors = _registry.validate_talent_definition(talent, "invalid.talent")
	_assert_true(_contains_text(talent_errors, "unsupported talent trigger"), "unsupported talent trigger is rejected")


func _all_conditions_pass_context() -> Dictionary:
	return {
		"actor": {
			"morale": 100,
			"troops": 1,
			"max_troops": 100,
			"armor": 999,
			"defense": 0,
			"army_composition": {"infantry": 0.8, "archer": 0.8, "cavalry": 0.8},
			"statuses": {"test.ready": 1},
		},
		"target": {"morale": 0, "defense": 0, "statuses": {}},
		"turn_stats": {"cards_played": 9, "attack_cards_played": 9, "enemy_morale_lost": 99},
	}


func _top_level_effect_types(card: Dictionary) -> Array[String]:
	var types: Array[String] = []
	for effect in card.get("effects", []):
		types.append(effect.get("type", ""))
	return types


func _deck_respects_ownership_and_limits(general: Dictionary) -> bool:
	var copies := {}
	for card_id in general.starting_deck:
		if not _registry.has_card(card_id):
			return false
		var card: Dictionary = _registry.get_card(card_id)
		var owner_scope: String = card.owner_scope
		if owner_scope.begins_with("general:") and owner_scope != "general:%s" % general.id:
			return false
		copies[card_id] = int(copies.get(card_id, 0)) + 1
		if int(copies[card_id]) > int(card.copy_limit):
			return false
	return true


func _contains_text(values: PackedStringArray, needle: String) -> bool:
	for value in values:
		if needle in value:
			return true
	return false


func _assert_true(value: bool, message: String) -> void:
	if value:
		_passed += 1
		print("TEST PASS: %s" % message)
	else:
		_failed += 1
		push_error("TEST FAIL: %s" % message)


func _assert_equal(actual, expected, message: String) -> void:
	if actual == expected:
		_passed += 1
		print("TEST PASS: %s" % message)
	else:
		_failed += 1
		push_error("TEST FAIL: %s (expected=%s, actual=%s)" % [message, str(expected), str(actual)])
