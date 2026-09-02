extends RefCounted
class_name MotionPolicy

const SETTING_PATH := "accessibility/reduce_motion"


static func reduced() -> bool:
	return bool(ProjectSettings.get_setting(SETTING_PATH, false))
