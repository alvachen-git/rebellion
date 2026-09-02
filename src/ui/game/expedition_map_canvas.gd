extends Control
class_name ExpeditionMapCanvas

signal node_selected(node_id: String)

const Tokens := preload("res://src/ui/theme/visual_tokens.gd")
const MotionPolicyScript := preload("res://src/ui/presentation/motion_policy.gd")
const BRONZE := Tokens.LIGHT_GOLD_DARK
const PARCHMENT := Tokens.PAPER_BRIGHT
const MUTED := Tokens.INK_SOFT
const ROUTE_Y := {
	"official_road": 0.2,
	"village_path": 0.42,
	"grain_route": 0.64,
	"shared": 0.42,
	"intel_route": 0.22,
	"supply_route": 0.42,
	"wealth_route": 0.64,
}

var _nodes: Array = []
var _edges: Array = []
var _route: Dictionary = {}
var _positions: Dictionary = {}


func _ready() -> void:
	custom_minimum_size = Vector2(0, 430)
	resized.connect(_rebuild)


func configure(nodes: Array, edges: Array, route: Dictionary) -> void:
	_nodes = nodes.duplicate(true)
	_edges = edges.duplicate(true)
	_route = route.duplicate(true)
	_rebuild()


func button_for_node(node_id: String) -> Button:
	for child in get_children():
		if child is Button and child.get_meta("node_id", "") == node_id:
			return child
	return null


func _rebuild() -> void:
	for child in get_children():
		child.queue_free()
	_positions.clear()
	if _nodes.is_empty() or size.x <= 0.0:
		queue_redraw()
		return
	var usable_width := maxf(size.x - 190.0, 760.0)
	for node in _nodes:
		if not node is Dictionary:
			continue
		var column := float(node.get("column", 0.0))
		var route_name := String(node.get("route", "shared"))
		var y_ratio := float(ROUTE_Y.get(route_name, 0.42))
		if node.get("id", "") in ["heyuan.start", "heyuan.merge.elite", "heyuan.county_seat"]:
			y_ratio = 0.42
		var center := Vector2(90.0 + usable_width * column / 6.0, 58.0 + (size.y - 130.0) * y_ratio)
		_positions[String(node.get("id", ""))] = center
		var button := Button.new()
		button.name = "Node_%s" % String(node.get("id", "")).replace(".", "_").replace("-", "_")
		button.set_meta("node_id", String(node.get("id", "")))
		button.position = center - Vector2(76.0, 28.0)
		button.size = Vector2(152.0, 56.0)
		button.text = _node_label(node)
		button.tooltip_text = String(node.get("presentation", {}).get("description", ""))
		button.disabled = not _route.get("available_next_node_ids", []).has(node.get("id", ""))
		_apply_node_style(button, node)
		button.pressed.connect(_emit_node_selected.bind(String(node.get("id", ""))))
		add_child(button)
		if MotionPolicyScript.reduced():
			button.modulate.a = 1.0
			continue
		button.modulate.a = 0.0
		button.scale = Vector2(0.94, 0.94)
		var tween := create_tween().set_parallel(true)
		var delay := minf(column * 0.035, 0.22)
		tween.tween_property(button, "modulate:a", 1.0, 0.18).set_delay(delay)
		tween.tween_property(button, "scale", Vector2.ONE, 0.18).set_delay(delay).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	queue_redraw()


func _emit_node_selected(node_id: String) -> void:
	node_selected.emit(node_id)


func _draw() -> void:
	draw_rect(Rect2(Vector2(10.0, 10.0), size - Vector2(20.0, 20.0)), Tokens.with_alpha(Tokens.PAPER_BRIGHT, 0.88))
	draw_line(Vector2(10.0, 10.0), Vector2(size.x - 10.0, 10.0), Tokens.with_alpha(BRONZE, 0.34), 1.0)
	for edge in _edges:
		if not edge is Dictionary:
			continue
		var from_id := String(edge.get("from", ""))
		var to_id := String(edge.get("to", ""))
		if not _positions.has(from_id) or not _positions.has(to_id):
			continue
		var visited: bool = _route.get("visited_node_ids", []).has(from_id) and _route.get("visited_node_ids", []).has(to_id)
		var color := Tokens.with_alpha(BRONZE, 0.94) if visited else Tokens.DISABLED
		draw_line(_positions[from_id], _positions[to_id], color, 4.0 if visited else 2.5, true)


func _node_label(node: Dictionary) -> String:
	var names := {
		"normal_combat": "战",
		"elite_combat": "锐",
		"military_objective": "据",
		"wealth_risk": "险",
		"event": "事",
		"loot": "获",
		"supply": "补",
		"intel": "谍",
		"boss": "城",
		"start": "营",
		"unknown": "?",
	}
	return "%s  %s" % [names.get(node.get("node_type", "unknown"), "·"), node.get("name", "未知")]


func _apply_node_style(button: Button, node: Dictionary) -> void:
	var node_id := String(node.get("id", ""))
	var visited: bool = _route.get("visited_node_ids", []).has(node_id)
	var completed: bool = _route.get("completed_node_ids", []).has(node_id)
	var available: bool = _route.get("available_next_node_ids", []).has(node_id)
	var normal := StyleBoxFlat.new()
	if available:
		normal.bg_color = Tokens.CINNABAR
	elif completed:
		normal.bg_color = Tokens.MINERAL_GREEN
	elif bool(node.get("is_revealed", false)):
		normal.bg_color = Tokens.PAPER
	else:
		normal.bg_color = Tokens.PAPER_SHADE
	normal.border_color = BRONZE if available else Tokens.DISABLED
	normal.set_border_width_all(2 if available else 1)
	normal.set_corner_radius_all(5)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("disabled", normal)
	var hover := normal.duplicate()
	hover.bg_color = Tokens.DEEP_TEAL
	hover.border_color = PARCHMENT
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_color_override("font_color", Tokens.PAPER_BRIGHT if available else Tokens.DEEP_TEAL)
	button.add_theme_color_override("font_disabled_color", Tokens.DEEP_TEAL if bool(node.get("is_revealed", false)) else Tokens.DISABLED)
	button.add_theme_font_size_override("font_size", 15)
	if completed:
		button.text += "  ✓"
