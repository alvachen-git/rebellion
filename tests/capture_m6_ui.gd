extends SceneTree

const GameScene := preload("res://src/ui/game/game_shell.tscn")


func _init() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var output_path := "/tmp/dynasty-rebellion-m6-main-city.png"
	var stage := "main_city"
	var capture_size := Vector2i(1600, 900)
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			output_path = argument.trim_prefix("--output=")
		elif argument.begins_with("--stage="):
			stage = argument.trim_prefix("--stage=")
		elif argument.begins_with("--width="):
			capture_size.x = int(argument.trim_prefix("--width="))
		elif argument.begins_with("--height="):
			capture_size.y = int(argument.trim_prefix("--height="))
	root.size = capture_size
	var shell = GameScene.instantiate()
	shell.save_root_override = "/tmp/dynasty-rebellion-m6-capture"
	shell.campaign_id_override = "campaign.capture"
	shell.map_seed_override = 20260902
	root.add_child(shell)
	for frame in 4:
		await process_frame
	shell.start_new_campaign()
	for frame in 4:
		await process_frame
	if stage == "target":
		shell.open_deployment()
	elif stage == "deck_editor":
		shell.open_deck_editor()
	elif stage == "deployment":
		shell.open_deployment()
		for frame in 3:
			await process_frame
		(shell.find_child("TargetButton_expedition_capture_heyuan_county", true, false) as Button).pressed.emit()
	elif stage in ["map", "encounter", "event", "retreat", "morale_failure", "death"]:
		shell.open_deployment()
		for frame in 3:
			await process_frame
		(shell.find_child("TargetButton_expedition_capture_heyuan_county", true, false) as Button).pressed.emit()
		for frame in 3:
			await process_frame
		shell.start_selected_expedition()
		if stage != "map":
			for frame in 4:
				await process_frame
			var expedition_before_battle: Dictionary = shell.flow_snapshot().expedition
			var event_id := ""
			var first_id := String(expedition_before_battle.route.available_next_node_ids[0])
			if stage == "event":
				for node in expedition_before_battle.visible_nodes:
					if int(node.layer) == 2 and node.node_type == "event":
						event_id = String(node.id)
				for edge in expedition_before_battle.map_edges:
					if edge.to == event_id and expedition_before_battle.route.available_next_node_ids.has(edge.from):
						first_id = String(edge.from)
						break
			shell.select_map_node(first_id)
			for frame in 4:
				await process_frame
			var expedition: Dictionary = shell.flow_snapshot().expedition
			if stage in ["encounter", "event"]:
				var first_request: Dictionary = expedition.pending_combat
				var first_combat = shell.find_child("IntegratedCombat", true, false)
				first_combat.battle_finished.emit({"battle_id": first_request.battle_id, "status": "victory", "player_remaining_troops": 1020, "player_remaining_morale": 75, "general_died": false, "general_injured": false})
				for frame in 5:
					await process_frame
				var encounter_id := event_id if stage == "event" else String(shell.flow_snapshot().expedition.route.available_next_node_ids[0])
				shell.select_map_node(encounter_id)
			else:
				var result := {
					"battle_id": expedition.pending_combat.battle_id,
					"status": "retreated" if stage == "retreat" else "defeat",
					"player_remaining_troops": 900 if stage != "death" else 0,
					"player_remaining_morale": 60 if stage == "retreat" else (0 if stage == "morale_failure" else 45),
					"general_died": stage == "death",
					"general_injured": stage == "morale_failure",
				}
				var combat = shell.find_child("IntegratedCombat", true, false)
				combat.battle_finished.emit(result)
	for frame in 24:
		await process_frame
	# UI transitions use real elapsed time; wait until every future-node fade-in is complete
	# so screenshot review measures the settled interface rather than animation timing.
	await create_timer(0.6).timeout
	RenderingServer.force_draw(false)
	await process_frame
	var image := root.get_texture().get_image()
	if image == null or image.save_png(output_path) != OK:
		push_error("Unable to save M6 UI capture: %s" % output_path)
		quit(1)
		return
	print("CAPTURE SAVED: %s (%dx%d)" % [output_path, image.get_width(), image.get_height()])
	quit(0)
