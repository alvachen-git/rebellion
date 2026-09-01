extends SceneTree

const CombatScene := preload("res://src/ui/combat/combat_screen.tscn")


func _init() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var output_path := "/tmp/dynasty-rebellion-m2-ui.png"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			output_path = argument.trim_prefix("--output=")
	var screen := CombatScene.instantiate()
	root.add_child(screen)
	for frame in 6:
		await process_frame
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
