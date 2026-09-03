extends SceneTree

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")
const GameFlowCoordinatorScript := preload("res://src/application/game_flow_coordinator.gd")
const SaveEnvelopeScript := preload("res://src/domain/campaign/save_envelope.gd")
const SaveGameCodecScript := preload("res://src/infrastructure/persistence/save_game_codec.gd")
const SaveFileStoreScript := preload("res://src/infrastructure/persistence/save_file_store.gd")
const CombatControllerScript := preload("res://src/domain/combat/combat_controller.gd")
const GameScene := preload("res://src/ui/game/game_shell.tscn")

const SAVE_ROOT := "/tmp/dynasty-rebellion-m6-deck-editor"
const EXPEDITION_ID := "expedition.capture_heyuan_county"

var _passed := 0
var _failed := 0
var _registry
var _bundle: Dictionary = {}


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_cleanup()
	_registry = ContentRegistryScript.new()
	_assert_true(_registry.load_all(), "deck-editor content registry loads")
	_bundle = {
		"bootstrap": _load_json("res://data/config/prototype_campaign_bootstrap.json"),
		"deployment_rules": _load_json("res://data/config/prototype_deployment_rules.json"),
		"encounters": _load_json("res://data/config/prototype_heyuan_encounters.json"),
		"army_economy": _load_json("res://data/config/prototype_army_economy.json"),
		"research_economy": _load_json("res://data/config/prototype_research_economy.json"),
		"general_progression": _load_json("res://data/config/prototype_general_progression.json"),
		"faction_cycle": _load_json("res://data/config/prototype_faction_cycle.json"),
	}
	_test_shared_deck_contract()
	_test_v3_migration_and_frozen_expedition()
	await _test_military_council_interactions()
	_cleanup()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_shared_deck_contract() -> void:
	var flow = _new_flow()
	_assert_true(flow.new_campaign("campaign.deck-domain", "2026-09-02T06:00:00Z").ok, "shared-deck campaign starts")
	var initial: Dictionary = flow.snapshot().campaign
	_assert_equal(initial.base_loadout, _bundle.bootstrap.initial_base_loadout, "new campaign uses the configured shared starter deck")
	_assert_true(not initial.has("general_loadouts"), "new campaign no longer stores per-general loadouts")
	var editor: Dictionary = flow.loadout_editor_snapshot()
	_assert_true(editor.ok and editor.minimum_size == 15 and editor.maximum_size == 25, "editor snapshot publishes the authoritative size range")
	_assert_equal(editor.public_cards.size(), 22, "editor snapshot lists all public research cards, including Rogue rewards")
	_assert_true(not _option(editor.public_cards, "card.public.cavalry.pursue").unlocked, "locked public cards remain visible but unavailable")

	var fourteen: Array = initial.base_loadout.duplicate()
	fourteen.pop_back()
	_assert_true(not flow.set_base_loadout({"action_id": "deck.14", "cards": fourteen}).ok, "fourteen-card base deck is rejected")
	_assert_true(flow.set_base_loadout({"action_id": "deck.15", "cards": initial.base_loadout}).ok, "fifteen-card base deck is accepted")
	var twenty_five := _expanded_legal_deck(initial.base_loadout, 25)
	_assert_equal(twenty_five.size(), 25, "test fixture can form a legal twenty-five-card base deck")
	_assert_true(flow.set_base_loadout({"action_id": "deck.25", "cards": twenty_five}).ok, "twenty-five-card base deck is accepted")
	var twenty_six := twenty_five.duplicate()
	twenty_six.append("card.public.general.inspire")
	_assert_true(not flow.set_base_loadout({"action_id": "deck.26", "cards": twenty_six}).ok, "twenty-six-card base deck is rejected even when card ownership is valid")
	var exclusive := twenty_five.duplicate()
	exclusive[0] = "card.general.zhao_lie.lone_breakthrough"
	_assert_true(not flow.set_base_loadout({"action_id": "deck.exclusive", "cards": exclusive}).ok, "general-exclusive card cannot enter the shared base deck")
	var unknown := twenty_five.duplicate()
	unknown[0] = "card.missing.prototype"
	_assert_true(not flow.set_base_loadout({"action_id": "deck.unknown", "cards": unknown}).ok, "unknown card cannot enter the shared base deck")
	var locked := twenty_five.duplicate()
	locked[0] = "card.public.cavalry.pursue"
	_assert_true(not flow.set_base_loadout({"action_id": "deck.locked", "cards": locked}).ok, "locked public card cannot enter the shared base deck")

	for general_id in ["general.zhao_lie", "general.zhou_jing", "general.han_yue"]:
		var ready: Dictionary = flow.expedition_readiness({"expedition_id": EXPEDITION_ID, "general_id": general_id})
		_assert_true(ready.ok and ready.base_deck == twenty_five and ready.exclusive_cards.size() == 1 and ready.deck.size() == 26, "%s appends one exclusive card outside the base limit" % general_id)
		_assert_equal(ready.deck.slice(0, 25), twenty_five, "%s keeps the base-deck order stable" % general_id)
	var state_before_death: Dictionary = flow.snapshot().campaign
	state_before_death.generals[0].status = "deceased"
	state_before_death.generals[0].active_talent_id = ""
	state_before_death.generals[0].unlocked_exclusive_cards = []
	state_before_death.generals[0].death_record = {"request_id": "test.death", "expedition_id": EXPEDITION_ID, "cause": "troops_zero", "lost_talent_id": "talent.zhao_lie.break_formation", "lost_exclusive_cards": ["card.general.zhao_lie.lone_breakthrough"]}
	var other_general = _new_flow()
	var envelope: Dictionary = flow.snapshot()
	envelope.erase("phase")
	envelope.campaign = state_before_death
	_write_json("%s/deceased.json" % SAVE_ROOT, envelope)
	_assert_true(other_general.load_campaign("%s/deceased.json" % SAVE_ROOT).ok, "campaign with a deceased general and intact shared deck reloads")
	_assert_equal(other_general.snapshot().campaign.base_loadout, twenty_five, "general death never mutates the shared base deck")
	_assert_true(other_general.expedition_readiness({"expedition_id": EXPEDITION_ID, "general_id": "general.zhou_jing"}).ok, "another general can still deploy with the shared deck")

	var started: Dictionary = flow.start_expedition({"run_id": "run.deck-contract", "expedition_id": EXPEDITION_ID, "general_id": "general.han_yue", "map_seed": 20260902}, "2026-09-02T06:01:00Z")
	_assert_true(started.ok, "valid composed deck starts an expedition")
	_assert_true(not flow.set_base_loadout({"action_id": "deck.blocked", "cards": initial.base_loadout}).ok, "shared deck cannot be edited during an expedition")
	_assert_true(flow.advance_to_node("heyuan.official.approach", "2026-09-02T06:02:00Z").ok and flow.phase() == "combat_checkpoint", "composed deck reaches a real combat checkpoint")
	var request: Dictionary = flow.pending_combat_request()
	_assert_equal(request.deck.back(), "card.general.han_yue.formation_breaking_crossbow", "real CombatRequest freezes the selected general's exclusive card last")
	_assert_true(CombatControllerScript.new().setup(request, _registry).is_empty(), "real CombatController accepts the composed deployment deck")


