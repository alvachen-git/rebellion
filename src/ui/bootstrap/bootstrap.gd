extends Control

const ContentRegistryScript := preload("res://src/domain/content/content_registry.gd")

@onready var status_label: Label = $Margin/Content/Status


func _ready() -> void:
	var registry := ContentRegistryScript.new()
	if registry.load_all():
		status_label.text = "工程启动成功 · 已载入 %d 张开发样例卡" % registry.card_count()
		status_label.modulate = Color(0.55, 0.82, 0.58)
	else:
		status_label.text = "内容校验失败：\n%s" % "\n".join(registry.get_errors())
		status_label.modulate = Color(0.92, 0.45, 0.4)
