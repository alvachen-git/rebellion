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
	await _test_event_choice_feedback()
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
	var support_status := shell.find_child("PopularSupportStatusLabel", true, false) as Label
	_assert_true(support_status != null and "20 / 100" in support_status.text, "main city visibly reports the initial long-term popular support")

	(shell.find_child("OpenDeploymentButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	_assert_true(shell.find_child("ExpeditionTargetStage", true, false) != null, "departure opens the three-target selection page")
	_assert_true(shell.find_child("TargetButton_expedition_capture_heyuan_county", true, false) != null, "Heyuan is visible as a destination")
	_assert_true(shell.find_child("TargetButton_expedition_secure_shimen_mountain", true, false) != null, "Shimen is visible as a destination")
	_assert_true(shell.find_child("TargetButton_expedition_capture_linze_market", true, false) != null, "Linze is visible as a destination")
	(shell.find_child("TargetButton_expedition_capture_heyuan_county", true, false) as Button).pressed.emit()
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
	var initial_expedition: Dictionary = shell.flow_snapshot().expedition
	_assert_equal(initial_expedition.generator_version, 4, "new UI expedition uses the branching-map generator")
	_assert_true(initial_expedition.visible_nodes.size() >= 19 and initial_expedition.visible_nodes.size() <= 24, "V4 UI receives a variable-size authored topology")
	var topology_changes := _internal_topology_changes(initial_expedition)
	_assert_true(topology_changes.splits >= 2 and topology_changes.merges >= 2, "the rendered route contains repeated branch and merge decisions")
	var all_categories_visible := true
	var future_details_hidden := false
	for node in initial_expedition.visible_nodes:
		all_categories_visible = all_categories_visible and node.node_type != "unknown" and bool(node.is_revealed)
		if int(node.layer) > 1 and node.node_type == "event":
			future_details_hidden = future_details_hidden or (node.name == "途中事件" and not bool(node.is_detail_revealed))
	_assert_true(all_categories_visible, "the player can inspect every future node category before choosing a lane")
	_assert_true(future_details_hidden, "the route forecast hides concrete future event details until arrival or scouting")
	var map_status_labels := _combined_label_text(shell.find_child("ExpeditionMapStage", true, false))
	_assert_true("民望 20（本次 +0）" in map_status_labels, "the expedition HUD shows projected and pending popular support")
	_assert_true(not "未知节点" in map_status_labels, "the V4 route UI presents future node categories instead of unknown nodes")

	var map = shell.find_child("RouteMap", true, false)
	var first_id := String(initial_expedition.route.available_next_node_ids[0])
	var first_node: Button = map.button_for_node(first_id)
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

	for step in 24:
		if shell.current_phase() == "settlement_pending":
			break
		await _settle_next_rogue_step(shell, step)
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
	_assert_true((shell.find_child("TargetButton_expedition_capture_heyuan_county", true, false) as Button).disabled, "captured Heyuan is disabled on the target page")
	(shell.find_child("TargetButton_expedition_secure_shimen_mountain", true, false) as Button).pressed.emit()
	await _settle_frames()
	_assert_true(not (shell.find_child("StartExpeditionButton", true, false) as Button).disabled, "post-growth state is visibly ready for a second expedition")
	shell.queue_free()
	await process_frame


func _test_event_choice_feedback() -> void:
	root.size = Vector2i(1280, 720)
	var shell = await _create_shell()
	(shell.find_child("NewCampaignButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	(shell.find_child("OpenDeploymentButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	(shell.find_child("TargetButton_expedition_capture_heyuan_county", true, false) as Button).pressed.emit()
	await _settle_frames()
	(shell.find_child("StartExpeditionButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	var expedition: Dictionary = shell.flow_snapshot().expedition
	var event_id: String = ""
	for node in expedition.visible_nodes:
		if int(node.layer) == 2 and node.node_type == "event":
			event_id = String(node.id)
	var opening_id := _opening_node_toward(expedition, event_id)
	(shell.find_child("RouteMap", true, false).button_for_node(opening_id) as Button).pressed.emit()
	await _settle_frames()
	var request: Dictionary = shell.flow_snapshot().expedition.pending_combat
	var combat = shell.find_child("IntegratedCombat", true, false)
	combat.battle_finished.emit({"battle_id": request.battle_id, "status": "victory", "player_remaining_troops": 1010, "player_remaining_morale": 76, "general_died": false, "general_injured": false})
	await _settle_frames()
	var event_button: Button = shell.find_child("RouteMap", true, false).button_for_node(event_id)
	_assert_true(event_button != null and not event_button.disabled, "a forecast event node becomes actionable only after its preceding battle")
	event_button.pressed.emit()
	await _settle_frames()
	_assert_equal(shell.current_phase(), "encounter_choice", "clicking the forecast event opens its frozen choice panel")
	var event_panel_text := _combined_label_text(shell.find_child("ExpeditionEncounterStage", true, false))
	_assert_true(not "途中事件\n" in event_panel_text and not event_panel_text.begins_with("途中事件"), "arrival replaces the generic event category with the concrete event title")
	var frozen_encounter: Dictionary = shell.flow_snapshot().expedition.pending_encounter
	var first_description := String(frozen_encounter.choices[0].get("description", ""))
	_assert_true(not first_description.is_empty() and first_description in event_panel_text, "event choices visibly state their known cost or possible outcome range")
	var before: Dictionary = shell.flow_snapshot().expedition
	var choice: Button = _first_enabled_encounter_button(shell)
	_assert_true(choice != null, "the concrete event exposes at least one enabled data-driven choice")
	if choice != null:
		choice.pressed.emit()
		await _settle_frames()
	var notice := shell.find_child("NoticeLabel", true, false) as Label
	_assert_true(notice != null and "选择已结算" in notice.text, "event settlement displays the actual resolved outcome feedback")
	var after: Dictionary = shell.flow_snapshot().expedition
	var state_changed: bool = int(before.general.troops) != int(after.general.troops) or int(before.general.morale) != int(after.general.morale) or int(before.pending_popular_support_delta) != int(after.pending_popular_support_delta) or int(before.pending_rebellion_delta) != int(after.pending_rebellion_delta) or before.unbanked_loot != after.unbanked_loot
	_assert_true(state_changed, "the event choice updates authoritative expedition state before returning to the map")
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


func _settle_next_rogue_step(shell, step: int) -> void:
	if shell.current_phase() == "expedition_map":
		var expedition: Dictionary = shell.flow_snapshot().expedition
		var available: Array = expedition.route.available_next_node_ids
		_assert_true(not available.is_empty(), "Rogue step %d exposes at least one reachable node" % step)
		if available.is_empty():
			return
		var node_id := String(available[0])
		var map = shell.find_child("RouteMap", true, false)
		var button: Button = map.button_for_node(node_id)
		_assert_true(button != null and not button.disabled, "%s is a visible Rogue route action" % node_id)
		button.pressed.emit()
		await _settle_frames()
	if shell.current_phase() in ["encounter_choice", "reward_choice"]:
		var choice_button: Button = null
		for preferred in ["leave", "skip", "observe", "scout", "ration", "mark", "avoid", "detour"]:
			var candidate := shell.find_child("EncounterChoice_%s" % preferred, true, false) as Button
			if candidate != null and not candidate.disabled:
				choice_button = candidate
				break
		if choice_button == null:
			choice_button = _first_enabled_encounter_button(shell)
		_assert_true(choice_button != null and not choice_button.disabled, "Rogue encounter choice is reachable in the UI")
		if choice_button != null:
			choice_button.pressed.emit()
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


func _first_enabled_encounter_button(node: Node) -> Button:
	if node is Button and node.name.begins_with("EncounterChoice_") and not node.disabled:
		return node
	for child in node.get_children():
		var result := _first_enabled_encounter_button(child)
		if result != null:
			return result
	return null


func _internal_topology_changes(expedition: Dictionary) -> Dictionary:
	var layer_counts := {}
	for node in expedition.visible_nodes:
		var layer := int(node.get("layer", -1))
		layer_counts[layer] = int(layer_counts.get(layer, 0)) + 1
	var splits := 0
	var merges := 0
	for layer in range(1, 7):
		if int(layer_counts.get(layer + 1, 0)) > int(layer_counts.get(layer, 0)):
			splits += 1
		elif int(layer_counts.get(layer + 1, 0)) < int(layer_counts.get(layer, 0)):
			merges += 1
	return {"splits": splits, "merges": merges}


func _opening_node_toward(expedition: Dictionary, target_id: String) -> String:
	for edge in expedition.map_edges:
		if edge.to == target_id and expedition.route.available_next_node_ids.has(edge.from):
			return String(edge.from)
	return String(expedition.route.available_next_node_ids[0])


func _combined_label_text(node: Node) -> String:
	if node == null:
		return ""
	var result: String = node.text if node is Label else ""
	for child in node.get_children():
		result += "\n" + _combined_label_text(child)
	return result


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
