extends SceneTree

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")
const ExpeditionMapGeneratorScript := preload("res://src/domain/expedition/expedition_map_generator.gd")
const ExpeditionRouteStateScript := preload("res://src/domain/expedition/expedition_route_state.gd")
const ExpeditionRunStateScript := preload("res://src/domain/expedition/expedition_run_state.gd")
const GameFlowCoordinatorScript := preload("res://src/application/game_flow_coordinator.gd")
const CampaignStateScript := preload("res://src/domain/campaign/campaign_state.gd")
const CampaignControllerScript := preload("res://src/domain/campaign/campaign_controller.gd")
const SaveFileStoreScript := preload("res://src/infrastructure/persistence/save_file_store.gd")
const SaveGameCodecScript := preload("res://src/infrastructure/persistence/save_game_codec.gd")
const GeneralRequestBuilderScript := preload("res://src/domain/combat/general_combat_request_builder.gd")
const CombatControllerScript := preload("res://src/domain/combat/combat_controller.gd")
const FixedStrategyCombatRunnerScript := preload("res://src/domain/combat/fixed_strategy_combat_runner.gd")

const SAVE_ROOT := "/tmp/dynasty-rebellion-m6-rogue"
const EXPEDITIONS := [
	"expedition.capture_heyuan_county",
	"expedition.secure_shimen_mountain",
	"expedition.capture_linze_market",
]
const REWARD_CARDS := [
	"card.public.rogue.shield_cart_advance",
	"card.public.rogue.crossbow_suppression",
	"card.public.rogue.roadside_ambush",
	"card.public.rogue.seize_grain_rally",
	"card.public.rogue.reward_the_ranks",
	"card.public.rogue.borrowed_passage",
]

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
var _bundle: Dictionary
var _action_sequence := 0


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_cleanup()
	_registry = ContentRegistryScript.new()
	_assert_true(_registry.load_all(), "M6-04 content registry loads")
	_bundle = _load_bundle()
	_test_content_contracts()
	_test_generator_contracts()
	_test_v4_information_contract()
	_test_reward_card_runtime()
	_test_save_v5_migration()
	_test_popular_support_and_event_failure()
	_test_choice_checkpoint_attack_and_retreat()
	_test_reward_checkpoint_reload()
	_test_item_use_and_rollback()
	_test_success_and_three_target_completion()
	_test_new_enemy_combat_runtime()
	_cleanup()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_content_contracts() -> void:
	_assert_equal(_registry.expedition_count(), 3, "three Rogue expedition targets are registered")
	_assert_equal(_registry.territory_count(), 3, "three capturable territories are registered")
	_assert_equal(_bundle.encounters.events.size(), 36, "Rogue config contains thirty-six data-driven events")
	var region_counts := {"common": 0, "heyuan": 0, "shimen": 0, "linze": 0}
	for event_id in _bundle.encounters.events:
		var region := String(event_id).split(".")[1]
		region_counts[region] = int(region_counts.get(region, 0)) + 1
	_assert_equal(region_counts, {"common": 12, "heyuan": 8, "shimen": 8, "linze": 8}, "event library contains twelve common and eight per destination")
	_assert_equal(_bundle.encounters.items.size(), 4, "Rogue config contains four temporary items")
	_assert_equal(_bundle.encounters.reward_card_ids, REWARD_CARDS, "Rogue reward pool contains the approved six cards")
	for card_id in REWARD_CARDS:
		var card: Dictionary = _registry.get_card(card_id)
		_assert_true(not card.is_empty() and card.get("upgrade_branches", []).size() == 2, "%s has two permanent upgrade branches" % card_id)
	for enemy_id in ["enemy.bandit.grunt", "enemy.bandit.archer", "enemy.bandit.raiders", "enemy.bandit.black_banner", "enemy.boss.shimen_chief"]:
		_assert_true(_registry.get_enemy(enemy_id).get("faction_tags", []).has("bandit"), "%s is tagged as bandit" % enemy_id)
	for enemy_id in ["enemy.merchant.guard", "enemy.merchant.crossbow", "enemy.merchant.escort_captain"]:
		_assert_true(_registry.get_enemy(enemy_id).get("faction_tags", []).has("merchant"), "%s is tagged as merchant" % enemy_id)
	var linze_boss: Dictionary = _registry.get_enemy("enemy.boss.linze_commissioner")
	_assert_true(linze_boss.faction_tags.has("government") and linze_boss.faction_tags.has("merchant"), "Linze boss carries both government and merchant tags")
	for event_id in _bundle.encounters.events:
		var choices: Array = _bundle.encounters.events[event_id].choices
		_assert_true(choices.size() >= 2 and choices.size() <= 3, "%s exposes two or three stable choices" % event_id)
		var seen := {}
		for choice in choices:
			seen[choice.choice_id] = true
		_assert_equal(seen.size(), choices.size(), "%s choice ids are unique" % event_id)
	var excessive_jump: Dictionary = _registry.get_expedition(EXPEDITIONS[0]).duplicate(true)
	excessive_jump.generator_profile.topology_templates[0].layer_node_counts = [3, 2, 1, 4, 2, 3, 2]
	_assert_true(not ExpeditionMapGeneratorScript.generate(excessive_jump, 1, 4).ok, "V4 rejects a three-node jump that would create a route fan")
	var missing_legacy: Dictionary = _registry.get_expedition(EXPEDITIONS[0]).duplicate(true)
	missing_legacy.legacy_generator_profiles.erase("3")
	_assert_true(not ExpeditionMapGeneratorScript.generate(missing_legacy, 1, 4).ok, "V4 rejects content that cannot restore active V3 routes")


