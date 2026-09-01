extends RefCounted
class_name CampaignController

const CampaignStateScript := preload("res://src/domain/campaign/campaign_state.gd")
const ArmyManagementServiceScript := preload("res://src/domain/campaign/army_management_service.gd")
const ResearchManagementServiceScript := preload("res://src/domain/campaign/research_management_service.gd")
const GeneralManagementServiceScript := preload("res://src/domain/campaign/general_management_service.gd")
const FactionCycleServiceScript := preload("res://src/domain/campaign/faction_cycle_service.gd")

const RESOURCE_KEY_BY_LOOT_ID := {
	"resource.silver": "silver",
	"resource.food": "food",
	"resource.recruits": "recruits",
	"resource.military_knowledge": "military_knowledge",
}

var _state: Dictionary = {}
var _army_economy: Dictionary = {}
var _research_economy: Dictionary = {}
var _research_cards: Dictionary = {}
var _general_progression: Dictionary = {}
var _general_definitions: Dictionary = {}
var _faction_cycle: Dictionary = {}
var _territory_definitions: Dictionary = {}
var _territory_by_expedition: Dictionary = {}


func setup(campaign_source: Dictionary) -> PackedStringArray:
	_state = {}
	var normalized := CampaignStateScript.normalize(campaign_source)
	var errors: PackedStringArray = CampaignStateScript.validate(normalized)
	if errors.is_empty():
		_state = normalized
	return errors


func apply_expedition_settlement(request: Dictionary) -> Dictionary:
	if _state.is_empty():
		return {"ok": false, "duplicate": false, "errors": PackedStringArray(["campaign: controller is not initialized"]), "resource_changes": {}}
	var errors := _validate_settlement(request)
	if not errors.is_empty():
		return {"ok": false, "duplicate": false, "errors": errors, "resource_changes": {}}
	var request_id: String = request.request_id
	if _state.applied_settlement_ids.has(request_id):
		return {"ok": true, "duplicate": true, "errors": PackedStringArray(), "resource_changes": {}}
	var next_state := _state.duplicate(true)
	var resource_changes := {}
	var army_losses := {"infantry": 0, "archer": 0, "cavalry": 0}
	if request.has("initial_troops") and request.has("army_composition"):
		var casualty_result: Dictionary = ArmyManagementServiceScript.calculate_casualties(request.initial_troops, request.remaining_troops, request.army_composition)
		if not casualty_result.ok:
			return {"ok": false, "duplicate": false, "errors": casualty_result.errors, "resource_changes": {}}
		army_losses = casualty_result.losses
		for army_type in ArmyManagementServiceScript.ARMY_TYPE_IDS:
			if int(next_state.army_inventory[army_type]) < int(army_losses[army_type]):
				return {"ok": false, "duplicate": false, "errors": PackedStringArray(["campaign: insufficient '%s' inventory for expedition casualties" % army_type]), "resource_changes": {}}
		for army_type in ArmyManagementServiceScript.ARMY_TYPE_IDS:
			next_state.army_inventory[army_type] = int(next_state.army_inventory[army_type]) - int(army_losses[army_type])
	if request.outcome == "success":
		for loot_id in request.loot_to_bank:
			var amount := int(request.loot_to_bank[loot_id])
			if RESOURCE_KEY_BY_LOOT_ID.has(loot_id):
				var resource_key: String = RESOURCE_KEY_BY_LOOT_ID[loot_id]
				next_state.resources[resource_key] = int(next_state.resources[resource_key]) + amount
				resource_changes[resource_key] = int(resource_changes.get(resource_key, 0)) + amount
			else:
				next_state.special_resources[loot_id] = int(next_state.special_resources.get(loot_id, 0)) + amount
				resource_changes[loot_id] = int(resource_changes.get(loot_id, 0)) + amount
	next_state.applied_settlement_ids.append(request_id)
	next_state.settlement_history.append({
		"request_id": request_id,
		"run_id": request.run_id,
		"expedition_id": request.expedition_id,
		"outcome": request.outcome,
		"resource_changes": resource_changes.duplicate(true),
		"army_losses": army_losses.duplicate(true),
	})
	next_state.pending_long_term_effects.append({
		"request_id": request_id,
		"general_id": request.general_id,
		"remaining_troops": int(request.remaining_troops),
		"remaining_morale": int(request.remaining_morale),
		"general_died": bool(request.general_died),
		"general_injured": bool(request.general_injured),
		"expedition_id": request.expedition_id,
		"outcome": request.outcome,
		"army_losses": army_losses.duplicate(true),
		"army_losses_applied": request.has("initial_troops") and request.has("army_composition"),
		"general_effect_applied": false,
		"faction_effect_applied": false,
	})
	_state = next_state
	return {"ok": true, "duplicate": false, "errors": PackedStringArray(), "resource_changes": resource_changes}


