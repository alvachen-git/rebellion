extends RefCounted
class_name GameFlowCoordinator

const SaveEnvelopeScript := preload("res://src/domain/campaign/save_envelope.gd")
const CampaignControllerScript := preload("res://src/domain/campaign/campaign_controller.gd")
const GeneralManagementServiceScript := preload("res://src/domain/campaign/general_management_service.gd")
const ExpeditionMapGeneratorScript := preload("res://src/domain/expedition/expedition_map_generator.gd")
const ExpeditionRunStateScript := preload("res://src/domain/expedition/expedition_run_state.gd")
const ExpeditionEncounterResolverScript := preload("res://src/domain/expedition/expedition_encounter_resolver.gd")
const DeploymentAssemblerScript := preload("res://src/application/deployment_assembler.gd")
const SaveSlotPolicyScript := preload("res://src/infrastructure/persistence/save_slot_policy.gd")

var _registry
var _config: Dictionary = {}
var _save_store
var _save_root := ""
var _envelope: Dictionary = {}
var _campaign
var _expedition
var _deployment
var _encounters
var _legacy_encounters


func setup(registry, config_bundle: Dictionary, save_store, save_root: String) -> PackedStringArray:
	_registry = registry
	_config = config_bundle.duplicate(true)
	_save_store = save_store
	_save_root = save_root.trim_suffix("/")
	var errors := PackedStringArray()
	for field in ["bootstrap", "deployment_rules", "encounters", "army_economy", "research_economy", "general_progression", "faction_cycle"]:
		if not _config.get(field, null) is Dictionary:
			errors.append("game flow config missing object '%s'" % field)
	if _save_root.is_empty():
		errors.append("game flow save_root must be non-empty")
	if not errors.is_empty():
		return errors
	_deployment = DeploymentAssemblerScript.new()
	errors.append_array(_deployment.setup(_registry, _config.deployment_rules, _card_definitions()))
	_encounters = ExpeditionEncounterResolverScript.new()
	errors.append_array(_encounters.setup(_config.encounters))
	if _config.get("legacy_encounters", null) is Dictionary:
		_legacy_encounters = ExpeditionEncounterResolverScript.new()
		errors.append_array(_legacy_encounters.setup(_config.legacy_encounters))
	return errors


func new_campaign(campaign_id: String, timestamp: String) -> Dictionary:
	if campaign_id.strip_edges().is_empty() or timestamp.strip_edges().is_empty():
		return _failure("game flow: campaign_id and timestamp must be non-empty")
	var candidate: Dictionary = SaveEnvelopeScript.create_empty(campaign_id, timestamp)
	var campaign: Dictionary = candidate.campaign
	campaign.main_city_stage = String(_config.bootstrap.get("main_city_stage", "ruined_camp"))
	campaign.resources = _integer_dictionary(_config.bootstrap.resources)
	campaign.army_inventory = _integer_dictionary(_config.bootstrap.army_inventory)
	campaign.special_resources = _integer_dictionary(_config.bootstrap.special_resources)
	campaign.popular_support_state.value = clampi(int(_config.bootstrap.get("popular_support", 20)), 0, 100)
	var starter_public: Array = _starter_public_card_ids()
	campaign.unlocked_public_cards = starter_public.duplicate()
	campaign.base_loadout = _initial_base_loadout()
	for general_id in _config.bootstrap.general_ids:
		var definition: Dictionary = _registry.get_general(general_id)
		if definition.is_empty():
			return _failure("game flow: missing bootstrap general '%s'" % general_id)
		campaign.generals.append(GeneralManagementServiceScript.create_instance(definition, false))
	campaign.generals.append(_config.bootstrap.player_placeholder.duplicate(true))
	var validation: PackedStringArray = SaveEnvelopeScript.validate(candidate)
	if not validation.is_empty():
		return {"ok": false, "errors": validation}
	var saved: Dictionary = _save_store.save(_autosave_path(), candidate, timestamp)
	if not saved.ok:
		return _store_failure(saved)
	var restore_errors: PackedStringArray = _restore_envelope(candidate)
	if not restore_errors.is_empty():
		return {"ok": false, "errors": restore_errors}
	return {"ok": true, "errors": PackedStringArray(), "phase": phase(), "path": _autosave_path()}