func _test_generator_contracts() -> void:
	var aggregate := {}
	var signatures := {}
	var topology_variants := {}
	for expedition_id in EXPEDITIONS:
		aggregate[expedition_id] = {"government": 0, "bandit": 0, "merchant": 0}
		signatures[expedition_id] = {}
		topology_variants[expedition_id] = {}
		var definition: Dictionary = _registry.get_expedition(expedition_id)
		for seed in range(1, 201):
			var first: Dictionary = ExpeditionMapGeneratorScript.generate(definition, seed, 4)
			var second: Dictionary = ExpeditionMapGeneratorScript.generate(definition, seed, 4)
			_assert_true(first.ok, "%s seed %d generates" % [expedition_id, seed])
			if not first.ok:
				continue
			var map: Dictionary = first.map
			_assert_equal(map.map_signature, second.map.map_signature, "%s seed %d signature is deterministic" % [expedition_id, seed])
			signatures[expedition_id][map.map_signature] = true
			topology_variants[expedition_id][map.topology_variant] = true
			var contract_errors := _generated_map_errors(map)
			_assert_true(contract_errors.is_empty(), "%s seed %d satisfies topology and content constraints: %s" % [expedition_id, seed, str(contract_errors)])
			for node in map.nodes:
				var faction := String(node.get("enemy_faction", ""))
				if faction in ["government", "bandit"]:
					aggregate[expedition_id][faction] += 1
				if node.node_type == "merchant":
					aggregate[expedition_id].merchant += 1
		_assert_true(signatures[expedition_id].size() > 20, "%s varies structurally and in content across seeds" % expedition_id)
		_assert_equal(topology_variants[expedition_id].size(), 5, "%s reaches all five authored topology families in 200 seeds" % expedition_id)
	_assert_true(aggregate[EXPEDITIONS[0]].government > aggregate[EXPEDITIONS[0]].bandit, "Heyuan generation favors government enemies")
	_assert_true(aggregate[EXPEDITIONS[1]].bandit > aggregate[EXPEDITIONS[1]].government, "Shimen generation favors bandit enemies")
	_assert_true(abs(int(aggregate[EXPEDITIONS[2]].government) - int(aggregate[EXPEDITIONS[2]].bandit)) < 100, "Linze government and bandit frequencies stay near even")
	_assert_true(aggregate[EXPEDITIONS[0]].merchant == aggregate[EXPEDITIONS[1]].merchant and aggregate[EXPEDITIONS[1]].merchant == aggregate[EXPEDITIONS[2]].merchant, "each V4 destination preserves exactly two merchant nodes per map")
	var legacy_v2_signatures := {
		EXPEDITIONS[0]: "v2-26c5fd4c",
		EXPEDITIONS[1]: "v2-6b985fd4",
		EXPEDITIONS[2]: "v2-47664700",
	}
	var legacy_v3_signatures := {
		EXPEDITIONS[0]: "v3-2b63b7a8",
		EXPEDITIONS[1]: "v3-335cdf92",
		EXPEDITIONS[2]: "v3-5314cd61",
	}
	for expedition_id in EXPEDITIONS:
		var legacy_v2: Dictionary = ExpeditionMapGeneratorScript.generate(_registry.get_expedition(expedition_id), 1, 2)
		_assert_true(legacy_v2.ok, "%s legacy V2 profile still generates" % expedition_id)
		if legacy_v2.ok:
			_assert_equal(legacy_v2.map.map_signature, legacy_v2_signatures[expedition_id], "%s legacy V2 signature remains byte-stable" % expedition_id)
		var legacy_v3: Dictionary = ExpeditionMapGeneratorScript.generate(_registry.get_expedition(expedition_id), 1, 3)
		_assert_true(legacy_v3.ok, "%s legacy V3 profile still generates" % expedition_id)
		if legacy_v3.ok:
			_assert_equal(legacy_v3.map.map_signature, legacy_v3_signatures[expedition_id], "%s legacy V3 signature remains byte-stable" % expedition_id)