func _test_v3_migration_and_frozen_expedition() -> void:
	var flow = _new_flow()
	_assert_true(flow.new_campaign("campaign.v3-audit", "2026-09-02T07:00:00Z").ok, "V3 migration fixture starts")
	_assert_true(flow.start_expedition({"run_id": "run.v3-frozen", "expedition_id": EXPEDITION_ID, "general_id": "general.zhao_lie", "map_seed": 77}, "2026-09-02T07:01:00Z").ok, "V3 migration fixture creates an active expedition")
	var legacy: Dictionary = flow.snapshot()
	legacy.erase("phase")
	legacy.save_version = 3
	legacy.content_version = "0.6.0-m6-flow"
	legacy.campaign.erase("base_loadout")
	legacy.campaign.loadout_system = {"applied_action_ids": [], "history": []}
	legacy.campaign.general_loadouts = {
		"general.zhao_lie": _registry.get_general("general.zhao_lie").starting_deck,
		"general.zhou_jing": _registry.get_general("general.zhou_jing").starting_deck,
		"general.han_yue": _registry.get_general("general.han_yue").starting_deck,
	}
	legacy.expedition.deck = _registry.get_general("general.zhao_lie").starting_deck.duplicate()
	var decoded: Dictionary = SaveGameCodecScript.new().decode(JSON.stringify(legacy))
	_assert_true(decoded.ok and decoded.to_version == 7, "Save V3 migrates through Save V7")
	_assert_equal(decoded.value.content_version, "0.6.0-m6-flow", "Save V3 migration preserves source content version")
	_assert_true(decoded.value.campaign.loadout_system.requires_legacy_recovery, "Save V3 migration requires explicit shared-deck recovery")
	_assert_equal(decoded.value.campaign.loadout_system.legacy_general_loadouts.size(), 3, "all three obsolete loadouts are retained for audit")
	_assert_true(not decoded.value.campaign.has("general_loadouts"), "obsolete loadouts are removed from gameplay state")
	_assert_equal(decoded.value.expedition.deck.size(), 20, "active expedition keeps its immutable V3 deck")
	var returned_v3: Dictionary = legacy.duplicate(true)
	returned_v3.expedition = null
	_write_json("%s/returned_v3.json" % SAVE_ROOT, returned_v3)
	var returned = _new_flow()
	_assert_true(returned.load_campaign("%s/returned_v3.json" % SAVE_ROOT).ok and returned.phase() == "main_city", "returned Save V3 reaches explicit recovery in the main city")
	var recovery: Dictionary = returned.recover_legacy_base_loadout("recover.v3", "2026-09-02T07:01:30Z")
	_assert_true(recovery.ok and recovery.cards.is_empty(), "V3 recovery grants no duplicate public cards when all starters were already unlocked")
	var recovery_record: Dictionary = returned.snapshot().campaign.loadout_system.history.back()
	_assert_equal(recovery_record.replaced_legacy_loadout_summary.size(), 3, "V3 recovery audit summarizes every replaced general loadout")
	_assert_equal(recovery_record.replaced_legacy_loadout_summary[0], {"general_id": "general.han_yue", "card_count": 20, "unique_card_count": 10}, "V3 recovery summary is stable and records card counts")
	_write_json("%s/active_v3.json" % SAVE_ROOT, legacy)
	var restored = _new_flow()
	_assert_true(restored.load_campaign("%s/active_v3.json" % SAVE_ROOT).ok, "migrated active expedition restores")
	_assert_equal(restored.phase(), "expedition_map", "legacy recovery does not interrupt an active expedition")
	_assert_equal(restored.snapshot().expedition.deck.size(), 20, "restored active expedition still uses the frozen old deck")
	_assert_true(not restored.recover_legacy_base_loadout("recover.during-run", "2026-09-02T07:02:00Z").ok, "legacy base deck can only be recovered after returning to main city")


