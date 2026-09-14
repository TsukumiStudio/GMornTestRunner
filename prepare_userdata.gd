extends SceneTree

## レンダラーより先に、対象プロジェクトの分離された保存先を作る。
func _initialize() -> void:
	var error := DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir())
	if error != OK:
		push_error("テスト用の保存先を作れない: %s" % error_string(error))
		quit(1)
		return
	quit(0)