func _generated_map_errors(map: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	var by_layer := {}
	var bosses := 0
	var node_by_id := {}
	var type_counts := {}
	var event_ids := {}
	for node in map.nodes:
		node_by_id[node.id] = node
		var layer := int(node.layer)
		if not by_layer.has(layer):
			by_layer[layer] = []
		by_layer[layer].append(node.id)
		if node.node_type == "boss":
			bosses += 1
		type_counts[node.node_type] = int(type_counts.get(node.node_type, 0)) + 1
		if node.node_type == "event":
			event_ids[node.get("encounter_id", "")] = true
	if by_layer.size() != 9: errors.append("layer count")
	if bosses != 1: errors.append("boss count")
	if String(map.get("topology_variant", "")).is_empty(): errors.append("topology variant")
	for layer in range(1, 8):
		var layer_size: int = by_layer.get(layer, []).size()
		if layer_size < 1 or layer_size > 4: errors.append("layer %d size" % layer)
	if by_layer.get(1, []).size() != 3: errors.append("opening route count")
	for layer in [2, 4, 6]:
		var minimum_size := 2 if layer == 2 else 3
		if by_layer.get(layer, []).size() < minimum_size: errors.append("noncombat layer %d size" % layer)
	if type_counts.get("event", 0) != 3 or event_ids.size() != 3: errors.append("event distribution")
	if type_counts.get("merchant", 0) != 2: errors.append("merchant count")
	if int(type_counts.get("supply", 0)) < 1: errors.append("supply count")
	if type_counts.get("item", 0) != 1: errors.append("item count")
	if type_counts.get("card_reward", 0) != 1: errors.append("card reward count")
	for layer in [1, 3, 7]:
		for node_id in by_layer.get(layer, []):
			if node_by_id[node_id].node_type != "normal_combat": errors.append("layer %d non-normal combat" % layer)
	for node_id in by_layer.get(5, []):
		if node_by_id[node_id].node_type != "elite_combat": errors.append("layer 5 non-elite combat")
	var outgoing := {}
	var incoming := {}
	var edge_keys := {}
	for edge in map.edges:
		outgoing[edge.from] = int(outgoing.get(edge.from, 0)) + 1
		incoming[edge.to] = int(incoming.get(edge.to, 0)) + 1
		var edge_key := "%s>%s" % [edge.from, edge.to]
		if edge_keys.has(edge_key): errors.append("duplicate edge")
		edge_keys[edge_key] = true
		var from_node: Dictionary = node_by_id[edge.from]
		var to_node: Dictionary = node_by_id[edge.to]
		if int(to_node.layer) != int(from_node.layer) + 1: errors.append("edge skips layer")
	for node in map.nodes:
		if node.id != map.boss_node_id:
			var minimum_exits := 3 if node.id == map.entry_node_id else 1
			var maximum_exits := 4 if node.id == map.entry_node_id else 3
			if int(outgoing.get(node.id, 0)) < minimum_exits or int(outgoing.get(node.id, 0)) > maximum_exits: errors.append("%s exits" % node.id)
		if node.id != map.entry_node_id:
			if int(incoming.get(node.id, 0)) < 1: errors.append("%s unreachable" % node.id)
	var types := {}
	for node in map.nodes:
		types[node.node_type] = true
	if not types.has("merchant"): errors.append("merchant missing")
	if not _map_has_faction(map, "government") or not _map_has_faction(map, "bandit"): errors.append("enemy faction coverage")
	var split_transitions := 0
	var merge_transitions := 0
	for layer in range(1, 7):
		if by_layer[layer + 1].size() > by_layer[layer].size(): split_transitions += 1
		elif by_layer[layer + 1].size() < by_layer[layer].size(): merge_transitions += 1
		var transition_edges: Array = []
		for edge in map.edges:
			if int(node_by_id[edge.from].layer) == layer:
				transition_edges.append(edge)
		for left_index in transition_edges.size():
			for right_index in range(left_index + 1, transition_edges.size()):
				var left: Dictionary = transition_edges[left_index]
				var right: Dictionary = transition_edges[right_index]
				var left_from := int(node_by_id[left.from].lane)
				var right_from := int(node_by_id[right.from].lane)
				var left_to := int(node_by_id[left.to].lane)
				var right_to := int(node_by_id[right.to].lane)
				if (left_from < right_from and left_to > right_to) or (left_from > right_from and left_to < right_to):
					errors.append("crossing edges at layer %d" % layer)
	if split_transitions < 2: errors.append("split transition count")
	if merge_transitions < 2: errors.append("merge transition count")
	return errors


func _test_v4_information_contract() -> void:
	var generated: Dictionary = ExpeditionMapGeneratorScript.generate(_registry.get_expedition(EXPEDITIONS[0]), 31415, 4)
	_assert_true(generated.ok, "V4 information fixture generates")
	if not generated.ok:
		return
	var route = ExpeditionRouteStateScript.new()
	_assert_true(route.setup(generated.map).is_empty(), "V4 route state accepts a branching and merging map")
	var initial_nodes: Array = route.visible_nodes()
	var future_event: Dictionary = {}
	for node in initial_nodes:
		_assert_true(node.node_type != "unknown" and bool(node.is_revealed), "%s exposes its category from expedition start" % node.id)
		if int(node.layer) == 2 and node.node_type == "event":
			future_event = node
	_assert_true(not future_event.is_empty(), "V4 map exposes a layer-two event category")
	if not future_event.is_empty():
		_assert_equal(future_event.name, "途中事件", "unscouted event hides its concrete title")
		_assert_true(not future_event.has("encounter_id") and not bool(future_event.is_detail_revealed), "unscouted event does not leak its content id")
	var scouted: Dictionary = route.reveal_future_layers(2)
	_assert_true(scouted.ok, "scout intelligence reveals the next two layers")
	var revealed_event: Dictionary = {}
	for node in route.visible_nodes():
		if node.id == future_event.get("id", ""):
			revealed_event = node
	_assert_true(not revealed_event.is_empty() and bool(revealed_event.is_detail_revealed) and revealed_event.has("encounter_id"), "scouting reveals the frozen event identity")
	_assert_equal(_bundle.encounters.items["item.run.scout_token"].effects.reveal_layers, 2, "scout token still targets two future layers")


func _test_popular_support_and_event_failure() -> void:
	var bounds = CampaignControllerScript.new()
	_assert_true(bounds.setup(CampaignStateScript.create("campaign.support-bounds")).is_empty(), "popular-support boundary controller configures")
	var upper_request := _support_only_settlement("support.bounds.upper", 500)
	_assert_true(bounds.apply_expedition_settlement(upper_request).ok and int(bounds.snapshot().popular_support_state.value) == 100, "popular support clamps at one hundred")
	var upper_history_size: int = bounds.snapshot().popular_support_state.history.size()
	var duplicate_upper: Dictionary = bounds.apply_expedition_settlement(upper_request)
	_assert_true(duplicate_upper.ok and duplicate_upper.duplicate and bounds.snapshot().popular_support_state.history.size() == upper_history_size, "duplicate settlement cannot apply popular support twice")
	_assert_true(bounds.apply_expedition_settlement(_support_only_settlement("support.bounds.lower", -500)).ok and int(bounds.snapshot().popular_support_state.value) == 0, "popular support clamps at zero")
	var hungry_seed := _seed_with_event(EXPEDITIONS[0], "event.common.hungry_civilians")
	_assert_true(hungry_seed > 0, "a deterministic seed exposes the hungry civilians event")
	var success_store = ToggleSaveStore.new()
	var success_flow = _new_flow(success_store, "%s/support-success" % SAVE_ROOT)
	_assert_true(success_flow.new_campaign("campaign.support-success", _timestamp()).ok, "popular-support success campaign starts")
	_assert_equal(success_flow.snapshot().campaign.popular_support_state.value, 20, "new campaign starts at twenty popular support")
	_assert_true(_start(success_flow, EXPEDITIONS[0], "run.support-success", hungry_seed).ok, "popular-support success expedition starts")
	_submit_victory_after_advance(success_flow, _opening_node_toward_type(success_flow, "event"), "support-opening")
	_assert_true(success_flow.advance_to_node(_next_node_of_type(success_flow, "event"), _timestamp()).ok, "hungry civilians checkpoint is reached")
	_assert_equal(success_flow.pending_encounter().title, "饥民倒卧", "arriving reveals the concrete event title")
	var before_choice: Dictionary = success_flow.snapshot()
	success_store.fail_next = true
	var failed_save: Dictionary = success_flow.submit_encounter_choice({"action_id": "support.relief.fail", "choice_id": "relieve"}, _timestamp())
	_assert_true(not failed_save.ok and failed_save.get("save_failed", false), "popular-support choice reports autosave failure")
	_assert_equal(success_flow.snapshot(), before_choice, "popular-support save failure rolls back the whole choice")
	_assert_true(success_flow.submit_encounter_choice({"action_id": "support.relief", "choice_id": "relieve"}, _timestamp()).ok, "hungry civilians can be relieved")
	_assert_equal(success_flow.snapshot().expedition.pending_popular_support_delta, 8, "relief records eight pending popular support")
	_assert_equal(success_flow.expedition_run_snapshot().projected_popular_support, 28, "projected popular support includes this expedition")
	_assert_true(_complete_rogue_route(success_flow, false).ok, "support expedition reaches successful settlement")
	_assert_true(success_flow.finalize_expedition(_timestamp()).ok, "successful support expedition finalizes")
	_assert_equal(success_flow.snapshot().campaign.popular_support_state.value, 28, "successful expedition commits popular support")

	var retreat_flow = _new_flow(ToggleSaveStore.new(), "%s/support-retreat" % SAVE_ROOT)
	_assert_true(retreat_flow.new_campaign("campaign.support-retreat", _timestamp()).ok, "popular-support retreat campaign starts")
	_assert_true(_start(retreat_flow, EXPEDITIONS[0], "run.support-retreat", hungry_seed).ok, "popular-support retreat expedition starts")
	_submit_victory_after_advance(retreat_flow, _opening_node_toward_type(retreat_flow, "event"), "support-retreat-opening")
	_assert_true(retreat_flow.advance_to_node(_next_node_of_type(retreat_flow, "event"), _timestamp()).ok, "retreat route reaches hungry civilians")
	_assert_true(retreat_flow.submit_encounter_choice({"action_id": "support.recruit", "choice_id": "recruit"}, _timestamp()).ok, "recruiting hungry civilians settles")
	_submit_retreat_after_advance(retreat_flow, _next_node_id(retreat_flow), "support-retreat")
	_assert_true(retreat_flow.finalize_expedition(_timestamp()).ok, "popular-support retreat finalizes")
	_assert_equal(retreat_flow.snapshot().campaign.popular_support_state.value, 17, "negative popular support persists through retreat")

	var flood_seed := _seed_with_event(EXPEDITIONS[1], "event.common.flash_flood")
	var failure_flow = _new_flow(ToggleSaveStore.new(), "%s/support-failure" % SAVE_ROOT)
	_assert_true(failure_flow.new_campaign("campaign.support-failure", _timestamp()).ok, "event-failure campaign starts")
	var failure_start: Dictionary = failure_flow.start_expedition({"run_id": "run.support-failure", "expedition_id": EXPEDITIONS[1], "general_id": "general.zhao_lie", "map_seed": flood_seed, "army_counts": {"infantry": 20, "archer": 0, "cavalry": 0}}, _timestamp())
	_assert_true(failure_start.ok, "event-failure expedition may deploy twenty troops")
	_submit_victory_after_advance(failure_flow, _opening_node_toward_type(failure_flow, "event"), "event-failure-opening")
	_assert_true(failure_flow.advance_to_node(_next_node_of_type(failure_flow, "event"), _timestamp()).ok, "event-failure route reaches flash flood")
	var public_risk: Dictionary = {}
	for choice in failure_flow.pending_encounter().choices:
		if choice.choice_id == "ford": public_risk = choice
	_assert_true(not public_risk.has("resolved_effects"), "public encounter snapshot never leaks a frozen risk result")
	var terminal: Dictionary = failure_flow.submit_encounter_choice({"action_id": "support.bridge", "choice_id": "bridge"}, _timestamp())
	_assert_true(terminal.ok and failure_flow.phase() == "settlement_pending", "event casualties can directly end an expedition")
	_assert_true(failure_flow.snapshot().expedition.general_injured and not failure_flow.snapshot().expedition.general_died, "event failure injures but never permanently kills the general")
	_assert_equal(failure_flow.snapshot().expedition.pending_popular_support_delta, 5, "support gained before event failure remains pending")
	_assert_true(failure_flow.finalize_expedition(_timestamp()).ok, "event-caused failure finalizes")
	_assert_equal(failure_flow.snapshot().campaign.popular_support_state.value, 25, "positive popular support persists through failure")


func _test_reward_card_runtime() -> void:
	var built: Dictionary = GeneralRequestBuilderScript.build("general.zhao_lie", _registry.get_enemy("enemy.bandit.grunt"), 4401, _registry, "m6-reward-card")
	built.request.deck = ["card.public.rogue.shield_cart_advance"]
	built.request.draw_count = 1
	built.request.starting_action_points = 3
	var controller = CombatControllerScript.new()
	_assert_true(controller.setup(built.request, _registry).is_empty(), "reward card enters a real CombatController")
	var played: Dictionary = controller.play_card(0)
	_assert_true(played.ok and int(controller.snapshot().player.armor) == 45, "Shield Cart Advance executes its existing armor effect")


func _test_save_v5_migration() -> void:
	var flow = _new_flow(ToggleSaveStore.new(), "%s/migration" % SAVE_ROOT)
	_assert_true(flow.new_campaign("campaign.m6-v4", "2026-09-02T10:00:00Z").ok, "V4 migration fixture starts")
	var source: Dictionary = flow.snapshot()
	source.erase("phase")
	source.save_version = 4
	source.content_version = "0.6.1-m6-deck-editor"
	source.campaign.erase("rebellion_state")
	source.campaign.territories.append({"territory_id": "territory.heyuan_county", "name": "河源县", "status": "controlled", "income_enabled": true, "acquired_cycle": 0, "source_request_id": "legacy:v4"})
	var decoded: Dictionary = SaveGameCodecScript.new().decode(JSON.stringify(source))
	_assert_true(decoded.ok and decoded.to_version == 7, "Save V4 migrates through Save V7")
	_assert_equal(decoded.value.campaign.popular_support_state.value, 20, "legacy campaign starts with twenty popular support")
	if decoded.ok:
		_assert_equal(decoded.value.campaign.rebellion_state.value, 30, "V4 Heyuan ownership infers thirty rebellion")
		_assert_equal(decoded.value.content_version, "0.6.1-m6-deck-editor", "migration preserves the old content version")

	var legacy_bundle := _bundle.duplicate(true)
	legacy_bundle.encounters = _load_json("res://data/config/prototype_heyuan_encounters.json")
	legacy_bundle.erase("legacy_encounters")
	var legacy_flow = GameFlowCoordinatorScript.new()
	_assert_true(legacy_flow.setup(_registry, legacy_bundle, ToggleSaveStore.new(), "%s/legacy" % SAVE_ROOT).is_empty(), "legacy active-run fixture configures")
	_assert_true(legacy_flow.new_campaign("campaign.m6-active-v4", "2026-09-02T10:01:00Z").ok, "legacy active-run fixture starts")
	_assert_true(legacy_flow.start_expedition({"run_id": "run.v4-active", "expedition_id": EXPEDITIONS[0], "general_id": "general.zhao_lie", "map_seed": 77}, "2026-09-02T10:02:00Z").ok, "legacy active Heyuan run starts")
	var active_source: Dictionary = legacy_flow.snapshot()
	active_source.erase("phase")
	active_source.save_version = 4
	active_source.expedition.erase("generator_version")
	active_source.expedition.erase("map_signature")
	var active_decoded: Dictionary = SaveGameCodecScript.new().decode(JSON.stringify(active_source))
	_assert_true(active_decoded.ok, "V4 active Heyuan migrates successfully")
	if active_decoded.ok:
		_assert_equal(active_decoded.value.expedition.generator_version, 1, "V4 active Heyuan stays on hidden legacy generator v1")
		_assert_equal(active_decoded.value.expedition.map_signature, "legacy-v1", "V4 active run receives the legacy signature")
		var legacy_path := "%s/legacy/autosave.json" % SAVE_ROOT
		_assert_true(SaveFileStoreScript.new().save(legacy_path, active_decoded.value, "2026-09-02T10:03:00Z").ok, "migrated legacy active run can be persisted")
		var restored = _new_flow(ToggleSaveStore.new(), "%s/legacy" % SAVE_ROOT)
		_assert_true(restored.load_campaign(legacy_path).ok, "Rogue coordinator restores a migrated active legacy route")
		_assert_equal(restored.snapshot().expedition.generator_version, 1, "restored legacy route is never rebuilt with generator v2")

	var v2_flow = _new_flow(ToggleSaveStore.new(), "%s/v2-active" % SAVE_ROOT)
	_assert_true(v2_flow.new_campaign("campaign.m6-active-v5", "2026-09-02T10:10:00Z").ok, "V5 active V2 fixture campaign starts")
	_assert_true(_start(v2_flow, EXPEDITIONS[1], "run.v2-template", 909).ok, "V2 fixture obtains a valid deployment snapshot")
	var template: Dictionary = v2_flow.snapshot().expedition
	var v2_generated: Dictionary = ExpeditionMapGeneratorScript.generate(_registry.get_expedition(EXPEDITIONS[1]), 909, 2)
	_assert_true(v2_generated.ok, "legacy V2 active map regenerates from its preserved profile")
	var v2_run = ExpeditionRunStateScript.new()
	var v2_setup_errors: PackedStringArray = v2_run.setup("run.v2-active", v2_generated.map, template.general, template.deck, template.card_overrides, 20)
	_assert_true(v2_setup_errors.is_empty(), "V5 fixture accepts the byte-stable V2 route")
	var v5_source: Dictionary = v2_flow.snapshot()
	v5_source.erase("phase")
	v5_source.save_version = 5
	v5_source.content_version = "0.7.0-m6-rogue-expeditions"
	v5_source.campaign.erase("popular_support_state")
	v5_source.expedition = v2_run.snapshot()
	v5_source.expedition.erase("initial_popular_support")
	v5_source.expedition.erase("pending_popular_support_delta")
	var v5_decoded: Dictionary = SaveGameCodecScript.new().decode(JSON.stringify(v5_source))
	_assert_true(v5_decoded.ok and v5_decoded.to_version == 7, "Save V5 active V2 run migrates to V7")
	if v5_decoded.ok:
		_assert_equal(v5_decoded.value.expedition.generator_version, 2, "V5 migration preserves active generator V2")
		_assert_equal(v5_decoded.value.expedition.map_signature, v2_generated.map.map_signature, "V5 migration preserves the V2 map signature")
		_assert_equal(v5_decoded.value.expedition.pending_popular_support_delta, 0, "V5 active run receives zero pending popular support")
		var v2_path := "%s/v2-active/autosave.json" % SAVE_ROOT
		_assert_true(SaveFileStoreScript.new().save(v2_path, v5_decoded.value, "2026-09-02T10:11:00Z").ok, "migrated active V2 run can be persisted")
		var v2_restored = _new_flow(ToggleSaveStore.new(), "%s/v2-active" % SAVE_ROOT)
		_assert_true(v2_restored.load_campaign(v2_path).ok, "coordinator restores the migrated active V2 route")
		_assert_equal(v2_restored.snapshot().expedition.map_signature, v2_generated.map.map_signature, "restored V2 route keeps its original topology and signature")

	var v3_generated: Dictionary = ExpeditionMapGeneratorScript.generate(_registry.get_expedition(EXPEDITIONS[1]), 314159, 3)
	_assert_true(v3_generated.ok, "legacy V3 active map regenerates from its preserved profile")
	var v3_run = ExpeditionRunStateScript.new()
	var v3_setup_errors: PackedStringArray = v3_run.setup("run.v3-active", v3_generated.map, template.general, template.deck, template.card_overrides, 20)
	_assert_true(v3_setup_errors.is_empty(), "current save accepts a frozen V3 three-lane route")
	var v3_source: Dictionary = v2_flow.snapshot()
	v3_source.erase("phase")
	v3_source.expedition = v3_run.snapshot()
	var v3_path := "%s/v3-active/autosave.json" % SAVE_ROOT
	_assert_true(SaveFileStoreScript.new().save(v3_path, v3_source, "2026-09-02T10:12:00Z").ok, "active V3 run can be persisted without conversion")
	var v3_restored = _new_flow(ToggleSaveStore.new(), "%s/v3-active" % SAVE_ROOT)
	_assert_true(v3_restored.load_campaign(v3_path).ok, "coordinator restores an active V3 route after V4 becomes current")
	_assert_equal(v3_restored.snapshot().expedition.generator_version, 3, "restored V3 route keeps its generator version")
	_assert_equal(v3_restored.snapshot().expedition.map_signature, v3_generated.map.map_signature, "restored V3 route keeps its original topology and signature")


func _test_choice_checkpoint_attack_and_retreat() -> void:
	var root_path := "%s/merchant-retreat" % SAVE_ROOT
	var flow = _new_flow(ToggleSaveStore.new(), root_path)
	_assert_true(flow.new_campaign("campaign.merchant-retreat", "2026-09-02T11:00:00Z").ok, "merchant-retreat campaign starts")
	_assert_true(_start(flow, EXPEDITIONS[0], "run.merchant-retreat", 20260902).ok, "merchant-retreat expedition starts")
	_submit_victory_after_advance(flow, _opening_node_toward_type(flow, "merchant"), "merchant-opening")
	var merchant_id := _next_node_of_type(flow, "merchant")
	_assert_true(not merchant_id.is_empty() and flow.advance_to_node(merchant_id, "2026-09-02T11:02:00Z").ok, "route reaches a merchant choice checkpoint")
	_assert_equal(flow.phase(), "encounter_choice", "merchant arrival pauses before the choice")
	var frozen: Dictionary = flow.pending_encounter()
	var reloaded = _new_flow(ToggleSaveStore.new(), root_path)
	_assert_true(reloaded.load_campaign("%s/autosave.json" % root_path).ok, "merchant choice checkpoint reloads")
	_assert_equal(reloaded.pending_encounter().encounter_id, frozen.encounter_id, "reload cannot reroll merchant offers")
	var poor_trade: Dictionary = reloaded.submit_encounter_choice({"action_id": "merchant.trade-card", "choice_id": "trade_card"}, "2026-09-02T11:03:00Z")
	_assert_true(not poor_trade.ok, "merchant rejects a purchase lacking unbanked silver")
	var attack: Dictionary = reloaded.submit_encounter_choice({"action_id": "merchant.attack", "choice_id": "attack"}, "2026-09-02T11:04:00Z")
	_assert_true(attack.ok and reloaded.phase() == "combat_checkpoint", "merchant attack enters a frozen guard combat")
	var duplicate: Dictionary = reloaded.submit_encounter_choice({"action_id": "merchant.attack", "choice_id": "attack"}, "2026-09-02T11:04:01Z")
	_assert_true(duplicate.ok and duplicate.duplicate, "merchant choice action id is idempotent after the phase changes")
	_assert_equal(reloaded.snapshot().expedition.pending_rebellion_delta, 8, "merchant attack records eight pending rebellion")
	var request: Dictionary = reloaded.pending_combat_request()
	var retreat := {"battle_id": request.battle_id, "status": "retreated", "player_remaining_troops": 1000, "player_remaining_morale": 70, "general_died": false, "general_injured": false}
	_assert_true(reloaded.submit_combat_result(retreat, "2026-09-02T11:05:00Z").ok, "merchant attacker may retreat")
	_assert_true(reloaded.finalize_expedition("2026-09-02T11:06:00Z").ok, "merchant retreat finalizes")
	_assert_equal(reloaded.snapshot().campaign.rebellion_state.value, 8, "merchant rebellion persists through retreat")
	_assert_true(reloaded.snapshot().campaign.territories.is_empty(), "retreat captures no territory")


func _test_reward_checkpoint_reload() -> void:
	var root_path := "%s/reward" % SAVE_ROOT
	var flow = _new_flow(ToggleSaveStore.new(), root_path)
	_assert_true(flow.new_campaign("campaign.reward", "2026-09-02T11:30:00Z").ok, "reward checkpoint campaign starts")
	_assert_true(_start(flow, EXPEDITIONS[1], "run.reward", 5150).ok, "reward checkpoint expedition starts")
	_submit_victory_after_advance(flow, _opening_node_toward_type(flow, "merchant"), "reward-opening")
	_assert_true(flow.advance_to_node(_next_node_of_type(flow, "merchant"), _timestamp()).ok, "reward route reaches merchant")
	_assert_true(flow.submit_encounter_choice({"action_id": "reward.merchant.leave", "choice_id": "leave"}, _timestamp()).ok, "reward route leaves merchant")
	_submit_victory_after_advance(flow, _next_node_id(flow), "layer-three")
	_assert_equal(flow.phase(), "reward_choice", "layer-three victory creates a reward checkpoint")
	var frozen: Dictionary = flow.pending_encounter()
	var reloaded = _new_flow(ToggleSaveStore.new(), root_path)
	_assert_true(reloaded.load_campaign("%s/autosave.json" % root_path).ok, "post-battle reward checkpoint reloads")
	_assert_equal(reloaded.pending_encounter().encounter_id, frozen.encounter_id, "reward cards remain frozen across reload")
	var card_choice: Dictionary = reloaded.pending_encounter().choices[1]
	var before_size: int = reloaded.snapshot().expedition.deck.size()
	_assert_true(reloaded.submit_encounter_choice({"action_id": "reward.take", "choice_id": card_choice.choice_id}, _timestamp()).ok, "temporary reward can be claimed after reload")
	_assert_equal(reloaded.snapshot().expedition.deck.size(), before_size + 1, "temporary reward appends to the current run deck")
	_assert_true(reloaded.snapshot().expedition.temporary_cards.has(card_choice.card_id), "temporary reward is tracked separately from permanent unlocks")


func _test_item_use_and_rollback() -> void:
	var root_path := "%s/item" % SAVE_ROOT
	var store = ToggleSaveStore.new()
	var flow = _new_flow(store, root_path)
	_assert_true(flow.new_campaign("campaign.item", "2026-09-02T12:00:00Z").ok, "item campaign starts")
	_assert_true(_start(flow, EXPEDITIONS[0], "run.item", 111).ok, "item expedition starts")
	_submit_victory_after_advance(flow, _opening_node_toward_type(flow, "merchant"), "item-opening")
	var merchant_id := _next_node_of_type(flow, "merchant")
	_assert_true(flow.advance_to_node(merchant_id, "2026-09-02T12:02:00Z").ok, "item route reaches merchant")
	var before_choice: Dictionary = flow.snapshot()
	store.fail_next = true
	var failed: Dictionary = flow.submit_encounter_choice({"action_id": "item.buy.fail", "choice_id": "trade_item"}, "2026-09-02T12:03:00Z")
	_assert_true(not failed.ok and failed.get("save_failed", false), "choice autosave failure is reported")
	_assert_equal(flow.snapshot(), before_choice, "choice autosave failure rolls back all effects and phase")
	var bought: Dictionary = flow.submit_encounter_choice({"action_id": "item.buy", "choice_id": "trade_item"}, "2026-09-02T12:04:00Z")
	_assert_true(bought.ok and flow.snapshot().expedition.temporary_items.size() == 1, "merchant trade buys one temporary item from unbanked loot")
	var item: Dictionary = flow.snapshot().expedition.temporary_items[0]
	var before_use: Dictionary = flow.snapshot()
	store.fail_next = true
	var failed_use: Dictionary = flow.use_expedition_item({"action_id": "item.use.fail", "item_instance_id": item.instance_id}, "2026-09-02T12:05:00Z")
	_assert_true(not failed_use.ok and failed_use.get("save_failed", false), "item autosave failure is reported")
	_assert_equal(flow.snapshot(), before_use, "item autosave failure restores the item and run state")
	var used: Dictionary = flow.use_expedition_item({"action_id": "item.use", "item_instance_id": item.instance_id}, "2026-09-02T12:06:00Z")
	_assert_true(used.ok and flow.snapshot().expedition.temporary_items.is_empty(), "temporary item is consumed between combats")
	var duplicate: Dictionary = flow.use_expedition_item({"action_id": "item.use", "item_instance_id": item.instance_id}, "2026-09-02T12:06:01Z")
	_assert_true(duplicate.ok and duplicate.duplicate, "item action id is idempotent after consumption")


func _test_success_and_three_target_completion() -> void:
	var root_path := "%s/three-targets" % SAVE_ROOT
	var flow = _new_flow(ToggleSaveStore.new(), root_path)
	_assert_true(flow.new_campaign("campaign.three-targets", "2026-09-02T13:00:00Z").ok, "three-target campaign starts")
	var initial_targets: Dictionary = flow.available_expeditions()
	_assert_equal(initial_targets.targets.size(), 3, "all three targets are visible from a new campaign")
	_assert_true(not initial_targets.all_captured, "new campaign is not already pacified")
	var permanent_card := ""
	for index in EXPEDITIONS.size():
		var expedition_id := String(EXPEDITIONS[index])
		_assert_true(_start(flow, expedition_id, "run.target.%d" % index, 8000 + index).ok, "%s can be selected without a fixed order" % expedition_id)
		var route_result: Dictionary = _complete_rogue_route(flow, index == 0)
		_assert_true(route_result.ok and flow.phase() == "settlement_pending", "%s reaches pending settlement" % expedition_id)
		if index == 0:
			permanent_card = String(route_result.get("permanent_card", ""))
			_assert_true(not permanent_card.is_empty() and flow.snapshot().expedition.deck.has(permanent_card), "elite permanent reward is usable immediately in the run deck")
		_assert_true(flow.finalize_expedition("2026-09-02T13:%02d:30Z" % (index + 1)).ok, "%s finalizes successfully" % expedition_id)
		_assert_equal(flow.snapshot().campaign.rebellion_state.value, 30 * (index + 1), "%s capture adds thirty rebellion" % expedition_id)
		_assert_true(not flow.expedition_readiness({"expedition_id": expedition_id, "general_id": "general.zhao_lie"}).ok, "captured target cannot be attacked again")
		if index < EXPEDITIONS.size() - 1:
			_assert_true(flow.expedition_readiness({"expedition_id": EXPEDITIONS[index + 1], "general_id": "general.zhao_lie"}).ok, "another uncaptured target remains available")
	var campaign: Dictionary = flow.snapshot().campaign
	_assert_equal(campaign.territories.size(), 3, "all three successful expeditions create three territories")
	_assert_equal(campaign.cycle, 3, "each primary target advances exactly one faction cycle")
	_assert_true(campaign.unlocked_public_cards.has(permanent_card), "successful return permanently unlocks the selected reward card")
	_assert_true(campaign.rebellion_state.suppression_forecast, "rebellion sixty or above only exposes the suppression forecast")
	_assert_equal(flow.phase(), "main_city", "three-target completion remains in the main city")
	_assert_true(flow.available_expeditions().all_captured, "three-target completion reports 三地平定")


func _test_new_enemy_combat_runtime() -> void:
	for enemy_id in ["enemy.bandit.grunt", "enemy.merchant.guard", "enemy.boss.shimen_chief", "enemy.boss.linze_commissioner"]:
		var result: Dictionary = FixedStrategyCombatRunnerScript.run_battle("general.zhao_lie", enemy_id, 9901, _registry, 80)
		_assert_true(result.status in ["victory", "defeat"], "%s completes through the real CombatController" % enemy_id)


func _complete_rogue_route(flow, take_permanent: bool) -> Dictionary:
	var permanent_card := ""
	for step in 30:
		match flow.phase():
			"expedition_map":
				var node_id := _next_node_id(flow)
				if node_id.is_empty():
					return {"ok": false, "reason": "no next node"}
				var advanced: Dictionary = flow.advance_to_node(node_id, _timestamp())
				if not advanced.ok:
					return advanced
			"combat_checkpoint":
				var request: Dictionary = flow.pending_combat_request()
				var expedition: Dictionary = flow.snapshot().expedition
				var result := {"battle_id": request.battle_id, "status": "victory", "player_remaining_troops": maxi(int(expedition.general.troops) - 5, 1), "player_remaining_morale": maxi(int(expedition.general.morale) - 1, 1), "general_died": false, "general_injured": false}
				var submitted: Dictionary = flow.submit_combat_result(result, _timestamp())
				if not submitted.ok:
					return submitted
			"combat_report":
				var report: Dictionary = flow.pending_combat_report()
				var acknowledged: Dictionary = flow.acknowledge_combat_report({"action_id": "report.%d" % _action_sequence, "report_id": report.get("report_id", "")}, _timestamp())
				_action_sequence += 1
				if not acknowledged.ok:
					return acknowledged
			"encounter_choice", "reward_choice":
				var encounter: Dictionary = flow.pending_encounter()
				var choice_id := _safe_choice_id(encounter)
				if take_permanent and encounter.kind == "reward" and not flow.snapshot().expedition.permanent_reward_claimed:
					for choice in encounter.choices:
						if bool(choice.get("permanent", false)) and bool(choice.get("available", false)):
							choice_id = String(choice.choice_id)
							permanent_card = String(choice.card_id)
							break
				var chosen: Dictionary = flow.submit_encounter_choice({"action_id": "choice.%d" % _action_sequence, "choice_id": choice_id}, _timestamp())
				_action_sequence += 1
				if not chosen.ok:
					return chosen
			"settlement_pending":
				return {"ok": true, "permanent_card": permanent_card}
	return {"ok": false, "reason": "route step limit"}


func _submit_victory_after_advance(flow, node_id: String, label: String) -> void:
	_assert_true(flow.advance_to_node(node_id, _timestamp()).ok and flow.phase() == "combat_checkpoint", "%s creates a combat checkpoint" % label)
	var request: Dictionary = flow.pending_combat_request()
	var expedition: Dictionary = flow.snapshot().expedition
	var result := {"battle_id": request.battle_id, "status": "victory", "player_remaining_troops": maxi(int(expedition.general.troops) - 5, 1), "player_remaining_morale": maxi(int(expedition.general.morale) - 1, 1), "general_died": false, "general_injured": false}
	_assert_true(flow.submit_combat_result(result, _timestamp()).ok, "%s victory settles" % label)
	var report: Dictionary = flow.pending_combat_report()
	_assert_true(flow.phase() == "combat_report" and not report.is_empty(), "%s victory creates a combat report" % label)
	var acknowledged: Dictionary = flow.acknowledge_combat_report({"action_id": "report.%d" % _action_sequence, "report_id": report.get("report_id", "")}, _timestamp())
	_action_sequence += 1
	_assert_true(acknowledged.ok, "%s combat report continues to the next phase" % label)


func _submit_retreat_after_advance(flow, node_id: String, label: String) -> void:
	_assert_true(flow.advance_to_node(node_id, _timestamp()).ok and flow.phase() == "combat_checkpoint", "%s creates a retreat checkpoint" % label)
	var request: Dictionary = flow.pending_combat_request()
	var expedition: Dictionary = flow.snapshot().expedition
	var result := {"battle_id": request.battle_id, "status": "retreated", "player_remaining_troops": int(expedition.general.troops), "player_remaining_morale": int(expedition.general.morale), "general_died": false, "general_injured": false}
	_assert_true(flow.submit_combat_result(result, _timestamp()).ok, "%s retreat settles" % label)


func _start(flow, expedition_id: String, run_id: String, seed: int) -> Dictionary:
	return flow.start_expedition({"run_id": run_id, "expedition_id": expedition_id, "general_id": "general.zhao_lie", "map_seed": seed}, _timestamp())


func _next_node_id(flow) -> String:
	var available: Array = flow.snapshot().expedition.route.available_next_node_ids
	return String(available[0]) if not available.is_empty() else ""


func _next_node_of_type(flow, node_type: String) -> String:
	var expedition: Dictionary = flow.snapshot().expedition
	for node_id in expedition.route.available_next_node_ids:
		for node in expedition.visible_nodes:
			if node.id == node_id and node.node_type == node_type:
				return String(node_id)
	return ""


func _opening_node_toward_type(flow, node_type: String) -> String:
	var expedition: Dictionary = flow.snapshot().expedition
	var available: Array = expedition.route.available_next_node_ids
	var target_ids := {}
	for node in expedition.visible_nodes:
		if int(node.get("layer", -1)) == 2 and node.get("node_type", "") == node_type:
			target_ids[node.id] = true
	for edge in expedition.map_edges:
		if available.has(edge.from) and target_ids.has(edge.to):
			return String(edge.from)
	return _next_node_id(flow)


func _seed_with_event(expedition_id: String, event_id: String) -> int:
	var definition: Dictionary = _registry.get_expedition(expedition_id)
	for seed in range(1, 5001):
		var generated: Dictionary = ExpeditionMapGeneratorScript.generate(definition, seed, 4)
		if not generated.ok:
			continue
		for node in generated.map.nodes:
			if int(node.get("layer", -1)) == 2 and node.get("encounter_id", "") == event_id:
				return seed
	return -1


func _safe_choice_id(encounter: Dictionary) -> String:
	for preferred in ["leave", "skip", "observe", "mark", "ration", "scout", "avoid", "detour", "burn"]:
		for choice in encounter.get("choices", []):
			if choice.choice_id == preferred and bool(choice.get("available", false)):
				return preferred
	for choice in encounter.get("choices", []):
		if bool(choice.get("available", false)):
			return String(choice.choice_id)
	return ""


func _map_has_faction(map: Dictionary, faction: String) -> bool:
	for node in map.nodes:
		if node.get("enemy_faction", "") == faction:
			return true
	return false


func _new_flow(store, root_path: String):
	var flow = GameFlowCoordinatorScript.new()
	var errors: PackedStringArray = flow.setup(_registry, _bundle, store, root_path)
	_assert_true(errors.is_empty(), "Rogue game flow configures at %s" % root_path.get_file())
	return flow


func _load_bundle() -> Dictionary:
	return {
		"bootstrap": _load_json("res://data/config/prototype_campaign_bootstrap.json"),
		"deployment_rules": _load_json("res://data/config/prototype_deployment_rules.json"),
		"encounters": _load_json("res://data/config/prototype_rogue_expeditions.json"),
		"legacy_encounters": _load_json("res://data/config/prototype_heyuan_encounters.json"),
		"army_economy": _load_json("res://data/config/prototype_army_economy.json"),
		"research_economy": _load_json("res://data/config/prototype_research_economy.json"),
		"general_progression": _load_json("res://data/config/prototype_general_progression.json"),
		"faction_cycle": _load_json("res://data/config/prototype_faction_cycle.json"),
	}


func _load_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	return JSON.parse_string(file.get_as_text())


func _timestamp() -> String:
	_action_sequence += 1
	return "2026-09-02T15:%02d:%02dZ" % [(_action_sequence / 60) % 60, _action_sequence % 60]


func _support_only_settlement(request_id: String, delta: int) -> Dictionary:
	return {
		"request_id": request_id,
		"run_id": "run.%s" % request_id,
		"expedition_id": EXPEDITIONS[0],
		"outcome": "retreated",
		"general_id": "general.zhao_lie",
		"remaining_troops": 1,
		"remaining_morale": 1,
		"general_died": false,
		"general_injured": false,
		"loot_to_bank": {},
		"lost_unbanked_loot": {},
		"popular_support_delta": delta,
	}


func _cleanup() -> void:
	for directory in ["migration", "legacy", "v2-active", "v3-active", "merchant-retreat", "reward", "item", "three-targets"]:
		var path := "%s/%s" % [SAVE_ROOT, directory]
		for name in ["autosave.json", "autosave.json.bak", "autosave.json.tmp", "manual_1.json", "manual_1.json.bak", "manual_1.json.tmp"]:
			var file_path := "%s/%s" % [path, name]
			if FileAccess.file_exists(file_path):
				DirAccess.remove_absolute(file_path)


func _assert_true(condition: bool, label: String) -> void:
	if condition:
		_passed += 1
		print("TEST PASS: %s" % label)
	else:
		_failed += 1
		push_error("TEST FAIL: %s" % label)


func _assert_equal(actual, expected, label: String) -> void:
	_assert_true(actual == expected, "%s (expected=%s actual=%s)" % [label, str(expected), str(actual)])