func load_campaign(path: String) -> Dictionary:
	var loaded: Dictionary = _save_store.load(path, _registry)
	if not loaded.ok:
		return {"ok": false, "errors": loaded.errors}
	var errors: PackedStringArray = _restore_envelope(loaded.value)
	if not errors.is_empty():
		return {"ok": false, "errors": errors}
	return {"ok": true, "errors": PackedStringArray(), "phase": phase(), "source": loaded.source, "recovered": loaded.recovered, "migrated": loaded.get("migrated", false)}


func phase() -> String:
	if _envelope.is_empty():
		return "uninitialized"
	if _envelope.campaign.get("campaign_status", "") == "game_over":
		return "game_over"
	if _expedition == null:
		return "main_city"
	var expedition_state: Dictionary = _expedition.snapshot()
	if not expedition_state.get("pending_combat", {}).is_empty():
		return "combat_checkpoint"
	if not expedition_state.get("pending_combat_report", {}).is_empty():
		return "combat_report"
	if not expedition_state.get("pending_encounter", {}).is_empty():
		return "reward_choice" if expedition_state.pending_encounter.get("kind", "") == "reward" else "encounter_choice"
	if expedition_state.get("status", "") == "active":
		return "expedition_map"
	if expedition_state.get("status", "") in ["awaiting_settlement", "retreated", "failed"]:
		return "settlement_pending"
	return "invalid"


func snapshot() -> Dictionary:
	var result: Dictionary = _current_envelope()
	result.phase = phase()
	return result


func set_base_loadout(request: Dictionary) -> Dictionary:
	var phase_error: String = _require_phase("main_city", "modify loadout")
	if not phase_error.is_empty():
		return _failure(phase_error)
	var result: Dictionary = _campaign.set_base_loadout(request)
	_sync_campaign()
	return result


func loadout_editor_snapshot() -> Dictionary:
	var phase_error: String = _require_phase("main_city", "inspect loadout")
	if not phase_error.is_empty():
		return _failure(phase_error)
	var campaign: Dictionary = _campaign.snapshot()
	if bool(campaign.loadout_system.get("requires_legacy_recovery", false)):
		return _failure("base loadout: requires_legacy_loadout_recovery")
	var base_deck: Array = campaign.base_loadout
	var public_cards: Array = []
	for card_id in _config.research_economy.eligible_public_card_ids:
		var card: Dictionary = _registry.get_card(String(card_id))
		public_cards.append({
			"id": card_id,
			"name": card.get("name", card_id),
			"cost": int(card.get("cost", 0)),
			"rarity": card.get("rarity", ""),
			"tags": card.get("tags", []).duplicate(),
			"copy_limit": int(card.get("copy_limit", 0)),
			"description": card.get("presentation", {}).get("description", ""),
			"unlocked": campaign.unlocked_public_cards.has(card_id),
			"count": base_deck.count(card_id),
			"upgrade_branch": campaign.card_upgrade_branches.get(card_id, ""),
		})
	var previews: Array = []
	for general_id in _config.bootstrap.general_ids:
		var general := _find_campaign_general(campaign.generals, String(general_id))
		var exclusive_cards: Array = general.get("unlocked_exclusive_cards", []).duplicate()
		previews.append({
			"general_id": general_id,
			"name": general.get("name", general_id),
			"status": general.get("status", ""),
			"injury_status": general.get("injury", {}).get("status", "healthy"),
			"exclusive_cards": exclusive_cards,
			"final_size": base_deck.size() + exclusive_cards.size(),
		})
	return {
		"ok": true,
		"errors": PackedStringArray(),
		"base_deck": base_deck.duplicate(),
		"minimum_size": int(_config.deployment_rules.base_deck_min_size),
		"maximum_size": int(_config.deployment_rules.base_deck_max_size),
		"public_cards": public_cards,
		"general_previews": previews,
	}


func replenish_troops(request: Dictionary) -> Dictionary:
	var phase_error: String = _require_phase("main_city", "replenish troops")
	if not phase_error.is_empty():
		return _failure(phase_error)
	var result: Dictionary = _campaign.replenish_troops(request)
	_sync_campaign()
	return result


