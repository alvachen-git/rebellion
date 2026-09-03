extends Button
class_name CardView

const Tokens := preload("res://src/ui/theme/visual_tokens.gd")
const AssetCatalogScript := preload("res://src/ui/presentation/visual_asset_catalog.gd")

enum Density { FULL, COMPACT, THUMBNAIL }

const FULL_SIZE := Vector2(156, 234)
const COMPACT_SIZE := Vector2(280, 44)
const THUMBNAIL_SIZE := Vector2(78, 117)

var _card: Dictionary = {}
var _runtime_state: Dictionary = {}
var _preview_damage := 0
var _density := Density.FULL
var _catalog = AssetCatalogScript.new()


func _ready() -> void:
	text = ""
	clip_contents = false
	focus_mode = Control.FOCUS_ALL
	if _card.is_empty():
		configure({"id": "card.placeholder", "name": "待命军令", "cost": 0, "presentation": {"description": "卡牌表现占位"}}, {}, 0, _density)


func configure(card_definition: Dictionary, runtime_state := {}, preview_damage := 0, density := Density.FULL) -> void:
	_card = card_definition.duplicate(true)
	_runtime_state = runtime_state.duplicate(true)
	_preview_damage = int(preview_damage)
	_density = int(density)
	if _catalog.entry("card.fallback").is_empty():
		_catalog.load_catalog()
	_rebuild()


func card_id() -> String:
	return String(_card.get("id", ""))


func display_density() -> int:
	return _density


func availability_reason() -> String:
	return String(_runtime_state.get("reason", ""))


func _rebuild() -> void:
	for child in get_children():
		child.free()
	text = ""
	if bool(_runtime_state.get("face_down", false)):
		_build_back()
	elif _density == Density.COMPACT:
		_build_compact()
	elif _density == Density.THUMBNAIL:
		_build_thumbnail()
	else:
		_build_full()
	_apply_state_style()


func _build_back() -> void:
	custom_minimum_size = THUMBNAIL_SIZE if _density == Density.THUMBNAIL else FULL_SIZE
	var margin := _content_margin(8)
	var field := PanelContainer.new()
	field.mouse_filter = Control.MOUSE_FILTER_IGNORE
	field.add_theme_stylebox_override("panel", Tokens.panel_style(Tokens.DEEP_TEAL, Tokens.LIGHT_GOLD, Tokens.RADIUS_MD, 2, Tokens.SPACE_SM))
	var seal := _label("义", 42 if _density != Density.THUMBNAIL else 24, Tokens.LIGHT_GOLD)
	seal.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	seal.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	seal.add_theme_stylebox_override("normal", Tokens.panel_style(Tokens.with_alpha(Tokens.MINERAL_GREEN, 0.62), Tokens.with_alpha(Tokens.PAPER_BRIGHT, 0.56), 32, 1, 0))
	field.add_child(seal)
	margin.add_child(field)
	add_child(margin)


func _build_full() -> void:
	custom_minimum_size = FULL_SIZE
	var margin := _content_margin(10)
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 5)
	margin.add_child(column)
	var heading := HBoxContainer.new()
	heading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cost := _label("%d" % int(_card.get("cost", 0)), 23, Tokens.PAPER_BRIGHT)
	cost.custom_minimum_size = Vector2(27, 27)
	cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cost.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cost.add_theme_stylebox_override("normal", Tokens.panel_style(Tokens.DEEP_TEAL, Tokens.LIGHT_GOLD, 14, 1, 0))
	heading.add_child(cost)
	var title := _label(String(_card.get("name", "无名军令")), 18, Tokens.DEEP_TEAL)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	heading.add_child(title)
	column.add_child(heading)
	column.add_child(_illustration(86))
	var meta := _label(_meta_text(), 11, Tokens.LIGHT_GOLD_DARK)
	meta.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	meta.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	column.add_child(meta)
	var description := _label(_description(), 13, Tokens.INK)
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(description)
	var footer := _label(_footer_text(), 11, _footer_color())
	footer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(footer)
	add_child(margin)


func _build_compact() -> void:
	custom_minimum_size = COMPACT_SIZE
	var margin := _content_margin(7)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 8)
	var cost := _label("%d令" % int(_card.get("cost", 0)), 13, Tokens.PAPER_BRIGHT)
	cost.custom_minimum_size = Vector2(37, 26)
	cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cost.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cost.add_theme_stylebox_override("normal", Tokens.panel_style(Tokens.DEEP_TEAL, Tokens.DEEP_TEAL, 13, 0, 0))
	row.add_child(cost)
	var title := _label(String(_card.get("name", "无名军令")), 15, Tokens.DEEP_TEAL)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(title)
	var status := _label(_compact_status(), 12, _footer_color())
	status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(status)
	margin.add_child(row)
	add_child(margin)


func _build_thumbnail() -> void:
	custom_minimum_size = THUMBNAIL_SIZE
	var margin := _content_margin(6)
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 3)
	var cost := _label("%d" % int(_card.get("cost", 0)), 16, Tokens.PAPER_BRIGHT)
	cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cost.add_theme_stylebox_override("normal", Tokens.panel_style(Tokens.DEEP_TEAL, Tokens.DEEP_TEAL, 10, 0, 0))
	column.add_child(cost)
	column.add_child(_illustration(53))
	var title := _label(String(_card.get("name", "军令")), 11, Tokens.DEEP_TEAL)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)
	margin.add_child(column)
	add_child(margin)


