extends Control
class_name GameShell

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")
const GameFlowCoordinatorScript := preload("res://src/application/game_flow_coordinator.gd")
const SaveFileStoreScript := preload("res://src/infrastructure/persistence/save_file_store.gd")
const CombatScene := preload("res://src/ui/combat/combat_screen.tscn")
const ExpeditionMapCanvasScript := preload("res://src/ui/game/expedition_map_canvas.gd")
const Tokens := preload("res://src/ui/theme/visual_tokens.gd")
const QingluThemeScript := preload("res://src/ui/theme/qinglu_theme.gd")
const CardViewScript := preload("res://src/ui/components/card_view.gd")
const GeneralCardViewScript := preload("res://src/ui/components/general_card_view.gd")
const MotionPolicyScript := preload("res://src/ui/presentation/motion_policy.gd")

const BRONZE := Tokens.LIGHT_GOLD_DARK
const PARCHMENT := Tokens.DEEP_TEAL
const INK := Tokens.INK
const MUTED := Tokens.INK_SOFT
const DANGER := Tokens.CINNABAR
const SUCCESS := Tokens.SUCCESS
const GENERAL_IDS := ["general.zhao_lie", "general.zhou_jing", "general.han_yue"]

var save_root_override := ""
var campaign_id_override := ""
var map_seed_override := -1

var _registry
var _flow
var _save_store
var _selected_general_id := GENERAL_IDS[0]
var _selected_expedition_id := ""
var _deployment_counts: Dictionary = {}
var _loadout_draft: Array = []
var _selected_loadout_card_id := ""
var _notice := ""
var _action_sequence := 0

@onready var stage_host: MarginContainer = %StageHost
@onready var phase_label: Label = %PhaseLabel
@onready var save_status: Label = %SaveStatus


func _ready() -> void:
	theme = QingluThemeScript.create()
	_apply_shell_style()
	var errors := _setup_flow()
	if not errors.is_empty():
		_render_fatal("初始化失败：%s" % "；".join(errors))
		return
	_render_welcome()


func start_new_campaign() -> Dictionary:
	var campaign_id := campaign_id_override
	if campaign_id.is_empty():
		campaign_id = "campaign.%d" % int(Time.get_unix_time_from_system())
	var result: Dictionary = _flow.new_campaign(campaign_id, _timestamp())
	if result.ok:
		_notice = "新军已立，河源、石门与临泽三路军报已送达。"
		_render_current_phase()
	else:
		_notice = _result_error(result)
		_render_welcome()
	return result


func continue_campaign() -> Dictionary:
	var result: Dictionary = _flow.load_campaign(_autosave_path())
	if result.ok:
		_notice = "已从%s恢复战役。" % ("最近备份" if result.recovered else "自动存档")
		_render_current_phase()
	else:
		_notice = _result_error(result)
		_render_welcome()
	return result


func load_manual(slot_number: int = 1) -> Dictionary:
	var result: Dictionary = _flow.load_campaign(_manual_path(slot_number))
	if result.ok:
		_notice = "已载入手动槽%d。" % slot_number
		_render_current_phase()
	else:
		_notice = _result_error(result)
		_render_welcome()
	return result


func flow_snapshot() -> Dictionary:
	return _flow.snapshot() if _flow != null else {}


func current_phase() -> String:
	return _flow.phase() if _flow != null else "uninitialized"


func open_deployment() -> void:
	if current_phase() != "main_city":
		return
	_deployment_counts = {}
	_render_target_selection()


func open_deck_editor() -> void:
	if current_phase() != "main_city":
		return
	var editor: Dictionary = _flow.loadout_editor_snapshot()
	if not editor.ok:
		_notice = _result_error(editor)
		_render_main_city()
		return
	_loadout_draft = editor.base_deck.duplicate()
	_selected_loadout_card_id = String(editor.public_cards[0].id) if not editor.public_cards.is_empty() else ""
	_notice = ""
	_render_deck_editor()


func start_selected_expedition() -> Dictionary:
	var request := {
		"run_id": "run.%d.%d" % [int(Time.get_unix_time_from_system()), _action_sequence],
		"expedition_id": _selected_expedition_id,
		"general_id": _selected_general_id,
		"map_seed": map_seed_override if map_seed_override >= 0 else int(Time.get_unix_time_from_system()) & 0x7fffffff,
	}
	if not _deployment_counts.is_empty():
		request.army_counts = _deployment_counts.duplicate(true)
	var result: Dictionary = _flow.start_expedition(request, _timestamp())
	if result.ok:
		_notice = "%s率军出征。" % _general_name(_selected_general_id)
		_render_current_phase()
	else:
		_notice = _result_error(result)
		_render_deployment()
	return result


func select_map_node(node_id: String) -> Dictionary:
	var result: Dictionary = _flow.advance_to_node(node_id, _timestamp())
	if result.ok:
		_notice = _resolution_notice(result.get("resolution", {}))
		_render_current_phase()
	else:
		_notice = _result_error(result)
		_render_map()
	return result


func confirm_settlement() -> Dictionary:
	var outcome: String = String(_flow.snapshot().get("expedition", {}).get("status", ""))
	var result: Dictionary = _flow.finalize_expedition(_timestamp())
	if result.ok:
		_notice = "目标已纳入义军版图。" if outcome == "awaiting_settlement" else "远征已经收束，伤亡与损失已登记。"
		_render_current_phase()
	else:
		_notice = _result_error(result)
		_render_settlement()
	return result


func _setup_flow() -> PackedStringArray:
	_registry = ContentRegistryScript.new()
	if not _registry.load_all():
		return _registry.get_errors()
	_save_store = SaveFileStoreScript.new()
	_flow = GameFlowCoordinatorScript.new()
	return _flow.setup(_registry, {
		"bootstrap": _load_json("res://data/config/prototype_campaign_bootstrap.json"),
		"deployment_rules": _load_json("res://data/config/prototype_deployment_rules.json"),
		"encounters": _load_json("res://data/config/prototype_rogue_expeditions.json"),
		"legacy_encounters": _load_json("res://data/config/prototype_heyuan_encounters.json"),
		"army_economy": _load_json("res://data/config/prototype_army_economy.json"),
		"research_economy": _load_json("res://data/config/prototype_research_economy.json"),
		"general_progression": _load_json("res://data/config/prototype_general_progression.json"),
		"faction_cycle": _load_json("res://data/config/prototype_faction_cycle.json"),
	}, _save_store, _save_root())


func _render_current_phase() -> void:
	match current_phase():
		"main_city":
			if _requires_legacy_loadout_recovery():
				_render_legacy_recovery()
			else:
				_render_main_city()
		"expedition_map":
			_render_map()
		"encounter_choice", "reward_choice":
			_render_encounter()
		"combat_checkpoint":
			_render_combat()
		"combat_report":
			_render_combat_report()
		"settlement_pending":
			_render_settlement()
		"game_over":
			_render_game_over()
		_:
			_render_welcome()


func _render_welcome() -> void:
	phase_label.text = "烽火初燃"
	save_status.text = "选择战役"
	var page := VBoxContainer.new()
	page.name = "WelcomeStage"
	page.alignment = BoxContainer.ALIGNMENT_CENTER
	page.add_theme_constant_override("separation", 18)
	var eyebrow := _label("VERTICAL SLICE · 三路远征", 15, BRONZE)
	eyebrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	page.add_child(eyebrow)
	var title := _label("山河将倾，举旗此刻", 50, PARCHMENT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	page.add_child(title)
	var copy := _label("整军、择将、定路线。在河源、石门与临泽之间选择下一处目标。", 19, MUTED)
	copy.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	page.add_child(copy)
	page.add_child(_spacer(0, 20))
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 14)
	var new_button := _button("建立新军", true, Vector2(190, 52))
	new_button.name = "NewCampaignButton"
	new_button.unique_name_in_owner = true
	new_button.pressed.connect(start_new_campaign)
	actions.add_child(new_button)
	var continue_button := _button("继续战役", false, Vector2(190, 52))
	continue_button.name = "ContinueButton"
	continue_button.unique_name_in_owner = true
	continue_button.disabled = not _autosave_exists()
	continue_button.pressed.connect(continue_campaign)
	actions.add_child(continue_button)
	page.add_child(actions)
	var manual_actions := HBoxContainer.new()
	manual_actions.alignment = BoxContainer.ALIGNMENT_CENTER
	manual_actions.add_theme_constant_override("separation", 10)
	for slot_number in range(1, 4):
		if not _manual_exists(slot_number):
			continue
		var manual_button := _button("载入手动槽%d" % slot_number, false, Vector2(150, 40))
		manual_button.name = "ManualLoad%dButton" % slot_number
		manual_button.pressed.connect(load_manual.bind(slot_number))
		manual_actions.add_child(manual_button)
	if manual_actions.get_child_count() > 0:
		page.add_child(manual_actions)
	else:
		manual_actions.free()
	if not _notice.is_empty():
		var notice := _label(_notice, 15, DANGER)
		notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		page.add_child(notice)
	_set_stage(page)