func unlock_public_card(request: Dictionary) -> Dictionary:
	var phase_error: String = _require_phase("main_city", "unlock card")
	if not phase_error.is_empty():
		return _failure(phase_error)
	var result: Dictionary = _campaign.unlock_public_card(request)
	_sync_campaign()
	return result


func upgrade_public_card(request: Dictionary) -> Dictionary:
	var phase_error: String = _require_phase("main_city", "upgrade card")
	if not phase_error.is_empty():
		return _failure(phase_error)
	var result: Dictionary = _campaign.upgrade_public_card(request)
	_sync_campaign()
	return result


func expedition_readiness(request: Dictionary) -> Dictionary:
	if phase() != "main_city":
		return _failure("game flow: expedition readiness is only available in main_city")
	var expedition_id := String(request.get("expedition_id", ""))
	if _is_expedition_captured(expedition_id):
		return _failure("game flow: expedition target is already controlled")
	return _deployment.readiness(_campaign.snapshot(), false, request)


func available_expeditions() -> Dictionary:
	if _campaign == null:
		return _failure("game flow: campaign is not initialized")
	var campaign: Dictionary = _campaign.snapshot()
	var targets: Array = []
	for expedition_id in _config.faction_cycle.cycle_advancing_expedition_ids:
		var definition: Dictionary = _registry.get_expedition(String(expedition_id))
		if definition.is_empty():
			continue
		var captured := _is_expedition_captured(String(expedition_id))
		targets.append({
			"expedition_id": expedition_id,
			"name": definition.name,
			"destination_name": definition.get("destination_name", definition.name),
			"theme": definition.get("theme", ""),
			"reward_summary": definition.get("reward_summary", ""),
			"boss_enemy_id": definition.get("generator_profile", {}).get("boss_enemy_id", ""),
			"captured": captured,
			"available": not captured and campaign.campaign_status == "active",
		})
	var rebellion: Dictionary = campaign.get("rebellion_state", {})
	return {"ok": true, "errors": PackedStringArray(), "targets": targets, "all_captured": not targets.is_empty() and targets.all(func(target): return bool(target.captured)), "rebellion": rebellion.duplicate(true), "popular_support": campaign.get("popular_support_state", {}).duplicate(true)}


func start_expedition(request: Dictionary, _timestamp: String) -> Dictionary:
	var phase_error: String = _require_phase("main_city", "start expedition")
	if not phase_error.is_empty():
		return _failure(phase_error)
	if _is_expedition_captured(String(request.get("expedition_id", ""))):
		return _failure("game flow: expedition target is already controlled")
	var before: Dictionary = _current_envelope()
	var assembled: Dictionary = _deployment.assemble(_campaign.snapshot(), false, request)
	if not assembled.ok:
		return assembled
	var definition: Dictionary = _registry.get_expedition(request.expedition_id)
	var generator_version := int(definition.get("generator_profile", {}).get("version", 1)) if _config.encounters.has("events") else 1
	var generated: Dictionary = ExpeditionMapGeneratorScript.generate(definition, int(request.map_seed), generator_version)
	if not generated.ok:
		return _failure(generated.error)
	var run = ExpeditionRunStateScript.new()
	var initial_support := int(_campaign.snapshot().get("popular_support_state", {}).get("value", 20))
	var errors: PackedStringArray = run.setup(request.run_id, generated.map, assembled.general, assembled.deck, assembled.card_overrides, initial_support, _config.general_progression)
	if not errors.is_empty():
		return {"ok": false, "errors": errors}
	_expedition = run
	_sync_expedition()
	var saved := _autosave("expedition_started", _timestamp)
	if not saved.ok:
		_restore_envelope(before)
		return saved
	return {"ok": true, "errors": PackedStringArray(), "phase": phase(), "army_counts": assembled.army_counts, "general": assembled.general}


