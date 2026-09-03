extends Control
class_name CombatantStageView

signal detail_visibility_changed(is_visible: bool)

const Tokens := preload("res://src/ui/theme/visual_tokens.gd")
const AssetCatalogScript := preload("res://src/ui/presentation/visual_asset_catalog.gd")
const STATUS_BRUSH_MASK := preload("res://assets/art/ui/status_brush_mask.png")
const HEAVY_ENEMY_IDS := {
	"enemy.elite.he_wei": true,
	"enemy.boss.yan_cheng": true,
}

enum Side { PLAYER, ENEMY }

var _side := Side.PLAYER
var _snapshot: Dictionary = {}
var _catalog = AssetCatalogScript.new()
var _portrait_button: Button
var _portrait: TextureRect
var _name_label: Label
var _troop_bar: TextureProgressBar
var _troop_label: Label
var _morale_bar: TextureProgressBar
var _morale_label: Label
var _detail_panel: PanelContainer
var _detail_label: Label


func _ready() -> void:
	clip_contents = false
	mouse_filter = Control.MOUSE_FILTER_PASS
	_catalog.load_catalog()
	_build()
	_apply_snapshot()


func configure(snapshot: Dictionary, side := Side.PLAYER) -> void:
	_snapshot = snapshot.duplicate(true)
	_side = int(side)
	if is_node_ready():
		_apply_snapshot()


func display_name_text() -> String:
	return _name_label.text if _name_label != null else _display_name()


func details_visible() -> bool:
	return _detail_panel != null and _detail_panel.visible


func persistent_status_text() -> String:
	if _troop_label == null or _morale_label == null:
		return ""
	return "%s｜%s" % [_troop_label.text, _morale_label.text]


func detailed_status_text() -> String:
	return _detail_label.text if _detail_label != null else _format_detail()


func battlefield_name_visible() -> bool:
	return _name_label != null and _name_label.visible


func status_bar_size() -> Vector2:
	if _troop_bar == null:
		return Vector2.ZERO
	return _troop_bar.get_parent().size


func presentation_asset_id() -> String:
	return _asset_id()


func _build() -> void:
	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 3)
	add_child(column)

	var portrait_center := CenterContainer.new()
	portrait_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	portrait_center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(portrait_center)

	_portrait_button = Button.new()
	_portrait_button.name = "PortraitButton"
	_portrait_button.custom_minimum_size = Vector2(214, 176)
	_portrait_button.focus_mode = Control.FOCUS_ALL
	_portrait_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_portrait_button.add_theme_stylebox_override("normal", _portrait_style(false))
	_portrait_button.add_theme_stylebox_override("hover", _portrait_style(true))
	_portrait_button.add_theme_stylebox_override("focus", _portrait_style(true))
	_portrait_button.add_theme_stylebox_override("pressed", _portrait_style(true))
	_portrait_button.mouse_entered.connect(_show_details)
	_portrait_button.mouse_exited.connect(_hide_details)
	_portrait_button.focus_entered.connect(_show_details)
	_portrait_button.focus_exited.connect(_hide_details)
	portrait_center.add_child(_portrait_button)

	_portrait = TextureRect.new()
	_portrait.name = "Portrait"
	_portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_portrait.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_portrait_button.add_child(_portrait)

	_name_label = Label.new()
	_name_label.name = "NameLabel"
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.add_theme_font_size_override("font_size", 18)
	_name_label.add_theme_color_override("font_color", Tokens.DEEP_TEAL if _side == Side.PLAYER else Tokens.CINNABAR)
	_name_label.add_theme_constant_override("outline_size", 4)
	_name_label.add_theme_color_override("font_outline_color", Tokens.with_alpha(Tokens.PAPER_BRIGHT, 0.94))
	# Names are secondary intelligence, not persistent battlefield chrome.
	_name_label.visible = false
	column.add_child(_name_label)

	var troop_row := _status_bar(Tokens.CINNABAR, "TroopStatus")
	_troop_bar = troop_row.bar
	_troop_label = troop_row.label
	column.add_child(_centered_status(troop_row.root, "TroopStatusCenter"))
	var morale_row := _status_bar(Tokens.DEEP_TEAL, "MoraleStatus")
	_morale_bar = morale_row.bar
	_morale_label = morale_row.label
	column.add_child(_centered_status(morale_row.root, "MoraleStatusCenter"))

	_detail_panel = PanelContainer.new()
	_detail_panel.name = "DetailPanel"
	_detail_panel.visible = false
	_detail_panel.z_index = 40
	_detail_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detail_panel.position = Vector2(236, 38) if _side == Side.PLAYER else Vector2(-246, 38)
	_detail_panel.size = Vector2(238, 146)
	_detail_panel.add_theme_stylebox_override("panel", Tokens.panel_style(
		Tokens.with_alpha(Tokens.PAPER_BRIGHT, 0.98),
		Tokens.MINERAL_GREEN if _side == Side.PLAYER else Tokens.CINNABAR,
		Tokens.RADIUS_MD,
		2,
		Tokens.SPACE_MD
	))
	add_child(_detail_panel)

	_detail_label = Label.new()
	_detail_label.name = "DetailLabel"
	_detail_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_detail_label.add_theme_font_size_override("font_size", 16)
	_detail_label.add_theme_color_override("font_color", Tokens.DEEP_TEAL_DARK)
	_detail_panel.add_child(_detail_label)


func _centered_status(status: Control, node_name: String) -> CenterContainer:
	var center := CenterContainer.new()
	center.name = node_name
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(status)
	return center


