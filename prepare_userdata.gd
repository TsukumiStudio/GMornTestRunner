extends SceneTree

## Godot 4.7 のレンダラーは初回の保存先を作らずにシェーダーキャッシュを開くので、先に作る。
func _initialize() -> void:
	var error := DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir())
	if error != OK:
		push_error("テスト用の保存先を作れない: %s" % error_string(error))
		quit(1)
		return
	quit(0)
