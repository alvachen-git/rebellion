extends Control
class_name CombatScreen

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")
const CombatControllerScript := preload("res://src/domain/combat/combat_controller.gd")
const GeneralRequestBuilderScript := preload("res://src/domain/combat/general_combat_request_builder.gd")

const BRONZE := Color("#c7984d")
const PARCHMENT := Color("#e5d5b1")
const MUTED := Color("#9c9a8e")
const DANGER := Color("#be6356")
const SUCCESS := Color("#6d9a70")
const CARD_WIDTH := 150.0
const CARD_HEIGHT := 202.0
const GENERAL_IDS := ["general.zhao_lie", "general.zhou_jing", "general.han_yue"]
const ENEMY_IDS := [
	"enemy.normal.patrol_inspector",
	"enemy.normal.local_militia",
	"enemy.normal.city_defenders",
	"enemy.normal.crossbow_company",
	"enemy.normal.overseer_unit",
	"enemy.elite.gao_wu",
	"enemy.elite.he_wei",
	"enemy.boss.yan_cheng",
]
const GENERAL_PREVIEW_SEEDS := {
	"general.zhao_lie": 15,
	"general.zhou_jing": 10,
	"general.han_yue": 4,
}

var battle_request_override: Dictionary = {}
var _registry
var _controller
var _card_buttons: Array[Button] = []

@onready var turn_label: Label = %TurnLabel
@onready var seed_label: Label = %SeedLabel
@onready var intent_label: Label = %IntentLabel
@onready var enemy_name: Label = %EnemyName
@onready var enemy_stats: Label = %EnemyStats
@onready var player_name: Label = %PlayerName
@onready var player_stats: Label = %PlayerStats
@onready var army_label: Label = %ArmyLabel
@onready var action_label: Label = %ActionLabel
@onready var feedback_label: Label = %FeedbackLabel
@onready var general_selector: OptionButton = %GeneralSelector
@onready var enemy_selector: OptionButton = %EnemySelector
@onready var selection_hint: Label = %SelectionHint
@onready var start_selected_button: Button = %StartSelectedButton
@onready var enemy_panel: PanelContainer = %EnemyPanel
@onready var player_panel: PanelContainer = %PlayerPanel
@onready var impact_label: Label = %ImpactLabel
@onready var hand_container: HBoxContainer = %HandContainer
@onready var end_turn_button: Button = %EndTurnButton
@onready var retreat_button: Button = %RetreatButton
@onready var retreat_dialog: ConfirmationDialog = %RetreatDialog
@onready var result_overlay: ColorRect = %ResultOverlay
@onready var result_title: Label = %ResultTitle
@onready var result_detail: Label = %ResultDetail


func _ready() -> void:
	end_turn_button.pressed.connect(end_turn)
	retreat_button.pressed.connect(request_retreat)
	retreat_dialog.confirmed.connect(confirm_retreat)
	%RestartButton.pressed.connect(restart_battle)
	start_selected_button.pressed.connect(start_selected_battle)
	general_selector.item_selected.connect(_on_selection_changed)
	enemy_selector.item_selected.connect(_on_selection_changed)
	if setup_battle(battle_request_override):
		_populate_selection_controls()


func setup_battle(request: Dictionary = {}) -> bool:
	_registry = ContentRegistryScript.new()
	if not _registry.load_all():
		_show_boot_error("内容校验失败：%s" % "；".join(_registry.get_errors()))
		return false
	_controller = CombatControllerScript.new()
	var actual_request := request if not request.is_empty() else _default_request()
	var errors = _controller.setup(actual_request, _registry)
	if not errors.is_empty():
		_show_boot_error("战斗初始化失败：%s" % "；".join(errors))
		return false
	result_overlay.visible = false
	feedback_label.text = "观察敌方意图，安排本回合出牌顺序。"
	_refresh()
	return true


func play_card_at(hand_index: int) -> Dictionary:
	if _controller == null:
		return {"ok": false, "reason": "战斗尚未初始化"}
	var before: Dictionary = _controller.snapshot()
	var availability = _controller.card_availability(hand_index)
	if not availability.ok:
		feedback_label.text = availability.reason
		_pulse_feedback(DANGER)
		return availability
	var card_id: String = _controller.snapshot().deck.hand[hand_index]
	var card: Dictionary = _registry.get_card(card_id)
	var result = _controller.play_card(hand_index)
	if result.ok:
		var after: Dictionary = _controller.snapshot()
		if int(after.get("enemy_phase", 1)) > int(before.get("enemy_phase", 1)):
			feedback_label.text = "%s发动【%s】：立即加固城防，并锁定下一次特殊行动。" % [
				after.enemy.get("name", "敌军"),
				after.get("enemy_talent", {}).get("name", "阶段天赋"),
			]
		else:
			feedback_label.text = "已打出【%s】" % card.get("name", card_id)
		_pulse_feedback(BRONZE)
	_refresh()
	return result


