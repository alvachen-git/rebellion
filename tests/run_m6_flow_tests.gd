extends SceneTree

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")
const GameFlowCoordinatorScript := preload("res://src/application/game_flow_coordinator.gd")
const SaveFileStoreScript := preload("res://src/infrastructure/persistence/save_file_store.gd")
const SaveEnvelopeScript := preload("res://src/domain/campaign/save_envelope.gd")
const SaveGameCodecScript := preload("res://src/infrastructure/persistence/save_game_codec.gd")
const CombatControllerScript := preload("res://src/domain/combat/combat_controller.gd")
const DeploymentAssemblerScript := preload("res://src/application/deployment_assembler.gd")
const ExpeditionEncounterResolverScript := preload("res://src/domain/expedition/expedition_encounter_resolver.gd")
const ExpeditionMapGeneratorScript := preload("res://src/domain/expedition/expedition_map_generator.gd")
const ExpeditionRunStateScript := preload("res://src/domain/expedition/expedition_run_state.gd")

const SAVE_ROOT := "/tmp/dynasty-rebellion-m6-flow"

class ToggleSaveStore:
	extends RefCounted
	var delegate = SaveFileStoreScript.new()
	var fail_next := false

	func save(path: String, envelope: Dictionary, timestamp: String = "") -> Dictionary:
		if fail_next:
			fail_next = false
			return {"ok": false, "errors": PackedStringArray(["injected save failure"])}
		return delegate.save(path, envelope, timestamp)

	func load(path: String, registry = null) -> Dictionary:
		return delegate.load(path, registry)

var _passed := 0
var _failed := 0
var _registry
var _bundle: Dictionary = {}
var _store


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_cleanup()
	_registry = ContentRegistryScript.new()
	_assert_true(_registry.load_all(), "M6 content registry loads")
	_bundle = {
		"bootstrap": _load_json("res://data/config/prototype_campaign_bootstrap.json"),
		"deployment_rules": _load_json("res://data/config/prototype_deployment_rules.json"),
		"encounters": _load_json("res://data/config/prototype_heyuan_encounters.json"),
		"army_economy": _load_json("res://data/config/prototype_army_economy.json"),
		"research_economy": _load_json("res://data/config/prototype_research_economy.json"),
		"general_progression": _load_json("res://data/config/prototype_general_progression.json"),
		"faction_cycle": _load_json("res://data/config/prototype_faction_cycle.json"),
	}
	_store = ToggleSaveStore.new()
	_test_save_v3_structural_migration()
	_test_explicit_legacy_loadout_recovery()
	_test_deterministic_encounter_contract()
	_test_complete_flow_and_recovery()
	_test_terminal_outcomes_and_game_over_phase()
	_test_autosave_failure_rolls_back()
	_cleanup()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_save_v3_structural_migration() -> void:
	var current := SaveEnvelopeScript.create_empty("campaign.v4", "2026-09-02T01:00:00Z")
	_assert_equal(current.save_version, 6, "new envelope uses Save V6")
	_assert_equal(current.content_version, "0.7.2-m6-route-variety", "new envelope uses the branching-route content version")
	var legacy := current.duplicate(true)
	legacy.save_version = 2
	legacy.content_version = "0.4.0-m4-map"
	legacy.campaign.erase("base_loadout")
	legacy.campaign.erase("loadout_system")
	var decoded := SaveGameCodecScript.new().decode(JSON.stringify(legacy))
	_assert_true(decoded.ok and decoded.migrated and decoded.to_version == 6, "Save V2 migrates through Save V6")
	_assert_equal(decoded.value.content_version, "0.4.0-m4-map", "V2 migration preserves old content version")
	_assert_true(decoded.value.campaign.base_loadout.is_empty(), "V2 migration does not silently choose a shared base loadout")
	_assert_true(decoded.value.campaign.loadout_system.requires_legacy_recovery, "V2 migration requires explicit shared-loadout recovery")
	_assert_true(decoded.value.campaign.loadout_system.history.is_empty(), "V2 migration creates an empty loadout audit ledger")