func _render_main_city() -> void:
	var snapshot: Dictionary = _flow.snapshot()
	var campaign: Dictionary = snapshot.campaign
	phase_label.text = "义军大营  /  长期整备"
	save_status.text = "周期 %d · 自动档有效" % int(campaign.cycle)
	var page := VBoxContainer.new()
	page.name = "MainCityStage"
	page.add_theme_constant_override("separation", 16)
	var heading := HBoxContainer.new()
	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_box.add_child(_label(_city_title(campaign.main_city_stage), 38, PARCHMENT))
	title_box.add_child(_label("所有长期成长都在此结算；出征中的规则不会在界面层重算。", 15, MUTED))
	heading.add_child(title_box)
	var expedition_button := _button("出征整备  →", true, Vector2(190, 50))
	expedition_button.name = "OpenDeploymentButton"
	expedition_button.unique_name_in_owner = true
	expedition_button.pressed.connect(open_deployment)
	var target_state: Dictionary = _flow.available_expeditions()
	expedition_button.disabled = bool(target_state.get("all_captured", false))
	if expedition_button.disabled:
		expedition_button.text = "三地平定"
	heading.add_child(expedition_button)
	page.add_child(heading)
	page.add_child(_resource_strip(campaign))
	var rebellion: Dictionary = campaign.get("rebellion_state", {})
	var rebellion_text := "叛乱值 %d / 100" % int(rebellion.get("value", 0))
	if bool(rebellion.get("suppression_forecast", false)):
		rebellion_text += "  ·  朝廷正在筹备围剿"
	var rebellion_label := _label(rebellion_text, 15, DANGER if bool(rebellion.get("suppression_forecast", false)) else BRONZE)
	rebellion_label.name = "RebellionStatusLabel"
	page.add_child(rebellion_label)
	var popular_support: Dictionary = campaign.get("popular_support_state", {})
	var support_label := _label("义军民望 %d / 100" % int(popular_support.get("value", 20)), 15, BRONZE)
	support_label.name = "PopularSupportStatusLabel"
	page.add_child(support_label)
	var territory_summary := _label(_territory_summary(campaign), 14, MUTED)
	territory_summary.name = "TerritorySummary"
	page.add_child(territory_summary)
	page.add_child(HSeparator.new())
	var workspace := HBoxContainer.new()
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.add_theme_constant_override("separation", 22)
	workspace.add_child(_paper_panel(_general_roster(campaign)))
	workspace.add_child(_paper_panel(_general_detail(campaign), true))
	workspace.add_child(_paper_panel(_growth_actions(campaign)))
	page.add_child(workspace)
	if not _notice.is_empty():
		page.add_child(_notice_label())
	_set_stage(page)


func _render_legacy_recovery() -> void:
	phase_label.text = "旧档整备恢复"
	save_status.text = "旧档迁移 · 需要玩家确认"
	var page := VBoxContainer.new()
	page.name = "LegacyRecoveryStage"
	page.alignment = BoxContainer.ALIGNMENT_CENTER
	page.add_theme_constant_override("separation", 18)
	var eyebrow := _label("旧开发档缺少长期牌组", 15, BRONZE)
	eyebrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	page.add_child(eyebrow)
	var title := _label("恢复通用基础军令", 42, PARCHMENT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	page.add_child(title)
	var detail := _label("此操作会授予当前15种原型初始公共卡，\n并建立每种各1张的共用基础牌组。旧的三套武将牌组仅保留为审计记录。\n不会修改原档的内容版本、资源或武将成长。", 18, MUTED)
	detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	page.add_child(detail)
	var audit := _label("恢复会写入审计流水，并保存到手动槽1；原自动档保持不变。", 14, SUCCESS)
	audit.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	page.add_child(audit)
	var recover := _button("确认恢复并进入主城", true, Vector2(280, 52))
	recover.name = "RecoverLegacyLoadoutsButton"
	recover.unique_name_in_owner = true
	recover.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	recover.pressed.connect(_recover_legacy_base_loadout)
	page.add_child(recover)
	var back := _button("返回起始页", false, Vector2(180, 42))
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back.pressed.connect(_render_welcome)
	page.add_child(back)
	if not _notice.is_empty():
		var notice := _notice_label()
		notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		page.add_child(notice)
	_set_stage(page)


func _general_roster(campaign: Dictionary) -> Control:
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(250, 0)
	column.add_theme_constant_override("separation", 9)
	column.add_child(_section_title("武将"))
	for general in campaign.generals:
		if not general is Dictionary or bool(general.get("is_player_character", false)):
			continue
		var button = GeneralCardViewScript.new()
		button.configure(general, {
			"selected": general.general_id == _selected_general_id,
			"available": general.get("status", "") != "deceased",
		}, GeneralCardViewScript.Density.COMPACT)
		button.pressed.connect(_select_general.bind(String(general.general_id)))
		column.add_child(button)
	return column


func _general_detail(campaign: Dictionary) -> Control:
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 12)
	var general := _campaign_general(campaign, _selected_general_id)
	if general.is_empty():
		_selected_general_id = GENERAL_IDS[0]
		general = _campaign_general(campaign, _selected_general_id)
	column.add_child(_section_title("武将概况"))
	column.add_child(_label("%s  ·  Lv.%d" % [general.name, int(general.level)], 27, PARCHMENT))
	column.add_child(_label("武勇 %d    统率 %d    政务 %d" % [int(general.attributes.martial), int(general.attributes.leadership), int(general.attributes.administration)], 17, MUTED))
	var injury := "健康" if general.get("injury", {}).get("status", "healthy") == "healthy" else "重伤 · 需随势力周期恢复"
	column.add_child(_label("状态：%s    经验：%d" % [injury, int(general.experience)], 15, SUCCESS if injury == "健康" else DANGER))
	column.add_child(HSeparator.new())
	var deck: Array = campaign.get("base_loadout", [])
	column.add_child(_label("军议堂 · 共用基础牌组  %d / 15–25" % deck.size(), 20, BRONZE))
	var summary := _label(_deck_summary(deck), 15, MUTED)
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(summary)
	var editor_button := _button("进入军议堂  →", false, Vector2(0, 42))
	editor_button.name = "OpenDeckEditorButton"
	editor_button.unique_name_in_owner = true
	editor_button.pressed.connect(open_deck_editor)
	column.add_child(editor_button)
	return column