func snapshot() -> Dictionary:
	return _state.duplicate(true)


func configure_army_economy(definition: Dictionary) -> PackedStringArray:
	_army_economy = {}
	var errors := ArmyManagementServiceScript.validate_economy_definition(definition)
	if errors.is_empty():
		_army_economy = definition.duplicate(true)
	return errors


func replenish_troops(request: Dictionary) -> Dictionary:
	if _state.is_empty():
		return _army_action_failure("campaign: controller is not initialized")
	if _army_economy.is_empty():
		return _army_action_failure("campaign: army economy is not configured")
	for field in ["action_id", "army_type", "batches"]:
		if not request.has(field):
			return _army_action_failure("army training: missing field '%s'" % field)
	if not request.action_id is String or request.action_id.strip_edges().is_empty():
		return _army_action_failure("army training: action_id must be a non-empty string")
	if _state.applied_army_action_ids.has(request.action_id):
		return {"ok": true, "duplicate": true, "errors": PackedStringArray(), "troops_added": 0, "main_costs": {}, "special_costs": {}}
	var quote: Dictionary = ArmyManagementServiceScript.quote_replenishment(_army_economy, String(request.army_type), request.batches)
	if not quote.ok:
		return {"ok": false, "duplicate": false, "errors": quote.errors, "troops_added": 0, "main_costs": {}, "special_costs": {}}
	for resource_id in quote.main_costs:
		if int(_state.resources.get(resource_id, 0)) < int(quote.main_costs[resource_id]):
			return _army_action_failure("army training: insufficient main resource '%s'" % resource_id)
	for resource_id in quote.special_costs:
		if int(_state.special_resources.get(resource_id, 0)) < int(quote.special_costs[resource_id]):
			return _army_action_failure("army training: insufficient special resource '%s'" % resource_id)
	var next_state := _state.duplicate(true)
	for resource_id in quote.main_costs:
		next_state.resources[resource_id] = int(next_state.resources[resource_id]) - int(quote.main_costs[resource_id])
	for resource_id in quote.special_costs:
		next_state.special_resources[resource_id] = int(next_state.special_resources[resource_id]) - int(quote.special_costs[resource_id])
	next_state.army_inventory[request.army_type] = int(next_state.army_inventory[request.army_type]) + int(quote.troops_added)
	next_state.applied_army_action_ids.append(request.action_id)
	next_state.army_history.append({
		"action_id": request.action_id,
		"action": "replenish_troops",
		"army_type": request.army_type,
		"batches": int(request.batches),
		"troops_added": int(quote.troops_added),
		"main_costs": quote.main_costs.duplicate(true),
		"special_costs": quote.special_costs.duplicate(true),
	})
	_state = next_state
	return {
		"ok": true,
		"duplicate": false,
		"errors": PackedStringArray(),
		"troops_added": quote.troops_added,
		"main_costs": quote.main_costs,
		"special_costs": quote.special_costs,
	}


func configure_research(economy_definition: Dictionary, card_definitions: Array) -> PackedStringArray:
	_research_economy = {}
	_research_cards = {}
	var errors := ResearchManagementServiceScript.validate_card_catalog(economy_definition, card_definitions)
	if not errors.is_empty():
		return errors
	_research_economy = economy_definition.duplicate(true)
	for card in card_definitions:
		if _research_economy.eligible_public_card_ids.has(card.id):
			_research_cards[card.id] = card.duplicate(true)
	return errors