func advance_to_node(node_id: String, timestamp: String) -> Dictionary:
	if phase() != "expedition_map":
		return _failure("game flow: can only advance from expedition_map")
	var before: Dictionary = _current_envelope()
	var advanced: Dictionary = _expedition.advance_to(node_id)
	if not advanced.ok:
		return advanced
	var expedition_snapshot: Dictionary = _expedition.snapshot()
	var resolver = _resolver_for_version(int(expedition_snapshot.get("generator_version", 1)))
	if resolver == null:
		_restore_envelope(before)
		return _failure("game flow: encounter resolver is unavailable for this generator version")
	var resolved: Dictionary = resolver.resolve(_expedition.current_node(), int(expedition_snapshot.seed), _registry.get_expedition(expedition_snapshot.expedition_id))
	if not resolved.ok:
		_restore_envelope(before)
		return resolved
	var resolution: Dictionary = resolved.resolution
	var event: String = "expedition_node_settled"
	var result: Dictionary
	if bool(resolution.get("requires_choice", false)):
		result = _expedition.begin_choice_resolution(resolution)
		event = "encounter_choice_created"
	elif not resolution.enemy_id.is_empty():
		var enemy: Dictionary = _registry.get_enemy(resolution.enemy_id)
		if enemy.is_empty():
			_restore_envelope(before)
			return _failure("game flow: missing encounter enemy '%s'" % resolution.enemy_id)
		result = _expedition.begin_combat_resolution(resolution, enemy)
		event = "combat_checkpoint_created"
	else:
		result = _expedition.settle_noncombat_resolution(resolution)
	if not result.ok:
		_restore_envelope(before)
		return result
	_sync_expedition()
	var saved: Dictionary = _autosave(event, timestamp)
	if not saved.ok:
		_restore_envelope(before)
		return saved
	result.phase = phase()
	result.resolution = resolution
	return result


func pending_encounter() -> Dictionary:
	if _expedition == null:
		return {}
	var encounter: Dictionary = _expedition.pending_encounter()
	for choice in encounter.get("choices", []):
		var availability: Dictionary = _expedition.choice_availability(String(choice.get("choice_id", "")))
		choice.available = bool(availability.get("available", false))
		choice.unavailable_reason = String(availability.get("reason", ""))
		choice.erase("resolved_effects")
		var card_id := String(choice.get("card_id", ""))
		if not card_id.is_empty():
			var card: Dictionary = _registry.get_card(card_id)
			choice.card_name = card.get("name", card_id)
			choice.card_description = card.get("presentation", {}).get("description", "")
	return encounter


func submit_encounter_choice(request: Dictionary, timestamp: String) -> Dictionary:
	if _expedition != null and _expedition.snapshot().get("choice_action_ids", []).has(String(request.get("action_id", ""))):
		return {"ok": true, "duplicate": true, "errors": PackedStringArray(), "phase": phase()}
	if not phase() in ["encounter_choice", "reward_choice"]:
		return _failure("game flow: no expedition choice is pending")
	for field in ["action_id", "choice_id"]:
		if String(request.get(field, "")).strip_edges().is_empty():
			return _failure("game flow: encounter choice requires %s" % field)
	var before := _current_envelope()
	var encounter: Dictionary = _expedition.pending_encounter()
	var selected: Dictionary = {}
	for choice in encounter.get("choices", []):
		if choice.get("choice_id", "") == request.choice_id:
			selected = choice
			break
	var enemy: Dictionary = {}
	var enemy_id := String(selected.get("combat_enemy_id", ""))
	if not enemy_id.is_empty(): enemy = _registry.get_enemy(enemy_id)
	var applied: Dictionary = _expedition.submit_encounter_choice(String(request.action_id), String(request.choice_id), enemy)
	if not applied.ok:
		_restore_envelope(before)
		return applied
	_sync_expedition()
	var event := "expedition_terminal_checkpoint" if phase() == "settlement_pending" else ("combat_checkpoint_created" if phase() == "combat_checkpoint" else "encounter_choice_settled")
	var saved := _autosave(event, timestamp)
	if not saved.ok:
		_restore_envelope(before)
		return saved
	applied.phase = phase()
	return applied