func _render_deck_editor() -> void:
	phase_label.text = "义军大营  /  军议堂"
	save_status.text = "基础牌组草稿 · 尚未写入存档"
	var editor: Dictionary = _flow.loadout_editor_snapshot()
	if not editor.ok:
		_notice = _result_error(editor)
		_render_main_city()
		return
	var page := VBoxContainer.new()
	page.name = "DeckEditorStage"
	page.add_theme_constant_override("separation", 12)
	var heading := HBoxContainer.new()
	var heading_copy := VBoxContainer.new()
	heading_copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading_copy.add_child(_label("军议堂", 36, PARCHMENT))
	heading_copy.add_child(_label("编排势力共用公共牌；出征时会自动追加所选武将的全部专属牌。", 15, MUTED))
	heading.add_child(heading_copy)
	var valid := _loadout_draft.size() >= int(editor.minimum_size) and _loadout_draft.size() <= int(editor.maximum_size)
	var count_text := "%d / %d–%d  ·  %s" % [_loadout_draft.size(), int(editor.minimum_size), int(editor.maximum_size), "军令合法" if valid else "还需%d张" % (int(editor.minimum_size) - _loadout_draft.size())]
	var count_label := _label(count_text, 18, SUCCESS if valid else DANGER)
	count_label.name = "BaseDeckCountLabel"
	count_label.unique_name_in_owner = true
	count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	heading.add_child(count_label)
	page.add_child(heading)
	page.add_child(HSeparator.new())

	var workspace := HBoxContainer.new()
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.add_theme_constant_override("separation", 20)
	workspace.add_child(_base_deck_column(editor))
	workspace.add_child(VSeparator.new())
	workspace.add_child(_public_library_column(editor))
	workspace.add_child(VSeparator.new())
	workspace.add_child(_paper_panel(_deployment_preview_column(editor), true))
	page.add_child(workspace)

	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	actions.add_theme_constant_override("separation", 12)
	var back := _button("放弃草稿，返回主城", false, Vector2(210, 46))
	back.name = "DeckEditorBackButton"
	back.pressed.connect(_cancel_base_loadout_edit)
	actions.add_child(back)
	var confirm := _button("确认编入基础军令", true, Vector2(240, 46))
	confirm.name = "ConfirmBaseLoadoutButton"
	confirm.unique_name_in_owner = true
	confirm.disabled = not valid
	confirm.pressed.connect(_confirm_base_loadout)
	actions.add_child(confirm)
	page.add_child(actions)
	if not _notice.is_empty():
		page.add_child(_notice_label())
	_set_stage(page)


func _base_deck_column(editor: Dictionary) -> Control:
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(390, 0)
	column.add_theme_constant_override("separation", 8)
	column.add_child(_section_title("当前基础牌组"))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 6)
	for card in editor.public_cards:
		var count := _loadout_draft.count(card.id)
		if count <= 0:
			continue
		var row := HBoxContainer.new()
		var select = CardViewScript.new()
		select.configure(card, {
			"available": true,
			"selected": card.id == _selected_loadout_card_id,
			"count": count,
			"copy_limit": card.copy_limit,
		}, 0, CardViewScript.Density.COMPACT)
		select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		select.pressed.connect(_select_loadout_card.bind(String(card.id)))
		row.add_child(select)
		var remove := _button("−", false, Vector2(44, 38))
		remove.name = "DeckRemoveButton_%s" % _node_safe_id(String(card.id))
		remove.pressed.connect(_remove_loadout_card.bind(String(card.id)))
		row.add_child(remove)
		rows.add_child(row)
	scroll.add_child(rows)
	column.add_child(scroll)
	return column


func _public_library_column(editor: Dictionary) -> Control:
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(440, 0)
	column.add_theme_constant_override("separation", 8)
	column.add_child(_section_title("势力公共牌库"))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 6)
	for card in editor.public_cards:
		var row := HBoxContainer.new()
		var current_count := _loadout_draft.count(card.id)
		var select = CardViewScript.new()
		select.configure(card, {
			"available": bool(card.unlocked),
			"selected": card.id == _selected_loadout_card_id,
			"locked": not bool(card.unlocked),
			"reason": "军学未解锁" if not bool(card.unlocked) else "",
			"count": current_count,
			"copy_limit": card.copy_limit,
		}, 0, CardViewScript.Density.COMPACT)
		select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		select.pressed.connect(_select_loadout_card.bind(String(card.id)))
		row.add_child(select)
		var add := _button("+", false, Vector2(44, 38))
		add.name = "DeckAddButton_%s" % _node_safe_id(String(card.id))
		add.disabled = not bool(card.unlocked) or current_count >= int(card.copy_limit) or _loadout_draft.size() >= int(editor.maximum_size)
		add.pressed.connect(_add_loadout_card.bind(String(card.id)))
		row.add_child(add)
		rows.add_child(row)
	scroll.add_child(rows)
	column.add_child(scroll)
	return column


func _deployment_preview_column(editor: Dictionary) -> Control:
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 10)
	column.add_child(_section_title("率将后合成预览"))
	var selected: Dictionary = {}
	for card in editor.public_cards:
		if card.id == _selected_loadout_card_id:
			selected = card
			break
	if not selected.is_empty():
		var selected_card = CardViewScript.new()
		selected_card.configure(selected, {
			"available": bool(selected.unlocked),
			"locked": not bool(selected.unlocked),
			"upgraded": not String(selected.upgrade_branch).is_empty(),
		}, 0, CardViewScript.Density.FULL)
		selected_card.disabled = true
		selected_card.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		column.add_child(selected_card)
	column.add_child(HSeparator.new())
	for preview in editor.general_previews:
		var unavailable: bool = preview.status == "deceased" or preview.injury_status != "healthy"
		var exclusive_names: Array[String] = []
		for card_id in preview.exclusive_cards:
			exclusive_names.append(String(_registry.get_card(String(card_id)).get("name", card_id)))
		var special_text := "、".join(exclusive_names) if not exclusive_names.is_empty() else "无"
		var label := _label("%s  ·  %d + %d = %d张\n专属：%s%s" % [preview.name, _loadout_draft.size(), preview.exclusive_cards.size(), _loadout_draft.size() + preview.exclusive_cards.size(), special_text, "  ·  不可出征" if unavailable else ""], 15, DANGER if unavailable else PARCHMENT)
		label.name = "DeckPreview_%s" % _node_safe_id(String(preview.general_id))
		column.add_child(label)
	return column


func _growth_actions(campaign: Dictionary) -> Control:
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(390, 0)
	column.add_theme_constant_override("separation", 10)
	column.add_child(_section_title("整军与军学"))
	var army_names := {"infantry": "步兵", "archer": "弓兵", "cavalry": "骑兵"}
	for army_type in ["infantry", "archer", "cavalry"]:
		var row := HBoxContainer.new()
		var label := _label("%s  %d" % [army_names[army_type], int(campaign.army_inventory[army_type])], 16, PARCHMENT)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var button := _button("补充 100", false, Vector2(112, 38))
		button.pressed.connect(_replenish.bind(army_type))
		row.add_child(button)
		column.add_child(row)
	column.add_child(HSeparator.new())
	var pursue_unlocked: bool = campaign.unlocked_public_cards.has("card.public.cavalry.pursue")
	var research_button := _button("【追亡逐北】已解锁" if pursue_unlocked else "解锁【追亡逐北】", false, Vector2(0, 42))
	research_button.name = "UnlockPursueButton"
	research_button.unique_name_in_owner = true
	research_button.disabled = pursue_unlocked
	research_button.pressed.connect(_unlock_pursue)
	column.add_child(research_button)
	var upgraded: bool = campaign.card_upgrade_branches.has("card.public.general.assault")
	var upgrade_button := _button("【突击】已永久升级" if upgraded else "升级【突击】·破势", false, Vector2(0, 42))
	upgrade_button.name = "UpgradeAssaultButton"
	upgrade_button.unique_name_in_owner = true
	upgrade_button.disabled = upgraded
	upgrade_button.pressed.connect(_upgrade_assault)
	column.add_child(upgrade_button)
	var save_button := _button("保存当前整备", false, Vector2(0, 42))
	save_button.name = "ManualSaveButton"
	save_button.unique_name_in_owner = true
	save_button.pressed.connect(_manual_save)
	column.add_child(save_button)
	return column


