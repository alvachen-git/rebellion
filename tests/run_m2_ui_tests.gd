extends SceneTree

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")
const CombatScene := preload("res://src/ui/combat/combat_screen.tscn")
const CombatantStageViewScript := preload("res://src/ui/components/combatant_stage_view.gd")

var _passed := 0
var _failed := 0
var _registry


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_registry = ContentRegistryScript.new()
	_assert_true(_registry.load_all(), "M2 content registry loads")
	await _test_default_layout_and_labels()
	await _test_combatant_template_routing()
	await _test_card_click_updates_shared_combat_state()
	await _test_card_hover_affordance()
	await _test_unavailable_card_explains_reason()
	await _test_end_turn_refreshes_hand_and_intent()
	await _test_retreat_confirmation_result_state()
	await _test_victory_and_restart_flow()
	await _test_m3_playable_selection_rebuilds_battle()
	await _test_boss_phase_trigger_is_explained_in_ui()
	await _test_layout_at_target_resolutions()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_default_layout_and_labels() -> void:
	var screen = await _create_screen(_request(_standard_deck(), 1600))
	_assert_true(screen.has_node("Page/Battlefield/IntentPanel"), "battlefield exposes a dedicated intent panel")
	_assert_true(screen.has_node("Page/Battlefield/PlayerCombatant"), "battlefield gives the player a dedicated image stage")
	_assert_true(screen.has_node("Page/Battlefield/EnemyCombatant"), "battlefield gives the enemy a dedicated image stage")
	_assert_true(screen.has_node("BattleBackdrop"), "battle background is a screen-wide layer behind battlefield and command UI")
	_assert_true(screen.has_node("Page/Command/Stack/HandScroll"), "hand is the primary card-based interaction")
	_assert_equal(screen.card_button_count(), 5, "opening hand renders five card buttons")
	_assert_true("第 1 回合" in screen.get_node("%TurnLabel").text, "turn label is visible")
	_assert_true(not screen.get_node("%IntentLabel").text.is_empty(), "enemy intent text is visible")
	_assert_true("3 / 3" in screen.get_node("%ActionLabel").text, "action point budget is visible")
	_assert_true("1000/1000" in screen.get_node("%PlayerCombatant").persistent_status_text(), "player troop values stay visible below the portrait")
	_assert_true("兵力" not in screen.get_node("%PlayerCombatant").persistent_status_text(), "persistent troop bar omits its Chinese label")
	_assert_true("士气" not in screen.get_node("%EnemyCombatant").persistent_status_text(), "persistent morale bar omits its Chinese label")
	_assert_true(not screen.get_node("%PlayerCombatant").battlefield_name_visible(), "player name is hidden from persistent battlefield chrome")
	_assert_true(not screen.get_node("%EnemyCombatant").battlefield_name_visible(), "enemy name is hidden from persistent battlefield chrome")
	var compact_bar: Vector2 = screen.get_node("%PlayerCombatant").status_bar_size()
	_assert_true(compact_bar.x <= 170.0 and compact_bar.y <= 20.0, "troop and morale bars use the selected ink-stroke footprint")
	_assert_true(ResourceLoader.exists("res://assets/art/ui/status_brush_mask.png"), "status bars use the selected real brush-stroke asset")
	_assert_true(not screen.get_node("%PlayerCombatant").details_visible(), "secondary player stats start collapsed")
	_assert_true(not screen.get_node("%EnemyCombatant").details_visible(), "secondary enemy stats start collapsed")
	var backdrop: Control = screen.get_node("%BattleBackdrop")
	var command: Control = screen.get_node("Page/Command")
	_assert_true(backdrop.get_global_rect().end.y >= command.get_global_rect().end.y, "continuous background reaches behind the full card-command area")
	var player_portrait := screen.get_node("%PlayerCombatant").find_child("PortraitButton", true, false) as Button
	player_portrait.mouse_entered.emit()
	_assert_true(screen.get_node("%PlayerCombatant").details_visible(), "hovering the player image expands detailed stats")
	_assert_true("护甲" in screen.get_node("%PlayerCombatant").detailed_status_text(), "hover detail includes armor")
	_assert_true("攻击" in screen.get_node("%PlayerCombatant").detailed_status_text(), "hover detail includes attack")
	_assert_true("兵种" in screen.get_node("%PlayerCombatant").detailed_status_text(), "hover detail includes army composition")
	_assert_true("率军武将" in screen.get_node("%PlayerCombatant").detailed_status_text(), "hover detail owns the hidden battlefield name")
	player_portrait.mouse_exited.emit()
	_assert_true(not screen.get_node("%PlayerCombatant").details_visible(), "leaving the player image collapses detailed stats")
	await _destroy_screen(screen)