func _test_military_council_interactions() -> void:
	root.size = Vector2i(1600, 900)
	var shell = await _create_shell()
	(shell.find_child("NewCampaignButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	var initial_deck: Array = shell.flow_snapshot().campaign.base_loadout.duplicate()
	var open := shell.find_child("OpenDeckEditorButton", true, false) as Button
	_assert_true(open != null, "main city presents the military-council location")
	open.pressed.emit()
	await _settle_frames()
	_assert_true(shell.find_child("DeckEditorStage", true, false) != null, "military-council location opens a dedicated editor")
	_assert_true("15 / 15–25" in (shell.find_child("BaseDeckCountLabel", true, false) as Label).text, "editor continuously displays the shared-deck size range")
	var pursue := shell.find_child("DeckAddButton_card_public_cavalry_pursue", true, false) as Button
	_assert_true(pursue != null and pursue.disabled, "locked Pursue is visible and disabled")
	for general_id in ["general.zhao_lie", "general.zhou_jing", "general.han_yue"]:
		_assert_true("15 + 1 = 16张" in (shell.find_child("DeckPreview_%s" % general_id.replace(".", "_"), true, false) as Label).text, "%s preview separates base and exclusive cards" % general_id)

	var remove := shell.find_child("DeckRemoveButton_card_public_general_assault", true, false) as Button
	remove.pressed.emit()
	await _settle_frames()
	_assert_true((shell.find_child("ConfirmBaseLoadoutButton", true, false) as Button).disabled, "confirm is disabled while the draft has fewer than fifteen cards")
	_assert_true("14 / 15–25" in (shell.find_child("BaseDeckCountLabel", true, false) as Label).text, "invalid draft explains its current size")
	(shell.find_child("DeckEditorBackButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	_assert_equal(shell.flow_snapshot().campaign.base_loadout, initial_deck, "returning to main city discards the unconfirmed draft")

	(shell.find_child("OpenDeckEditorButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	var add_assault := shell.find_child("DeckAddButton_card_public_general_assault", true, false) as Button
	add_assault.pressed.emit()
	await _settle_frames()
	_assert_true(not (shell.find_child("ConfirmBaseLoadoutButton", true, false) as Button).disabled, "legal sixteen-card draft can be confirmed")
	(shell.find_child("ConfirmBaseLoadoutButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	_assert_equal(shell.flow_snapshot().campaign.base_loadout.count("card.public.general.assault"), 2, "confirmed editor draft updates the authoritative shared deck")
	_assert_equal(shell.flow_snapshot().campaign.loadout_system.history.back().action, "set_base_loadout", "confirmed editor action is audited")
	(shell.find_child("ManualSaveButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	_assert_true(FileAccess.file_exists("%s/manual_1.json" % SAVE_ROOT), "shared deck persists through the existing manual-save action")

	(shell.find_child("OpenDeploymentButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	(shell.find_child("TargetButton_expedition_capture_heyuan_county", true, false) as Button).pressed.emit()
	await _settle_frames()
	var breakdown := shell.find_child("DeploymentDeckBreakdown", true, false) as Label
	_assert_true("16张  +  专属牌 1张  =  出战牌组 17张" in breakdown.text and "独胆破阵" in breakdown.text, "deployment clearly previews Zhao Lie's composed deck")
	var selector := shell.find_child("DeploymentGeneralSelector", true, false) as OptionButton
	selector.select(1)
	selector.item_selected.emit(1)
	await _settle_frames()
	breakdown = shell.find_child("DeploymentDeckBreakdown", true, false) as Label
	_assert_true("后发制人" in breakdown.text and not "独胆破阵" in breakdown.text, "switching general changes only the exclusive-card preview")

	(shell.find_child("DeploymentBackButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	(shell.find_child("TargetSelectionBackButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	(shell.find_child("OpenDeckEditorButton", true, false) as Button).pressed.emit()
	await _settle_frames()
	root.size = Vector2i(1280, 720)
	await _settle_frames()
	var confirm := shell.find_child("ConfirmBaseLoadoutButton", true, false) as Button
	var scale_factor := minf(1280.0 / 1600.0, 720.0 / 900.0)
	var screen_end := confirm.get_global_rect().end * scale_factor
	_assert_true(screen_end.x <= 1280.0 and screen_end.y <= 720.0, "military-council confirmation remains reachable at 1280x720")
	shell.queue_free()
	await process_frame

	var reloaded = await _create_unstarted_shell()
	var manual := reloaded.find_child("ManualLoad1Button", true, false) as Button
	_assert_true(manual != null, "start screen exposes the saved shared-deck slot")
	manual.pressed.emit()
	await _settle_frames()
	_assert_equal(reloaded.flow_snapshot().campaign.base_loadout.count("card.public.general.assault"), 2, "manual reload preserves the edited shared deck")
	reloaded.queue_free()
	await process_frame


func _expanded_legal_deck(base: Array, target_size: int) -> Array:
	var result := base.duplicate()
	for card_id in _bundle.research_economy.eligible_public_card_ids:
		if not result.has(card_id):
			continue
		var limit := int(_registry.get_card(card_id).copy_limit)
		while result.count(card_id) < limit and result.size() < target_size:
			result.append(card_id)
		if result.size() >= target_size:
			break
	return result


func _option(options: Array, card_id: String) -> Dictionary:
	for option in options:
		if option is Dictionary and option.id == card_id:
			return option
	return {}


func _new_flow():
	var flow = GameFlowCoordinatorScript.new()
	_assert_true(flow.setup(_registry, _bundle, SaveFileStoreScript.new(), SAVE_ROOT).is_empty(), "deck-editor game flow configures")
	return flow


func _create_shell():
	var shell = await _create_unstarted_shell()
	return shell


func _create_unstarted_shell():
	var shell = GameScene.instantiate()
	shell.save_root_override = SAVE_ROOT
	shell.campaign_id_override = "campaign.deck-ui"
	shell.map_seed_override = 301
	root.add_child(shell)
	await _settle_frames()
	return shell


func _settle_frames() -> void:
	await process_frame
	await process_frame
	await process_frame


func _load_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	return JSON.parse_string(file.get_as_text())


func _write_json(path: String, value: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(value))
	file.close()


func _cleanup() -> void:
	for name in ["autosave.json", "autosave.json.bak", "autosave.json.tmp", "manual_1.json", "manual_1.json.bak", "manual_1.json.tmp", "deceased.json", "active_v3.json"]:
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
	_assert_true(actual == expected, "%s (expected=%s actual=%s)" % [label, expected, actual])