func unlock_public_card(request: Dictionary) -> Dictionary:
	var common_error := _validate_research_action_request(request, false)
	if not common_error.is_empty():
		return _research_action_failure(common_error)
	var action_id: String = request.action_id
	if _state.research.applied_action_ids.has(action_id):
		return _research_duplicate()
	var card_id: String = request.card_id
	if _state.unlocked_public_cards.has(card_id):
		return _research_action_failure("research: public card '%s' is already unlocked" % card_id)
	var quote: Dictionary = ResearchManagementServiceScript.quote_unlock(_research_economy, _research_cards[card_id])
	if not quote.ok:
		return _research_failure_from_errors(quote.errors)
	var affordability_error := _research_affordability_error(quote)
	if not affordability_error.is_empty():
		return _research_action_failure(affordability_error)
	var next_state := _state.duplicate(true)
	_deduct_research_costs(next_state, quote)
	next_state.unlocked_public_cards.append(card_id)
	next_state.research.applied_action_ids.append(action_id)
	next_state.research.history.append({
		"action_id": action_id,
		"action": "unlock_public_card",
		"card_id": card_id,
		"main_costs": quote.main_costs.duplicate(true),
		"special_costs": quote.special_costs.duplicate(true),
	})
	_state = next_state
	return {"ok": true, "duplicate": false, "errors": PackedStringArray(), "main_costs": quote.main_costs, "special_costs": quote.special_costs}


func upgrade_public_card(request: Dictionary) -> Dictionary:
	var common_error := _validate_research_action_request(request, true)
	if not common_error.is_empty():
		return _research_action_failure(common_error)
	var action_id: String = request.action_id
	if _state.research.applied_action_ids.has(action_id):
		return _research_duplicate()
	var card_id: String = request.card_id
	if not _state.unlocked_public_cards.has(card_id):
		return _research_action_failure("research: public card '%s' must be unlocked before upgrade" % card_id)
	if _state.card_upgrade_branches.has(card_id):
		return _research_action_failure("research: public card '%s' already has a permanent upgrade" % card_id)
	var branch_id: String = request.branch_id
	var quote: Dictionary = ResearchManagementServiceScript.quote_upgrade(_research_economy, _research_cards[card_id], branch_id)
	if not quote.ok:
		return _research_failure_from_errors(quote.errors)
	var affordability_error := _research_affordability_error(quote)
	if not affordability_error.is_empty():
		return _research_action_failure(affordability_error)
	var next_state := _state.duplicate(true)
	_deduct_research_costs(next_state, quote)
	next_state.card_upgrade_branches[card_id] = branch_id
	next_state.research.applied_action_ids.append(action_id)
	next_state.research.history.append({
		"action_id": action_id,
		"action": "upgrade_public_card",
		"card_id": card_id,
		"branch_id": branch_id,
		"main_costs": quote.main_costs.duplicate(true),
		"special_costs": quote.special_costs.duplicate(true),
	})
	_state = next_state
	return {"ok": true, "duplicate": false, "errors": PackedStringArray(), "main_costs": quote.main_costs, "special_costs": quote.special_costs}


func resolved_public_card(card_id: String) -> Dictionary:
	if _state.is_empty():
		return {"ok": false, "errors": PackedStringArray(["campaign: controller is not initialized"]), "card": {}}
	if not _research_cards.has(card_id):
		return {"ok": false, "errors": PackedStringArray(["research: unknown public card '%s'" % card_id]), "card": {}}
	if not _state.unlocked_public_cards.has(card_id):
		return {"ok": false, "errors": PackedStringArray(["research: public card '%s' is locked" % card_id]), "card": {}}
	return ResearchManagementServiceScript.resolve_card_definition(_research_cards[card_id], String(_state.card_upgrade_branches.get(card_id, "")))


func configure_generals(progression_definition: Dictionary, general_definitions: Array) -> PackedStringArray:
	_general_progression = {}
	_general_definitions = {}
	var errors := GeneralManagementServiceScript.validate_progression_definition(progression_definition)
	errors.append_array(GeneralManagementServiceScript.validate_general_catalog(general_definitions))
	if not errors.is_empty():
		return errors
	_general_progression = progression_definition.duplicate(true)
	for definition in general_definitions:
		_general_definitions[definition.id] = definition.duplicate(true)
	return errors