func _test_combatant_template_routing() -> void:
	var cases := [
		{"id": "general.zhou_jing", "side": CombatantStageViewScript.Side.PLAYER, "composition": {"infantry": 0.75, "archer": 0.15, "cavalry": 0.10}, "expected": "combatant.rebel.infantry"},
		{"id": "general.han_yue", "side": CombatantStageViewScript.Side.PLAYER, "composition": {"infantry": 0.25, "archer": 0.65, "cavalry": 0.10}, "expected": "combatant.rebel.archer"},
		{"id": "general.zhao_lie", "side": CombatantStageViewScript.Side.PLAYER, "composition": {"infantry": 0.20, "archer": 0.10, "cavalry": 0.70}, "expected": "combatant.rebel.cavalry"},
		{"id": "enemy.normal.city_defenders", "side": CombatantStageViewScript.Side.ENEMY, "composition": {"infantry": 0.85, "archer": 0.15, "cavalry": 0.0}, "expected": "combatant.government.infantry"},
		{"id": "enemy.normal.crossbow_company", "side": CombatantStageViewScript.Side.ENEMY, "composition": {"infantry": 0.20, "archer": 0.80, "cavalry": 0.0}, "expected": "combatant.government.archer"},
		{"id": "enemy.elite.he_wei", "side": CombatantStageViewScript.Side.ENEMY, "composition": {"infantry": 0.90, "archer": 0.0, "cavalry": 0.10}, "expected": "combatant.government.heavy"},
		{"id": "enemy.boss.yan_cheng", "side": CombatantStageViewScript.Side.ENEMY, "composition": {"infantry": 0.75, "archer": 0.25, "cavalry": 0.0}, "expected": "combatant.government.heavy"},
	]
	for case in cases:
		var view = CombatantStageViewScript.new()
		view.configure({"id": case.id, "name": case.id, "army_composition": case.composition}, case.side)
		root.add_child(view)
		await process_frame
		_assert_equal(view.presentation_asset_id(), case.expected, "%s routes to its dominant battlefield template" % case.id)
		view.queue_free()
		await process_frame


func _test_card_click_updates_shared_combat_state() -> void:
	var screen = await _create_screen(_request(_standard_deck(), 1601))
	var before: Dictionary = screen.combat_snapshot()
	var attack_index: int = before.deck.hand.find("dev.basic_attack")
	_assert_true(attack_index >= 0, "test hand contains an attack card")
	var card_button: Button = screen.get_node("%HandContainer").get_child(attack_index)
	card_button.pressed.emit()
	await process_frame
	var after: Dictionary = screen.combat_snapshot()
	_assert_true(after.deck.hand.size() == before.deck.hand.size() - 1, "card button pressed signal reaches combat command")
	_assert_true(after.enemy.troops < before.enemy.troops, "card interaction changes enemy troops")
	_assert_equal(after.action_points, before.action_points - 1, "action label state follows the domain controller")
	_assert_equal(screen.card_button_count(), 4, "played card is removed from rendered hand")
	await _destroy_screen(screen)


func _test_unavailable_card_explains_reason() -> void:
	var request := _request(["dev.m0_validation_sample"], 1602)
	request.player.army_composition.cavalry = 0.1
	var screen = await _create_screen(request)
	var result: Dictionary = screen.play_card_at(0)
	_assert_true(not result.ok, "ineligible card is not played")
	_assert_true("20%" in screen.get_node("%FeedbackLabel").text, "UI displays the exact failed army condition")
	await _destroy_screen(screen)


func _test_card_hover_affordance() -> void:
	var screen = await _create_screen(_request(_standard_deck(), 1605))
	var card_button: Button = screen.get_node("%HandContainer").get_child(0)
	card_button.mouse_entered.emit()
	await create_timer(0.12).timeout
	_assert_true(card_button.scale.x > 1.0, "card hover raises visual emphasis")
	_assert_true(not screen.get_node("%FeedbackLabel").text.is_empty(), "card hover provides contextual feedback")
	var feedback_style := screen.get_node("Page/Command/Stack/StatusRow/FeedbackBadge").get_theme_stylebox("panel") as StyleBoxFlat
	_assert_true(feedback_style != null and feedback_style.bg_color.a <= 0.01, "card hover feedback has no long rectangular backing")
	card_button.mouse_exited.emit()
	await _destroy_screen(screen)