func end_turn() -> Dictionary:
	if _controller == null:
		return {"ok": false, "reason": "战斗尚未初始化"}
	var before: Dictionary = _controller.snapshot()
	var resolved_intent: Dictionary = before.get("enemy_intent", {}).duplicate(true)
	var result = _controller.end_player_turn()
	var after: Dictionary = _controller.snapshot()
	_refresh()
	if result.ok:
		feedback_label.text = _enemy_resolution_text(resolved_intent, before, after)
		_animate_enemy_resolution(resolved_intent, before, after)
	return result


func request_retreat() -> void:
	if _controller != null and _controller.is_active():
		retreat_dialog.popup_centered(Vector2i(520, 240))


func confirm_retreat() -> Dictionary:
	var result = _controller.retreat()
	_refresh()
	return result


func restart_battle() -> void:
	setup_battle(battle_request_override)


func start_selected_battle() -> bool:
	var general_id := String(general_selector.get_selected_metadata())
	var enemy_id := String(enemy_selector.get_selected_metadata())
	if general_id.is_empty() or enemy_id.is_empty():
		_show_boot_error("请先选择率军武将与敌军。")
		return false
	var built: Dictionary = GeneralRequestBuilderScript.build(
		general_id,
		_registry.get_enemy(enemy_id),
		int(GENERAL_PREVIEW_SEEDS.get(general_id, 22301)),
		_registry,
		"m3-playable-selection"
	)
	if not built.ok:
		_show_boot_error(built.error)
		return false
	battle_request_override = built.request
	return setup_battle(battle_request_override)


func combat_snapshot() -> Dictionary:
	return _controller.snapshot() if _controller != null else {}


func card_button_count() -> int:
	return _card_buttons.size()


func _refresh() -> void:
	var state: Dictionary = _controller.snapshot()
	turn_label.text = "第 %d 回合" % state.turn
	seed_label.text = "SEED %d" % state.seed
	enemy_name.text = "严阵以待 · %s" % state.enemy.get("name", state.enemy.id)
	enemy_stats.text = _format_stats(state.enemy)
	player_name.text = "率军武将 · %s" % state.player.get("name", state.player.id)
	player_stats.text = _format_stats(state.player)
	army_label.text = _format_army(state.player.army_composition)
	action_label.text = "%d / %d 行动力" % [state.action_points, state.starting_action_points]
	intent_label.text = _format_intent(state.enemy_intent)
	_rebuild_hand(state)
	var active: bool = state.status == "active"
	end_turn_button.disabled = not active
	retreat_button.disabled = not active
	if not active:
		_show_result(state.result)


func _rebuild_hand(state: Dictionary) -> void:
	for child in hand_container.get_children():
		child.queue_free()
	_card_buttons.clear()
	for hand_index in state.deck.hand.size():
		var card_id: String = state.deck.hand[hand_index]
		var card: Dictionary = _registry.get_card(card_id)
		var availability = _controller.card_availability(hand_index)
		var button := Button.new()
		button.name = "Card%d" % hand_index
		button.custom_minimum_size = Vector2(CARD_WIDTH, CARD_HEIGHT)
		button.size_flags_vertical = Control.SIZE_SHRINK_END
		button.text = _format_card(card, _controller.preview_card_damage(hand_index))
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.focus_mode = Control.FOCUS_ALL
		button.tooltip_text = "点击出牌" if availability.ok else availability.reason
		_apply_card_style(button, availability.ok, card.get("tags", []))
		button.pressed.connect(play_card_at.bind(hand_index))
		button.mouse_entered.connect(_on_card_hover.bind(button, hand_index))
		button.mouse_exited.connect(_on_card_unhover.bind(button))
		hand_container.add_child(button)
		_card_buttons.append(button)
		button.modulate.a = 0.0
		button.position.y += 18.0
		var tween := create_tween().set_parallel(true)
		var delay: float = hand_index * 0.035
		tween.tween_property(button, "modulate:a", 1.0, 0.16).set_delay(delay)
		tween.tween_property(button, "position:y", button.position.y - 18.0, 0.16).set_delay(delay).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _on_card_hover(button: Button, hand_index: int) -> void:
	var availability = _controller.card_availability(hand_index)
	feedback_label.text = "预计造成 %d 兵力伤害" % _controller.preview_card_damage(hand_index) if availability.ok else availability.reason
	button.z_index = 5
	var tween := create_tween().set_parallel(true)
	tween.tween_property(button, "scale", Vector2(1.04, 1.04), 0.1)
	tween.tween_property(button, "position:y", button.position.y - 10.0, 0.1)