func _test_explicit_legacy_loadout_recovery() -> void:
	_cleanup()
	var source_flow = _new_flow(ToggleSaveStore.new())
	_assert_true(source_flow.new_campaign("campaign.legacy-loadout", "2026-09-02T01:10:00Z").ok, "legacy recovery fixture starts from a valid roster")
	var legacy: Dictionary = source_flow.snapshot()
	legacy.erase("phase")
	legacy.save_version = 2
	legacy.content_version = "0.4.0-m4-map"
	legacy.campaign.erase("base_loadout")
	legacy.campaign.erase("loadout_system")
	_write_text("%s/legacy_v2.json" % SAVE_ROOT, JSON.stringify(legacy))
	var flow = _new_flow(ToggleSaveStore.new())
	var loaded: Dictionary = flow.load_campaign("%s/legacy_v2.json" % SAVE_ROOT)
	_assert_true(loaded.ok and loaded.migrated, "legacy Save V2 loads through structural Save V4 migration")
	var blocked: Dictionary = flow.expedition_readiness({"expedition_id": "expedition.capture_heyuan_county", "general_id": "general.zhao_lie"})
	_assert_true(not blocked.ok and blocked.get("requires_legacy_loadout_recovery", false), "migrated save requires explicit loadout recovery")
	var recovered: Dictionary = flow.recover_legacy_base_loadout("loadout-recovery:v2", "2026-09-02T01:11:00Z")
	_assert_true(recovered.ok and not recovered.duplicate, "explicit legacy recovery grants starter cards and creates the shared base deck")
	_assert_equal(flow.snapshot().campaign.unlocked_public_cards.size(), 15, "legacy recovery grants exactly the current 15 prototype starter cards")
	_assert_equal(flow.snapshot().campaign.base_loadout.size(), 15, "legacy recovery creates the configured fifteen-card shared base deck")
	_assert_equal(flow.snapshot().campaign.loadout_system.history[0].action, "recover_legacy_base_loadout", "legacy recovery is auditable")
	var replay: Dictionary = flow.recover_legacy_base_loadout("loadout-recovery:v2", "2026-09-02T01:12:00Z")
	_assert_true(replay.ok and replay.duplicate, "legacy loadout recovery action id is idempotent")
	_assert_equal(flow.snapshot().content_version, "0.4.0-m4-map", "legacy recovery preserves migrated content_version")


func _test_deterministic_encounter_contract() -> void:
	var resolver = ExpeditionEncounterResolverScript.new()
	_assert_true(resolver.setup(_bundle.encounters).is_empty(), "Heyuan encounter config validates")
	var generated: Dictionary = ExpeditionMapGeneratorScript.generate(_registry.get_expedition("expedition.capture_heyuan_county"), 9917).map
	var node: Dictionary = generated.node_by_id["heyuan.merge.elite"]
	var first: Dictionary = resolver.resolve(node, 9917)
	var replay: Dictionary = resolver.resolve(node, 9917)
	_assert_equal(first, replay, "same expedition seed and node resolve identical enemy, battle seed and rewards")
	_assert_true(first.resolution.enemy_id in ["enemy.elite.gao_wu", "enemy.elite.he_wei"], "merge elite resolves only from the authored elite pool")
	var official_event := resolver.resolve({"id": "heyuan.official.event-test", "node_type": "event", "route": "official_road"}, 9917)
	_assert_equal(official_event.resolution.immediate_effects.buff, {"type": "ModifyNextBattleAttack", "amount": 4.0}, "official event grants only next-battle attack +4")
	var supply := resolver.resolve({"id": "heyuan.supply-test", "node_type": "supply", "route": "shared"}, 9917)
	_assert_equal(supply.resolution.immediate_effects, {"restore_troops_ratio": 0.15, "restore_morale": 20.0}, "supply effect stays data-driven and capped by Expedition state")