func _status_bar(fill_color: Color, node_name: String) -> Dictionary:
	var root := Control.new()
	root.name = node_name
	root.custom_minimum_size = Vector2(170, 20)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bar := TextureProgressBar.new()
	bar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.texture_under = STATUS_BRUSH_MASK
	bar.texture_progress = STATUS_BRUSH_MASK
	bar.tint_under = Tokens.with_alpha(Tokens.DEEP_TEAL_DARK, 0.62)
	bar.tint_progress = fill_color
	bar.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	root.add_child(bar)
	var label := Label.new()
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 15)
	label.add_theme_color_override("font_color", Tokens.PAPER_BRIGHT)
	label.add_theme_constant_override("outline_size", 0)
	root.add_child(label)
	return {"root": root, "bar": bar, "label": label}


func _portrait_style(emphasized: bool) -> StyleBoxFlat:
	var border := Tokens.with_alpha(Tokens.FOCUS, 0.82) if emphasized else Color.TRANSPARENT
	return Tokens.panel_style(Color.TRANSPARENT, border, Tokens.RADIUS_MD, 2 if emphasized else 0, 0)


func _apply_snapshot() -> void:
	if _portrait == null:
		return
	_name_label.text = _display_name()
	_name_label.add_theme_color_override("font_color", Tokens.DEEP_TEAL if _side == Side.PLAYER else Tokens.CINNABAR)
	_portrait.texture = _catalog.texture(_asset_id())
	var fallback_id := "general.fallback" if _side == Side.PLAYER else "enemy.fallback"
	if _portrait.texture == null:
		_portrait.texture = _catalog.texture(fallback_id)
	_portrait.flip_h = _side == Side.ENEMY
	var troops := int(_snapshot.get("troops", 0))
	var max_troops := maxi(int(_snapshot.get("max_troops", troops)), 1)
	var morale := int(_snapshot.get("morale", 0))
	var max_morale := maxi(int(_snapshot.get("max_morale", morale)), 1)
	_troop_bar.max_value = max_troops
	_troop_bar.value = clampi(troops, 0, max_troops)
	_troop_label.text = "%d/%d" % [troops, max_troops]
	_morale_bar.max_value = max_morale
	_morale_bar.value = clampi(morale, 0, max_morale)
	_morale_label.text = "%d/%d" % [morale, max_morale]
	_detail_label.text = _format_detail()
	_detail_panel.position = Vector2(236, 38) if _side == Side.PLAYER else Vector2(-246, 38)
	_detail_panel.add_theme_stylebox_override("panel", Tokens.panel_style(
		Tokens.with_alpha(Tokens.PAPER_BRIGHT, 0.98),
		Tokens.MINERAL_GREEN if _side == Side.PLAYER else Tokens.CINNABAR,
		Tokens.RADIUS_MD,
		2,
		Tokens.SPACE_MD
	))
	_portrait_button.tooltip_text = "%s｜悬停或聚焦查看详细军情" % _display_name()
	_portrait_button.accessibility_name = "%s，%s，%s" % [_display_name(), _troop_label.text, _morale_label.text]
	_portrait_button.add_theme_stylebox_override("normal", _portrait_style(false))
	_portrait_button.add_theme_stylebox_override("hover", _portrait_style(true))
	_portrait_button.add_theme_stylebox_override("focus", _portrait_style(true))


func _show_details() -> void:
	if _detail_panel == null:
		return
	_detail_panel.visible = true
	z_index = 30
	detail_visibility_changed.emit(true)


func _hide_details() -> void:
	if _detail_panel == null:
		return
	_detail_panel.visible = false
	z_index = 0
	detail_visibility_changed.emit(false)


func _display_name() -> String:
	var prefix := "率军武将" if _side == Side.PLAYER else "敌军"
	return "%s · %s" % [prefix, String(_snapshot.get("name", _snapshot.get("id", "未明")))]


func _asset_id() -> String:
	var combatant_id := String(_snapshot.get("id", ""))
	if _side == Side.ENEMY and HEAVY_ENEMY_IDS.has(combatant_id):
		return "combatant.government.heavy"
	match _dominant_army_type():
		"archer":
			return "combatant.rebel.archer" if _side == Side.PLAYER else "combatant.government.archer"
		"cavalry":
			return "combatant.rebel.cavalry"
		_:
			return "combatant.rebel.infantry" if _side == Side.PLAYER else "combatant.government.infantry"


func _dominant_army_type() -> String:
	var composition: Dictionary = _snapshot.get("army_composition", {})
	var dominant := "infantry"
	var dominant_ratio := float(composition.get(dominant, 0.0))
	for army_type in ["archer", "cavalry"]:
		var ratio := float(composition.get(army_type, 0.0))
		if ratio > dominant_ratio:
			dominant = army_type
			dominant_ratio = ratio
	return dominant


func _format_detail() -> String:
	return "%s\n护甲 %d　攻击 %d　防御 %d\n%s" % [
		_display_name(),
		int(_snapshot.get("armor", 0)),
		roundi(float(_snapshot.get("attack", 0))),
		roundi(float(_snapshot.get("defense", 0))),
		_format_army(_snapshot.get("army_composition", {})),
	]


func _format_army(composition: Dictionary) -> String:
	if composition.is_empty():
		return "兵种构成：未侦明"
	return "兵种　步 %d%% · 弓 %d%% · 骑 %d%%" % [
		roundi(float(composition.get("infantry", 0.0)) * 100.0),
		roundi(float(composition.get("archer", 0.0)) * 100.0),
		roundi(float(composition.get("cavalry", 0.0)) * 100.0),
	]