func use_expedition_item(request: Dictionary, timestamp: String) -> Dictionary:
	if _expedition != null and _expedition.snapshot().get("applied_item_action_ids", []).has(String(request.get("action_id", ""))):
		return {"ok": true, "duplicate": true, "errors": PackedStringArray(), "phase": phase()}
	if _expedition == null or not phase() in ["expedition_map", "encounter_choice", "reward_choice"]:
		return _failure("game flow: temporary items can only be used between combats")
	var item_id := ""
	for item in _expedition.snapshot().get("temporary_items", []):
		if item.get("instance_id", "") == request.get("item_instance_id", ""):
			item_id = String(item.item_id)
			break
	if item_id.is_empty():
		return _failure("game flow: unknown temporary item instance")
	var definition: Dictionary = _encounters.item_definition(item_id)
	definition.id = item_id
	var before := _current_envelope()
	var applied: Dictionary = _expedition.use_temporary_item(String(request.get("action_id", "")), String(request.get("item_instance_id", "")), definition)
	if not applied.ok:
		return applied
	_sync_expedition()
	var saved := _autosave("expedition_item_used", timestamp)
	if not saved.ok:
		_restore_envelope(before)
		return saved
	applied.phase = phase()
	return applied


func expedition_run_snapshot() -> Dictionary:
	if _expedition == null:
		return {}
	var result: Dictionary = _expedition.snapshot()
	for item in result.get("temporary_items", []):
		var definition: Dictionary = _encounters.item_definition(String(item.get("item_id", "")))
		item.name = definition.get("name", item.get("item_id", ""))
		item.description = definition.get("description", "")
	for node in result.get("visible_nodes", []):
		if not bool(node.get("is_detail_revealed", false)):
			continue
		var enemy_id := String(node.get("enemy_id", ""))
		if not enemy_id.is_empty():
			var enemy: Dictionary = _registry.get_enemy(enemy_id)
			if not enemy.is_empty():
				node.name = String(enemy.get("name", node.name))
		var encounter_id := String(node.get("encounter_id", ""))
		if not encounter_id.is_empty():
			var encounter_definition: Dictionary = _encounters.event_definition(encounter_id)
			if not encounter_definition.is_empty():
				node.name = String(encounter_definition.get("name", node.name))
	return result


func pending_combat_request() -> Dictionary:
	if _expedition == null:
		return {}
	return _expedition.pending_combat_request()


func pending_combat_report() -> Dictionary:
	if _expedition == null:
		return {}
	var report: Dictionary = _expedition.pending_combat_report()
	if report.is_empty():
		return report
	var enemy: Dictionary = _registry.get_enemy(String(report.get("enemy_id", "")))
	report.enemy_name = enemy.get("name", report.get("enemy_id", "未知敌军"))
	var item_id := String(report.get("item_gained", ""))
	if not item_id.is_empty():
		var item: Dictionary = _encounters.item_definition(item_id)
		report.item_name = item.get("name", item_id)
	return report


func submit_combat_result(result: Dictionary, timestamp: String) -> Dictionary:
	if phase() != "combat_checkpoint":
		var battle_id: String = String(result.get("battle_id", ""))
		if _expedition != null and _expedition.snapshot().get("settled_battle_ids", []).has(battle_id):
			return {"ok": true, "duplicate": true, "errors": PackedStringArray(), "phase": phase()}
		return _failure("game flow: no combat checkpoint is pending")
	var before: Dictionary = _current_envelope()
	var applied: Dictionary = _expedition.apply_combat_result(result)
	if not applied.ok:
		return applied
	_sync_expedition()
	var event: String = "combat_report_created" if phase() == "combat_report" else ("expedition_terminal_checkpoint" if phase() == "settlement_pending" else "expedition_node_settled")
	var saved: Dictionary = _autosave(event, timestamp)
	if not saved.ok:
		_restore_envelope(before)
		return saved
	applied.phase = phase()
	return applied


func acknowledge_combat_report(request: Dictionary, timestamp: String) -> Dictionary:
	var action_id := String(request.get("action_id", ""))
	if _expedition != null and _expedition.snapshot().get("acknowledged_combat_report_action_ids", []).has(action_id):
		return {"ok": true, "duplicate": true, "errors": PackedStringArray(), "phase": phase()}
	if phase() != "combat_report":
		return _failure("game flow: no combat report is pending")
	var report_id := String(request.get("report_id", ""))
	if action_id.strip_edges().is_empty() or report_id.strip_edges().is_empty():
		return _failure("game flow: combat report confirmation requires action_id and report_id")
	var before := _current_envelope()
	var acknowledged: Dictionary = _expedition.acknowledge_combat_report(action_id, report_id)
	if not acknowledged.ok:
		return acknowledged
	_sync_expedition()
	var saved := _autosave("combat_report_acknowledged", timestamp)
	if not saved.ok:
		_restore_envelope(before)
		return saved
	acknowledged.phase = phase()
	return acknowledged