func _test_complete_flow_and_recovery() -> void:
	var flow = _new_flow(_store)
	var created: Dictionary = flow.new_campaign("campaign.m6-flow", "2026-09-02T02:00:00Z")
	_assert_true(created.ok, "new campaign initializes and autosaves atomically")
	var initial: Dictionary = flow.snapshot()
	_assert_equal(initial.phase, "main_city", "new campaign enters main city")
	_assert_equal(initial.campaign.resources, {"silver": 600, "food": 800, "recruits": 1000, "military_knowledge": 250}, "bootstrap main resources match the prototype config")
	_assert_equal(initial.campaign.army_inventory, {"infantry": 1200, "archer": 900, "cavalry": 900}, "bootstrap army inventory matches the prototype config")
	_assert_equal(initial.campaign.special_resources, {"resource.warhorse": 500, "resource.cavalry_fragment": 0}, "bootstrap special resources include zero fragments")
	_assert_equal(initial.campaign.generals.size(), 4, "bootstrap creates three generals and the non-deployable player placeholder")
	_assert_equal(initial.campaign.unlocked_public_cards.size(), 15, "bootstrap unlocks exactly the 15 cards used by starting decks")
	_assert_true(not initial.campaign.unlocked_public_cards.has("card.public.cavalry.pursue"), "pursue remains locked at campaign start")
	_assert_equal(initial.campaign.base_loadout.size(), 15, "bootstrap stores one fifteen-card shared base loadout")
	_assert_equal(_unique_count(initial.campaign.base_loadout), 15, "bootstrap base loadout contains each starter public card once")
	for general_id in ["general.zhao_lie", "general.zhou_jing", "general.han_yue"]:
		var ready: Dictionary = flow.expedition_readiness({"expedition_id": "expedition.capture_heyuan_county", "general_id": general_id})
		_assert_true(ready.ok and ready.base_deck.size() == 15 and ready.exclusive_cards.size() == 1 and ready.deck.size() == 16, "%s combines the shared base deck with one exclusive card" % general_id)
	var placeholder: Dictionary = flow.expedition_readiness({"expedition_id": "expedition.capture_heyuan_county", "general_id": "general.player.placeholder"})
	_assert_true(not placeholder.ok, "player placeholder cannot deploy")
	var default_ready: Dictionary = flow.expedition_readiness({"expedition_id": "expedition.capture_heyuan_county", "general_id": "general.zhao_lie"})
	_assert_equal(default_ready.army_counts, {"infantry": 210, "archer": 105, "cavalry": 735}, "largest remainder allocation exactly fills Zhao Lie's cap")
	var too_many: Dictionary = flow.expedition_readiness({"expedition_id": "expedition.capture_heyuan_county", "general_id": "general.zhao_lie", "army_counts": {"infantry": 1051, "archer": 0, "cavalry": 0}})
	_assert_true(not too_many.ok, "deployment rejects counts above the general cap")
	var locked_deck: Array = initial.campaign.base_loadout.duplicate()
	locked_deck[0] = "card.public.cavalry.pursue"
	_assert_true(not flow.set_base_loadout({"action_id": "loadout.locked", "cards": locked_deck}).ok, "base loadout rejects a locked public card")
	var wrong_owner: Array = initial.campaign.base_loadout.duplicate()
	wrong_owner[14] = "card.general.han_yue.formation_breaking_crossbow"
	_assert_true(not flow.set_base_loadout({"action_id": "loadout.owner", "cards": wrong_owner}).ok, "base loadout rejects every general-exclusive card")
	var short_deck: Array = initial.campaign.base_loadout.duplicate()
	short_deck.pop_back()
	_assert_true(not flow.set_base_loadout({"action_id": "loadout.short", "cards": short_deck}).ok, "base loadout rejects a deck shorter than fifteen cards")
	var over_limit: Array = initial.campaign.base_loadout.duplicate()
	over_limit[3] = "card.public.general.assault"
	over_limit[4] = "card.public.general.assault"
	over_limit[5] = "card.public.general.assault"
	_assert_true(not flow.set_base_loadout({"action_id": "loadout.copy-limit", "cards": over_limit}).ok, "base loadout enforces per-card copy limits")
	var assembler = DeploymentAssemblerScript.new()
	_assert_true(assembler.setup(_registry, _bundle.deployment_rules, _card_definitions()).is_empty(), "deployment assembler configures for availability boundaries")
	var injured_campaign: Dictionary = initial.campaign.duplicate(true)
	injured_campaign.generals[0].injury = {"status": "major_injury", "remaining_cycles": 1}
	_assert_true(not assembler.readiness(injured_campaign, false, {"expedition_id": "expedition.capture_heyuan_county", "general_id": "general.zhao_lie"}).ok, "majorly injured general cannot deploy")
	var deceased_campaign: Dictionary = initial.campaign.duplicate(true)
	deceased_campaign.generals[0].status = "deceased"
	_assert_true(not assembler.readiness(deceased_campaign, false, {"expedition_id": "expedition.capture_heyuan_county", "general_id": "general.zhao_lie"}).ok, "deceased general cannot deploy")
	var started: Dictionary = flow.start_expedition({"run_id": "run.m6-flow", "expedition_id": "expedition.capture_heyuan_county", "general_id": "general.zhao_lie", "map_seed": 20260902}, "2026-09-02T02:01:00Z")
	_assert_true(started.ok and flow.phase() == "expedition_map", "valid preparation starts the expedition map")
	_assert_true(not flow.replenish_troops({"action_id": "army.blocked", "army_type": "infantry", "batches": 1}).ok, "main-city army actions are blocked during expedition")
	_assert_true(flow.save_manual(1, "2026-09-02T02:02:00Z").ok, "expedition map can be manually saved")
	var map_reload = _new_flow(ToggleSaveStore.new())
	_assert_true(map_reload.load_campaign("%s/manual_1.json" % SAVE_ROOT).ok, "expedition map restores from a manual save")
	_assert_equal(map_reload.snapshot().expedition.seed, 20260902, "map restore preserves expedition seed")
	var tampered: Dictionary = map_reload.snapshot().expedition
	tampered.route.available_next_node_ids = ["heyuan.county_seat"]
	var regenerated: Dictionary = ExpeditionMapGeneratorScript.generate(_registry.get_expedition(tampered.expedition_id), int(tampered.seed)).map
	_assert_true(not ExpeditionRunStateScript.new().restore(tampered, regenerated).is_empty(), "strict restore rejects tampered available route nodes")
	var forged_display: Dictionary = map_reload.snapshot().expedition
	forged_display.visible_nodes = [{"id": "forged.display.node"}]
	var display_restore = ExpeditionRunStateScript.new()
	_assert_true(display_restore.restore(forged_display, regenerated).is_empty(), "restore ignores untrusted serialized visible-node display data")
	_assert_true(not display_restore.snapshot().visible_nodes.any(func(node): return node.get("id", "") == "forged.display.node"), "restored visible nodes are regenerated from authoritative content")
	var duplicate_ledger: Dictionary = map_reload.snapshot().expedition
	duplicate_ledger.resolution_ids = ["resolution.duplicate", "resolution.duplicate"]
	_assert_true(not ExpeditionRunStateScript.new().restore(duplicate_ledger, regenerated).is_empty(), "strict restore rejects duplicate resolution ledger ids")
	flow = map_reload
	var first: Dictionary = flow.advance_to_node("heyuan.official.approach", "2026-09-02T02:03:00Z")
	_assert_true(first.ok, "first official-road node resolves")
	if flow.phase() == "combat_checkpoint":
		var checkpoint: Dictionary = flow.pending_combat_request()
		_assert_true(not checkpoint.is_empty(), "combat node creates an immutable checkpoint request")
		var checkpoint_reload = _new_flow(ToggleSaveStore.new())
		_assert_true(checkpoint_reload.load_campaign("%s/autosave.json" % SAVE_ROOT).ok, "combat checkpoint loads from autosave")
		var normalized_checkpoint: Dictionary = JSON.parse_string(JSON.stringify(checkpoint))
		_assert_equal(checkpoint_reload.pending_combat_request(), normalized_checkpoint, "combat restart uses the exact serialized request")
		_test_real_combat_override_contract(checkpoint)
		flow = checkpoint_reload
		var stale := {"battle_id": "run.other:node.other", "status": "victory", "player_remaining_troops": 1010, "player_remaining_morale": 74}
		_assert_true(not flow.submit_combat_result(stale, "2026-09-02T02:03:30Z").ok, "stale or cross-battle CombatResult is rejected")
		_submit_victory(flow, 1010, 74, "first combat settles after checkpoint recovery")
	_complete_route(flow)
	_assert_equal(flow.phase(), "settlement_pending", "Boss result stops at settlement_pending")
	var terminal_snapshot: Dictionary = flow.snapshot()
	var settlement_store = ToggleSaveStore.new()
	var settlement_reload = _new_flow(settlement_store)
	_assert_true(settlement_reload.load_campaign("%s/autosave.json" % SAVE_ROOT).ok, "settlement checkpoint restores from autosave")
	_assert_equal(settlement_reload.phase(), "settlement_pending", "restored terminal checkpoint does not finalize implicitly")
	_assert_equal(settlement_reload.snapshot().expedition.seed, terminal_snapshot.expedition.seed, "terminal restore preserves expedition identity")
	flow = settlement_reload
	var before_failed_final: Dictionary = flow.snapshot()
	settlement_store.fail_next = true
	var failed_final: Dictionary = flow.finalize_expedition("2026-09-02T02:19:00Z")
	_assert_true(not failed_final.ok and failed_final.get("save_failed", false), "final settlement save failure is reported")
	_assert_equal(flow.snapshot(), before_failed_final, "failed final save stays at settlement_pending without Campaign mutation")
	var finalized: Dictionary = flow.finalize_expedition("2026-09-02T02:20:00Z")
	_assert_true(finalized.ok and flow.phase() == "main_city", "explicit finalization returns to main city")
	var returned: Dictionary = flow.snapshot()
	_assert_equal(returned.campaign.cycle, 1, "primary expedition success advances one faction cycle")
	_assert_equal(returned.campaign.territories[0].territory_id, "territory.heyuan_county", "finalization captures Heyuan County")
	_assert_equal(returned.campaign.generals[0].level, 2, "successful expedition applies one level of growth")
	_assert_true(int(returned.campaign.special_resources["resource.cavalry_fragment"]) == 1, "Boss reward banks one cavalry fragment")
	_assert_equal(returned.campaign.army_inventory, {"infantry": 1120, "archer": 860, "cavalry": 620}, "finalization deducts exact categorized losses from the frozen deployment")
	_assert_true(flow.replenish_troops({"action_id": "army.after-return", "army_type": "cavalry", "batches": 2}).ok, "returned campaign can replenish expedition cavalry losses")
	_assert_true(flow.unlock_public_card({"action_id": "research.unlock-pursue", "card_id": "card.public.cavalry.pursue"}).ok, "returned campaign can unlock pursue with the Boss fragment")
	_assert_true(flow.upgrade_public_card({"action_id": "research.upgrade-assault", "card_id": "card.public.general.assault", "branch_id": "break_momentum"}).ok, "returned campaign can permanently upgrade an existing card")
	var new_deck: Array = flow.snapshot().campaign.base_loadout.duplicate()
	new_deck[8] = "card.public.cavalry.pursue"
	var changed: Dictionary = flow.set_base_loadout({"action_id": "loadout.after-return", "cards": new_deck})
	_assert_true(changed.ok, "returned campaign can modify the shared base loadout")
	var after_change: Dictionary = flow.snapshot()
	var duplicate: Dictionary = flow.set_base_loadout({"action_id": "loadout.after-return", "cards": initial.campaign.base_loadout})
	_assert_true(duplicate.ok and duplicate.duplicate and flow.snapshot() == after_change, "replayed loadout action id is idempotent")
	_assert_true(flow.save_manual(2, "2026-09-02T02:25:00Z").ok, "post-return changes save explicitly")
	var final_reload = _new_flow(ToggleSaveStore.new())
	_assert_true(final_reload.load_campaign("%s/manual_2.json" % SAVE_ROOT).ok, "post-return manual save reloads")
	var second_ready: Dictionary = final_reload.expedition_readiness({"expedition_id": "expedition.secure_shimen_mountain", "general_id": "general.zhao_lie"})
	_assert_true(second_ready.ok, "post-return state is legal for a second expedition without starting it: %s" % str(second_ready.get("errors", [])))
	if second_ready.ok:
		_assert_equal(second_ready.troop_cap, 1075, "level-two leadership raises Zhao Lie's troop cap by 25")
		var final_assembler = DeploymentAssemblerScript.new()
		final_assembler.setup(_registry, _bundle.deployment_rules, _card_definitions())
		var assembled: Dictionary = final_assembler.assemble(final_reload.snapshot().campaign, false, {"run_id": "run.readiness-only", "expedition_id": "expedition.capture_heyuan_county", "general_id": "general.zhao_lie", "map_seed": 33})
		_assert_equal(assembled.general.attack, 35.0, "level-two martial raises deployment attack by 1")
		_assert_equal(assembled.general.defense, 18.5, "level-two leadership raises deployment defense by 0.5")
		_assert_equal(assembled.card_overrides["card.public.general.assault"].effects[0].base_power, 80.0, "deployment freezes the selected permanent card upgrade")