func _on_card_unhover(button: Button) -> void:
	button.z_index = 0
	var tween := create_tween().set_parallel(true)
	tween.tween_property(button, "scale", Vector2.ONE, 0.1)
	tween.tween_property(button, "position:y", 0.0, 0.1)


func _show_result(result: Dictionary) -> void:
	result_overlay.visible = true
	match result.get("status", ""):
		"victory":
			result_title.text = "此战告捷"
			result_title.modulate = SUCCESS
		"retreated":
			result_title.text = "撤军保将"
			result_title.modulate = BRONZE
		_:
			result_title.text = "军势溃败"
			result_title.modulate = DANGER
	result_detail.text = "历经 %d 回合\n我方剩余兵力 %d · 士气 %d" % [
		result.get("turns", 0),
		result.get("player_remaining_troops", 0),
		result.get("player_remaining_morale", 0),
	]


func _show_boot_error(message: String) -> void:
	feedback_label.text = message
	feedback_label.modulate = DANGER


func _pulse_feedback(color: Color) -> void:
	feedback_label.modulate = color
	var tween := create_tween()
	tween.tween_property(feedback_label, "modulate", MUTED, 0.35)


func _enemy_resolution_text(intent: Dictionary, before: Dictionary, after: Dictionary) -> String:
	var action_names := {"attack": "强攻", "defend": "固守", "disrupt": "扰乱", "recover": "整军"}
	var action_name: String = action_names.get(intent.get("intent_type", "special"), "特殊行动")
	if intent.get("intent_type", "") == "special":
		action_name = intent.get("name", action_name)
	var troop_loss := maxi(int(before.player.troops) - int(after.player.troops), 0)
	var morale_loss := maxi(int(before.player.morale) - int(after.player.morale), 0)
	var outcomes: Array[String] = []
	if troop_loss > 0:
		outcomes.append("我方兵力 -%d" % troop_loss)
	if morale_loss > 0:
		outcomes.append("我方士气 -%d" % morale_loss)
	if intent.get("intent_type", "") == "defend":
		outcomes.append("敌军护甲升至 %d" % int(after.enemy.armor))
	if outcomes.is_empty():
		outcomes.append("行动已完成")
	return "敌军发动【%s】：%s。下一意图已公开。" % [action_name, "，".join(outcomes)]