func finalize_expedition(timestamp: String) -> Dictionary:
	if phase() != "settlement_pending":
		return _failure("game flow: expedition is not pending final settlement")
	var before: Dictionary = _current_envelope()
	var settlement: Dictionary = _expedition.create_settlement_request()
	if not settlement.ok:
		return settlement
	var committed: Dictionary = _campaign.apply_expedition_settlement(settlement.request)
	if not committed.ok:
		return committed
	var finalized: Dictionary = _campaign.finalize_pending_settlement(settlement.request.request_id)
	if not finalized.ok:
		_restore_envelope(before)
		return finalized
	_expedition = null
	_sync_campaign()
	_envelope.expedition = null
	var saved: Dictionary = _autosave("expedition_final_settled", timestamp)
	if not saved.ok:
		_restore_envelope(before)
		return saved
	return {"ok": true, "duplicate": false, "errors": PackedStringArray(), "phase": phase(), "settlement_request_id": settlement.request.request_id, "game_over": finalized.get("game_over", false)}


func recover_legacy_base_loadout(action_id: String, timestamp: String) -> Dictionary:
	var phase_error: String = _require_phase("main_city", "recover legacy loadouts")
	if not phase_error.is_empty():
		return _failure(phase_error)
	var result: Dictionary = _campaign.recover_legacy_base_loadout({"action_id": action_id, "timestamp": timestamp}, _starter_public_card_ids(), _initial_base_loadout())
	_sync_campaign()
	return result


func save_manual(slot_number: int, timestamp: String) -> Dictionary:
	if not SaveSlotPolicyScript.can_manual_save(phase()):
		return _failure("game flow: manual save is not allowed during '%s'" % phase())
	var slot_id: String = SaveSlotPolicyScript.manual_slot_id(slot_number)
	if slot_id.is_empty():
		return _failure("game flow: manual slot must be between 1 and 3")
	var saved: Dictionary = _save_store.save("%s/%s.json" % [_save_root, slot_id], _current_envelope(), timestamp)
	if not saved.ok:
		return _store_failure(saved)
	_envelope.updated_at = timestamp
	return {"ok": true, "errors": PackedStringArray(), "path": "%s/%s.json" % [_save_root, slot_id]}


func _restore_envelope(source: Dictionary) -> PackedStringArray:
	var validation: PackedStringArray = SaveEnvelopeScript.validate(source)
	if not validation.is_empty():
		return validation
	var campaign = CampaignControllerScript.new()
	var errors: PackedStringArray = campaign.setup(source.campaign)
	if not errors.is_empty():
		return errors
	errors.append_array(_configure_campaign(campaign))
	if not errors.is_empty():
		return errors
	var run = null
	if source.expedition is Dictionary:
		var generator_version := int(source.expedition.get("generator_version", 1))
		var generated: Dictionary = ExpeditionMapGeneratorScript.generate(_registry.get_expedition(source.expedition.expedition_id), int(source.expedition.seed), generator_version)
		if not generated.ok:
			return PackedStringArray([generated.error])
		run = ExpeditionRunStateScript.new()
		var campaign_general := _find_campaign_general(source.campaign.get("generals", []), String(source.expedition.get("general", {}).get("id", "")))
		errors.append_array(run.restore(source.expedition, generated.map, _config.general_progression, campaign_general))
		if not errors.is_empty():
			return errors
	_envelope = source.duplicate(true)
	_campaign = campaign
	_expedition = run
	return PackedStringArray()


func _configure_campaign(campaign) -> PackedStringArray:
	var errors := PackedStringArray()
	errors.append_array(campaign.configure_army_economy(_config.army_economy))
	errors.append_array(campaign.configure_research(_config.research_economy, _card_definitions()))
	errors.append_array(campaign.configure_generals(_config.general_progression, _general_definitions()))
	errors.append_array(campaign.configure_faction(_config.faction_cycle, _territory_definitions()))
	errors.append_array(campaign.configure_loadouts(
		_card_definitions(),
		int(_config.deployment_rules.base_deck_min_size),
		int(_config.deployment_rules.base_deck_max_size)
	))
	return errors


