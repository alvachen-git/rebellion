extends RefCounted
class_name QingluTheme

const Tokens := preload("res://src/ui/theme/visual_tokens.gd")
const SANS_PATH := "res://assets/fonts/source_han/SourceHanSansCN-VF.ttf"
const SERIF_PATH := "res://assets/fonts/source_han/SourceHanSerifCN-VF.ttf"


static func create() -> Theme:
	var result := Theme.new()
	var sans = load(SANS_PATH)
	if sans is Font:
		result.default_font = sans
	result.default_font_size = Tokens.FONT_BODY

	_configure_labels(result)
	_configure_panels(result)
	_configure_buttons(result)
	_configure_inputs(result)
	_configure_scrollbars(result)
	_configure_separators(result)
	return result


static func serif_font() -> Font:
	var resource = load(SERIF_PATH)
	return resource if resource is Font else null


static func _configure_labels(theme: Theme) -> void:
	theme.set_color("font_color", "Label", Tokens.INK)
	theme.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0))
	theme.set_type_variation("QingluTitle", "Label")
	theme.set_font_size("font_size", "QingluTitle", Tokens.FONT_TITLE)
	theme.set_color("font_color", "QingluTitle", Tokens.DEEP_TEAL)
	var serif := serif_font()
	if serif != null:
		theme.set_font("font", "QingluTitle", serif)
	theme.set_type_variation("QingluHeading", "Label")
	theme.set_font_size("font_size", "QingluHeading", Tokens.FONT_HEADING)
	theme.set_color("font_color", "QingluHeading", Tokens.DEEP_TEAL)
	if serif != null:
		theme.set_font("font", "QingluHeading", serif)
	theme.set_type_variation("QingluMuted", "Label")
	theme.set_color("font_color", "QingluMuted", Tokens.INK_SOFT)
	theme.set_type_variation("QingluCaption", "Label")
	theme.set_font_size("font_size", "QingluCaption", Tokens.FONT_CAPTION)
	theme.set_color("font_color", "QingluCaption", Tokens.INK_SOFT)
	theme.set_type_variation("QingluGold", "Label")
	theme.set_color("font_color", "QingluGold", Tokens.LIGHT_GOLD_DARK)
	theme.set_type_variation("QingluDanger", "Label")
	theme.set_color("font_color", "QingluDanger", Tokens.CINNABAR)
	theme.set_type_variation("QingluSuccess", "Label")
	theme.set_color("font_color", "QingluSuccess", Tokens.SUCCESS)


static func _configure_panels(theme: Theme) -> void:
	theme.set_stylebox("panel", "PanelContainer", Tokens.panel_style(
		Tokens.with_alpha(Tokens.PAPER, 0.96), Tokens.with_alpha(Tokens.LIGHT_GOLD_DARK, 0.58), Tokens.RADIUS_MD, 1, Tokens.SPACE_MD
	))
	theme.set_type_variation("QingluDarkPanel", "PanelContainer")
	theme.set_stylebox("panel", "QingluDarkPanel", Tokens.panel_style(
		Tokens.with_alpha(Tokens.DEEP_TEAL, 0.96), Tokens.LIGHT_GOLD_DARK, Tokens.RADIUS_MD, 1, Tokens.SPACE_MD
	))
	theme.set_type_variation("QingluPaperPanel", "PanelContainer")
	theme.set_stylebox("panel", "QingluPaperPanel", Tokens.panel_style(
		Tokens.with_alpha(Tokens.PAPER_BRIGHT, 0.97), Tokens.PAPER_SHADE, Tokens.RADIUS_MD, 1, Tokens.SPACE_MD
	))