func _test_end_turn_refreshes_hand_and_intent() -> void:
	var request := _request(_standard_deck(), 1603)
	request.enemy.skills = [_attack_skill(45)]
	var screen = await _create_screen(request)
	var before: Dictionary = screen.combat_snapshot()
	screen.get_node("%EndTurnButton").pressed.emit()
	await process_frame
	var state: Dictionary = screen.combat_snapshot()
	_assert_true(state.turn == 2, "end-turn button pressed signal reaches combat command")
	_assert_equal(state.turn, 2, "enemy action resolves before the second player turn")
	_assert_true(state.player.troops < before.player.troops, "revealed enemy attack reduces player troops")
	_assert_true("敌军发动【强攻】" in screen.get_node("%FeedbackLabel").text, "enemy attack is named in persistent feedback")
	_assert_true("兵力 -" in screen.get_node("%ImpactLabel").text, "enemy damage is shown as impact text")
	_assert_true(screen.get_node("%ImpactLabel").visible, "enemy action displays immediate battlefield feedback")
	_assert_true(screen.card_button_count() > 0, "new turn renders a refreshed hand")
	_assert_true(not screen.get_node("%IntentLabel").text.is_empty(), "next enemy intent remains visible")
	await _destroy_screen(screen)


func _test_retreat_confirmation_result_state() -> void:
	var screen = await _create_screen(_request(_standard_deck(), 1604))
	screen.get_node("%RetreatButton").pressed.emit()
	_assert_true(screen.get_node("%RetreatDialog").visible, "retreat first opens a confirmation dialog")
	screen.get_node("%RetreatDialog").confirmed.emit()
	await process_frame
	_assert_equal(screen.combat_snapshot().result.status, "retreated", "confirmed retreat uses the distinct domain result")
	_assert_true(screen.get_node("%ResultOverlay").visible, "retreat displays the battle result overlay")
	_assert_true("撤军" in screen.get_node("%ResultTitle").text, "result title communicates retreat")
	await _destroy_screen(screen)


func _test_victory_and_restart_flow() -> void:
	var request := _request(["dev.demoralize"], 1606)
	request.enemy.morale = 25
	var screen = await _create_screen(request)
	var card_button: Button = screen.get_node("%HandContainer").get_child(0)
	card_button.pressed.emit()
	await process_frame
	_assert_equal(screen.combat_snapshot().result.status, "victory", "card interaction can reach a victory result")
	_assert_true("告捷" in screen.get_node("%ResultTitle").text, "victory result has a distinct title")
	screen.get_node("%RestartButton").pressed.emit()
	await process_frame
	_assert_true(screen.combat_snapshot().status == "active", "restart button creates a fresh active battle")
	_assert_true(not screen.get_node("%ResultOverlay").visible, "restart closes the result overlay")
	await _destroy_screen(screen)


func _test_m3_playable_selection_rebuilds_battle() -> void:
	var screen = await _create_screen({})
	var general_selector: OptionButton = screen.get_node("%GeneralSelector")
	var enemy_selector: OptionButton = screen.get_node("%EnemySelector")
	_assert_equal(general_selector.item_count, 3, "playable selector exposes the three approved Builds")
	_assert_equal(enemy_selector.item_count, 8, "playable selector exposes five normal, two elite, and one boss enemy")
	general_selector.select(1)
	general_selector.item_selected.emit(1)
	enemy_selector.select(6)
	enemy_selector.item_selected.emit(6)
	_assert_true("重步防御反击" in screen.get_node("%SelectionHint").text, "selection hint updates to the chosen Build")
	screen.get_node("%StartSelectedButton").pressed.emit()
	await process_frame
	var state: Dictionary = screen.combat_snapshot()
	_assert_equal(state.player.id, "general.zhou_jing", "battle selection starts with Zhou Jing")
	_assert_equal(state.enemy.id, "enemy.elite.he_wei", "battle selection starts against He Wei")
	_assert_equal(state.enemy.armor, 180, "selected He Wei battle carries initial black armor")
	_assert_equal(state.seed, 10, "selected Build uses its deterministic preview seed")
	_assert_true("周靖" in screen.get_node("%PlayerCombatant").display_name_text(), "battlefield updates the selected general name")
	_assert_true("贺巍" in screen.get_node("%EnemyCombatant").display_name_text(), "battlefield updates the selected enemy name")
	_assert_equal(screen.card_button_count(), 5, "selected Build deals a five-card opening hand")
	enemy_selector.select(7)
	enemy_selector.item_selected.emit(7)
	_assert_true("守城主将" in screen.get_node("%SelectionHint").text, "selection hint exposes Yan Cheng's boss identity")
	screen.get_node("%StartSelectedButton").pressed.emit()
	await process_frame
	state = screen.combat_snapshot()
	_assert_equal(state.enemy.id, "enemy.boss.yan_cheng", "battle selection can start against Yan Cheng")
	_assert_equal(state.enemy.troops, 1750, "selected Yan Cheng battle carries full boss troops")
	_assert_true("严成" in screen.get_node("%EnemyCombatant").display_name_text(), "battlefield updates the boss name")
	await _destroy_screen(screen)