func initialize_general(request: Dictionary) -> Dictionary:
	var common_error := _validate_general_action_request(request, ["action_id", "general_id"], true)
	if not common_error.is_empty():
		return _general_action_failure(common_error)
	var action_id: String = request.action_id
	if _state.general_system.applied_initialization_ids.has(action_id):
		return _general_action_duplicate()
	var general_id: String = request.general_id
	if not _general_definitions.has(general_id):
		return _general_action_failure("general: unknown catalog general '%s'" % general_id)
	if _find_general_index(general_id) >= 0:
		return _general_action_failure("general: '%s' is already initialized" % general_id)
	var next_state := _state.duplicate(true)
	var instance: Dictionary = GeneralManagementServiceScript.create_instance(_general_definitions[general_id], false)
	next_state.generals.append(instance)
	next_state.general_system.applied_initialization_ids.append(action_id)
	next_state.general_system.history.append({
		"action_id": action_id,
		"action": "initialize_general",
		"general_id": general_id,
	})
	_state = next_state
	return {"ok": true, "duplicate": false, "errors": PackedStringArray(), "general": instance.duplicate(true)}


func apply_pending_general_effect(request_id: String) -> Dictionary:
	if _state.is_empty():
		return _general_action_failure("campaign: controller is not initialized")
	if _general_progression.is_empty():
		return _general_action_failure("campaign: general progression is not configured")
	if request_id.strip_edges().is_empty():
		return _general_action_failure("general effect: request_id must be a non-empty string")
	if _state.general_system.applied_effect_ids.has(request_id):
		return _general_action_duplicate()
	var effect_index := _find_pending_effect_index(request_id)
	if effect_index < 0:
		return _general_action_failure("general effect: unknown settlement request '%s'" % request_id)
	var effect: Dictionary = _state.pending_long_term_effects[effect_index]
	var effect_error := _validate_pending_general_effect(effect, request_id)
	if not effect_error.is_empty():
		return _general_action_failure(effect_error)
	if bool(effect.get("general_effect_applied", false)):
		return _general_action_duplicate()
	if bool(effect.get("general_died", false)) and bool(effect.get("general_injured", false)):
		return _general_action_failure("general effect: death and major injury cannot both be true")
	var general_id: String = String(effect.get("general_id", ""))
	var general_index := _find_general_index(general_id)
	if general_index < 0:
		return _general_action_failure("general effect: unknown campaign general '%s'" % general_id)
	var instance: Dictionary = _state.generals[general_index]
	if instance.status != "active":
		return _general_action_failure("general effect: general '%s' is not active" % general_id)
	var applied: Dictionary = GeneralManagementServiceScript.apply_expedition_effect(instance, effect, _general_progression)
	var next_state := _state.duplicate(true)
	next_state.generals[general_index] = applied.instance
	next_state.pending_long_term_effects[effect_index].general_effect_applied = true
	next_state.general_system.applied_effect_ids.append(request_id)
	next_state.general_system.history.append({
		"action_id": request_id,
		"action": "apply_expedition_effect",
		"general_id": general_id,
		"experience_gained": applied.experience_gained,
		"level_gained": applied.level_gained,
		"died": applied.died,
		"injured": applied.injured,
	})
	var game_over := bool(applied.died) and bool(applied.instance.is_player_character)
	if game_over:
		next_state.campaign_status = "game_over"
		next_state.game_over_record = {
			"request_id": request_id,
			"general_id": general_id,
			"reason": "player_character_died",
		}
	_state = next_state
	return {
		"ok": true,
		"duplicate": false,
		"errors": PackedStringArray(),
		"general": applied.instance.duplicate(true),
		"experience_gained": applied.experience_gained,
		"level_gained": applied.level_gained,
		"died": applied.died,
		"injured": applied.injured,
		"game_over": game_over,
	}


func apply_general_recovery_cycle(action_id: String) -> Dictionary:
	if _state.is_empty():
		return _general_action_failure("campaign: controller is not initialized")
	if action_id.strip_edges().is_empty():
		return _general_action_failure("general recovery: action_id must be a non-empty string")
	if _state.general_system.applied_recovery_ids.has(action_id):
		return _general_action_duplicate()
	if _state.campaign_status != "active":
		return _general_action_failure("general recovery: campaign is already game_over")
	var next_state := _state.duplicate(true)
	var changed_general_ids := []
	var recovered_general_ids := []
	for index in next_state.generals.size():
		var recovery: Dictionary = GeneralManagementServiceScript.advance_recovery(next_state.generals[index])
		if recovery.changed:
			next_state.generals[index] = recovery.instance
			changed_general_ids.append(recovery.instance.general_id)
			if recovery.recovered:
				recovered_general_ids.append(recovery.instance.general_id)
	next_state.general_system.applied_recovery_ids.append(action_id)
	next_state.general_system.history.append({
		"action_id": action_id,
		"action": "advance_injury_recovery",
		"changed_general_ids": changed_general_ids.duplicate(true),
		"recovered_general_ids": recovered_general_ids.duplicate(true),
	})
	_state = next_state
	return {
		"ok": true,
		"duplicate": false,
		"errors": PackedStringArray(),
		"changed_general_ids": changed_general_ids,
		"recovered_general_ids": recovered_general_ids,
	}


