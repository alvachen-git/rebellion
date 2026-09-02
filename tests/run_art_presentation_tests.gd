extends SceneTree

const CatalogScript := preload("res://src/ui/presentation/visual_asset_catalog.gd")
const CardViewScript := preload("res://src/ui/components/card_view.gd")
const GeneralCardViewScript := preload("res://src/ui/components/general_card_view.gd")
const ArtIconScript := preload("res://src/ui/components/art_icon.gd")
const QingluThemeScript := preload("res://src/ui/theme/qinglu_theme.gd")
const MotionPolicyScript := preload("res://src/ui/presentation/motion_policy.gd")

const CARD_IDS := [
	"card.public.archery.armor_piercing_arrow", "card.public.general.assault",
	"card.public.cavalry.charge", "card.public.cavalry.harass", "card.public.cavalry.pursue",
	"card.public.general.change_orders", "card.public.defense.counter_stance",
	"card.general.zhou_jing.delayed_strike", "card.public.morale.feint",
	"card.general.han_yue.formation_breaking_crossbow", "card.public.general.guard",
	"card.public.general.inspire", "card.general.zhao_lie.lone_breakthrough",
	"card.public.archery.prepared_volley", "card.public.morale.press_advantage",
	"card.public.archery.repeating_crossbow", "card.public.defense.shield_wall",
	"card.public.defense.turn_defense_to_offense", "card.public.morale.war_cry",
]
const GENERAL_IDS := ["general.zhao_lie", "general.zhou_jing", "general.han_yue"]
const ENEMY_IDS := [
	"enemy.normal.city_defenders", "enemy.normal.crossbow_company", "enemy.normal.local_militia",
	"enemy.normal.overseer_unit", "enemy.normal.patrol_inspector", "enemy.elite.gao_wu",
	"enemy.elite.he_wei", "enemy.boss.yan_cheng",
]
const ICON_IDS := [
	"resource.grain", "resource.wood", "resource.iron", "army.infantry", "army.archer",
	"army.cavalry", "status.troops", "status.morale", "status.armor", "status.action",
	"status.injury", "status.death", "node.combat", "node.objective", "node.event", "node.loot",
]
const SCREEN_IDS := [
	"screen.main_city.stage1", "screen.deck_editor", "screen.deployment", "screen.expedition_map",
	"screen.combat.heyuan", "screen.settlement", "screen.failure",
]
const COMBATANT_IDS := [
	"combatant.rebel.infantry", "combatant.government.infantry", "combatant.rebel.archer",
	"combatant.government.archer", "combatant.rebel.cavalry", "combatant.government.heavy",
]

var _passed := 0
var _failed := 0


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_test_catalog_contract()
	_test_fonts_and_licenses()
	await _test_card_view_contract()
	await _test_general_card_contract()
	await _test_icons_at_required_sizes()
	_test_reduced_motion_policy()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_catalog_contract() -> void:
	var catalog = CatalogScript.new()
	_assert_true(catalog.load_catalog(), "visual asset catalog loads")
	_assert_equal(CARD_IDS.size(), 19, "vertical slice has exactly 19 required card ids")
	_assert_equal(GENERAL_IDS.size(), 3, "vertical slice has exactly 3 required general ids")
	_assert_equal(ENEMY_IDS.size(), 8, "vertical slice has exactly 8 required enemy ids")
	var required: Array = []
	required.append_array(CARD_IDS)
	required.append_array(GENERAL_IDS)
	required.append_array(ENEMY_IDS)
	required.append_array(SCREEN_IDS)
	required.append_array(COMBATANT_IDS)
	for icon_id in ICON_IDS:
		required.append("icon.%s" % icon_id)
	var errors := catalog.validate(required)
	_assert_equal(errors.size(), 0, "every required stable id resolves to an existing presentation asset: %s" % "; ".join(errors))
	for combatant_id in COMBATANT_IDS:
		_assert_equal(String(catalog.entry(combatant_id).get("kind", "")), "combatant_standee", "%s is registered as a battlefield standee" % combatant_id)
	for representative_id in [
		"card.public.general.assault", "card.public.general.guard", "card.public.morale.war_cry",
		"card.public.archery.repeating_crossbow", "card.public.cavalry.charge",
		"card.general.zhou_jing.delayed_strike", "general.zhao_lie", "general.zhou_jing",
		"general.han_yue", "enemy.normal.patrol_inspector", "enemy.elite.gao_wu", "enemy.boss.yan_cheng",
	]:
		_assert_true(String(catalog.entry(representative_id).get("status", "")).contains("representative"), "%s is bound to a representative-review asset" % representative_id)