func _content_margin(amount: int) -> MarginContainer:
	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, amount)
	return margin


func _illustration(height: int) -> Control:
	var holder := PanelContainer.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.custom_minimum_size = Vector2(0, height)
	holder.add_theme_stylebox_override("panel", Tokens.panel_style(Tokens.MIST, Tokens.with_alpha(Tokens.MINERAL_GREEN, 0.5), 4, 1, 0))
	var texture := _catalog.texture(card_id())
	if texture == null:
		texture = _catalog.texture("card.fallback")
	if texture != null:
		var image := TextureRect.new()
		image.mouse_filter = Control.MOUSE_FILTER_IGNORE
		image.texture = texture
		image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		holder.add_child(image)
	else:
		var motif := _label(_motif_glyph(), 28, Tokens.MINERAL_GREEN)
		motif.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		motif.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		holder.add_child(motif)
	return holder


func _apply_state_style() -> void:
	var available := bool(_runtime_state.get("available", true))
	var selected := bool(_runtime_state.get("selected", false))
	var locked := bool(_runtime_state.get("locked", false))
	var upgraded := bool(_runtime_state.get("upgraded", false))
	var base_fill := Tokens.PAPER_BRIGHT if available else Tokens.PAPER_SHADE.lightened(0.2)
	var border := Tokens.CINNABAR if selected else (Tokens.LIGHT_GOLD if upgraded else Tokens.LIGHT_GOLD_DARK)
	if locked:
		border = Tokens.DISABLED
	var normal := Tokens.panel_style(base_fill, border, Tokens.RADIUS_MD, 2 if selected or upgraded else 1, 0)
	var hover := normal.duplicate()
	hover.bg_color = Tokens.MIST.lightened(0.28)
	hover.border_color = Tokens.FOCUS
	var pressed := hover.duplicate()
	pressed.bg_color = Tokens.MIST
	var disabled_style := normal.duplicate()
	disabled_style.bg_color = Tokens.PAPER_SHADE.lightened(0.12)
	add_theme_stylebox_override("normal", normal)
	add_theme_stylebox_override("hover", hover)
	add_theme_stylebox_override("focus", hover)
	add_theme_stylebox_override("pressed", pressed)
	add_theme_stylebox_override("disabled", disabled_style)
	disabled = not available
	tooltip_text = _tooltip()
	# Disabled cards stay unmistakably muted, but remain readable over the new
	# continuous illustrated battlefield rather than disappearing into it.
	modulate = Color(1, 1, 1, 0.9) if not available else Color.WHITE


func _description() -> String:
	var presentation = _card.get("presentation", {})
	return String(presentation.get("description", _card.get("description", "暂无说明")))


func _meta_text() -> String:
	var values: Array[String] = []
	values.append(_rarity_name(String(_card.get("rarity", "basic"))))
	var tags: Array = _card.get("tags", [])
	if tags.has("attack"):
		values.append("攻势")
	elif tags.has("defense"):
		values.append("守势")
	if _is_exclusive():
		values.append("专属")
	return " · ".join(values)


func _footer_text() -> String:
	var values: Array[String] = []
	if _preview_damage > 0:
		values.append("预计伤害 %d" % _preview_damage)
	if bool(_runtime_state.get("exhausted", false)) or _card.get("tags", []).has("exhaust"):
		values.append("耗尽")
	if bool(_runtime_state.get("upgraded", false)):
		values.append("已升级")
	if bool(_runtime_state.get("locked", false)):
		values.append("未解锁")
	if not bool(_runtime_state.get("available", true)):
		values.append(String(_runtime_state.get("reason", "当前不可用")))
	return " · ".join(values) if not values.is_empty() else "公共军令"


func _compact_status() -> String:
	var count := int(_runtime_state.get("count", 0))
	var limit := int(_runtime_state.get("copy_limit", _card.get("copy_limit", 0)))
	if bool(_runtime_state.get("locked", false)):
		return "锁定"
	if count > 0 and limit > 0:
		return "%d/%d" % [count, limit]
	if _is_exclusive():
		return "专属"
	return _rarity_name(String(_card.get("rarity", "basic")))


func _footer_color() -> Color:
	if not bool(_runtime_state.get("available", true)) or bool(_runtime_state.get("locked", false)):
		return Tokens.CINNABAR
	if bool(_runtime_state.get("upgraded", false)):
		return Tokens.SUCCESS
	return Tokens.LIGHT_GOLD_DARK


func _tooltip() -> String:
	var status := _footer_text()
	return "%s｜%s｜%s" % [String(_card.get("name", "军令")), _description(), status]


func _motif_glyph() -> String:
	var tags: Array = _card.get("tags", [])
	if tags.has("attack"):
		return "戈"
	if tags.has("defense"):
		return "盾"
	if tags.has("morale"):
		return "旗"
	if tags.has("archery"):
		return "弩"
	if tags.has("cavalry"):
		return "骑"
	return "令"


func _is_exclusive() -> bool:
	return String(_card.get("owner_scope", "public")).begins_with("general:")


func _rarity_name(rarity: String) -> String:
	return {"basic": "基础", "advanced": "进阶", "rare": "稀有"}.get(rarity, rarity)


func _label(value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label