func _autosave(event: String, timestamp: String) -> Dictionary:
	if not SaveSlotPolicyScript.should_autosave(event):
		return _failure("game flow: unsupported autosave event '%s'" % event)
	var saved: Dictionary = _save_store.save(_autosave_path(), _current_envelope(), timestamp)
	if not saved.ok:
		return _store_failure(saved)
	_envelope.updated_at = timestamp
	return {"ok": true, "errors": PackedStringArray()}


func _current_envelope() -> Dictionary:
	var result: Dictionary = _envelope.duplicate(true)
	if _campaign != null:
		result.campaign = _campaign.snapshot()
	if _expedition != null:
		result.expedition = _expedition.snapshot()
	else:
		result.expedition = null
	return result


func _sync_campaign() -> void:
	_envelope.campaign = _campaign.snapshot()


func _sync_expedition() -> void:
	_envelope.expedition = _expedition.snapshot() if _expedition != null else null


func _card_definitions() -> Array:
	var result: Array = []
	for card_id in _config.get("research_economy", {}).get("eligible_public_card_ids", []):
		result.append(_registry.get_card(card_id))
	for general_id in _config.get("bootstrap", {}).get("general_ids", []):
		for card_id in _registry.get_general(general_id).get("starting_deck", []):
			if not _contains_definition(result, card_id):
				result.append(_registry.get_card(card_id))
	return result


func _general_definitions() -> Array:
	var result: Array = []
	for general_id in _config.bootstrap.general_ids:
		result.append(_registry.get_general(general_id))
	return result


func _territory_definitions() -> Array:
	var result: Array = []
	for expedition_id in _config.get("faction_cycle", {}).get("cycle_advancing_expedition_ids", []):
		var expedition: Dictionary = _registry.get_expedition(String(expedition_id))
		var territory_id := String(expedition.get("territory_id", ""))
		if territory_id.is_empty() and expedition_id == "expedition.capture_heyuan_county":
			territory_id = "territory.heyuan_county"
		var territory: Dictionary = _registry.get_territory(territory_id)
		if not territory.is_empty():
			result.append(territory)
	return result


func _starter_public_card_ids() -> Array:
	var locked: Array = _config.bootstrap.get("locked_initial_public_card_ids", [])
	var result: Array = []
	for general_id in _config.bootstrap.general_ids:
		for card_id in _registry.get_general(general_id).starting_deck:
			var card: Dictionary = _registry.get_card(card_id)
			if card.get("owner_scope", "") == "public" and not locked.has(card_id) and not result.has(card_id):
				result.append(card_id)
	return result


func _initial_base_loadout() -> Array:
	return _config.bootstrap.get("initial_base_loadout", []).duplicate()


func _find_campaign_general(generals: Array, general_id: String) -> Dictionary:
	for general in generals:
		if general is Dictionary and general.get("general_id", "") == general_id:
			return general
	return {}


func _contains_definition(definitions: Array, id: String) -> bool:
	for definition in definitions:
		if definition is Dictionary and definition.get("id", "") == id:
			return true
	return false


func _integer_dictionary(source: Dictionary) -> Dictionary:
	var result := {}
	for key in source:
		result[key] = int(source[key])
	return result


func _autosave_path() -> String:
	return "%s/autosave.json" % _save_root


func _require_phase(expected: String, action: String) -> String:
	if phase() != expected:
		return "game flow: cannot %s during '%s'" % [action, phase()]
	return ""


func _store_failure(result: Dictionary) -> Dictionary:
	return {"ok": false, "errors": result.get("errors", PackedStringArray(["save failed"])), "save_failed": true}


func _failure(message: String) -> Dictionary:
	return {"ok": false, "errors": PackedStringArray([message])}


func _is_expedition_captured(expedition_id: String) -> bool:
	if _campaign == null:
		return false
	for territory in _campaign.snapshot().get("territories", []):
		var definition: Dictionary = _registry.get_territory(String(territory.get("territory_id", "")))
		if definition.get("source_expedition_id", "") == expedition_id:
			return true
	return false


func _resolver_for_version(generator_version: int):
	if generator_version == 1 and _legacy_encounters != null:
		return _legacy_encounters
	return _encounters