func _test_fonts_and_licenses() -> void:
	_assert_true(ResourceLoader.exists("res://assets/fonts/source_han/SourceHanSansCN-VF.ttf"), "Source Han Sans CN imports")
	_assert_true(ResourceLoader.exists("res://assets/fonts/source_han/SourceHanSerifCN-VF.ttf"), "Source Han Serif CN imports")
	_assert_true(FileAccess.file_exists("res://assets/fonts/source_han/LICENSE-SourceHanSans.txt"), "Source Han Sans license is bundled")
	_assert_true(FileAccess.file_exists("res://assets/fonts/source_han/LICENSE-SourceHanSerif.txt"), "Source Han Serif license is bundled")
	var theme := QingluThemeScript.create()
	_assert_true(theme.default_font != null, "Qinglu theme uses the bundled Chinese sans font")
	_assert_true(QingluThemeScript.serif_font() != null, "Qinglu title font uses the bundled Chinese serif font")


func _test_card_view_contract() -> void:
	var card := {
		"id": "card.general.zhou_jing.delayed_strike", "name": "后发制人", "cost": 1,
		"rarity": "rare", "owner_scope": "general:general.zhou_jing", "copy_limit": 1,
		"tags": ["attack", "exhaust"], "presentation": {"description": "护甲充足时发动反击。"},
	}
	for density in [CardViewScript.Density.FULL, CardViewScript.Density.COMPACT, CardViewScript.Density.THUMBNAIL]:
		var view = CardViewScript.new()
		view.configure(card, {"available": true, "selected": true, "upgraded": true, "exhausted": true}, 72, density)
		root.add_child(view)
		await process_frame
		_assert_equal(view.card_id(), card.id, "CardView density %d keeps the stable card id" % density)
		_assert_equal(view.display_density(), density, "CardView exposes requested density %d" % density)
		_assert_true(view.tooltip_text.contains("预计伤害 72"), "CardView displays provided preview damage without calculating it")
		view.queue_free()
		await process_frame
	var locked = CardViewScript.new()
	locked.configure(card, {"available": false, "locked": true, "reason": "军学未解锁"}, 0, CardViewScript.Density.FULL)
	root.add_child(locked)
	await process_frame
	_assert_true(locked.disabled and locked.availability_reason() == "军学未解锁", "locked CardView carries explicit non-color reason")
	locked.queue_free()
	var back = CardViewScript.new()
	back.configure(card, {"available": true, "face_down": true}, 0, CardViewScript.Density.THUMBNAIL)
	root.add_child(back)
	await process_frame
	_assert_true(back.get_child_count() > 0, "shared CardView provides a card-back presentation")
	back.queue_free()


func _test_general_card_contract() -> void:
	var healthy := {
		"general_id": "general.zhao_lie", "name": "赵烈", "level": 1,
		"status": "active", "injury": {"status": "healthy"},
		"attributes": {"martial": 84, "leadership": 72, "administration": 24},
		"presentation": {"build_name": "士气骑兵猛攻"},
	}
	var view = GeneralCardViewScript.new()
	view.configure(healthy, {"available": true, "selected": true}, GeneralCardViewScript.Density.FULL)
	root.add_child(view)
	await process_frame
	_assert_equal(view.general_id(), "general.zhao_lie", "GeneralCardView binds the stable general id")
	_assert_true(not view.disabled and view.tooltip_text.contains("可出征"), "healthy general card is actionable with text status")
	view.queue_free()
	var deceased := healthy.duplicate(true)
	deceased.status = "deceased"
	var dead_view = GeneralCardViewScript.new()
	dead_view.configure(deceased, {"available": false}, GeneralCardViewScript.Density.COMPACT)
	root.add_child(dead_view)
	await process_frame
	_assert_true(dead_view.disabled and dead_view.tooltip_text.contains("阵亡"), "deceased general card is disabled with explicit text status")
	dead_view.queue_free()


func _test_icons_at_required_sizes() -> void:
	for pixel_size in [16, 24, 32]:
		for icon_id in ICON_IDS:
			var icon = ArtIconScript.new()
			icon.configure(icon_id, icon_id, pixel_size)
			root.add_child(icon)
			await process_frame
			_assert_equal(icon.custom_minimum_size, Vector2(pixel_size, pixel_size), "%s supports %dpx and a text tooltip" % [icon_id, pixel_size])
			_assert_true(icon.tooltip_text == icon_id, "%s has a non-color text label" % icon_id)
			icon.queue_free()


func _test_reduced_motion_policy() -> void:
	var previous = ProjectSettings.get_setting(MotionPolicyScript.SETTING_PATH, false)
	ProjectSettings.set_setting(MotionPolicyScript.SETTING_PATH, true)
	_assert_true(MotionPolicyScript.reduced(), "reduced-motion setting disables optional presentation tweens")
	ProjectSettings.set_setting(MotionPolicyScript.SETTING_PATH, previous)


func _assert_true(condition: bool, label: String) -> void:
	if condition:
		_passed += 1
		print("TEST PASS: %s" % label)
	else:
		_failed += 1
		push_error("TEST FAIL: %s" % label)


func _assert_equal(actual, expected, label: String) -> void:
	_assert_true(actual == expected, "%s (expected=%s actual=%s)" % [label, str(expected), str(actual)])
