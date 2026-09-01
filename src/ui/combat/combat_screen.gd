extends Control
class_name CombatScreen

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")
const CombatControllerScript := preload("res://src/domain/combat/combat_controller.gd")

const BRONZE := Color("#c7984d")
const PARCHMENT := Color("#e5d5b1")
const MUTED := Color("#9c9a8e")
const DANGER := Color("#be6356")
const SUCCESS := Color("#6d9a70")
const CARD_WIDTH := 150.0
const CARD_HEIGHT := 202.0

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
	setup_battle(battle_request_override)


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
	var availability = _controller.card_availability(hand_index)
	if not availability.ok:
		feedback_label.text = availability.reason
		_pulse_feedback(DANGER)
		return availability
	var card_id: String = _controller.snapshot().deck.hand[hand_index]
	var card: Dictionary = _registry.get_card(card_id)
	var result = _controller.play_card(hand_index)
	if result.ok:
		feedback_label.text = "已打出【%s】" % card.get("name", card_id)
		_pulse_feedback(BRONZE)
	_refresh()
	return result


func end_turn() -> Dictionary:
	if _controller == null:
		return {"ok": false, "reason": "战斗尚未初始化"}
	var result = _controller.end_player_turn()
	if result.ok:
		feedback_label.text = "敌军行动已结算，新的手牌已经发下。"
	_refresh()
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


func combat_snapshot() -> Dictionary:
	return _controller.snapshot() if _controller != null else {}


func card_button_count() -> int:
	return _card_buttons.size()


func _refresh() -> void:
	var state: Dictionary = _controller.snapshot()
	turn_label.text = "第 %d 回合" % state.turn
	seed_label.text = "SEED %d" % state.seed
	enemy_name.text = "严阵以待 · %s" % _display_name(state.enemy.id)
	enemy_stats.text = _format_stats(state.enemy)
	player_name.text = "率军武将 · 赵烈（原型）"
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
	return "%s%s" % [labels.get(kind, "※ 特殊"), " · 威力%d" % damage if damage > 0 else ""]


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


func _display_name(identifier: String) -> String:
	return "基准官军" if identifier == "dev.baseline_enemy" else identifier


func _default_request() -> Dictionary:
	var enemy: Dictionary = _registry.get_enemy("dev.baseline_enemy")
	return {
		"battle_id": "m2-ui-prototype",
		"seed": 22301,
		"player": {
			"id": "dev.zhao_lie",
			"is_player_character": false,
			"troops": 1000,
			"max_troops": 1000,
			"morale": 85,
			"max_morale": 100,
			"attack": 25,
			"defense": 20,
			"army_composition": {"infantry": 0.35, "archer": 0.15, "cavalry": 0.5},
		},
		"enemy": enemy,
		"deck": [
			"dev.basic_attack",
			"dev.basic_attack",
			"dev.guard",
			"dev.demoralize",
			"dev.tactical_cycle",
			"dev.effect_matrix",
			"dev.m0_validation_sample",
		],
	}
