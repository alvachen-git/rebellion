extends SceneTree

const GameScene := preload("res://src/ui/game/game_shell.tscn")
const CAPTURE_ROOT := "/tmp/dynasty-rebellion-m6-capture"


func _init() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var output_path := "/tmp/dynasty-rebellion-m6-main-city.png"
	var stage := "main_city"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			output_path = argument.trim_prefix("--output=")
		elif argument.begins_with("--stage="):
			stage = argument.trim_prefix("--stage=")
	var shell = GameScene.instantiate()
	shell.save_root_override = CAPTURE_ROOT
	shell.campaign_id_override = "campaign.capture"
	shell.map_seed_override = 20260902
	root.add_child(shell)
	for frame in 4:
		await process_frame
	shell.start_new_campaign()
	for frame in 4:
		await process_frame
	if stage == "deck_editor":
		shell.open_deck_editor()
	elif stage == "deployment":
		shell.open_deployment()
	elif stage in ["map", "battle", "battle_hover_player", "battle_hover_enemy", "success", "retreat", "morale_failure", "death", "game_over"]:
		shell.open_deployment()
		await process_frame
		shell.start_selected_expedition()
		if stage == "success":
			await _capture_success_path(shell)
		elif stage != "map":
			for frame in 4:
				await process_frame
			shell.select_map_node("heyuan.official.approach")
			if stage in ["battle_hover_player", "battle_hover_enemy"]:
				for frame in 6:
					await process_frame
				var combatant_name := "PlayerCombatant" if stage == "battle_hover_player" else "EnemyCombatant"
				var combatant = shell.find_child(combatant_name, true, false)
				var portrait := combatant.find_child("PortraitButton", true, false) as Button
				portrait.mouse_entered.emit()
			elif stage != "battle":
				for frame in 4:
					await process_frame
				var expedition: Dictionary = shell.flow_snapshot().expedition
				var result := {
					"battle_id": expedition.pending_combat.battle_id,
					"status": "retreated" if stage == "retreat" else "defeat",
					"player_remaining_troops": 0 if stage in ["death", "game_over"] else 900,
					"player_remaining_morale": 60 if stage == "retreat" else (0 if stage == "morale_failure" else 45),
					"general_died": stage in ["death", "game_over"],
					"general_injured": stage == "morale_failure",
				}
				var combat = shell.find_child("IntegratedCombat", true, false)
				combat.battle_finished.emit(result)
				if stage == "game_over":
					for frame in 6:
						await process_frame
					await _open_authoritative_game_over(shell)
	for frame in 24:
		await process_frame
	RenderingServer.force_draw(false)
	await process_frame
	var image := root.get_texture().get_image()
	if image == null or image.save_png(output_path) != OK:
		push_error("Unable to save M6 UI capture: %s" % output_path)
		quit(1)
		return
	print("CAPTURE SAVED: %s (%dx%d)" % [output_path, image.get_width(), image.get_height()])
	quit(0)


func _open_authoritative_game_over(shell) -> void:
	var envelope: Dictionary = shell.flow_snapshot()
	envelope.erase("phase")
	envelope.campaign.campaign_status = "game_over"
	envelope.campaign.game_over_record = {
		"request_id": "capture.game-over",
		"general_id": "general.player.placeholder",
		"expedition_id": "expedition.capture_heyuan_county",
		"reason": "player_character_death",
	}
	var file := FileAccess.open("%s/autosave.json" % CAPTURE_ROOT, FileAccess.WRITE)
	if file == null:
		push_error("Unable to write authoritative Game Over capture save")
		return
	file.store_string(JSON.stringify(envelope, "  "))
	file.close()
	shell.queue_free()
	await process_frame
	var resumed = GameScene.instantiate()
	resumed.save_root_override = CAPTURE_ROOT
	resumed.campaign_id_override = "campaign.capture"
	resumed.map_seed_override = 20260902
	root.add_child(resumed)
	for frame in 4:
		await process_frame
	var continue_button := resumed.find_child("ContinueButton", true, false) as Button
	if continue_button == null:
		push_error("Unable to find ContinueButton for authoritative Game Over capture")
		return
	continue_button.pressed.emit()
	for frame in 8:
		await process_frame


func _capture_success_path(shell) -> void:
	for node_id in ["heyuan.official.approach", "heyuan.official.checkpoint", "heyuan.official.armory", "heyuan.merge.elite", "heyuan.late.intel", "heyuan.county_seat"]:
		for frame in 3:
			await process_frame
		var result: Dictionary = shell.select_map_node(node_id)
		if not result.ok:
			push_error("Unable to advance capture route to %s: %s" % [node_id, result.get("error", result.get("reason", "unknown"))])
			return
		if shell.current_phase() == "combat_checkpoint":
			for frame in 3:
				await process_frame
			var expedition: Dictionary = shell.flow_snapshot().expedition
			var combat = shell.find_child("IntegratedCombat", true, false)
			combat.battle_finished.emit({
				"battle_id": expedition.pending_combat.battle_id,
				"status": "victory",
				"player_remaining_troops": maxi(int(expedition.general.troops) - 24, 1),
				"player_remaining_morale": maxi(int(expedition.general.morale) - 2, 1),
				"general_died": false,
				"general_injured": false,
			})