func _test_real_combat_override_contract(checkpoint: Dictionary) -> void:
	var upgraded := checkpoint.duplicate(true)
	var assault: Dictionary = _registry.get_card("card.public.general.assault")
	var resolved: Dictionary = assault.duplicate(true)
	resolved.effects = [{"type": "DealDamage", "base_power": 80, "target": "opponent"}]
	resolved.applied_upgrade_branch = "break_momentum"
	upgraded.card_overrides = {"card.public.general.assault": resolved}
	upgraded.draw_count = 20
	upgraded.starting_action_points = 20
	var base := upgraded.duplicate(true)
	base.card_overrides = {}
	var upgraded_combat = CombatControllerScript.new()
	var base_combat = CombatControllerScript.new()
	_assert_true(upgraded_combat.setup(upgraded, _registry).is_empty() and base_combat.setup(base, _registry).is_empty(), "real CombatController accepts saved card overrides")
	var upgraded_index: int = upgraded_combat.snapshot().deck.hand.find("card.public.general.assault")
	var base_index: int = base_combat.snapshot().deck.hand.find("card.public.general.assault")
	upgraded_combat.play_card(upgraded_index)
	base_combat.play_card(base_index)
	_assert_true(int(upgraded_combat.snapshot().enemy.troops) < int(base_combat.snapshot().enemy.troops), "upgraded override changes real combat damage without mutating registry")
	_assert_equal(_registry.get_card("card.public.general.assault").effects[0].base_power, 60, "card override leaves shared content unchanged")