func _test_boss_phase_trigger_is_explained_in_ui() -> void:
	var request := _request(["card.public.general.assault", "card.public.general.assault"], 2410)
	request.enemy = _registry.get_enemy("enemy.boss.yan_cheng")
	request.enemy.troops = 928
	var screen = await _create_screen(request)
	var first_index: int = screen.combat_snapshot().deck.hand.find("card.public.general.assault")
	screen.play_card_at(first_index)
	var second_index: int = screen.combat_snapshot().deck.hand.find("card.public.general.assault")
	screen.play_card_at(second_index)
	_assert_equal(screen.combat_snapshot().enemy_phase, 2, "UI battle reaches Yan Cheng phase two through real card actions")
	_assert_true("死守孤城" in screen.get_node("%FeedbackLabel").text, "UI names Yan Cheng's phase talent when it triggers")
	_assert_true("锁定下一次特殊行动" in screen.get_node("%FeedbackLabel").text, "UI explains the forced action consequence")
	await _destroy_screen(screen)


func _test_layout_at_target_resolutions() -> void:
	for resolution in [Vector2i(1600, 900), Vector2i(1280, 720)]:
		root.size = resolution
		var screen = await _create_screen(_request(_standard_deck(), resolution.x))
		await process_frame
		var end_button: Button = screen.get_node("%EndTurnButton")
		var start_button: Button = screen.get_node("%StartSelectedButton")
		var hand_scroll: ScrollContainer = screen.get_node("Page/Command/Stack/HandScroll")
		var hand_container: Container = screen.get_node("%HandContainer")
		var button_logical_end: Vector2 = end_button.get_global_rect().end
		var scale_factor := minf(float(resolution.x) / 1600.0, float(resolution.y) / 900.0)
		var button_screen_end := button_logical_end * scale_factor
		_assert_true(
			button_screen_end.x <= resolution.x + 1.0 and button_screen_end.y <= resolution.y + 1.0,
			"end-turn action fits at %dx%d (screen end %.1f, %.1f)" % [
				resolution.x,
				resolution.y,
				button_screen_end.x,
				button_screen_end.y,
			]
		)
		_assert_true(hand_scroll.size.y >= 190.0, "hand remains readable at %dx%d" % [resolution.x, resolution.y])
		_assert_true(float(hand_container.get("card_separation")) < 0.0, "floating hand overlaps slightly at %dx%d" % [resolution.x, resolution.y])
		_assert_true(absf((hand_container.get_child(0) as Control).rotation_degrees) > 0.1, "floating hand keeps a fan silhouette at %dx%d" % [resolution.x, resolution.y])
		_assert_true(start_button.get_global_rect().end.x <= 1600.0, "battle setup action fits the logical canvas at %dx%d" % [resolution.x, resolution.y])
		_assert_equal(screen.card_button_count(), 5, "all opening cards render at %dx%d" % [resolution.x, resolution.y])
		await _destroy_screen(screen)


func _create_screen(request: Dictionary):
	var screen = CombatScene.instantiate()
	screen.battle_request_override = request
	root.add_child(screen)
	await process_frame
	await process_frame
	return screen


func _destroy_screen(screen) -> void:
	screen.queue_free()
	await process_frame


func _request(deck: Array, seed: int) -> Dictionary:
	return {
		"battle_id": "m2-ui-test",
		"seed": seed,
		"player": {
			"id": "dev.zhao_lie",
			"is_player_character": false,
			"troops": 1000,
			"max_troops": 1000,
			"morale": 85,
			"max_morale": 100,
			"attack": 25,
			"defense": 20,
			"army_composition": {"infantry": 0.35, "archer": 0.15, "cavalry": 0.5},
		},
		"enemy": _registry.get_enemy("dev.baseline_enemy"),
		"deck": deck,
	}


func _standard_deck() -> Array:
	return [
		"dev.basic_attack",
		"dev.guard",
		"dev.demoralize",
		"dev.tactical_cycle",
		"dev.effect_matrix",
	]


func _attack_skill(base_power: int) -> Dictionary:
	return {
		"id": "test.ui_attack",
		"intent_type": "attack",
		"weight": 1,
		"conditions": [],
		"effects": [{"type": "DealDamage", "base_power": base_power, "target": "opponent"}],
	}


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