static func _configure_buttons(theme: Theme) -> void:
	var normal := Tokens.panel_style(Tokens.PAPER, Tokens.PAPER_SHADE, Tokens.RADIUS_SM, 1, Tokens.SPACE_SM)
	var hover := normal.duplicate()
	hover.bg_color = Tokens.PAPER_BRIGHT
	hover.border_color = Tokens.MINERAL_GREEN
	var pressed := normal.duplicate()
	pressed.bg_color = Tokens.MIST
	pressed.border_color = Tokens.DEEP_TEAL
	var disabled := normal.duplicate()
	disabled.bg_color = Tokens.PAPER_SHADE.lightened(0.18)
	disabled.border_color = Tokens.DISABLED
	var focus := hover.duplicate()
	focus.border_color = Tokens.FOCUS
	focus.set_border_width_all(2)
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		theme.set_stylebox(state, "Button", {"normal": normal, "hover": hover, "pressed": pressed, "disabled": disabled, "focus": focus}[state])
	theme.set_color("font_color", "Button", Tokens.DEEP_TEAL)
	theme.set_color("font_hover_color", "Button", Tokens.DEEP_TEAL_DARK)
	theme.set_color("font_pressed_color", "Button", Tokens.DEEP_TEAL_DARK)
	theme.set_color("font_disabled_color", "Button", Tokens.DISABLED)
	theme.set_type_variation("QingluPrimaryButton", "Button")
	var primary := Tokens.panel_style(Tokens.DEEP_TEAL, Tokens.LIGHT_GOLD, Tokens.RADIUS_SM, 1, Tokens.SPACE_SM)
	var primary_hover := primary.duplicate()
	primary_hover.bg_color = Tokens.MINERAL_GREEN
	primary_hover.border_color = Tokens.PAPER_BRIGHT
	var primary_pressed := primary.duplicate()
	primary_pressed.bg_color = Tokens.DEEP_TEAL_DARK
	var primary_disabled := primary.duplicate()
	primary_disabled.bg_color = Tokens.DISABLED.darkened(0.25)
	primary_disabled.border_color = Tokens.DISABLED
	theme.set_stylebox("normal", "QingluPrimaryButton", primary)
	theme.set_stylebox("hover", "QingluPrimaryButton", primary_hover)
	theme.set_stylebox("focus", "QingluPrimaryButton", primary_hover)
	theme.set_stylebox("pressed", "QingluPrimaryButton", primary_pressed)
	theme.set_stylebox("disabled", "QingluPrimaryButton", primary_disabled)
	for color_name in ["font_color", "font_hover_color", "font_pressed_color"]:
		theme.set_color(color_name, "QingluPrimaryButton", Tokens.PAPER_BRIGHT)
	theme.set_color("font_disabled_color", "QingluPrimaryButton", Tokens.MIST)


static func _configure_inputs(theme: Theme) -> void:
	for type_name in ["OptionButton", "SpinBox", "LineEdit"]:
		theme.set_color("font_color", type_name, Tokens.DEEP_TEAL)
	theme.set_stylebox("normal", "LineEdit", Tokens.panel_style(Tokens.PAPER_BRIGHT, Tokens.PAPER_SHADE, Tokens.RADIUS_SM, 1, Tokens.SPACE_SM))
	theme.set_stylebox("focus", "LineEdit", Tokens.panel_style(Tokens.PAPER_BRIGHT, Tokens.FOCUS, Tokens.RADIUS_SM, 2, Tokens.SPACE_SM))


static func _configure_scrollbars(theme: Theme) -> void:
	var transparent := StyleBoxEmpty.new()
	theme.set_stylebox("scroll", "VScrollBar", transparent)
	theme.set_stylebox("scroll_focus", "VScrollBar", transparent)
	theme.set_stylebox("grabber", "VScrollBar", Tokens.panel_style(Tokens.MINERAL_GREEN, Tokens.MINERAL_GREEN, 4, 0, 2))
	theme.set_stylebox("grabber_highlight", "VScrollBar", Tokens.panel_style(Tokens.MOUNTAIN_BLUE, Tokens.MOUNTAIN_BLUE, 4, 0, 2))
	theme.set_stylebox("grabber_pressed", "VScrollBar", Tokens.panel_style(Tokens.DEEP_TEAL, Tokens.DEEP_TEAL, 4, 0, 2))


static func _configure_separators(theme: Theme) -> void:
	var horizontal := StyleBoxLine.new()
	horizontal.color = Tokens.with_alpha(Tokens.LIGHT_GOLD_DARK, 0.46)
	horizontal.thickness = 1
	theme.set_stylebox("separator", "HSeparator", horizontal)
	var vertical := StyleBoxLine.new()
	vertical.color = Tokens.with_alpha(Tokens.LIGHT_GOLD_DARK, 0.36)
	vertical.thickness = 1
	vertical.vertical = true
	theme.set_stylebox("separator", "VSeparator", vertical)