func _render_target_selection() -> void:
	phase_label.text = "义军大营  /  选择远征目标"
	save_status.text = "目标确认前不会离营"
	var result: Dictionary = _flow.available_expeditions()
	var page := VBoxContainer.new()
	page.name = "ExpeditionTargetStage"
	page.add_theme_constant_override("separation", 15)
	page.add_child(_label("三路军报", 38, PARCHMENT))
	page.add_child(_label("选择一处尚未控制的目标。地图、遭遇与奖励将在出征时由 Seed 冻结。", 16, MUTED))
	var rebellion: Dictionary = result.get("rebellion", {})
	var warning := "当前叛乱值 %d / 100" % int(rebellion.get("value", 0))
	if bool(rebellion.get("suppression_forecast", false)):
		warning += "  ·  朝廷正在筹备围剿（本批仅预告）"
	page.add_child(_label(warning, 15, DANGER if bool(rebellion.get("suppression_forecast", false)) else BRONZE))
	page.add_child(_label("义军民望 %d / 100" % int(result.get("popular_support", {}).get("value", 20)), 15, BRONZE))
	page.add_child(HSeparator.new())
	var targets := HBoxContainer.new()
	targets.size_flags_vertical = Control.SIZE_EXPAND_FILL
	targets.add_theme_constant_override("separation", 18)
	for target in result.get("targets", []):
		var column := VBoxContainer.new()
		column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		column.add_theme_constant_override("separation", 10)
		column.add_child(_label(String(target.destination_name), 28, PARCHMENT))
		column.add_child(_label(String(target.theme), 17, BRONZE))
		var boss: Dictionary = _registry.get_enemy(String(target.boss_enemy_id))
		var detail := _label("首领：%s\n主要收益：%s\n路线：9层随机分支 · 约5–7战" % [boss.get("name", "未知"), target.reward_summary], 15, MUTED)
		detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		column.add_child(detail)
		var button := _button("已控制" if target.captured else "选择此地  →", not target.captured, Vector2(0, 52))
		button.name = "TargetButton_%s" % _node_safe_id(String(target.expedition_id))
		button.disabled = bool(target.captured)
		button.pressed.connect(_select_expedition_target.bind(String(target.expedition_id)))
		column.add_child(button)
		targets.add_child(column)
	page.add_child(targets)
	var back := _button("返回主城", false, Vector2(160, 44))
	back.name = "TargetSelectionBackButton"
	back.size_flags_horizontal = Control.SIZE_SHRINK_END
	back.pressed.connect(_render_main_city)
	page.add_child(back)
	_set_stage(page)


func _render_deployment() -> void:
	phase_label.text = "义军大营  /  出征整备"
	save_status.text = "尚未离营"
	var campaign: Dictionary = _flow.snapshot().campaign
	var page := VBoxContainer.new()
	page.name = "DeploymentStage"
	page.add_theme_constant_override("separation", 16)
	var expedition_definition: Dictionary = _registry.get_expedition(_selected_expedition_id)
	page.add_child(_label(String(expedition_definition.get("name", "出征整备")), 38, PARCHMENT))
	page.add_child(_label("选择率军武将，冻结兵种、属性与“共用基础牌 + 武将专属牌”。", 16, MUTED))
	page.add_child(HSeparator.new())
	var selector_row := HBoxContainer.new()
	selector_row.add_theme_constant_override("separation", 16)
	selector_row.add_child(_label("率军武将", 18, BRONZE))
	var selector := OptionButton.new()
	selector.name = "DeploymentGeneralSelector"
	selector.unique_name_in_owner = true
	selector.custom_minimum_size = Vector2(320, 44)
	for general_id in GENERAL_IDS:
		var general := _campaign_general(campaign, general_id)
		selector.add_item("%s · Lv.%d" % [general.name, int(general.level)])
		selector.set_item_metadata(selector.item_count - 1, general_id)
		if general_id == _selected_general_id:
			selector.select(selector.item_count - 1)
	selector.item_selected.connect(_deployment_general_changed.bind(selector))
	selector_row.add_child(selector)
	page.add_child(selector_row)
	var readiness: Dictionary = _flow.expedition_readiness({"expedition_id": _selected_expedition_id, "general_id": _selected_general_id})
	if readiness.ok and _deployment_counts.is_empty():
		_deployment_counts = readiness.army_counts.duplicate(true)
	if not _deployment_counts.is_empty():
		readiness = _flow.expedition_readiness({"expedition_id": _selected_expedition_id, "general_id": _selected_general_id, "army_counts": _deployment_counts})
	var workspace := HBoxContainer.new()
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.add_theme_constant_override("separation", 30)
	var army_column := VBoxContainer.new()
	army_column.custom_minimum_size = Vector2(520, 0)
	army_column.add_theme_constant_override("separation", 12)
	army_column.add_child(_section_title("兵种配置"))
	var army_names := {"infantry": "步兵", "archer": "弓兵", "cavalry": "骑兵"}
	for army_type in ["infantry", "archer", "cavalry"]:
		var row := HBoxContainer.new()
		var label := _label("%s  /  库存 %d" % [army_names[army_type], int(campaign.army_inventory[army_type])], 17, PARCHMENT)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var spin := SpinBox.new()
		spin.name = "Army_%s" % army_type.capitalize()
		spin.custom_minimum_size = Vector2(160, 42)
		spin.min_value = 0
		spin.max_value = int(campaign.army_inventory[army_type])
		spin.step = 1
		spin.value = int(_deployment_counts.get(army_type, 0))
		spin.value_changed.connect(_army_count_changed.bind(army_type))
		row.add_child(spin)
		army_column.add_child(row)
	var total_label := _label("合计 %d / 带兵上限 %d" % [_army_total(), int(readiness.get("troop_cap", 0))], 17, BRONZE)
	total_label.name = "DeploymentTotalLabel"
	army_column.add_child(total_label)
	workspace.add_child(_paper_panel(army_column))
	var deck_column := VBoxContainer.new()
	deck_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	deck_column.add_theme_constant_override("separation", 12)
	deck_column.add_child(_section_title("冻结内容"))
	deck_column.add_child(_label("%s" % _general_name(_selected_general_id), 26, PARCHMENT))
	var base_deck: Array = readiness.get("base_deck", campaign.get("base_loadout", []))
	var exclusive_cards: Array = readiness.get("exclusive_cards", [])
	var final_deck: Array = readiness.get("deck", [])
	var deck_breakdown := _label("基础牌 %d张  +  专属牌 %d张  =  出战牌组 %d张\n%s\n专属：%s" % [base_deck.size(), exclusive_cards.size(), final_deck.size(), _deck_summary(base_deck), _deck_summary(exclusive_cards) if not exclusive_cards.is_empty() else "无"], 16, MUTED)
	deck_breakdown.name = "DeploymentDeckBreakdown"
	deck_breakdown.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	deck_column.add_child(deck_breakdown)
	deck_column.add_child(_label("地图 Seed：%d" % (map_seed_override if map_seed_override >= 0 else int(Time.get_unix_time_from_system()) & 0x7fffffff), 14, MUTED))
	workspace.add_child(_paper_panel(deck_column, true))
	page.add_child(workspace)
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	actions.add_theme_constant_override("separation", 12)
	var back := _button("返回主城", false, Vector2(150, 48))
	back.name = "DeploymentBackButton"
	back.pressed.connect(_render_target_selection)
	actions.add_child(back)
	var start := _button("确认军令，开始远征", true, Vector2(240, 48))
	start.name = "StartExpeditionButton"
	start.unique_name_in_owner = true
	start.disabled = not readiness.ok
	start.pressed.connect(start_selected_expedition)
	actions.add_child(start)
	page.add_child(actions)
	if not _notice.is_empty():
		page.add_child(_notice_label())
	_set_stage(page)


