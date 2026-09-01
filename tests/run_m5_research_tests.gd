extends SceneTree

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")
const ResearchManagementServiceScript := preload("res://src/domain/campaign/research_management_service.gd")
const CampaignStateScript := preload("res://src/domain/campaign/campaign_state.gd")
const CampaignControllerScript := preload("res://src/domain/campaign/campaign_controller.gd")
const SaveEnvelopeScript := preload("res://src/domain/campaign/save_envelope.gd")
const SaveGameCodecScript := preload("res://src/infrastructure/persistence/save_game_codec.gd")

const ECONOMY_PATH := "res://data/config/prototype_research_economy.json"

var _passed := 0
var _failed := 0
var _registry
var _economy: Dictionary = {}
var _cards: Array = []


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	_registry = ContentRegistryScript.new()
	_assert_true(_registry.load_all(), "M5 research content registry loads")
	_economy = _load_json(ECONOMY_PATH)
	for card_id in _economy.get("eligible_public_card_ids", []):
		_cards.append(_registry.get_card(card_id))
	_test_research_state_and_old_save_normalization()
	_test_research_economy_and_catalog_contracts()
	_test_unlock_transaction_and_idempotency()
	_test_special_clue_unlock_and_rollbacks()
	_test_permanent_upgrade_transaction()
	_test_upgrade_failures_and_locked_branch()
	_test_resolved_card_definition()
	_test_research_save_round_trip()
	print("TEST SUMMARY: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_research_state_and_old_save_normalization() -> void:
	var state: Dictionary = CampaignStateScript.create("campaign.research")
	_assert_equal(state.research, {"applied_action_ids": [], "history": []}, "new CampaignState exposes research transaction state")
	_assert_true(state.unlocked_public_cards.is_empty(), "new campaign does not silently choose its starting public library")
	_assert_true(state.card_upgrade_branches.is_empty(), "new campaign starts without permanent card upgrades")
	var old_state := state.duplicate(true)
	old_state.research = {}
	var controller = CampaignControllerScript.new()
	_assert_true(controller.setup(old_state).is_empty(), "old V1 research object receives additive defaults")
	_assert_equal(controller.snapshot().research, {"applied_action_ids": [], "history": []}, "old V1 research state normalizes to empty ledgers")
	var duplicate_unlock := state.duplicate(true)
	duplicate_unlock.unlocked_public_cards = ["card.public.general.assault", "card.public.general.assault"]
	_assert_error_contains(CampaignStateScript.validate(duplicate_unlock), "duplicate", "CampaignState rejects duplicate public card unlocks")
	var orphan_upgrade := state.duplicate(true)
	orphan_upgrade.card_upgrade_branches["card.public.general.assault"] = "swift"
	_assert_error_contains(CampaignStateScript.validate(orphan_upgrade), "locked card", "CampaignState rejects an upgrade for a locked card")


func _test_research_economy_and_catalog_contracts() -> void:
	_assert_true(not _economy.is_empty(), "prototype research economy config loads")
	_assert_true(ResearchManagementServiceScript.validate_economy_definition(_economy).is_empty(), "prototype research economy satisfies its contract")
	_assert_equal(_economy.balance_status, "prototype_temporary", "research costs remain explicitly marked prototype-only")
	_assert_equal(_economy.eligible_public_card_ids.size(), 16, "research catalog contains exactly the sixteen M3 public cards")
	_assert_true(ResearchManagementServiceScript.validate_card_catalog(_economy, _cards).is_empty(), "all eligible research cards resolve to valid public definitions")
	var assault: Dictionary = _registry.get_card("card.public.general.assault")
	var basic_quote: Dictionary = ResearchManagementServiceScript.quote_unlock(_economy, assault)
	_assert_equal(basic_quote.main_costs, {"silver": 40, "military_knowledge": 20}, "basic unlock quote uses centralized prototype costs")
	var pursuit: Dictionary = _registry.get_card("card.public.cavalry.pursue")
	var rare_quote: Dictionary = ResearchManagementServiceScript.quote_unlock(_economy, pursuit)
	_assert_equal(rare_quote.special_costs, {"resource.cavalry_fragment": 1}, "rare cavalry research demonstrates a fragment requirement")
	var falsely_final := _economy.duplicate(true)
	falsely_final.balance_status = "final"
	_assert_error_contains(ResearchManagementServiceScript.validate_economy_definition(falsely_final), "prototype_temporary", "research costs cannot silently become final balance")
	var duplicate_ids := _economy.duplicate(true)
	duplicate_ids.eligible_public_card_ids.append(duplicate_ids.eligible_public_card_ids[0])
	_assert_error_contains(ResearchManagementServiceScript.validate_economy_definition(duplicate_ids), "unique", "research catalog rejects duplicate eligible ids")
	var broken_cards := _cards.duplicate(true)
	broken_cards[0].upgrade_branches[1].id = broken_cards[0].upgrade_branches[0].id
	_assert_error_contains(ResearchManagementServiceScript.validate_card_catalog(_economy, broken_cards), "branch ids", "research catalog rejects duplicate permanent branch ids")
	var exclusive: Dictionary = _registry.get_card("card.general.zhao_lie.lone_breakthrough")
	var exclusive_economy := _economy.duplicate(true)
	exclusive_economy.eligible_public_card_ids[0] = exclusive.id
	_assert_error_contains(ResearchManagementServiceScript.validate_card_catalog(exclusive_economy, [exclusive]), "not a public card", "research catalog rejects a general-exclusive card")


func _test_unlock_transaction_and_idempotency() -> void:
	var controller = _funded_controller("campaign.unlock")
	var request := {"action_id": "research:unlock:assault", "card_id": "card.public.general.assault"}
	var request_before := request.duplicate(true)
	var first: Dictionary = controller.unlock_public_card(request)
	_assert_true(first.ok and not first.duplicate, "valid public card research commits once")
	_assert_equal(request, request_before, "unlock transaction does not mutate its request DTO")
	var state: Dictionary = controller.snapshot()
	_assert_equal(state.unlocked_public_cards, ["card.public.general.assault"], "research permanently unlocks the public card")
	_assert_equal(state.resources.silver, 960, "unlock consumes silver")
	_assert_equal(state.resources.military_knowledge, 980, "unlock consumes military knowledge")
	_assert_equal(state.research.history.size(), 1, "unlock appends one research audit record")
	var after_first := state.duplicate(true)
	var duplicate: Dictionary = controller.unlock_public_card(request)
	_assert_true(duplicate.ok and duplicate.duplicate, "same research action id is idempotent")
	_assert_equal(controller.snapshot(), after_first, "duplicate unlock cannot consume resources or add history twice")
	var second_action := {"action_id": "research:unlock:assault:again", "card_id": "card.public.general.assault"}
	_assert_true(not controller.unlock_public_card(second_action).ok, "already unlocked card rejects a distinct second action")
	_assert_equal(controller.snapshot(), after_first, "rejected second unlock leaves research state unchanged")


func _test_special_clue_unlock_and_rollbacks() -> void:
	var poor_controller = _funded_controller("campaign.no-fragment", false)
	var before: Dictionary = poor_controller.snapshot()
	var pursuit_request := {"action_id": "research:unlock:pursuit", "card_id": "card.public.cavalry.pursue"}
	_assert_true(not poor_controller.unlock_public_card(pursuit_request).ok, "rare research rejects a missing cavalry fragment")
	_assert_equal(poor_controller.snapshot(), before, "missing fragment rolls back silver and military knowledge")
	var funded = _funded_controller("campaign.with-fragment", true)
	_assert_true(funded.unlock_public_card(pursuit_request).ok, "rare research unlocks when its clue and main resources exist")
	_assert_equal(funded.snapshot().special_resources["resource.cavalry_fragment"], 1, "successful rare research consumes one fragment")
	var empty_controller = CampaignControllerScript.new()
	_assert_true(not empty_controller.unlock_public_card({}).ok, "research rejects an uninitialized controller")
	var unconfigured = CampaignControllerScript.new()
	unconfigured.setup(CampaignStateScript.create("campaign.no-research-config"))
	_assert_true(not unconfigured.unlock_public_card({"action_id": "research:no-config", "card_id": "card.public.general.assault"}).ok, "research rejects a missing catalog")
	var controller = _funded_controller("campaign.unlock-failures")
	_assert_true(not controller.unlock_public_card({}).ok, "unlock rejects missing fields")
	_assert_true(not controller.unlock_public_card({"action_id": "research:unknown", "card_id": "card.unknown"}).ok, "unlock rejects an unknown card")
	var no_money: Dictionary = CampaignStateScript.create("campaign.no-money")
	no_money.resources.military_knowledge = 1000
	var no_money_controller = CampaignControllerScript.new()
	no_money_controller.setup(no_money)
	no_money_controller.configure_research(_economy, _cards)
	var no_money_before := no_money_controller.snapshot()
	_assert_true(not no_money_controller.unlock_public_card({"action_id": "research:no-money", "card_id": "card.public.general.assault"}).ok, "unlock rejects insufficient silver")
	_assert_equal(no_money_controller.snapshot(), no_money_before, "insufficient main resources cause a full research rollback")


func _test_permanent_upgrade_transaction() -> void:
	var controller = _funded_controller("campaign.upgrade")
	controller.unlock_public_card({"action_id": "research:unlock:charge", "card_id": "card.public.cavalry.charge"})
	var request := {"action_id": "research:upgrade:charge:swift", "card_id": "card.public.cavalry.charge", "branch_id": "swift_assault"}
	var before_request := request.duplicate(true)
	var upgraded: Dictionary = controller.upgrade_public_card(request)
	_assert_true(upgraded.ok and not upgraded.duplicate, "valid branch upgrade commits once")
	_assert_equal(request, before_request, "upgrade transaction does not mutate its request DTO")
	var state: Dictionary = controller.snapshot()
	_assert_equal(state.card_upgrade_branches["card.public.cavalry.charge"], "swift_assault", "upgrade stores exactly one permanent branch id")
	_assert_equal(state.resources.silver, 890, "unlock plus basic upgrade consume their configured silver")
	_assert_equal(state.resources.military_knowledge, 940, "unlock plus basic upgrade consume their configured military knowledge")
	_assert_equal(state.research.history.size(), 2, "unlock and upgrade produce separate audit records")
	var after_upgrade := state.duplicate(true)
	var duplicate: Dictionary = controller.upgrade_public_card(request)
	_assert_true(duplicate.ok and duplicate.duplicate, "same upgrade action is idempotent")
	_assert_equal(controller.snapshot(), after_upgrade, "duplicate upgrade cannot consume its cost twice")


func _test_upgrade_failures_and_locked_branch() -> void:
	var controller = _funded_controller("campaign.upgrade-failures")
	_assert_true(not controller.upgrade_public_card({"action_id": "research:upgrade:locked", "card_id": "card.public.general.assault", "branch_id": "swift"}).ok, "locked card cannot be upgraded")
	controller.unlock_public_card({"action_id": "research:unlock:upgrade-test", "card_id": "card.public.general.assault"})
	var before_unknown: Dictionary = controller.snapshot()
	_assert_true(not controller.upgrade_public_card({"action_id": "research:upgrade:unknown", "card_id": "card.public.general.assault", "branch_id": "not-a-branch"}).ok, "upgrade rejects an unknown branch")
	_assert_equal(controller.snapshot(), before_unknown, "unknown branch cannot consume upgrade resources")
	_assert_true(controller.upgrade_public_card({"action_id": "research:upgrade:first", "card_id": "card.public.general.assault", "branch_id": "swift"}).ok, "first valid branch choice succeeds")
	var permanently_locked: Dictionary = controller.snapshot()
	_assert_true(not controller.upgrade_public_card({"action_id": "research:upgrade:change-mind", "card_id": "card.public.general.assault", "branch_id": "break_momentum"}).ok, "second branch cannot replace a permanent choice")
	_assert_equal(controller.snapshot(), permanently_locked, "rejected respec preserves the original branch and resources")
	var poor_state: Dictionary = CampaignStateScript.create("campaign.upgrade-poor")
	poor_state.unlocked_public_cards = ["card.public.general.assault"]
	poor_state.resources.silver = 1000
	poor_state.resources.military_knowledge = 10
	var poor_controller = CampaignControllerScript.new()
	poor_controller.setup(poor_state)
	poor_controller.configure_research(_economy, _cards)
	var poor_before := poor_controller.snapshot()
	_assert_true(not poor_controller.upgrade_public_card({"action_id": "research:upgrade:no-knowledge", "card_id": "card.public.general.assault", "branch_id": "swift"}).ok, "upgrade rejects insufficient military knowledge")
	_assert_equal(poor_controller.snapshot(), poor_before, "failed upgrade rolls back every resource and branch field")


func _test_resolved_card_definition() -> void:
	var controller = _funded_controller("campaign.resolve")
	_assert_true(not controller.resolved_public_card("card.public.cavalry.charge").ok, "locked public card cannot enter a resolved deck")
	controller.unlock_public_card({"action_id": "research:unlock:resolve", "card_id": "card.public.cavalry.charge"})
	var base: Dictionary = controller.resolved_public_card("card.public.cavalry.charge")
	_assert_true(base.ok, "unlocked base card resolves before upgrade")
	_assert_equal(base.card.cost, 1, "unupgraded card keeps its base cost")
	var original: Dictionary = _registry.get_card("card.public.cavalry.charge")
	controller.upgrade_public_card({"action_id": "research:upgrade:resolve", "card_id": "card.public.cavalry.charge", "branch_id": "swift_assault"})
	var resolved: Dictionary = controller.resolved_public_card("card.public.cavalry.charge")
	_assert_true(resolved.ok, "permanently upgraded card resolves")
	_assert_equal(resolved.card.cost, 0, "resolved swift branch applies its cost override")
	_assert_equal(resolved.card.effects[0].base_power, 50, "resolved swift branch applies its effect override")
	_assert_equal(resolved.card.applied_upgrade_branch, "swift_assault", "resolved card identifies its permanent branch")
	_assert_equal(original.cost, 1, "branch resolution does not mutate shared card content")
	_assert_true(not original.has("applied_upgrade_branch"), "shared card definition remains free of campaign runtime state")


func _test_research_save_round_trip() -> void:
	var controller = _funded_controller("campaign.research-save")
	controller.unlock_public_card({"action_id": "research:save:unlock", "card_id": "card.public.general.assault"})
	controller.upgrade_public_card({"action_id": "research:save:upgrade", "card_id": "card.public.general.assault", "branch_id": "break_momentum"})
	var envelope: Dictionary = SaveEnvelopeScript.create_empty("campaign.research-save", "2026-09-01T00:00:00Z")
	envelope.campaign = controller.snapshot()
	var codec = SaveGameCodecScript.new()
	var encoded: Dictionary = codec.encode(envelope)
	_assert_true(encoded.ok, "research CampaignState encodes through Save V1")
	var decoded: Dictionary = codec.decode(encoded.text)
	_assert_true(decoded.ok, "research CampaignState decodes through Save V1")
	var restored: Dictionary = CampaignStateScript.normalize(decoded.value.campaign)
	_assert_true(CampaignStateScript.validate(restored).is_empty(), "restored research CampaignState remains valid")
	_assert_equal(restored.unlocked_public_cards, ["card.public.general.assault"], "save round-trip preserves public card unlock")
	_assert_equal(restored.card_upgrade_branches["card.public.general.assault"], "break_momentum", "save round-trip preserves the irreversible branch")
	_assert_equal(restored.research.applied_action_ids.size(), 2, "save round-trip preserves research idempotency ledger")


func _funded_controller(campaign_id: String, with_fragment: bool = true):
	var state: Dictionary = CampaignStateScript.create(campaign_id)
	state.resources.silver = 1000
	state.resources.military_knowledge = 1000
	if with_fragment:
		state.special_resources["resource.cavalry_fragment"] = 2
	var controller = CampaignControllerScript.new()
	_assert_true(controller.setup(state).is_empty(), "%s controller setup succeeds" % campaign_id)
	_assert_true(controller.configure_research(_economy, _cards).is_empty(), "%s research catalog setup succeeds" % campaign_id)
	return controller


func _load_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}


func _assert_error_contains(errors: PackedStringArray, fragment: String, label: String) -> void:
	var found := false
	for error in errors:
		if fragment in error:
			found = true
			break
	_assert_true(found, label)


func _assert_true(condition: bool, label: String) -> void:
	if condition:
		_passed += 1
		print("TEST PASS: %s" % label)
	else:
		_failed += 1
		push_error("TEST FAIL: %s" % label)


func _assert_equal(actual, expected, label: String) -> void:
	_assert_true(actual == expected, "%s (expected=%s actual=%s)" % [label, expected, actual])
