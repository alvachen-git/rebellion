extends RefCounted
class_name SaveSlotPolicy

const MANUAL_SLOT_COUNT := 3
const AUTOSAVE_SLOT_ID := "autosave"
const MANUAL_SAVE_CONTEXTS := {
	"main_city": true,
	"expedition_map": true,
}
const AUTOSAVE_EVENTS := {
	"new_campaign": true,
	"combat_checkpoint_created": true,
	"expedition_node_settled": true,
	"expedition_terminal_checkpoint": true,
	"expedition_final_settled": true,
}


static func manual_slot_id(slot_number: int) -> String:
	if slot_number < 1 or slot_number > MANUAL_SLOT_COUNT:
		return ""
	return "manual_%d" % slot_number


static func can_manual_save(context: String) -> bool:
	return MANUAL_SAVE_CONTEXTS.has(context)


static func should_autosave(event: String) -> bool:
	return AUTOSAVE_EVENTS.has(event)


static func recovery_mode_for_context(context: String) -> String:
	if context == "combat":
		return "restart_current_battle_from_checkpoint"
	return "resume_exact_state"
