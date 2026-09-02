extends SceneTree

const GameScene := preload("res://src/ui/game/game_shell.tscn")

const SAVE_ROOT := "/tmp/dynasty-rebellion-m6-ui"

var _passed := 0
var _failed := 0


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_cleanup()
	root.size = Vector2i(1600, 900)
	await _test_player_visible_vertical_slice()
	_cleanup()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_player_visible_vertical_slice() -> void:
	var shell = await _create_shell()
	_assert_true(shell.find_child("WelcomeStage", true, false) != null, "game opens on the campaign start screen")
	var new_button := shell.find_child("NewCampaignButton", true, false) as Button
	_assert_true(new_button != null and new_button.visible, "new campaign is a visible primary action")
	new_button.pressed.emit()
	await _settle_frames()
	_assert_equal(shell.current_phase(), "main_city", "new campaign button enters the main city")
	_assert_true(shell.find_child("MainCityStage", true, false) != null, "main city renders the long-term workspace")
	_assert_true(shell.find_child("OpenDeploymentButton", true, false) != null, "main city exposes expedition preparation")

	(shell.find_child("OpenDeploymentButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	var selector := shell.find_child("DeploymentGeneralSelector", true, false) as OptionButton
	_assert_true(selector != null and selector.item_count == 3, "deployment exposes the three approved generals")
	var start := shell.find_child("StartExpeditionButton", true, false) as Button
	_assert_true(start != null and not start.disabled, "default army counts and loadout produce a legal departure order")
	_assert_true("1050" in (shell.find_child("DeploymentTotalLabel", true, false) as Label).text, "deployment displays the exact frozen troop total")
	start.pressed.emit()
	await _settle_frames()
	_assert_equal(shell.current_phase(), "expedition_map", "departure order enters the expedition map")
	_assert_true(shell.find_child("RouteMap", true, false) != null, "expedition renders the data-driven route map")

	var map = shell.find_child("RouteMap", true, false)
	var first_node: Button = map.button_for_node("heyuan.official.approach")
	_assert_true(first_node != null and not first_node.disabled, "the first legal route node is visibly actionable")
	first_node.pressed.emit()
	await _settle_frames()
	_assert_equal(shell.current_phase(), "combat_checkpoint", "map node click creates the combat checkpoint UI")
	_assert_true(shell.find_child("IntegratedCombat", true, false) != null, "the existing CombatScreen is embedded into the campaign flow")

	shell.queue_free()
	await process_frame
	shell = await _create_shell()
	var continue_button := shell.find_child("ContinueButton", true, false) as Button
	_assert_true(continue_button != null and not continue_button.disabled, "autosave makes continue available after relaunch")
	continue_button.pressed.emit()
	await _settle_frames()
	_assert_equal(shell.current_phase(), "combat_checkpoint", "continue restores the exact combat checkpoint")
	var combat = shell.find_child("IntegratedCombat", true, false)
	_assert_true(combat != null and combat.integrated_mode, "restored combat remains in integrated campaign mode")
	await _play_first_battle(combat)
	_assert_true(not combat.combat_snapshot().result.is_empty(), "real card and end-turn interactions produce a CombatResult")
	_assert_equal(combat.combat_snapshot().result.status, "victory", "the deterministic first encounter is won through CombatController")
	(combat.find_child("RestartButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	_assert_equal(shell.current_phase(), "expedition_map", "confirming the battle result returns to the route map")

	for node_id in ["heyuan.official.checkpoint", "heyuan.official.armory", "heyuan.merge.elite", "heyuan.late.intel", "heyuan.county_seat"]:
		await _settle_visible_node(shell, node_id)
	_assert_equal(shell.current_phase(), "settlement_pending", "Boss victory opens the final settlement screen")
	_assert_true(shell.find_child("SettlementStage", true, false) != null, "terminal expedition state has a dedicated settlement presentation")
	var settle_button := shell.find_child("FinalizeExpeditionButton", true, false) as Button
	_assert_true(settle_button != null and settle_button.visible, "settlement requires an explicit player confirmation")
	settle_button.pressed.emit()
	await _settle_frames()
	_assert_equal(shell.current_phase(), "main_city", "final settlement returns the player to the main city")
	_assert_equal(shell.flow_snapshot().campaign.territories[0].territory_id, "territory.heyuan_county", "player-visible success captures Heyuan County")
	_assert_true("河源县" in (shell.find_child("TerritorySummary", true, false) as Label).text, "returned main city visibly reports the captured territory")

	var before_cavalry := int(shell.flow_snapshot().campaign.army_inventory.cavalry)
	var cavalry_button := _button_with_text(shell, "补充 100", 2)
	_assert_true(cavalry_button != null, "main city presents cavalry replenishment")
	cavalry_button.pressed.emit()
	await _settle_frames()
	_assert_equal(shell.flow_snapshot().campaign.army_inventory.cavalry, before_cavalry + 100, "replenishment button changes authoritative army inventory")
	(shell.find_child("UnlockPursueButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	_assert_true(shell.flow_snapshot().campaign.unlocked_public_cards.has("card.public.cavalry.pursue"), "research button unlocks Pursue after the Boss reward")
	(shell.find_child("UpgradeAssaultButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	_assert_equal(shell.flow_snapshot().campaign.card_upgrade_branches.get("card.public.general.assault", ""), "break_momentum", "upgrade button commits the irreversible Assault branch")
	var open_editor := shell.find_child("OpenDeckEditorButton", true, false) as Button
	_assert_true(open_editor != null, "main city exposes the dedicated military-council location")
	open_editor.pressed.emit()
	await _settle_frames()
	var add_pursue := shell.find_child("DeckAddButton_card_public_cavalry_pursue", true, false) as Button
	_assert_true(add_pursue != null and not add_pursue.disabled, "unlocked card is available in the shared public-card library")
	add_pursue.pressed.emit()
	await _settle_frames()
	(shell.find_child("ConfirmBaseLoadoutButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	_assert_true(shell.flow_snapshot().campaign.base_loadout.has("card.public.cavalry.pursue"), "military council adds Pursue to the shared base loadout")
	(shell.find_child("ManualSaveButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	_assert_true(FileAccess.file_exists("%s/manual_1.json" % SAVE_ROOT), "main-city save action writes the explicit manual slot")

	root.size = Vector2i(1280, 720)
	await _settle_frames()
	var departure := shell.find_child("OpenDeploymentButton", true, false) as Button
	var scale_factor := minf(1280.0 / 1600.0, 720.0 / 900.0)
	var departure_screen_end := departure.get_global_rect().end * scale_factor
	_assert_true(departure_screen_end.x <= 1280.0 and departure_screen_end.y <= 720.0, "main-city primary action fits at 1280x720")
	departure.pressed.emit()
	await _settle_frames()
	_assert_true(not (shell.find_child("StartExpeditionButton", true, false) as Button).disabled, "post-growth state is visibly ready for a second expedition")
	shell.queue_free()
	await process_frame


func _play_first_battle(combat) -> void:
	for turn in 30:
		if combat.combat_snapshot().status != "active":
			return
		var played := true
		while played and combat.combat_snapshot().status == "active":
			played = false
			var hand_size: int = combat.combat_snapshot().deck.hand.size()
			for index in hand_size:
				var result: Dictionary = combat.play_card_at(index)
				if result.ok:
					played = true
					await process_frame
					break
		if combat.combat_snapshot().status == "active":
			combat.end_turn()
			await process_frame


func _settle_visible_node(shell, node_id: String) -> void:
	var map = shell.find_child("RouteMap", true, false)
	var button: Button = map.button_for_node(node_id)
	_assert_true(button != null and not button.disabled, "%s is the next visible route action" % node_id)
	button.pressed.emit()
	await _settle_frames()
	if shell.current_phase() == "combat_checkpoint":
		var expedition: Dictionary = shell.flow_snapshot().expedition
		var request: Dictionary = expedition.pending_combat
		var remaining := maxi(int(expedition.general.troops) - 35, 1)
		var combat = shell.find_child("IntegratedCombat", true, false)
		combat.battle_finished.emit({
			"battle_id": request.battle_id,
			"status": "victory",
			"player_remaining_troops": remaining,
			"player_remaining_morale": maxi(int(expedition.general.morale) - 3, 1),
			"general_died": false,
			"general_injured": false,
		})
		await _settle_frames()


func _create_shell():
	var shell = GameScene.instantiate()
	shell.save_root_override = SAVE_ROOT
	shell.campaign_id_override = "campaign.m6-ui"
	shell.map_seed_override = 20260902
	root.add_child(shell)
	await _settle_frames()
	return shell


func _settle_frames() -> void:
	await process_frame
	await process_frame
	await process_frame


func _button_with_text(shell, text: String, occurrence: int) -> Button:
	var matches: Array[Button] = []
	_collect_buttons(shell, text, matches)
	return matches[occurrence] if occurrence >= 0 and occurrence < matches.size() else null


func _collect_buttons(node: Node, text: String, result: Array[Button]) -> void:
	if node is Button and node.text == text:
		result.append(node)
	for child in node.get_children():
		_collect_buttons(child, text, result)


func _cleanup() -> void:
	for name in ["autosave.json", "autosave.json.bak", "autosave.json.tmp", "manual_1.json", "manual_1.json.bak", "manual_1.json.tmp"]:
		var path := "%s/%s" % [SAVE_ROOT, name]
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func _assert_true(condition: bool, label: String) -> void:
	if condition:
		_passed += 1
		print("TEST PASS: %s" % label)
	else:
		_failed += 1
		push_error("TEST FAIL: %s" % label)


func _assert_equal(actual, expected, label: String) -> void:
	if actual == expected:
		_passed += 1
		print("TEST PASS: %s (expected=%s actual=%s)" % [label, str(expected), str(actual)])
	else:
		_failed += 1
		push_error("TEST FAIL: %s (expected=%s actual=%s)" % [label, str(expected), str(actual)])