func _complete_route(flow) -> void:
	_settle_node(flow, "heyuan.official.checkpoint", 960, 70)
	_settle_node(flow, "heyuan.official.armory", 900, 66)
	_settle_node(flow, "heyuan.merge.elite", 800, 58)
	_settle_node(flow, "heyuan.late.intel", 800, 58)
	_assert_true(flow.snapshot().expedition.intel.get("boss_profile_revealed", false), "intel node records Boss profile visibility without a combat buff")
	_settle_node(flow, "heyuan.county_seat", 650, 50)


func _settle_node(flow, node_id: String, troops: int, morale: int) -> void:
	var entered: Dictionary = flow.advance_to_node(node_id, "2026-09-02T02:10:00Z")
	_assert_true(entered.ok, "%s resolves deterministically" % node_id)
	if flow.phase() == "combat_checkpoint":
		_submit_victory(flow, troops, morale, "%s combat settles" % node_id)


func _submit_victory(flow, troops: int, morale: int, label: String) -> void:
	var request: Dictionary = flow.pending_combat_request()
	var result := {"battle_id": request.battle_id, "status": "victory", "player_remaining_troops": troops, "player_remaining_morale": morale, "general_died": false, "general_injured": false}
	var applied: Dictionary = flow.submit_combat_result(result, "2026-09-02T02:11:00Z")
	_assert_true(applied.ok, label)
	var duplicate: Dictionary = flow.submit_combat_result(result, "2026-09-02T02:11:01Z")
	_assert_true(duplicate.ok and duplicate.duplicate, "%s is idempotent on replay" % label)


