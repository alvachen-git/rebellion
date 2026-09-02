extends RefCounted
class_name VisualTokens

## “青绿绘卷卡阵”唯一颜色、间距与形状来源。
## 页面脚本可以选择语义 Token，但不得自行复制十六进制颜色。

const DEEP_TEAL := Color("#103B42")
const DEEP_TEAL_DARK := Color("#08282E")
const INK := Color("#202722")
const INK_SOFT := Color("#4B5751")
const MINERAL_GREEN := Color("#4E7F78")
const MOUNTAIN_BLUE := Color("#7EAFB7")
const MIST := Color("#DCEBE9")
const PAPER := Color("#F3EAD6")
const PAPER_BRIGHT := Color("#FFF9EA")
const PAPER_SHADE := Color("#D9CBAE")
const LIGHT_GOLD := Color("#C9A95C")
const LIGHT_GOLD_DARK := Color("#8D7439")
const CINNABAR := Color("#A74331")
const CINNABAR_SOFT := Color("#D67A65")
const SUCCESS := Color("#4F7C5D")
const DISABLED := Color("#8A918A")
const FOCUS := Color("#E8C96E")

const SPACE_XS := 4
const SPACE_SM := 8
const SPACE_MD := 12
const SPACE_LG := 18
const SPACE_XL := 28

const RADIUS_SM := 4
const RADIUS_MD := 8
const RADIUS_LG := 12

const FONT_CAPTION := 13
const FONT_BODY := 16
const FONT_BODY_LARGE := 18
const FONT_HEADING := 24
const FONT_TITLE := 38

const MOTION_FAST := 0.10
const MOTION_NORMAL := 0.18
const MOTION_SLOW := 0.34


static func panel_style(
		fill: Color = PAPER,
		border: Color = LIGHT_GOLD_DARK,
		radius: int = RADIUS_MD,
		border_width: int = 1,
		content_margin: int = SPACE_MD
	) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(radius)
	style.content_margin_left = content_margin
	style.content_margin_top = content_margin
	style.content_margin_right = content_margin
	style.content_margin_bottom = content_margin
	return style


static func outlined_style(fill: Color, border: Color, emphasized := false) -> StyleBoxFlat:
	return panel_style(fill, border, RADIUS_MD, 2 if emphasized else 1, SPACE_MD)


static func with_alpha(color: Color, alpha: float) -> Color:
	return Color(color, alpha)
