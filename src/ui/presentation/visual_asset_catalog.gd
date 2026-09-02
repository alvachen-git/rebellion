extends RefCounted
class_name VisualAssetCatalog

const CATALOG_PATH := "res://data/presentation/visual_assets.json"

var _entries: Dictionary = {}
var _errors: PackedStringArray = []


func load_catalog(path := CATALOG_PATH) -> bool:
	_entries.clear()
	_errors.clear()
	if not FileAccess.file_exists(path):
		_errors.append("表现资产目录不存在：%s" % path)
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_errors.append("表现资产目录无法读取：%s" % path)
		return false
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		_errors.append("表现资产目录必须是 JSON Object：%s" % path)
		return false
	var assets = parsed.get("assets", {})
	if not assets is Dictionary:
		_errors.append("表现资产目录 assets 必须是 Object")
		return false
	_entries = assets.duplicate(true)
	return true


func entry(stable_id: String) -> Dictionary:
	return _entries.get(stable_id, {}).duplicate(true)


func texture(stable_id: String) -> Texture2D:
	var asset := entry(stable_id)
	var path := String(asset.get("path", ""))
	if path.is_empty() or not ResourceLoader.exists(path, "Texture2D"):
		return null
	var resource = load(path)
	return resource if resource is Texture2D else null


func validate(required_ids: Array) -> PackedStringArray:
	var result := PackedStringArray()
	for stable_id_value in required_ids:
		var stable_id := String(stable_id_value)
		if not _entries.has(stable_id):
			result.append("表现资产未登记：%s" % stable_id)
			continue
		var path := String(_entries[stable_id].get("path", ""))
		if path.is_empty():
			result.append("表现资产路径为空：%s" % stable_id)
		elif not FileAccess.file_exists(path) and not ResourceLoader.exists(path):
			result.append("表现资产路径不存在：%s -> %s" % [stable_id, path])
	return result


func errors() -> PackedStringArray:
	return _errors.duplicate()