func general_availability(general_id: String) -> Dictionary:
	if _state.is_empty():
		return {"ok": false, "available": false, "reason": "campaign_not_initialized"}
	if _state.campaign_status != "active":
		return {"ok": true, "available": false, "reason": "campaign_game_over"}
	var index := _find_general_index(general_id)
	if index < 0:
		return {"ok": false, "available": false, "reason": "unknown_general"}
	var instance: Dictionary = _state.generals[index]
	if not bool(instance.vertical_slice_deployment_enabled):
		return {"ok": true, "available": false, "reason": "vertical_slice_player_placeholder"}
	if instance.status == "deceased":
		return {"ok": true, "available": false, "reason": "deceased"}
	if instance.injury.status == "major_injury":
		return {"ok": true, "available": false, "reason": "major_injury"}
	return {"ok": true, "available": true, "reason": "available"}


func configure_faction(cycle_definition: Dictionary, territory_definitions: Array) -> PackedStringArray:
	_faction_cycle = {}
	_territory_definitions = {}
	_territory_by_expedition = {}
	var errors := FactionCycleServiceScript.validate_catalog(cycle_definition, territory_definitions)
	if not errors.is_empty():
		return errors
	_faction_cycle = cycle_definition.duplicate(true)
	for definition in territory_definitions:
		_territory_definitions[definition.id] = definition.duplicate(true)
		_territory_by_expedition[definition.source_expedition_id] = definition.duplicate(true)
	return errors