func _render_map() -> void:
	var expedition: Dictionary = _flow.expedition_run_snapshot()
	phase_label.text = "%s  /  行军图" % expedition.expedition_name
	save_status.text = "SEED %d · 节点后自动保存" % int(expedition.seed)
	var page := VBoxContainer.new()
	page.name = "ExpeditionMapStage"
	page.add_theme_constant_override("separation", 10)
	var heading := HBoxContainer.new()
	var title := _label("%s行军图" % expedition.destination_name, 34, PARCHMENT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(title)
	heading.add_child(_label("%s  ·  兵力 %d  ·  士气 %d" % [expedition.general.name, int(expedition.general.troops), int(expedition.general.morale)], 16, MUTED))
	page.add_child(heading)
	page.add_child(_label("战利品袋：%s  ·  临时牌 +%d  ·  民望 %d（本次 %+d）  ·  本次叛乱 %+d" % [_loot_text(expedition.unbanked_loot), expedition.temporary_cards.size(), int(expedition.projected_popular_support), int(expedition.pending_popular_support_delta), int(expedition.pending_rebellion_delta)], 15, BRONZE))
	page.add_child(_label("全图显示节点类别；抵达或使用斥候令牌后可查看具体事件与敌军。", 13, MUTED))
	page.add_child(_label("图例：战=普通战  锐=精英  事=事件  商=商人  补=补给  物=物品  策=卡牌  城=决战", 13, MUTED))
	page.add_child(_temporary_item_bar(expedition))
	var canvas = ExpeditionMapCanvasScript.new()
	canvas.name = "RouteMap"
	canvas.unique_name_in_owner = true
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas.node_selected.connect(select_map_node)
	page.add_child(canvas)
	canvas.configure(expedition.visible_nodes, expedition.map_edges, expedition.route)
	if not _notice.is_empty():
		page.add_child(_notice_label())
	_set_stage(page)


func _render_encounter() -> void:
	var expedition: Dictionary = _flow.expedition_run_snapshot()
	var encounter: Dictionary = _flow.pending_encounter()
	phase_label.text = "%s  /  %s" % [expedition.destination_name, "军略选择" if encounter.get("kind", "") == "reward" else "途中遭遇"]
	save_status.text = "选择内容已冻结并自动保存"
	var page := VBoxContainer.new()
	page.name = "ExpeditionEncounterStage"
	page.alignment = BoxContainer.ALIGNMENT_CENTER
	page.add_theme_constant_override("separation", 14)
	page.add_child(_label(String(encounter.get("title", "途中遭遇")), 40, PARCHMENT))
	var description := _label(String(encounter.get("description", "")), 17, MUTED)
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(description)
	page.add_child(_label("兵力 %d  ·  士气 %d  ·  民望 %d（本次 %+d）  ·  战利品 %s" % [int(expedition.general.troops), int(expedition.general.morale), int(expedition.projected_popular_support), int(expedition.pending_popular_support_delta), _loot_text(expedition.unbanked_loot)], 15, BRONZE))
	page.add_child(_temporary_item_bar(expedition))
	page.add_child(HSeparator.new())
	for choice in encounter.get("choices", []):
		var label_text := String(choice.get("label", "选择"))
		if not String(choice.get("card_name", "")).is_empty():
			label_text += " · %s" % choice.card_name
		var button := _button(label_text, bool(choice.get("available", false)), Vector2(0, 48))
		button.name = "EncounterChoice_%s" % _node_safe_id(String(choice.choice_id))
		button.disabled = not bool(choice.get("available", false))
		button.tooltip_text = String(choice.get("unavailable_reason", choice.get("description", ""))) if button.disabled else String(choice.get("card_description", choice.get("description", "")))
		button.pressed.connect(_submit_encounter_choice.bind(String(choice.choice_id)))
		page.add_child(button)
		if encounter.get("kind", "") == "event":
			var known_outcomes := String(choice.get("description", ""))
			if button.disabled and not String(choice.get("unavailable_reason", "")).is_empty():
				known_outcomes += "（不可选：%s）" % choice.unavailable_reason
			var detail := _label("风险范围：%s" % known_outcomes if bool(choice.get("risk", false)) else known_outcomes, 13, MUTED)
			detail.name = "EncounterChoiceDetail_%s" % _node_safe_id(String(choice.choice_id))
			detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			page.add_child(detail)
	if not _notice.is_empty(): page.add_child(_notice_label())
	_set_stage(page)


func _render_combat() -> void:
	var expedition: Dictionary = _flow.expedition_run_snapshot()
	phase_label.text = "%s  /  遭遇战" % expedition.destination_name
	save_status.text = "战斗检查点已保存"
	var screen = CombatScene.instantiate()
	screen.name = "IntegratedCombat"
	screen.integrated_mode = true
	screen.battle_request_override = _flow.pending_combat_request()
	screen.battle_finished.connect(_on_battle_finished)
	_set_stage(screen, true)


func _on_battle_finished(result: Dictionary) -> void:
	var submitted: Dictionary = _flow.submit_combat_result(result, _timestamp())
	_notice = _battle_result_notice(result) if submitted.ok else _result_error(submitted)
	_render_current_phase()


func _render_combat_report() -> void:
	var expedition: Dictionary = _flow.expedition_run_snapshot()
	var report: Dictionary = _flow.pending_combat_report()
	phase_label.text = "%s  /  战后捷报" % expedition.destination_name
	save_status.text = "战果与历练已自动保存"
	var page := VBoxContainer.new()
	page.name = "CombatReportStage"
	page.add_theme_constant_override("separation", 14)
	var heading := HBoxContainer.new()
	var heading_copy := VBoxContainer.new()
	heading_copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title := _label("克城大捷" if bool(report.get("expedition_terminal", false)) else "破敌", 46, DANGER)
	title.name = "CombatReportTitle"
	heading_copy.add_child(title)
	heading_copy.add_child(_label("击破%s · 第%d场胜利" % [report.get("enemy_name", "敌军"), int(report.get("completed_battles", 0))], 19, PARCHMENT))
	heading.add_child(heading_copy)
	var seal := _label("捷\n报", 28, Tokens.PAPER_BRIGHT)
	seal.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	seal.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	seal.custom_minimum_size = Vector2(84, 84)
	var seal_panel := PanelContainer.new()
	var seal_style := Tokens.panel_style(DANGER, Tokens.with_alpha(Tokens.CINNABAR.darkened(0.28), 0.9), 42, 3, 8)
	seal_panel.add_theme_stylebox_override("panel", seal_style)
	seal_panel.add_child(seal)
	heading.add_child(seal_panel)
	page.add_child(heading)
	page.add_child(HSeparator.new())
	var workspace := HBoxContainer.new()
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.add_theme_constant_override("separation", 18)
	var general_data := {
		"general_id": expedition.general.id,
		"name": expedition.general.name,
		"level": int(report.get("current_level", 1)),
		"experience": int(report.get("projected_experience", 0)),
		"status": "active",
		"injury": {"status": "healthy"},
		"attributes": expedition.general.get("attributes", {}),
	}
	var general_card = GeneralCardViewScript.new()
	general_card.configure(general_data, {"available": true, "selected": true}, GeneralCardViewScript.Density.COMPACT)
	general_card.custom_minimum_size = Vector2(270, 0)
	workspace.add_child(general_card)
	var growth := VBoxContainer.new()
	growth.custom_minimum_size = Vector2(390, 0)
	growth.add_theme_constant_override("separation", 12)
	growth.add_child(_section_title("武将历练"))
	var experience_gain := _label("经验 +%d" % int(report.get("experience_gained", 0)), 32, SUCCESS)
	experience_gain.name = "CombatReportExperienceGain"
	growth.add_child(experience_gain)
	var experience_bar := ProgressBar.new()
	experience_bar.name = "CombatReportExperienceBar"
	experience_bar.custom_minimum_size = Vector2(0, 28)
	experience_bar.min_value = 0
	experience_bar.max_value = maxf(1.0, float(report.get("next_level_experience", report.get("projected_experience", 1))))
	experience_bar.value = float(report.get("projected_experience", 0))
	experience_bar.show_percentage = false
	experience_bar.add_theme_stylebox_override("background", Tokens.panel_style(Tokens.with_alpha(Tokens.PAPER_SHADE, 0.72), Tokens.PAPER_SHADE, Tokens.RADIUS_SM, 0, 0))
	experience_bar.add_theme_stylebox_override("fill", Tokens.panel_style(Tokens.MINERAL_GREEN, Tokens.MINERAL_GREEN, Tokens.RADIUS_SM, 0, 0))
	growth.add_child(experience_bar)
	var experience_text := _label("累计经验 %d · 本趟已获 %d" % [int(report.get("projected_experience", 0)), int(report.get("pending_experience_total", 0))], 16, PARCHMENT)
	experience_text.name = "CombatReportExperienceTotal"
	growth.add_child(experience_text)
	if int(report.get("projected_level", 1)) > int(report.get("current_level", 1)):
		var upgrade_text := "回城后可升至 Lv.%d" % int(report.projected_level)
		var attribute_growth: Dictionary = report.get("projected_attribute_growth", {})
		if not attribute_growth.is_empty():
			upgrade_text += "\n武勇 %+d · 统率 %+d · 政务 %+d" % [int(attribute_growth.get("martial", 0)), int(attribute_growth.get("leadership", 0)), int(attribute_growth.get("administration", 0))]
		var upgrade := _label(upgrade_text, 18, BRONZE)
		upgrade.name = "CombatReportLevelPreview"
		growth.add_child(upgrade)
	else:
		growth.add_child(_label("历练将在回城结算时正式生效。", 14, MUTED))
	workspace.add_child(_paper_panel(growth))
	var rewards := VBoxContainer.new()
	rewards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rewards.add_theme_constant_override("separation", 10)
	rewards.add_child(_section_title("本场战果"))
	var troop_delta := int(report.get("troops_delta", 0))
	var morale_delta := int(report.get("morale_delta", 0))
	var losses := _label("兵力 %d  %s\n士气 %d  %s" % [int(report.get("troops_after", 0)), _signed_value(troop_delta), int(report.get("morale_after", 0)), _signed_value(morale_delta)], 18, DANGER if troop_delta < 0 else PARCHMENT)
	losses.name = "CombatReportLosses"
	rewards.add_child(losses)
	rewards.add_child(HSeparator.new())
	var loot_gained: Dictionary = report.get("loot_gained", {})
	var reward_text := "本场奖励：%s" % (_loot_text(loot_gained) if not loot_gained.is_empty() else "无资源")
	if not String(report.get("item_name", "")).is_empty():
		reward_text += "\n临时物品：%s" % report.item_name
	var reward_label := _label(reward_text, 18, SUCCESS)
	reward_label.name = "CombatReportRewards"
	rewards.add_child(reward_label)
	var total_label := _label("战利品袋：%s" % _loot_text(report.get("unbanked_loot_total", {})), 15, BRONZE)
	total_label.name = "CombatReportLootTotal"
	total_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rewards.add_child(total_label)
	var warning := _label("尚未入库 · 远征失败将全部丢失", 15, DANGER)
	warning.name = "CombatReportLootWarning"
	rewards.add_child(warning)
	var route_progress: Dictionary = report.get("route_progress", {})
	rewards.add_child(_label("行军进度：第%d / %d层" % [int(route_progress.get("layer", 0)), int(route_progress.get("max_layer", 8))], 14, MUTED))
	if bool(report.get("post_battle_reward_pending", false)):
		rewards.add_child(_label("发现新军略 · 继续后进行选择", 16, BRONZE))
	workspace.add_child(_paper_panel(rewards, true))
	page.add_child(workspace)
	var continue_button := _button("查看远征总报" if bool(report.get("expedition_terminal", false)) else "收拢队伍，继续行军", true, Vector2(280, 52))
	continue_button.name = "AcknowledgeCombatReportButton"
	continue_button.size_flags_horizontal = Control.SIZE_SHRINK_END
	continue_button.pressed.connect(_acknowledge_combat_report.bind(String(report.get("report_id", ""))))
	page.add_child(continue_button)
	if not _notice.is_empty():
		page.add_child(_notice_label())
	_set_stage(page)
	if not MotionPolicyScript.reduced():
		experience_bar.value = float(report.get("experience_before", 0))
		growth.modulate.a = 0.0
		rewards.modulate.a = 0.0
		continue_button.modulate.a = 0.0
		var tween := create_tween()
		tween.tween_interval(0.08)
		tween.tween_property(growth, "modulate:a", 1.0, 0.16)
		tween.parallel().tween_property(experience_bar, "value", float(report.get("projected_experience", 0)), 0.42).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tween.tween_property(rewards, "modulate:a", 1.0, 0.18)
		tween.tween_property(continue_button, "modulate:a", 1.0, 0.14)


func _acknowledge_combat_report(report_id: String) -> void:
	var result: Dictionary = _flow.acknowledge_combat_report({"action_id": _action_id("combat-report"), "report_id": report_id}, _timestamp())
	_notice = "战果已记入军簿。" if result.ok else _result_error(result)
	_render_current_phase()


func _render_settlement() -> void:
	var expedition: Dictionary = _flow.snapshot().expedition
	phase_label.text = "远征终报  /  待最终结算"
	save_status.text = "终态检查点已保存"
	var page := VBoxContainer.new()
	page.name = "SettlementStage"
	page.alignment = BoxContainer.ALIGNMENT_CENTER
	var content := VBoxContainer.new()
	content.custom_minimum_size = Vector2(720, 0)
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_theme_constant_override("separation", 18)
	var success: bool = expedition.status == "awaiting_settlement"
	var title := _label("%s克复" % expedition.destination_name if success else ("撤军归营" if expedition.status == "retreated" else "军势受挫"), 46, SUCCESS if success else BRONZE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(title)
	var outcome_label := _label(_settlement_outcome_text(expedition), 19, PARCHMENT)
	outcome_label.name = "SettlementOutcomeLabel"
	outcome_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(outcome_label)
	var summary := "率军：%s\n剩余兵力：%d / %d    剩余士气：%d\n%s" % [
		expedition.general.name,
		int(expedition.general.troops),
		int(expedition.initial_troops),
		int(expedition.general.morale),
		("待入库战利品：%s" % _loot_text(expedition.unbanked_loot)) if success else ("已失去战利品：%s" % _loot_text(expedition.lost_unbanked_loot)),
	]
	summary += "\n义军民望：%d（本次 %+d）    本次叛乱：%+d" % [int(expedition.projected_popular_support), int(expedition.pending_popular_support_delta), int(expedition.pending_rebellion_delta)]
	var experience_total := int(expedition.get("pending_battle_experience", 0))
	if bool(expedition.get("general_died", false)):
		summary += "\n本趟历练：%d（武将阵亡，无法保留）" % experience_total
	else:
		summary += "\n本趟历练：+%d经验" % experience_total
		if int(expedition.get("projected_general_level", expedition.get("initial_general_level", 1))) > int(expedition.get("initial_general_level", 1)):
			summary += " · 回城后升至 Lv.%d" % int(expedition.projected_general_level)
	var detail := _label(summary, 20, PARCHMENT)
	detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(detail)
	var consequence := _label(_settlement_consequence_text(expedition), 16, DANGER if not success else MUTED)
	consequence.name = "SettlementConsequenceLabel"
	consequence.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(consequence)
	var settle := _button("确认结算，返回主城", true, Vector2(300, 54))
	settle.name = "FinalizeExpeditionButton"
	settle.unique_name_in_owner = true
	settle.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	settle.pressed.connect(confirm_settlement)
	content.add_child(settle)
	var settlement_panel := _paper_panel(content)
	settlement_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	page.add_child(settlement_panel)
	_set_stage(page)


func _render_game_over() -> void:
	phase_label.text = "战役终结"
	save_status.text = "玩家角色死亡"
	var page := VBoxContainer.new()
	page.name = "GameOverStage"
	page.alignment = BoxContainer.ALIGNMENT_CENTER
	var content := VBoxContainer.new()
	content.custom_minimum_size = Vector2(600, 300)
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_theme_constant_override("separation", 18)
	var title := _label("义旗坠地", 50, DANGER)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(title)
	var explanation := _label("玩家角色永久死亡，本次战役已经结束。", 19, MUTED)
	explanation.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(explanation)
	var button := _button("返回起始页", false, Vector2(200, 50))
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.pressed.connect(_render_welcome)
	content.add_child(button)
	var panel := _paper_panel(content)
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	page.add_child(panel)
	_set_stage(page)


func _render_fatal(message: String) -> void:
	phase_label.text = "初始化失败"
	var label := _label(message, 19, DANGER)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_set_stage(label)


func _select_general(general_id: String) -> void:
	_selected_general_id = general_id
	_render_main_city()


func _select_expedition_target(expedition_id: String) -> void:
	_selected_expedition_id = expedition_id
	_deployment_counts = {}
	_notice = ""
	_render_deployment()


func _deployment_general_changed(index: int, selector: OptionButton) -> void:
	_selected_general_id = String(selector.get_item_metadata(index))
	_deployment_counts = {}
	_render_deployment()


func _army_count_changed(value: float, army_type: String) -> void:
	_deployment_counts[army_type] = int(value)
	var readiness: Dictionary = _flow.expedition_readiness({"expedition_id": _selected_expedition_id, "general_id": _selected_general_id, "army_counts": _deployment_counts})
	var total_label := find_child("DeploymentTotalLabel", true, false) as Label
	var start_button := find_child("StartExpeditionButton", true, false) as Button
	if total_label != null:
		total_label.text = "合计 %d / 带兵上限 %d" % [_army_total(), int(readiness.get("troop_cap", 0))]
		total_label.modulate = BRONZE if readiness.ok else DANGER
	if start_button != null:
		start_button.disabled = not readiness.ok


func _replenish(army_type: String) -> void:
	var result: Dictionary = _flow.replenish_troops({"action_id": _action_id("army.%s" % army_type), "army_type": army_type, "batches": 1})
	_notice = "已补充100名%s。" % {"infantry": "步兵", "archer": "弓兵", "cavalry": "骑兵"}[army_type] if result.ok else _result_error(result)
	_render_main_city()


func _unlock_pursue() -> void:
	var result: Dictionary = _flow.unlock_public_card({"action_id": _action_id("research.unlock.pursue"), "card_id": "card.public.cavalry.pursue"})
	_notice = "已永久解锁【追亡逐北】。" if result.ok else _result_error(result)
	_render_main_city()


func _upgrade_assault() -> void:
	var result: Dictionary = _flow.upgrade_public_card({"action_id": _action_id("research.upgrade.assault"), "card_id": "card.public.general.assault", "branch_id": "break_momentum"})
	_notice = "【突击】已选择永久分支：破势。" if result.ok else _result_error(result)
	_render_main_city()


func _select_loadout_card(card_id: String) -> void:
	_selected_loadout_card_id = card_id
	_render_deck_editor()


func _add_loadout_card(card_id: String) -> void:
	var editor: Dictionary = _flow.loadout_editor_snapshot()
	if not editor.ok:
		_notice = _result_error(editor)
		_render_deck_editor()
		return
	var option := _public_card_option(editor.public_cards, card_id)
	if option.is_empty() or not bool(option.unlocked) or _loadout_draft.size() >= int(editor.maximum_size) or _loadout_draft.count(card_id) >= int(option.copy_limit):
		_notice = "该卡当前不能继续编入。"
	else:
		_loadout_draft.append(card_id)
		_selected_loadout_card_id = card_id
		_notice = "已加入【%s】，当前%d张。" % [option.name, _loadout_draft.size()]
	_render_deck_editor()


func _remove_loadout_card(card_id: String) -> void:
	var index := _loadout_draft.find(card_id)
	if index >= 0:
		_loadout_draft.remove_at(index)
		_selected_loadout_card_id = card_id
		_notice = "已移除一张【%s】，当前%d张。" % [_registry.get_card(card_id).get("name", card_id), _loadout_draft.size()]
	_render_deck_editor()


func _confirm_base_loadout() -> void:
	var result: Dictionary = _flow.set_base_loadout({"action_id": _action_id("base-loadout"), "cards": _loadout_draft.duplicate()})
	if not result.ok:
		_notice = _result_error(result)
		_render_deck_editor()
		return
	_notice = "共用基础牌组已更新；请在主城手动保存，或随下一战检查点写入自动档。"
	_loadout_draft = []
	_render_main_city()


func _cancel_base_loadout_edit() -> void:
	_loadout_draft = []
	_notice = "已放弃未确认的牌组草稿。"
	_render_main_city()


func _manual_save() -> void:
	var result: Dictionary = _flow.save_manual(1, _timestamp())
	_notice = "整备已写入手动槽一。" if result.ok else _result_error(result)
	_render_main_city()


func _submit_encounter_choice(choice_id: String) -> void:
	var before: Dictionary = _flow.expedition_run_snapshot()
	var result: Dictionary = _flow.submit_encounter_choice({"action_id": _action_id("encounter"), "choice_id": choice_id}, _timestamp())
	_notice = _choice_result_notice(before, _flow.expedition_run_snapshot()) if result.ok else _result_error(result)
	_render_current_phase()


func _choice_result_notice(before: Dictionary, after: Dictionary) -> String:
	if before.is_empty() or after.is_empty():
		return "选择已结算。"
	var changes: Array[String] = []
	var troop_delta := int(after.get("general", {}).get("troops", 0)) - int(before.get("general", {}).get("troops", 0))
	var morale_delta := int(after.get("general", {}).get("morale", 0)) - int(before.get("general", {}).get("morale", 0))
	var support_delta := int(after.get("pending_popular_support_delta", 0)) - int(before.get("pending_popular_support_delta", 0))
	var rebellion_delta := int(after.get("pending_rebellion_delta", 0)) - int(before.get("pending_rebellion_delta", 0))
	if troop_delta != 0: changes.append("兵力 %+d" % troop_delta)
	if morale_delta != 0: changes.append("士气 %+d" % morale_delta)
	if support_delta != 0: changes.append("民望 %+d" % support_delta)
	if rebellion_delta != 0: changes.append("叛乱 %+d" % rebellion_delta)
	if after.get("status", "") == "failed": changes.append("远征失败")
	return "选择已结算%s。" % ("：%s" % "、".join(changes) if not changes.is_empty() else "")


func _use_temporary_item(item_instance_id: String) -> void:
	var result: Dictionary = _flow.use_expedition_item({"action_id": _action_id("item"), "item_instance_id": item_instance_id}, _timestamp())
	_notice = "临时物品已使用。" if result.ok else _result_error(result)
	_render_current_phase()


func _recover_legacy_base_loadout() -> void:
	var result: Dictionary = _flow.recover_legacy_base_loadout(_action_id("legacy.loadout.recovery"), _timestamp())
	if not result.ok:
		_notice = _result_error(result)
		_render_legacy_recovery()
		return
	var saved: Dictionary = _flow.save_manual(1, _timestamp())
	_notice = "旧档牌组已恢复，并写入手动槽1。" if saved.ok else "牌组已恢复，但手动保存失败：%s" % _result_error(saved)
	_render_current_phase()


func _set_stage(content: Control, full_bleed := false) -> void:
	for child in stage_host.get_children():
		child.queue_free()
	stage_host.add_theme_constant_override("margin_left", 0 if full_bleed else 42)
	stage_host.add_theme_constant_override("margin_top", 0 if full_bleed else 26)
	stage_host.add_theme_constant_override("margin_right", 0 if full_bleed else 42)
	stage_host.add_theme_constant_override("margin_bottom", 0 if full_bleed else 30)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stage_host.add_child(content)
	if MotionPolicyScript.reduced():
		content.modulate.a = 1.0
		return
	content.modulate.a = 0.0
	content.position.y += 8.0
	var tween := create_tween().set_parallel(true)
	tween.tween_property(content, "modulate:a", 1.0, 0.2)
	tween.tween_property(content, "position:y", content.position.y - 8.0, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _resource_strip(campaign: Dictionary) -> Control:
	var strip := HBoxContainer.new()
	strip.add_theme_constant_override("separation", 28)
	var values := [
		["银钱", campaign.resources.silver], ["粮食", campaign.resources.food],
		["兵源", campaign.resources.recruits], ["军学", campaign.resources.military_knowledge],
		["战马", campaign.special_resources.get("resource.warhorse", 0)],
		["兵法残篇", campaign.special_resources.get("resource.cavalry_fragment", 0)],
	]
	for pair in values:
		var label := _label("%s  %d" % [pair[0], int(pair[1])], 17, PARCHMENT)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		strip.add_child(label)
	return strip


func _temporary_item_bar(expedition: Dictionary) -> Control:
	var bar := HBoxContainer.new()
	bar.name = "TemporaryItemBar"
	bar.add_theme_constant_override("separation", 8)
	bar.add_child(_label("临时物品 %d / 3" % expedition.get("temporary_items", []).size(), 14, MUTED))
	for item in expedition.get("temporary_items", []):
		var button := _button("使用 · %s" % item.get("name", item.get("item_id", "物品")), false, Vector2(150, 36))
		button.name = "UseItem_%s" % _node_safe_id(String(item.get("instance_id", "")))
		button.tooltip_text = String(item.get("description", ""))
		button.pressed.connect(_use_temporary_item.bind(String(item.get("instance_id", ""))))
		bar.add_child(button)
	return bar


func _button(text: String, primary: bool, minimum := Vector2(0, 42)) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = minimum
	button.focus_mode = Control.FOCUS_ALL
	button.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	if primary:
		button.theme_type_variation = "QingluPrimaryButton"
	return button


func _label(text: String, size_value: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size_value)
	label.add_theme_color_override("font_color", color)
	return label


func _section_title(text: String) -> Label:
	var label := _label(text.to_upper(), 14, BRONZE)
	label.custom_minimum_size = Vector2(0, 28)
	return label


func _notice_label() -> Label:
	var label := _label(_notice, 14, SUCCESS if not ("失败" in _notice or "不足" in _notice or "不能" in _notice) else DANGER)
	label.name = "NoticeLabel"
	label.unique_name_in_owner = true
	return label


func _spacer(width: float, height: float) -> Control:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(width, height)
	return spacer


func _paper_panel(content: Control, expand := false) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.theme_type_variation = "QingluPaperPanel"
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	if expand:
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(content)
	return panel


func _apply_shell_style() -> void:
	var panel := Tokens.panel_style(Tokens.with_alpha(Tokens.PAPER_BRIGHT, 0.96), Tokens.with_alpha(Tokens.LIGHT_GOLD_DARK, 0.42), 0, 0, Tokens.SPACE_SM)
	panel.border_width_bottom = 1
	$Page/TopBar.add_theme_stylebox_override("panel", panel)
	$Page/TopBar/Margin/Row/Brand.theme_type_variation = "QingluHeading"
	phase_label.theme_type_variation = "QingluMuted"
	save_status.theme_type_variation = "QingluCaption"


func _load_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var value = JSON.parse_string(file.get_as_text())
	file.close()
	return value if value is Dictionary else {}


func _save_root() -> String:
	return save_root_override if not save_root_override.is_empty() else "user://m6_vertical_slice"


func _autosave_path() -> String:
	return "%s/autosave.json" % _save_root().trim_suffix("/")


func _manual_path(slot_number: int) -> String:
	return "%s/manual_%d.json" % [_save_root().trim_suffix("/"), slot_number]


func _autosave_exists() -> bool:
	var path := ProjectSettings.globalize_path(_autosave_path())
	return FileAccess.file_exists(path) or FileAccess.file_exists(path + ".bak")


func _manual_exists(slot_number: int) -> bool:
	var path := ProjectSettings.globalize_path(_manual_path(slot_number))
	return FileAccess.file_exists(path) or FileAccess.file_exists(path + ".bak")


func _requires_legacy_loadout_recovery() -> bool:
	if _flow == null or current_phase() != "main_city":
		return false
	return bool(_flow.snapshot().get("campaign", {}).get("loadout_system", {}).get("requires_legacy_recovery", false))


func _timestamp() -> String:
	return Time.get_datetime_string_from_system(true, false) + "Z"


func _action_id(prefix: String) -> String:
	_action_sequence += 1
	return "ui.%s.%d.%d" % [prefix, int(Time.get_unix_time_from_system()), _action_sequence]


func _result_error(result: Dictionary) -> String:
	if result.has("reason") and not String(result.reason).is_empty():
		return String(result.reason)
	var errors = result.get("errors", [])
	if (errors is Array or errors is PackedStringArray) and not errors.is_empty():
		var parts := PackedStringArray()
		for error in errors:
			parts.append(String(error))
		return "；".join(parts)
	return "操作未完成"


func _campaign_general(campaign: Dictionary, general_id: String) -> Dictionary:
	for general in campaign.get("generals", []):
		if general is Dictionary and general.get("general_id", "") == general_id:
			return general
	return {}


func _general_name(general_id: String) -> String:
	var definition: Dictionary = _registry.get_general(general_id)
	return String(definition.get("name", general_id))


func _city_title(stage: String) -> String:
	return {"ruined_camp": "破寨新营", "rebel_camp": "义军大营"}.get(stage, "义军大营")


func _territory_summary(campaign: Dictionary) -> String:
	if campaign.get("territories", []).is_empty():
		return "势力 · 尚无正式领地"
	var names: Array[String] = []
	for territory in campaign.territories:
		if territory is Dictionary:
			var definition: Dictionary = _registry.get_territory(String(territory.get("territory_id", "")))
			names.append("%s%s" % [definition.get("name", territory.get("territory_id", "未知领地")), " · 下期生效" if not bool(territory.get("income_enabled", false)) else " · 收入生效"])
	return "势力 · %s" % "  /  ".join(names)


func _deck_summary(deck: Array) -> String:
	var counts := {}
	for card_id in deck:
		counts[card_id] = int(counts.get(card_id, 0)) + 1
	var parts: Array[String] = []
	for card_id in counts:
		var card: Dictionary = _registry.get_card(String(card_id))
		parts.append("%s×%d" % [card.get("name", card_id), int(counts[card_id])])
	return "  ·  ".join(parts)


func _public_card_option(options: Array, card_id: String) -> Dictionary:
	for option in options:
		if option is Dictionary and option.get("id", "") == card_id:
			return option
	return {}


func _rarity_name(rarity: String) -> String:
	return {"basic": "基础", "advanced": "高级", "rare": "稀有", "secret": "秘策"}.get(rarity, rarity)


func _node_safe_id(value: String) -> String:
	return value.replace(".", "_").replace(":", "_").replace("-", "_")


func _loot_text(loot: Dictionary) -> String:
	if loot.is_empty():
		return "尚无"
	var names := {"resource.silver": "银钱", "resource.food": "粮食", "resource.recruits": "兵源", "resource.military_knowledge": "军学", "resource.cavalry_fragment": "兵法残篇"}
	var parts: Array[String] = []
	for resource_id in loot:
		parts.append("%s +%d" % [names.get(resource_id, resource_id), int(loot[resource_id])])
	return "  ·  ".join(parts)


func _signed_value(value: int) -> String:
	return "%+d" % value


func _army_total() -> int:
	return int(_deployment_counts.get("infantry", 0)) + int(_deployment_counts.get("archer", 0)) + int(_deployment_counts.get("cavalry", 0))


func _resolution_notice(resolution: Dictionary) -> String:
	if not String(resolution.get("enemy_id", "")).is_empty():
		return "遭遇敌军，战斗检查点已保存。"
	if resolution.get("immediate_effects", {}).has("intel"):
		return "斥候已查明严成军势。"
	if resolution.get("immediate_effects", {}).has("restore_troops_ratio"):
		return "完成补给，兵力与士气已经恢复。"
	return "节点已结算，行军图已自动保存。"


func _battle_result_notice(result: Dictionary) -> String:
	match result.get("status", ""):
		"victory":
			return "战斗胜利，节点奖励已进入战利品袋。"
		"retreated":
			return "已撤军，未入库战利品全部丢失。"
		_:
			return "战斗失败，伤亡结果等待最终结算。"


func _settlement_outcome_text(expedition: Dictionary) -> String:
	if expedition.status == "awaiting_settlement":
		return "%s守军败退，目标已经控制。" % expedition.destination_name
	if expedition.status == "retreated":
		return "武将生还，远征目标未完成。"
	if bool(expedition.get("general_died", false)):
		return "%s阵亡，远征立即终止。" % expedition.general.name
	if int(expedition.general.morale) <= 0:
		return "军心崩溃，%s重伤归营。" % expedition.general.name
	return "兵力溃散，远征目标未完成。"


func _settlement_consequence_text(expedition: Dictionary) -> String:
	if expedition.status == "awaiting_settlement":
		return "确认后：战利品入库、伤亡扣除、武将成长、%s归属、民望、叛乱值与势力周期一次提交。" % expedition.destination_name
	var consequences: Array[String] = ["未入库战利品全部丢失", "已发生兵损永久扣除", "%s不会取得" % expedition.destination_name, "已发生的民望与叛乱影响仍会提交", "势力周期不推进"]
	if bool(expedition.get("general_died", false)):
		consequences.insert(0, "%s永久死亡" % expedition.general.name)
	elif bool(expedition.get("general_injured", false)):
		consequences.insert(0, "%s进入重伤" % expedition.general.name)
	else:
		consequences.insert(0, "%s安全生还" % expedition.general.name)
	return "确认后：%s。" % "；".join(consequences)