func _test_autosave_failure_rolls_back() -> void:
	_cleanup()
	var store = ToggleSaveStore.new()
	var flow = _new_flow(store)
	_assert_true(flow.new_campaign("campaign.rollback", "2026-09-02T03:00:00Z").ok, "rollback fixture campaign starts")
	_assert_true(flow.start_expedition({"run_id": "run.rollback", "expedition_id": "expedition.capture_heyuan_county", "general_id": "general.zhao_lie", "map_seed": 17}, "2026-09-02T03:01:00Z").ok, "rollback fixture expedition starts")
	var before: Dictionary = flow.snapshot()
	store.fail_next = true
	var failed: Dictionary = flow.advance_to_node("heyuan.official.approach", "2026-09-02T03:02:00Z")
	_assert_true(not failed.ok and failed.get("save_failed", false), "injected checkpoint save failure is reported")
	_assert_equal(flow.snapshot(), before, "save failure rolls route, rewards, request and phase back together")


func _test_terminal_outcomes_and_game_over_phase() -> void:
	_cleanup()
	var retreat = _new_terminal_flow("campaign.retreat", "run.retreat")
	var retreat_request: Dictionary = retreat.pending_combat_request()
	var retreated: Dictionary = retreat.submit_combat_result({"battle_id": retreat_request.battle_id, "status": "retreated", "player_remaining_troops": 900, "player_remaining_morale": 60, "general_died": false, "general_injured": false}, "2026-09-02T04:02:00Z")
	_assert_true(retreated.ok and retreat.phase() == "settlement_pending", "retreat first persists the terminal checkpoint")
	_assert_true(retreat.finalize_expedition("2026-09-02T04:03:00Z").ok, "retreat finalizes explicitly")
	_assert_equal(retreat.snapshot().campaign.cycle, 0, "retreat does not advance the prototype faction cycle")
	_assert_true(retreat.snapshot().campaign.territories.is_empty(), "retreat cannot capture Heyuan or bank expedition loot")
	_assert_equal(retreat.snapshot().campaign.army_inventory, {"infantry": 1170, "archer": 885, "cavalry": 795}, "retreat preserves and classifies real troop losses")

	var morale_failure = _new_terminal_flow("campaign.morale-failure", "run.morale-failure")
	var morale_request: Dictionary = morale_failure.pending_combat_request()
	var defeated: Dictionary = morale_failure.submit_combat_result({"battle_id": morale_request.battle_id, "status": "defeat", "player_remaining_troops": 900, "player_remaining_morale": 0, "general_died": false, "general_injured": true}, "2026-09-02T04:12:00Z")
	_assert_true(defeated.ok and morale_failure.phase() == "settlement_pending", "morale defeat persists before finalization")
	_assert_true(morale_failure.finalize_expedition("2026-09-02T04:13:00Z").ok, "morale defeat finalizes explicitly")
	_assert_equal(morale_failure.snapshot().campaign.generals[0].injury.status, "major_injury", "morale failure applies the CombatResult injury once")
	_assert_equal(morale_failure.snapshot().campaign.cycle, 0, "morale failure does not advance time under the current prototype policy")

	var death = _new_terminal_flow("campaign.death", "run.death")
	var death_request: Dictionary = death.pending_combat_request()
	var death_result: Dictionary = death.submit_combat_result({"battle_id": death_request.battle_id, "status": "defeat", "player_remaining_troops": 0, "player_remaining_morale": 50, "general_died": true, "general_injured": false}, "2026-09-02T04:22:00Z")
	_assert_true(death_result.ok and death.finalize_expedition("2026-09-02T04:23:00Z").ok, "troop-zero death reaches explicit final settlement")
	_assert_equal(death.snapshot().campaign.generals[0].status, "deceased", "ordinary general permanent death is preserved")
	_assert_true(not death.expedition_readiness({"expedition_id": "expedition.capture_heyuan_county", "general_id": "general.zhao_lie"}).ok, "deceased general cannot prepare another expedition")
	var game_over_envelope: Dictionary = death.snapshot()
	game_over_envelope.erase("phase")
	game_over_envelope.campaign.campaign_status = "game_over"
	game_over_envelope.campaign.game_over_record = {"request_id": "test.game-over", "general_id": "general.player.placeholder", "expedition_id": "expedition.capture_heyuan_county", "reason": "player_character_death"}
	_write_text("%s/game_over.json" % SAVE_ROOT, JSON.stringify(game_over_envelope))
	var game_over_flow = _new_flow(ToggleSaveStore.new())
	_assert_true(game_over_flow.load_campaign("%s/game_over.json" % SAVE_ROOT).ok, "valid Game Over envelope loads")
	_assert_equal(game_over_flow.phase(), "game_over", "campaign_status is the sole authority for the Game Over phase")


