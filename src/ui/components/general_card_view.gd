extends Button
class_name GeneralCardView

const Tokens := preload("res://src/ui/theme/visual_tokens.gd")
const AssetCatalogScript := preload("res://src/ui/presentation/visual_asset_catalog.gd")

enum Density { FULL, COMPACT }

var _snapshot: Dictionary = {}
var _selection_state: Dictionary = {}
var _density := Density.FULL
var _catalog = AssetCatalogScript.new()


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	if _snapshot.is_empty():
		configure({"general_id": "general.placeholder", "name": "待命武将", "level": 1}, {}, _density)


func configure(snapshot: Dictionary, selection_state := {}, density := Density.FULL) -> void:
	_snapshot = snapshot.duplicate(true)
	_selection_state = selection_state.duplicate(true)
	_density = int(density)
	if _catalog.entry("general.fallback").is_empty():
		_catalog.load_catalog()
	_rebuild()


func general_id() -> String:
	return String(_snapshot.get("general_id", _snapshot.get("id", "")))


func _rebuild() -> void:
	for child in get_children():
		child.free()
	# 根按钮保留状态文本，兼容键盘/读屏语义和既有自动化；实际可见排版由子 Label 完成。
	text = "%s · Lv.%d · %s" % [_snapshot.get("name", "武将"), int(_snapshot.get("level", 1)), _status_text()]
	for color_name in ["font_color", "font_hover_color", "font_pressed_color", "font_disabled_color"]:
		add_theme_color_override(color_name, Color.TRANSPARENT)
	custom_minimum_size = Vector2(206, 304) if _density == Density.FULL else Vector2(270, 76)
	if _density == Density.COMPACT:
		_build_compact()
	else:
		_build_full()
	_apply_style()


func _build_full() -> void:
	var margin := _margin(10)
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 7)
	var portrait := _portrait(150)
	column.add_child(portrait)
	var name := _label("%s  ·  Lv.%d" % [_snapshot.get("name", "武将"), int(_snapshot.get("level", 1))], 22, Tokens.DEEP_TEAL)
	name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(name)
	column.add_child(_label(_attributes(), 14, Tokens.INK_SOFT))
	column.add_child(_label(_build_name(), 13, Tokens.LIGHT_GOLD_DARK))
	column.add_child(_label(_status_text(), 13, _status_color()))
	margin.add_child(column)
	add_child(margin)


func _build_compact() -> void:
	var margin := _margin(8)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 10)
	row.add_child(_portrait(58))
	var text_column := VBoxContainer.new()
	text_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_column.add_child(_label("%s  ·  Lv.%d" % [_snapshot.get("name", "武将"), int(_snapshot.get("level", 1))], 17, Tokens.DEEP_TEAL))
	text_column.add_child(_label("%s · %s" % [_build_name(), _status_text()], 12, _status_color()))
	row.add_child(text_column)
	margin.add_child(row)
	add_child(margin)


func _portrait(height: int) -> Control:
	var holder := PanelContainer.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.custom_minimum_size = Vector2(height * 0.78, height)
	holder.add_theme_stylebox_override("panel", Tokens.panel_style(Tokens.MIST, Tokens.MINERAL_GREEN, 4, 1, 0))
	var texture := _catalog.texture(general_id())
	if texture == null:
		texture = _catalog.texture("general.fallback")
	if texture != null:
		var image := TextureRect.new()
		image.mouse_filter = Control.MOUSE_FILTER_IGNORE
		image.texture = texture
		image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		holder.add_child(image)
	else:
		var seal := _label(String(_snapshot.get("name", "将")).left(1), 36, Tokens.MINERAL_GREEN)
		seal.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		seal.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		holder.add_child(seal)
	return holder


func _apply_style() -> void:
	var selected := bool(_selection_state.get("selected", false))
	var available := bool(_selection_state.get("available", _status_text() == "可出征"))
	var border := Tokens.CINNABAR if selected else Tokens.LIGHT_GOLD_DARK
	var normal := Tokens.panel_style(Tokens.PAPER_BRIGHT if available else Tokens.PAPER_SHADE.lightened(0.15), border, Tokens.RADIUS_MD, 2 if selected else 1, 0)
	var hover := normal.duplicate()
	hover.bg_color = Tokens.MIST.lightened(0.22)
	hover.border_color = Tokens.FOCUS
	add_theme_stylebox_override("normal", normal)
	add_theme_stylebox_override("hover", hover)
	add_theme_stylebox_override("focus", hover)
	add_theme_stylebox_override("pressed", hover)
	add_theme_stylebox_override("disabled", normal)
	disabled = not available
	modulate = Color.WHITE if available else Color(1, 1, 1, 0.72)
	tooltip_text = "%s｜%s｜%s" % [_snapshot.get("name", "武将"), _build_name(), _status_text()]


func _attributes() -> String:
	var attributes: Dictionary = _snapshot.get("attributes", {})
	if attributes.is_empty():
		return "属性待命"
	return "武勇 %d  统率 %d  政务 %d" % [int(attributes.get("martial", 0)), int(attributes.get("leadership", 0)), int(attributes.get("administration", 0))]


func _build_name() -> String:
	var presentation: Dictionary = _snapshot.get("presentation", {})
	return String(presentation.get("build_name", _selection_state.get("build_name", "义军武将")))


func _status_text() -> String:
	if String(_snapshot.get("status", "active")) == "deceased":
		return "阵亡"
	var injury: Dictionary = _snapshot.get("injury", {})
	var injury_status := String(_snapshot.get("injury_status", injury.get("status", "healthy")))
	if injury_status != "healthy":
		return "重伤 · 不可出征"
	if not bool(_selection_state.get("available", true)):
		return String(_selection_state.get("reason", "不可出征"))
	return "可出征"


func _status_color() -> Color:
	return Tokens.SUCCESS if _status_text() == "可出征" else Tokens.CINNABAR


func _margin(amount: int) -> MarginContainer:
	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, amount)
	return margin


func _label(value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label