func apply_pending_faction_effect(request_id: String) -> Dictionary:
	if _state.is_empty():
		return _faction_action_failure("campaign: controller is not initialized")
	if _faction_cycle.is_empty() or _territory_definitions.is_empty():
		return _faction_action_failure("campaign: faction catalog is not configured")
	if _state.campaign_status != "active":
		return _faction_action_failure("faction cycle: campaign is already game_over")
	if request_id.strip_edges().is_empty():
		return _faction_action_failure("faction effect: request_id must be a non-empty string")
	if _state.faction.applied_effect_ids.has(request_id):
		return _faction_action_duplicate()
	var effect_index := _find_pending_effect_index(request_id)
	if effect_index < 0:
		return _faction_action_failure("faction effect: unknown settlement request '%s'" % request_id)
	var effect: Dictionary = _state.pending_long_term_effects[effect_index]
	var effect_error := _validate_pending_faction_effect(effect, request_id)
	if not effect_error.is_empty():
		return _faction_action_failure(effect_error)
	if bool(effect.faction_effect_applied):
		return _faction_action_duplicate()
	var expedition_id: String = effect.expedition_id
	var outcome: String = effect.outcome
	var advances_cycle: bool = _faction_cycle.cycle_advancing_expedition_ids.has(expedition_id) and _faction_cycle.cycle_advancing_outcomes.has(outcome)
	var next_state := _state.duplicate(true)
	if not advances_cycle:
		next_state.pending_long_term_effects[effect_index].faction_effect_applied = true
		next_state.faction.applied_effect_ids.append(request_id)
		next_state.faction.history.append({
			"action_id": request_id,
			"action": "skip_faction_cycle",
			"expedition_id": expedition_id,
			"outcome": outcome,
			"reason": "outcome_not_configured" if _faction_cycle.cycle_advancing_expedition_ids.has(expedition_id) else "not_major_expedition",
		})
		_state = next_state
		return {
			"ok": true,
			"duplicate": false,
			"skipped": true,
			"errors": PackedStringArray(),
			"cycle_advanced": 0,
			"captured_territory_ids": [],
			"main_income": {},
			"special_income": {},
			"changed_general_ids": [],
			"recovered_general_ids": [],
		}
	var target_cycle := int(next_state.cycle) + 1
	var captured_territory_ids := []
	if _territory_by_expedition.has(expedition_id):
		var territory_definition: Dictionary = _territory_by_expedition[expedition_id]
		if _find_territory_index_in_state(next_state, territory_definition.id) < 0:
			next_state.territories.append(FactionCycleServiceScript.create_territory_instance(territory_definition, target_cycle, request_id))
			next_state.main_city_stage = territory_definition.main_city_stage_on_capture
			captured_territory_ids.append(territory_definition.id)
	var income: Dictionary = FactionCycleServiceScript.calculate_cycle_income(
		next_state.territories,
		_territory_definitions,
		target_cycle,
		int(_faction_cycle.new_territory_income_delay_cycles)
	)
	if not income.ok:
		return _faction_failure_from_errors(income.errors)
	for resource_id in income.main_income:
		next_state.resources[resource_id] = int(next_state.resources.get(resource_id, 0)) + int(income.main_income[resource_id])
	for resource_id in income.special_income:
		next_state.special_resources[resource_id] = int(next_state.special_resources.get(resource_id, 0)) + int(income.special_income[resource_id])
	next_state.cycle = target_cycle
	var recovery_action_id := "faction-recovery:%s" % request_id
	var recovery: Dictionary = _advance_general_recovery_in_state(next_state, recovery_action_id)
	next_state.pending_long_term_effects[effect_index].faction_effect_applied = true
	next_state.faction.applied_effect_ids.append(request_id)
	next_state.faction.history.append({
		"action_id": request_id,
		"action": "advance_faction_cycle",
		"expedition_id": expedition_id,
		"outcome": outcome,
		"from_cycle": target_cycle - 1,
		"to_cycle": target_cycle,
		"captured_territory_ids": captured_territory_ids.duplicate(true),
		"contributing_territory_ids": income.contributing_territory_ids.duplicate(true),
		"main_income": income.main_income.duplicate(true),
		"special_income": income.special_income.duplicate(true),
		"recovery_action_id": recovery_action_id,
	})
	var state_errors: PackedStringArray = CampaignStateScript.validate(next_state)
	if not state_errors.is_empty():
		return _faction_failure_from_errors(state_errors)
	_state = next_state
	return {
		"ok": true,
		"duplicate": false,
		"skipped": false,
		"errors": PackedStringArray(),
		"cycle_advanced": 1,
		"captured_territory_ids": captured_territory_ids,
		"main_income": income.main_income,
		"special_income": income.special_income,
		"changed_general_ids": recovery.changed_general_ids,
		"recovered_general_ids": recovery.recovered_general_ids,
	}