func _new_terminal_flow(campaign_id: String, run_id: String):
	var flow = _new_flow(ToggleSaveStore.new())
	_assert_true(flow.new_campaign(campaign_id, "2026-09-02T04:00:00Z").ok, "%s terminal fixture creates a campaign" % campaign_id)
	_assert_true(flow.start_expedition({"run_id": run_id, "expedition_id": "expedition.capture_heyuan_county", "general_id": "general.zhao_lie", "map_seed": 17}, "2026-09-02T04:01:00Z").ok, "%s terminal fixture starts an expedition" % campaign_id)
	_assert_true(flow.advance_to_node("heyuan.official.approach", "2026-09-02T04:01:30Z").ok and flow.phase() == "combat_checkpoint", "%s terminal fixture reaches combat" % campaign_id)
	return flow


func _new_flow(store):
	var flow = GameFlowCoordinatorScript.new()
	var errors := flow.setup(_registry, _bundle, store, SAVE_ROOT)
	_assert_true(errors.is_empty(), "game flow coordinator configures")
	return flow


func _load_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	return JSON.parse_string(file.get_as_text())


func _card_definitions() -> Array:
	var result := []
	for card_id in _bundle.research_economy.eligible_public_card_ids:
		result.append(_registry.get_card(card_id))
	for general_id in _bundle.bootstrap.general_ids:
		for card_id in _registry.get_general(general_id).starting_deck:
			var exists := false
			for definition in result:
				if definition.id == card_id:
					exists = true
					break
			if not exists:
				result.append(_registry.get_card(card_id))
	return result


func _write_text(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _unique_count(values: Array) -> int:
	var seen := {}
	for value in values:
		seen[value] = true
	return seen.size()


func _cleanup() -> void:
	for name in ["autosave.json", "autosave.json.bak", "autosave.json.tmp", "manual_1.json", "manual_1.json.bak", "manual_1.json.tmp", "manual_2.json", "manual_2.json.bak", "manual_2.json.tmp", "legacy_v2.json", "game_over.json"]:
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
