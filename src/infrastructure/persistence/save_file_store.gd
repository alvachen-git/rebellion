extends RefCounted
class_name SaveFileStore

const SaveGameCodecScript := preload("res://src/infrastructure/persistence/save_game_codec.gd")
const SaveContentReferenceValidatorScript := preload("res://src/infrastructure/persistence/save_content_reference_validator.gd")

var _codec = SaveGameCodecScript.new()


func save(path: String, envelope: Dictionary, updated_at: String = "") -> Dictionary:
	if path.strip_edges().is_empty():
		return _failure("save file: path must be non-empty")
	var value := envelope.duplicate(true)
	if not updated_at.is_empty():
		value.updated_at = updated_at
	var encoded: Dictionary = _codec.encode(value)
	if not encoded.ok:
		return {"ok": false, "errors": encoded.errors, "backup_created": false}
	var final_path := ProjectSettings.globalize_path(path)
	var directory_path := final_path.get_base_dir()
	var directory_error := DirAccess.make_dir_recursive_absolute(directory_path)
	if directory_error != OK:
		return _failure("save file: cannot create directory '%s' (error %d)" % [directory_path, directory_error])
	var temporary_path := final_path + ".tmp"
	var backup_path := final_path + ".bak"
	_remove_if_present(temporary_path)
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return _failure("save file: cannot open temporary file '%s' (error %d)" % [temporary_path, FileAccess.get_open_error()])
	file.store_string(encoded.text)
	file.flush()
	file.close()
	var verified: Dictionary = _read_decoded(temporary_path)
	if not verified.ok:
		_remove_if_present(temporary_path)
		return {"ok": false, "errors": verified.errors, "backup_created": false}
	var had_primary := FileAccess.file_exists(final_path)
	var rotated_primary := false
	var preserved_backup := false
	if had_primary:
		var current_primary: Dictionary = _read_decoded(final_path)
		if current_primary.ok:
			_remove_if_present(backup_path)
			var backup_error := DirAccess.rename_absolute(final_path, backup_path)
			if backup_error != OK:
				_remove_if_present(temporary_path)
				return _failure("save file: cannot rotate primary to backup (error %d)" % backup_error)
			rotated_primary = true
		else:
			preserved_backup = FileAccess.file_exists(backup_path)
			var remove_error := DirAccess.remove_absolute(final_path)
			if remove_error != OK:
				_remove_if_present(temporary_path)
				return _failure("save file: cannot remove invalid primary before replacement (error %d)" % remove_error)
	var promote_error := DirAccess.rename_absolute(temporary_path, final_path)
	if promote_error != OK:
		if rotated_primary and FileAccess.file_exists(backup_path):
			DirAccess.rename_absolute(backup_path, final_path)
		elif preserved_backup and FileAccess.file_exists(backup_path):
			DirAccess.copy_absolute(backup_path, final_path)
		_remove_if_present(temporary_path)
		return _failure("save file: cannot promote validated temporary file (error %d)" % promote_error)
	return {
		"ok": true,
		"errors": PackedStringArray(),
		"backup_created": rotated_primary,
		"backup_preserved": preserved_backup,
		"path": final_path,
		"backup_path": backup_path if FileAccess.file_exists(backup_path) else "",
	}


func load(path: String, registry: Variant = null) -> Dictionary:
	if path.strip_edges().is_empty():
		return _load_failure("save file: path must be non-empty")
	var final_path := ProjectSettings.globalize_path(path)
	var primary: Dictionary = _read_decoded(final_path, registry)
	if primary.ok:
		return _load_success(primary, "primary", false)
	var backup: Dictionary = _read_decoded(final_path + ".bak", registry)
	if backup.ok:
		var result := _load_success(backup, "backup", true)
		result.primary_errors = primary.errors
		return result
	var errors := PackedStringArray()
	for error in primary.errors:
		errors.append("primary: %s" % error)
	for error in backup.errors:
		errors.append("backup: %s" % error)
	return {"ok": false, "errors": errors, "source": "none", "recovered": false}


func _read_decoded(path: String, registry: Variant = null) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _failure("save file: '%s' does not exist" % path)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _failure("save file: cannot open '%s' (error %d)" % [path, FileAccess.get_open_error()])
	var text := file.get_as_text()
	file.close()
	var decoded: Dictionary = _codec.decode(text)
	if not decoded.ok or registry == null:
		return decoded
	var reference_errors: PackedStringArray = SaveContentReferenceValidatorScript.new().validate(decoded.value, registry)
	if not reference_errors.is_empty():
		return {"ok": false, "errors": reference_errors}
	return decoded


func _load_success(decoded: Dictionary, source: String, recovered: bool) -> Dictionary:
	return {
		"ok": true,
		"errors": PackedStringArray(),
		"value": decoded.value,
		"source": source,
		"recovered": recovered,
		"migrated": decoded.get("migrated", false),
		"from_version": decoded.get("from_version", 0),
		"to_version": decoded.get("to_version", 0),
	}


func _remove_if_present(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _failure(message: String) -> Dictionary:
	return {"ok": false, "errors": PackedStringArray([message]), "backup_created": false}


func _load_failure(message: String) -> Dictionary:
	return {"ok": false, "errors": PackedStringArray([message]), "source": "none", "recovered": false}
