extends SceneTree

const CombatScene := preload("res://src/ui/combat/combat_screen.tscn")


func _init() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var output_path := "/tmp/dynasty-rebellion-m2-ui.png"
	var show_enemy_action := false
	var general_id := ""
	var enemy_id := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			output_path = argument.trim_prefix("--output=")
		elif argument == "--enemy-action":
			show_enemy_action = true
		elif argument.begins_with("--general="):
			general_id = argument.trim_prefix("--general=")
		elif argument.begins_with("--enemy="):
			enemy_id = argument.trim_prefix("--enemy=")
	var screen := CombatScene.instantiate()
	root.add_child(screen)
	for frame in 6:
		await process_frame
	if not general_id.is_empty():
		_select_metadata(screen.get_node("%GeneralSelector"), general_id)
	if not enemy_id.is_empty():
		_select_metadata(screen.get_node("%EnemySelector"), enemy_id)
	if not general_id.is_empty() or not enemy_id.is_empty():
		screen.start_selected_battle()
		for frame in 6:
			await process_frame
	if show_enemy_action:
		screen.end_turn()
		await create_timer(0.12).timeout
	RenderingServer.force_draw(false)
	await process_frame
	var image := root.get_texture().get_image()
	var result := image.save_png(output_path)
	if result != OK:
		push_error("Unable to save M2 UI capture: %s" % output_path)
		quit(1)
		return
	print("CAPTURE SAVED: %s (%dx%d)" % [output_path, image.get_width(), image.get_height()])
	quit(0)


func _select_metadata(selector: OptionButton, value: String) -> void:
	for index in selector.item_count:
		if String(selector.get_item_metadata(index)) == value:
			selector.select(index)
			return
	push_error("Unable to select capture metadata: %s" % value)
