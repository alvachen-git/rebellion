extends SceneTree

const GameScene := preload("res://src/ui/game/game_shell.tscn")

const ROOT_BASE := "/tmp/dynasty-rebellion-m6-experience"

var _passed := 0
var _failed := 0


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	root.size = Vector2i(1600, 900)
	await _test_player_retreat_experience()
	await _test_morale_failure_experience()
	await _test_permanent_death_and_game_over_experience()
	await _test_legacy_loadout_recovery_experience()
	await create_timer(0.3).timeout
	await process_frame
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_player_retreat_experience() -> void:
	var save_root := "%s/retreat" % ROOT_BASE
	_cleanup(save_root)
	var shell = await _create_shell(save_root, "campaign.retreat-ui")
	await _enter_first_combat(shell)
	var combat = shell.find_child("IntegratedCombat", true, false)
	(combat.find_child("RetreatButton", true, false) as Button).pressed.emit()
	_assert_true((combat.find_child("RetreatDialog", true, false) as ConfirmationDialog).visible, "retreat first presents the permanent-loss confirmation")
	(combat.find_child("RetreatDialog", true, false) as ConfirmationDialog).confirmed.emit()
	await _settle_frames()
	_assert_equal(combat.combat_snapshot().result.status, "retreated", "confirmed UI retreat produces the distinct CombatResult")
	(combat.find_child("RestartButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	_assert_equal(shell.current_phase(), "settlement_pending", "retreat stops at the persisted final report")
	var outcome := shell.find_child("SettlementOutcomeLabel", true, false) as Label
	var consequence := shell.find_child("SettlementConsequenceLabel", true, false) as Label
	_assert_true("武将生还" in outcome.text, "retreat report leads with survival rather than generic failure")
	_assert_true("战利品全部丢失" in consequence.text and "兵损永久扣除" in consequence.text, "retreat report names both irreversible losses")
	(shell.find_child("FinalizeExpeditionButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	_assert_equal(shell.current_phase(), "main_city", "retreat confirmation returns to the main city")
	_assert_equal(shell.flow_snapshot().campaign.cycle, 0, "retreat UI does not advance the prototype faction cycle")
	_assert_true(shell.flow_snapshot().campaign.territories.is_empty(), "retreat UI cannot capture Heyuan County")
	shell.queue_free()
	await process_frame


func _test_morale_failure_experience() -> void:
	var save_root := "%s/morale" % ROOT_BASE
	_cleanup(save_root)
	var shell = await _create_shell(save_root, "campaign.morale-ui")
	await _enter_first_combat(shell)
	var expedition: Dictionary = shell.flow_snapshot().expedition
	var combat = shell.find_child("IntegratedCombat", true, false)
	combat.battle_finished.emit({
		"battle_id": expedition.pending_combat.battle_id,
		"status": "defeat",
		"player_remaining_troops": 900,
		"player_remaining_morale": 0,
		"general_died": false,
		"general_injured": true,
	})
	await _settle_frames()
	_assert_equal(shell.current_phase(), "settlement_pending", "morale collapse opens the persisted failure report")
	var outcome := shell.find_child("SettlementOutcomeLabel", true, false) as Label
	var consequence := shell.find_child("SettlementConsequenceLabel", true, false) as Label
	_assert_true("军心崩溃" in outcome.text and "重伤归营" in outcome.text, "morale failure is explained in player language")
	_assert_true("赵烈进入重伤" in consequence.text and "势力周期不推进" in consequence.text, "morale report previews the exact long-term consequences")
	(shell.find_child("FinalizeExpeditionButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	_assert_equal(shell.flow_snapshot().campaign.generals[0].injury.status, "major_injury", "failure confirmation applies the previewed major injury")
	_assert_true(_button_containing(shell, "赵烈").text.contains("重伤"), "returned roster visibly marks the injured general")
	shell.queue_free()
	await process_frame


func _test_permanent_death_and_game_over_experience() -> void:
	var save_root := "%s/death" % ROOT_BASE
	_cleanup(save_root)
	var shell = await _create_shell(save_root, "campaign.death-ui")
	await _enter_first_combat(shell)
	var expedition: Dictionary = shell.flow_snapshot().expedition
	var combat = shell.find_child("IntegratedCombat", true, false)
	combat.battle_finished.emit({
		"battle_id": expedition.pending_combat.battle_id,
		"status": "defeat",
		"player_remaining_troops": 0,
		"player_remaining_morale": 45,
		"general_died": true,
		"general_injured": false,
	})
	await _settle_frames()
	_assert_true("赵烈阵亡" in (shell.find_child("SettlementOutcomeLabel", true, false) as Label).text, "death report names the fallen general")
	_assert_true("赵烈永久死亡" in (shell.find_child("SettlementConsequenceLabel", true, false) as Label).text, "death report states permanence before confirmation")
	root.size = Vector2i(1280, 720)
	await _settle_frames()
	var finalize := shell.find_child("FinalizeExpeditionButton", true, false) as Button
	var scale_factor := minf(1280.0 / 1600.0, 720.0 / 900.0)
	var button_screen_end := finalize.get_global_rect().end * scale_factor
	_assert_true(button_screen_end.x <= 1280.0 and button_screen_end.y <= 720.0, "permanent-death confirmation fits at 1280x720")
	finalize.pressed.emit()
	await _settle_frames()
	_assert_equal(shell.flow_snapshot().campaign.generals[0].status, "deceased", "death confirmation permanently changes the Campaign general")
	var dead_button := _button_containing(shell, "赵烈")
	_assert_true(dead_button != null and dead_button.disabled and dead_button.text.contains("阵亡"), "returned roster disables the deceased general")

	var game_over_envelope: Dictionary = shell.flow_snapshot()
	game_over_envelope.erase("phase")
	game_over_envelope.campaign.campaign_status = "game_over"
	game_over_envelope.campaign.game_over_record = {"request_id": "ui.game-over", "general_id": "general.player.placeholder", "expedition_id": "expedition.capture_heyuan_county", "reason": "player_character_death"}
	_write_json("%s/autosave.json" % save_root, game_over_envelope)
	shell.queue_free()
	await process_frame
	root.size = Vector2i(1600, 900)
	shell = await _create_unstarted_shell(save_root, "campaign.death-ui")
	(shell.find_child("ContinueButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	_assert_equal(shell.current_phase(), "game_over", "loading a player-death save enters the authoritative Game Over phase")
	_assert_true(shell.find_child("GameOverStage", true, false) != null and "义旗坠地" in _all_label_text(shell), "Game Over has a distinct player-visible ending")
	shell.queue_free()
	await process_frame


func _test_legacy_loadout_recovery_experience() -> void:
	var save_root := "%s/legacy" % ROOT_BASE
	_cleanup(save_root)
	var source = await _create_shell(save_root, "campaign.legacy-ui")
	var legacy: Dictionary = source.flow_snapshot()
	legacy.erase("phase")
	legacy.save_version = 2
	legacy.content_version = "0.4.0-m4-map"
	legacy.campaign.erase("base_loadout")
	legacy.campaign.erase("loadout_system")
	source.queue_free()
	await process_frame
	_write_json("%s/autosave.json" % save_root, legacy)
	var shell = await _create_unstarted_shell(save_root, "campaign.legacy-ui")
	(shell.find_child("ContinueButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	_assert_true(shell.find_child("LegacyRecoveryStage", true, false) != null, "migrated V2 save opens an explicit recovery screen instead of a broken main city")
	_assert_true("15种原型初始公共卡" in _all_label_text(shell) and "共用基础牌组" in _all_label_text(shell), "recovery screen tells the player exactly what will be granted")
	(shell.find_child("RecoverLegacyLoadoutsButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	_assert_equal(shell.current_phase(), "main_city", "confirmed legacy recovery enters the main city")
	_assert_equal(shell.flow_snapshot().campaign.base_loadout.size(), 15, "legacy recovery creates the shared fifteen-card base loadout")
	_assert_equal(shell.flow_snapshot().campaign.loadout_system.history[0].action, "recover_legacy_base_loadout", "legacy recovery remains auditable through the UI")
	_assert_true(FileAccess.file_exists("%s/manual_1.json" % save_root), "recovered state is explicitly saved to manual slot one")
	var untouched_auto := _read_json("%s/autosave.json" % save_root)
	_assert_equal(untouched_auto.save_version, 2.0, "recovery does not overwrite the original V2 autosave")
	_assert_true(not untouched_auto.campaign.has("base_loadout"), "original legacy autosave remains structurally untouched")
	shell.queue_free()
	await process_frame
	shell = await _create_unstarted_shell(save_root, "campaign.legacy-ui")
	var manual_button := shell.find_child("ManualLoad1Button", true, false) as Button
	_assert_true(manual_button != null, "start screen exposes the recovered manual slot")
	manual_button.pressed.emit()
	await _settle_frames()
	_assert_true(shell.find_child("MainCityStage", true, false) != null and shell.find_child("LegacyRecoveryStage", true, false) == null, "manual slot reload enters the recovered main city without repeating recovery")
	shell.queue_free()
	await process_frame


func _enter_first_combat(shell) -> void:
	(shell.find_child("OpenDeploymentButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	(shell.find_child("StartExpeditionButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	var map = shell.find_child("RouteMap", true, false)
	(map.button_for_node("heyuan.official.approach") as Button).pressed.emit()
	await _settle_frames()
	_assert_equal(shell.current_phase(), "combat_checkpoint", "experience fixture reaches a real combat checkpoint")


func _create_shell(save_root: String, campaign_id: String):
	var shell = await _create_unstarted_shell(save_root, campaign_id)
	(shell.find_child("NewCampaignButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	return shell


func _create_unstarted_shell(save_root: String, campaign_id: String):
	var shell = GameScene.instantiate()
	shell.save_root_override = save_root
	shell.campaign_id_override = campaign_id
	shell.map_seed_override = 20260902
	root.add_child(shell)
	await _settle_frames()
	return shell


func _button_containing(node: Node, fragment: String) -> Button:
	if node is Button and fragment in node.text:
		return node
	for child in node.get_children():
		var found := _button_containing(child, fragment)
		if found != null:
			return found
	return null


func _all_label_text(node: Node) -> String:
	var parts := PackedStringArray()
	_collect_label_text(node, parts)
	return "\n".join(parts)


func _collect_label_text(node: Node, parts: PackedStringArray) -> void:
	if node is Label:
		parts.append(node.text)
	for child in node.get_children():
		_collect_label_text(child, parts)


func _settle_frames() -> void:
	await process_frame
	await process_frame
	await process_frame


func _write_json(path: String, value: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(value))
	file.close()


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	var value = JSON.parse_string(file.get_as_text())
	file.close()
	return value if value is Dictionary else {}


func _cleanup(save_root: String) -> void:
	for slot in ["autosave", "manual_1", "manual_2", "manual_3"]:
		for suffix in [".json", ".json.bak", ".json.tmp"]:
			var path := "%s/%s%s" % [save_root, slot, suffix]
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
