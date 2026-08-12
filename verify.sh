#!/bin/bash
# この部品だけを確かめる。
#
# 一時の置き場へ最小のGodotプロジェクトと、わざと通る／落ちるテストを作って回す。
# ここで見たいのは「落ちるべきものが落ちる」ことである。通るものが通るだけの
# 確認では、判定が甘い側へ壊れたときに気付けない。
set -u

runner_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

mkdir -p "$work_dir/tests"
# 起動確認は主場面を開いて閉じる。主場面が無いとGodotは待ち続けるので、
# 空でも1つ置く。
cat > "$work_dir/main.tscn" <<'SCENE'
[gd_scene format=3]

[node name="Main" type="Node"]
SCENE

cat > "$work_dir/project.godot" <<'PROJECT'
config_version=5

[application]

config/name="GMornTestRunner Verify"
run/main_scene="res://main.tscn"
config/features=PackedStringArray("4.7")
PROJECT

# 通るテスト。
cat > "$work_dir/tests/good_test.gd" <<'GD'
extends SceneTree

func _initialize() -> void:
	print("GOOD TEST: PASS")
	quit(0)
GD

# 印は出すが、実行時エラーも出るテスト。落ちなければならない。
# 単発SEが1つも鳴っていない不具合は、まさにこの形で長期間見逃されていた。
cat > "$work_dir/tests/noisy_test.gd" <<'GD'
extends SceneTree

func _initialize() -> void:
	print("SCRIPT ERROR: わざと出している")
	print("NOISY TEST: PASS")
	quit(0)
GD

# 印を出さずに終わるテスト。落ちなければならない。
cat > "$work_dir/tests/silent_test.gd" <<'GD'
extends SceneTree

func _initialize() -> void:
	quit(0)
GD

# 後始末の枠に置くテスト。最後に回る。
cat > "$work_dir/tests/cleanup_test.gd" <<'GD'
extends SceneTree

func _initialize() -> void:
	print("CLEANUP TEST: PASS")
	quit(0)
GD

export GMORN_TEST_PROJECT="$work_dir"
failed=0

check() {
	local label="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		printf '  %-34s OK\n' "$label"
	else
		printf '  %-34s 期待=%s 実際=%s\n' "$label" "$expected" "$actual"
		failed=$((failed + 1))
	fi
}

# 通るものだけを並べたら成功で終わる。
cat > "$work_dir/tests/tests.conf" <<'CONF'
[headless]
good

[cleanup]
cleanup
CONF
output=$("$runner_dir/run_tests.sh" headless 2>&1)
check "通るものだけなら成功" 0 $?
printf '%s' "$output" | grep -q "すべて成功" || { echo "  「すべて成功」が出ない"; failed=$((failed + 1)); }
printf '%s' "$output" | grep -q "後始末" || { echo "  後始末の枠が回っていない"; failed=$((failed + 1)); }

# 印が出ていても実行時エラーがあれば落ちる。
cat > "$work_dir/tests/tests.conf" <<'CONF'
[headless]
good
noisy
CONF
"$runner_dir/run_tests.sh" headless >/dev/null 2>&1
check "印が出ていてもエラーなら落ちる" 1 $?

# 印が出なければ落ちる。
cat > "$work_dir/tests/tests.conf" <<'CONF'
[headless]
silent
CONF
"$runner_dir/run_tests.sh" headless >/dev/null 2>&1
check "印が無ければ落ちる" 1 $?

# 無い名前を書いたら落ちる。黙って読み飛ばすと、消したテストに気付けない。
cat > "$work_dir/tests/tests.conf" <<'CONF'
[headless]
missing
CONF
output=$("$runner_dir/run_tests.sh" headless 2>&1)
check "無い名前は落ちる" 1 $?
printf '%s' "$output" | grep -q "見つからない" || { echo "  見つからない旨が出ない"; failed=$((failed + 1)); }

# 描画の枠はヘッドレスでは回らない。取り違えると、窓の要るテストが常に落ちる。
cat > "$work_dir/tests/tests.conf" <<'CONF'
[headless]
good

[render]
silent
CONF
"$runner_dir/run_tests.sh" headless >/dev/null 2>&1
check "描画の枠は既定で回らない" 0 $?

# 書き付けが無ければ、黙って0件成功にせず落ちる。
rm -f "$work_dir/tests/tests.conf"
"$runner_dir/run_tests.sh" headless >/dev/null 2>&1
check "書き付けが無ければ落ちる" 1 $?

# 印の言葉と置き場は差し替えられる。
mkdir -p "$work_dir/spec"
cat > "$work_dir/spec/thing.spec.gd" <<'GD'
extends SceneTree

func _initialize() -> void:
	print("=== ALL GREEN ===")
	quit(0)
GD
cat > "$work_dir/spec/tests.conf" <<'CONF'
[headless]
thing
CONF
GMORN_TEST_DIR=spec GMORN_TEST_SUFFIX=.spec.gd GMORN_TEST_MARKER="ALL GREEN" \
	"$runner_dir/run_tests.sh" headless >/dev/null 2>&1
check "置き場と印を差し替えられる" 0 $?

if [ "$failed" -ne 0 ]; then
	echo "GMORN TEST RUNNER VERIFY: 失敗 ${failed}件"
	exit 1
fi
echo "GMORN TEST RUNNER VERIFY: PASS"