func _validate_settlement(request: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if _state.get("campaign_status", "active") != "active":
		errors.append("settlement: campaign is already game_over")
	for field in ["request_id", "run_id", "expedition_id", "outcome", "general_id", "remaining_troops", "remaining_morale", "general_died", "general_injured", "loot_to_bank", "lost_unbanked_loot"]:
		if not request.has(field):
			errors.append("settlement: missing field '%s'" % field)
	if not errors.is_empty():
		return errors
	for field in ["request_id", "run_id", "expedition_id", "general_id"]:
		if String(request[field]).strip_edges().is_empty():
			errors.append("settlement: %s must be non-empty" % field)
	if not request.outcome in ["success", "retreated", "failed"]:
		errors.append("settlement: unsupported outcome '%s'" % request.outcome)
	if not _is_non_negative_whole_number(request.remaining_troops) or not _is_non_negative_whole_number(request.remaining_morale):
		errors.append("settlement: remaining combat state cannot be negative")
	if not request.general_died is bool or not request.general_injured is bool:
		errors.append("settlement: general flags must be boolean")
	elif request.general_died and request.general_injured:
		errors.append("settlement: general cannot be dead and injured simultaneously")
	if not request.loot_to_bank is Dictionary or not request.lost_unbanked_loot is Dictionary:
		errors.append("settlement: loot fields must be objects")
		return errors
	var has_initial_troops := request.has("initial_troops")
	var has_composition := request.has("army_composition")
	if has_initial_troops != has_composition:
		errors.append("settlement: initial_troops and army_composition must be provided together")
	elif has_initial_troops:
		var casualty_result: Dictionary = ArmyManagementServiceScript.calculate_casualties(request.initial_troops, request.remaining_troops, request.army_composition)
		errors.append_array(casualty_result.errors)
	if request.outcome != "success" and not request.loot_to_bank.is_empty():
		errors.append("settlement: only success may bank loot")
	if request.outcome == "success" and not request.lost_unbanked_loot.is_empty():
		errors.append("settlement: success cannot report lost loot")
	for loot_id in request.loot_to_bank:
		if String(loot_id).strip_edges().is_empty() or not _is_positive_whole_number(request.loot_to_bank[loot_id]):
			errors.append("settlement: banked loot entries require non-empty ids and positive amounts")
	for loot_id in request.lost_unbanked_loot:
		if String(loot_id).strip_edges().is_empty() or not _is_positive_whole_number(request.lost_unbanked_loot[loot_id]):
			errors.append("settlement: lost loot entries require non-empty ids and positive amounts")
	return errors


func _is_non_negative_whole_number(value: Variant) -> bool:
	if value is int:
		return value >= 0
	if value is float:
		return is_finite(value) and value >= 0.0 and value == floor(value)
	return false


func _is_positive_whole_number(value: Variant) -> bool:
	return _is_non_negative_whole_number(value) and float(value) > 0.0


func _army_action_failure(error: String) -> Dictionary:
	return {"ok": false, "duplicate": false, "errors": PackedStringArray([error]), "troops_added": 0, "main_costs": {}, "special_costs": {}}


func _validate_research_action_request(request: Dictionary, requires_branch: bool) -> String:
	if _state.is_empty():
		return "campaign: controller is not initialized"
	if _research_economy.is_empty() or _research_cards.is_empty():
		return "campaign: research catalog is not configured"
	var fields := ["action_id", "card_id"]
	if requires_branch:
		fields.append("branch_id")
	for field in fields:
		if not request.has(field):
			return "research: missing field '%s'" % field
		if not request[field] is String or request[field].strip_edges().is_empty():
			return "research: %s must be a non-empty string" % field
	if not _research_cards.has(request.card_id):
		return "research: unknown public card '%s'" % request.card_id
	return ""


func _research_affordability_error(quote: Dictionary) -> String:
	for resource_id in quote.main_costs:
		if int(_state.resources.get(resource_id, 0)) < int(quote.main_costs[resource_id]):
			return "research: insufficient main resource '%s'" % resource_id
	for resource_id in quote.special_costs:
		if int(_state.special_resources.get(resource_id, 0)) < int(quote.special_costs[resource_id]):
			return "research: insufficient special resource '%s'" % resource_id
	return ""


func _deduct_research_costs(state: Dictionary, quote: Dictionary) -> void:
	for resource_id in quote.main_costs:
		state.resources[resource_id] = int(state.resources[resource_id]) - int(quote.main_costs[resource_id])
	for resource_id in quote.special_costs:
		state.special_resources[resource_id] = int(state.special_resources[resource_id]) - int(quote.special_costs[resource_id])


func _research_action_failure(error: String) -> Dictionary:
	return {"ok": false, "duplicate": false, "errors": PackedStringArray([error]), "main_costs": {}, "special_costs": {}}


func _research_failure_from_errors(errors: PackedStringArray) -> Dictionary:
	return {"ok": false, "duplicate": false, "errors": errors, "main_costs": {}, "special_costs": {}}


func _research_duplicate() -> Dictionary:
	return {"ok": true, "duplicate": true, "errors": PackedStringArray(), "main_costs": {}, "special_costs": {}}


func _validate_general_action_request(request: Dictionary, fields: Array, requires_catalog: bool) -> String:
	if _state.is_empty():
		return "campaign: controller is not initialized"
	if _state.campaign_status != "active":
		return "campaign: campaign is already game_over"
	if requires_catalog and (_general_progression.is_empty() or _general_definitions.is_empty()):
		return "campaign: general catalog is not configured"
	for field in fields:
		if not request.has(field):
			return "general: missing field '%s'" % field
		if not request[field] is String or request[field].strip_edges().is_empty():
			return "general: %s must be a non-empty string" % field
	return ""


func _find_general_index(general_id: String) -> int:
	for index in _state.generals.size():
		if _state.generals[index] is Dictionary and _state.generals[index].get("general_id", "") == general_id:
			return index
	return -1


func _find_pending_effect_index(request_id: String) -> int:
	for index in _state.pending_long_term_effects.size():
		if _state.pending_long_term_effects[index] is Dictionary and _state.pending_long_term_effects[index].get("request_id", "") == request_id:
			return index
	return -1


func _find_territory_index_in_state(state: Dictionary, territory_id: String) -> int:
	for index in state.territories.size():
		if state.territories[index] is Dictionary and state.territories[index].get("territory_id", "") == territory_id:
			return index
	return -1


func _validate_pending_general_effect(effect: Dictionary, request_id: String) -> String:
	for field in ["request_id", "general_id", "expedition_id", "outcome", "remaining_troops", "general_died", "general_injured", "general_effect_applied"]:
		if not effect.has(field):
			return "general effect: missing field '%s'" % field
	if effect.request_id != request_id:
		return "general effect: request id mismatch"
	for field in ["request_id", "general_id", "expedition_id"]:
		if not effect[field] is String or effect[field].strip_edges().is_empty():
			return "general effect: %s must be a non-empty string" % field
	if not effect.outcome in ["success", "retreated", "failed"]:
		return "general effect: unsupported outcome '%s'" % effect.outcome
	if not _is_non_negative_whole_number(effect.remaining_troops):
		return "general effect: remaining_troops must be non-negative"
	for field in ["general_died", "general_injured", "general_effect_applied"]:
		if not effect[field] is bool:
			return "general effect: %s must be boolean" % field
	return ""


func _validate_pending_faction_effect(effect: Dictionary, request_id: String) -> String:
	for field in ["request_id", "expedition_id", "outcome", "faction_effect_applied"]:
		if not effect.has(field):
			return "faction effect: missing field '%s'" % field
	if effect.request_id != request_id:
		return "faction effect: request id mismatch"
	for field in ["request_id", "expedition_id"]:
		if not effect[field] is String or effect[field].strip_edges().is_empty():
			return "faction effect: %s must be a non-empty string" % field
	if not effect.outcome in ["success", "retreated", "failed"]:
		return "faction effect: unsupported outcome '%s'" % effect.outcome
	if not effect.faction_effect_applied is bool:
		return "faction effect: faction_effect_applied must be boolean"
	return ""


func _advance_general_recovery_in_state(state: Dictionary, action_id: String) -> Dictionary:
	var changed_general_ids := []
	var recovered_general_ids := []
	for index in state.generals.size():
		var recovery: Dictionary = GeneralManagementServiceScript.advance_recovery(state.generals[index])
		if recovery.changed:
			state.generals[index] = recovery.instance
			changed_general_ids.append(recovery.instance.general_id)
			if recovery.recovered:
				recovered_general_ids.append(recovery.instance.general_id)
	state.general_system.applied_recovery_ids.append(action_id)
	state.general_system.history.append({
		"action_id": action_id,
		"action": "advance_injury_recovery",
		"changed_general_ids": changed_general_ids.duplicate(true),
		"recovered_general_ids": recovered_general_ids.duplicate(true),
	})
	return {"changed_general_ids": changed_general_ids, "recovered_general_ids": recovered_general_ids}


func _general_action_failure(error: String) -> Dictionary:
	return {"ok": false, "duplicate": false, "errors": PackedStringArray([error]), "general": {}}


func _general_action_duplicate() -> Dictionary:
	return {"ok": true, "duplicate": true, "errors": PackedStringArray(), "general": {}}


func _faction_action_failure(error: String) -> Dictionary:
	return {"ok": false, "duplicate": false, "skipped": false, "errors": PackedStringArray([error]), "cycle_advanced": 0, "captured_territory_ids": [], "main_income": {}, "special_income": {}}


func _faction_failure_from_errors(errors: PackedStringArray) -> Dictionary:
	return {"ok": false, "duplicate": false, "skipped": false, "errors": errors, "cycle_advanced": 0, "captured_territory_ids": [], "main_income": {}, "special_income": {}}


func _faction_action_duplicate() -> Dictionary:
	return {"ok": true, "duplicate": true, "skipped": false, "errors": PackedStringArray(), "cycle_advanced": 0, "captured_territory_ids": [], "main_income": {}, "special_income": {}}
