extends RefCounted
class_name SaveGameCodec

const SaveEnvelopeScript := preload("res://src/domain/campaign/save_envelope.gd")


func encode(envelope: Dictionary) -> Dictionary:
	var errors := SaveEnvelopeScript.validate(envelope)
	if not errors.is_empty():
		return {"ok": false, "errors": errors}
	return {"ok": true, "text": JSON.stringify(envelope, "  ", false)}


func decode(text: String) -> Dictionary:
	var json := JSON.new()
	var parse_error := json.parse(text)
	if parse_error != OK:
		return {
			"ok": false,
			"errors": PackedStringArray([
				"save: invalid JSON at line %d: %s" % [json.get_error_line(), json.get_error_message()]
			]),
		}
	var value = json.data
	if not value is Dictionary:
		return {"ok": false, "errors": PackedStringArray(["save: root JSON value must be an object"])}
	var errors := SaveEnvelopeScript.validate(value)
	if not errors.is_empty():
		return {"ok": false, "errors": errors}
	return {"ok": true, "value": value}
