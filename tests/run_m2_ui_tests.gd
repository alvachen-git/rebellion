extends SceneTree

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")
const CombatScene := preload("res://src/ui/combat/combat_screen.tscn")

var _passed := 0
var _failed := 0
var _registry


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_registry = ContentRegistryScript.new()
	_assert_true(_registry.load_all(), "M2 content registry loads")
	await _test_default_layout_and_labels()
	await _test_card_click_updates_shared_combat_state()
	await _test_card_hover_affordance()
	await _test_unavailable_card_explains_reason()
	await _test_end_turn_refreshes_hand_and_intent()
	await _test_retreat_confirmation_result_state()
	await _test_victory_and_restart_flow()
	await _test_layout_at_target_resolutions()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_default_layout_and_labels() -> void:
	var screen = await _create_screen(_request(_standard_deck(), 1600))
	_assert_true(screen.has_node("Page/Battlefield/IntentPanel"), "battlefield exposes a dedicated intent panel")
	_assert_true(screen.has_node("Page/Command/Stack/HandScroll"), "hand is the primary card-based interaction")
	_assert_equal(screen.card_button_count(), 5, "opening hand renders five card buttons")
	_assert_true("第 1 回合" in screen.get_node("%TurnLabel").text, "turn label is visible")
	_assert_true(not screen.get_node("%IntentLabel").text.is_empty(), "enemy intent text is visible")
	_assert_true("3 / 3" in screen.get_node("%ActionLabel").text, "action point budget is visible")
	await _destroy_screen(screen)


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
	card_button.mouse_exited.emit()
	await _destroy_screen(screen)


func _test_end_turn_refreshes_hand_and_intent() -> void:
	var screen = await _create_screen(_request(_standard_deck(), 1603))
	screen.get_node("%EndTurnButton").pressed.emit()
	await process_frame
	var state: Dictionary = screen.combat_snapshot()
	_assert_true(state.turn == 2, "end-turn button pressed signal reaches combat command")
	_assert_equal(state.turn, 2, "enemy action resolves before the second player turn")
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


func _test_layout_at_target_resolutions() -> void:
	for resolution in [Vector2i(1600, 900), Vector2i(1280, 720)]:
		root.size = resolution
		var screen = await _create_screen(_request(_standard_deck(), resolution.x))
		await process_frame
		var end_button: Button = screen.get_node("%EndTurnButton")
		var hand_scroll: ScrollContainer = screen.get_node("Page/Command/Stack/HandScroll")
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