func _animate_enemy_resolution(intent: Dictionary, before: Dictionary, after: Dictionary) -> void:
	var troop_loss := maxi(int(before.player.troops) - int(after.player.troops), 0)
	var morale_loss := maxi(int(before.player.morale) - int(after.player.morale), 0)
	var is_attack: bool = intent.get("intent_type", "") == "attack" or troop_loss > 0 or morale_loss > 0
	impact_label.text = _impact_text(intent, troop_loss, morale_loss, after)
	impact_label.modulate = DANGER if is_attack else BRONZE
	impact_label.modulate.a = 1.0
	impact_label.visible = true
	var impact_start_y := impact_label.position.y
	impact_label.position.y = impact_start_y + 8.0

	var movement := create_tween()
	var enemy_start_x := enemy_panel.position.x
	if is_attack:
		movement.tween_property(enemy_panel, "position:x", enemy_start_x - 30.0, 0.09).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		movement.tween_property(enemy_panel, "position:x", enemy_start_x, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		player_panel.modulate = DANGER.lightened(0.22)
		var hit_flash := create_tween()
		hit_flash.tween_property(player_panel, "modulate", Color.WHITE, 0.34)
	else:
		enemy_panel.modulate = BRONZE.lightened(0.2)
		movement.tween_property(enemy_panel, "modulate", Color.WHITE, 0.34)

	var float_text := create_tween().set_parallel(true)
	float_text.tween_property(impact_label, "position:y", impact_start_y - 18.0, 0.55).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	float_text.tween_property(impact_label, "modulate:a", 0.0, 0.55).set_delay(0.18)
	float_text.chain().tween_callback(func(): impact_label.visible = false)


func _impact_text(intent: Dictionary, troop_loss: int, morale_loss: int, after: Dictionary) -> String:
	var values: Array[String] = []
	if troop_loss > 0:
		values.append("兵力 -%d" % troop_loss)
	if morale_loss > 0:
		values.append("士气 -%d" % morale_loss)
	if not values.is_empty():
		return "  ".join(values)
	if intent.get("intent_type", "") == "defend":
		return "敌军护甲 %d" % int(after.enemy.armor)
	return "敌军行动"


func _format_stats(combatant: Dictionary) -> String:
	return "兵力 %d/%d    士气 %d/%d    护甲 %d\n攻击 %d    防御 %d" % [
		combatant.troops,
		combatant.max_troops,
		combatant.morale,
		combatant.max_morale,
		combatant.armor,
		roundi(combatant.attack),
		roundi(combatant.defense),
	]


func _format_army(composition: Dictionary) -> String:
	return "步 %d%%  ·  弓 %d%%  ·  骑 %d%%" % [
		roundi(float(composition.get("infantry", 0.0)) * 100.0),
		roundi(float(composition.get("archer", 0.0)) * 100.0),
		roundi(float(composition.get("cavalry", 0.0)) * 100.0),
	]


func _format_intent(intent: Dictionary) -> String:
	var labels := {"attack": "⚔ 强攻", "defend": "◆ 固守", "disrupt": "▼ 扰乱", "recover": "＋ 整军"}
	var kind: String = intent.get("intent_type", "special")
	var damage := 0
	for effect in intent.get("effects", []):
		if effect.get("type", "") == "DealDamage":
			damage += int(effect.get("base_power", 0))
	var label: String = labels.get(kind, "※ %s" % intent.get("name", "特殊"))
	return "%s%s" % [label, " · 威力%d" % damage if damage > 0 else ""]


func _format_card(card: Dictionary, preview_damage: int) -> String:
	var description: String = card.get("presentation", {}).get("description", "")
	var damage_line := "\n预计伤害 %d" % preview_damage if preview_damage > 0 else ""
	return "%d 令\n\n%s\n\n%s%s" % [card.get("cost", 0), card.get("name", "无名卡"), description, damage_line]


func _apply_card_style(button: Button, available: bool, tags: Array) -> void:
	var base := StyleBoxFlat.new()
	base.bg_color = Color("#3f3427") if available else Color("#292824")
	base.border_color = BRONZE if available else Color("#55534b")
	base.set_border_width_all(2)
	base.corner_radius_top_left = 7
	base.corner_radius_top_right = 7
	base.corner_radius_bottom_left = 7
	base.corner_radius_bottom_right = 7
	base.content_margin_left = 14
	base.content_margin_top = 12
	base.content_margin_right = 14
	base.content_margin_bottom = 12
	button.add_theme_stylebox_override("normal", base)
	var hover := base.duplicate()
	hover.bg_color = Color("#58452e") if tags.has("attack") else Color("#41493f")
	hover.border_color = PARCHMENT
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("focus", hover)
	button.add_theme_color_override("font_color", PARCHMENT if available else Color("#77756d"))
	button.add_theme_color_override("font_hover_color", Color.WHITE)
	button.add_theme_font_size_override("font_size", 16)


func _populate_selection_controls() -> void:
	general_selector.clear()
	for general_id in GENERAL_IDS:
		var general: Dictionary = _registry.get_general(general_id)
		general_selector.add_item("%s · %s" % [general.name, general.presentation.build_name])
		general_selector.set_item_metadata(general_selector.item_count - 1, general_id)
	enemy_selector.clear()
	for enemy_id in ENEMY_IDS:
		var enemy: Dictionary = _registry.get_enemy(enemy_id)
		var tier_names := {"normal": "普通", "elite": "精英", "boss": "首领"}
		var tier_name: String = tier_names.get(enemy.get("tier", "normal"), "普通")
		enemy_selector.add_item("%s · %s" % [tier_name, enemy.name])
		enemy_selector.set_item_metadata(enemy_selector.item_count - 1, enemy_id)
	_select_metadata(general_selector, combat_snapshot().get("player", {}).get("id", GENERAL_IDS[0]))
	_select_metadata(enemy_selector, combat_snapshot().get("enemy", {}).get("id", ENEMY_IDS[0]))
	_on_selection_changed(0)


func _select_metadata(selector: OptionButton, value: String) -> void:
	for index in selector.item_count:
		if String(selector.get_item_metadata(index)) == value:
			selector.select(index)
			return


func _on_selection_changed(_index: int) -> void:
	if general_selector.item_count == 0 or enemy_selector.item_count == 0:
		return
	var general: Dictionary = _registry.get_general(String(general_selector.get_selected_metadata()))
	var enemy: Dictionary = _registry.get_enemy(String(enemy_selector.get_selected_metadata()))
	selection_hint.text = "%s｜%s" % [general.presentation.build_name, enemy.presentation.description]


func _default_request() -> Dictionary:
	var built: Dictionary = GeneralRequestBuilderScript.build(
		GENERAL_IDS[0],
		_registry.get_enemy(ENEMY_IDS[0]),
		int(GENERAL_PREVIEW_SEEDS[GENERAL_IDS[0]]),
		_registry,
		"m3-default-playable-battle"
	)
	return built.request
