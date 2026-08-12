#!/bin/bash
# Godotのテストを、正しい実行環境で回す。
#
# テストは2種類ある。取り違えると、音声の実再生や演出の途中状態を見るテストが
# 常に落ちるか、逆に検証されないまま通ったことになる。
#   ヘッドレス : シーン生成、状態遷移、計算、保存変換、入力のルーティング
#   通常描画   : AudioStreamPlayerの実再生、Tweenの実時間演出、Shader、マウス挙動
#
# 使い方:
#   run_tests.sh            ヘッドレスのみ（既定。窓を開かない）
#   run_tests.sh headless   同上
#   run_tests.sh render     通常描画のみ（窓が開く。頼まれたときだけ）
#   run_tests.sh all        両方（窓が開く。頼まれたときだけ）
#
# 何を回すかは一覧の書き付け（既定 `tests/tests.conf`）で決める。書式は README.md を参照。
#
# 設定はすべて環境変数で渡せる。
#   GODOT_BIN               Godot実行ファイル
#   GMORN_TEST_PROJECT      プロジェクトの場所（既定: この台本の親の親）
#   GMORN_TEST_MANIFEST     一覧の書き付け（既定: $GMORN_TEST_PROJECT/tests/tests.conf）
#   GMORN_TEST_DIR          テストの置き場（既定: tests）
#   GMORN_TEST_SUFFIX       テストの名前の後ろ（既定: _test.gd）
#   GMORN_TEST_TIMEOUT      1本あたりの制限秒（既定: 240）
#   GMORN_TEST_MARKER       成功の印（既定: TEST: PASS）
#   GMORN_TEST_SILENT_ENV   回している間だけ 1 にする環境変数の名前（既定: 無し）
#   GMORN_TEST_RENDER_POSITION  描画テストの窓の位置（既定: 6000,6000）

set -u

runner_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=${GMORN_TEST_PROJECT:-$(CDPATH= cd -- "$runner_dir/../.." && pwd)}
cd "$project_dir" || exit 1

test_dir=${GMORN_TEST_DIR:-tests}
test_suffix=${GMORN_TEST_SUFFIX:-_test.gd}
manifest=${GMORN_TEST_MANIFEST:-$test_dir/tests.conf}
timeout_seconds=${GMORN_TEST_TIMEOUT:-240}
pass_marker=${GMORN_TEST_MARKER:-TEST: PASS}
render_position=${GMORN_TEST_RENDER_POSITION:-6000,6000}

if [ ! -f "$manifest" ]; then
	echo "一覧の書き付けが無い: $manifest"
	exit 1
fi

# 一覧の書き付けを読む。`[headless]` `[render]` `[cleanup]` で区切る。
# `#` から後ろと空行は読み飛ばす。
HEADLESS_TESTS=()
RENDER_TESTS=()
CLEANUP_TESTS=()
section=""
while IFS= read -r line || [ -n "$line" ]; do
	line=${line%%#*}
	line=$(printf '%s' "$line" | tr -d '[:space:]')
	[ -z "$line" ] && continue
	case "$line" in
		"[headless]") section=headless; continue ;;
		"[render]") section=render; continue ;;
		"[cleanup]") section=cleanup; continue ;;
	esac
	case "$section" in
		headless) HEADLESS_TESTS+=("$line") ;;
		render) RENDER_TESTS+=("$line") ;;
		cleanup) CLEANUP_TESTS+=("$line") ;;
		*) echo "区切りの前に名前がある: $line"; exit 1 ;;
	esac
done < "$manifest"

godot_bin="${GODOT_BIN:-$(command -v godot 2>/dev/null)}"
if [ -z "$godot_bin" ] && [ -x /Applications/Godot.app/Contents/MacOS/Godot ]; then
	godot_bin=/Applications/Godot.app/Contents/MacOS/Godot
fi
if [ -z "$godot_bin" ]; then
	echo "Godot実行ファイルが見つからない。GODOT_BIN を設定する。"
	exit 1
fi

# 時間切れの子プロセスを確実に始末する。取り逃がすとGodotが残り続ける。
# `timeout` は環境によって入っていない（macOSの既定には無い）ので perl で行う。
run_limited() {
	perl -e '
		my $limit = shift @ARGV;
		my $pid = fork();
		if (!defined $pid) { exit 125; }
		if ($pid == 0) { exec @ARGV; exit 127; }
		$SIG{ALRM} = sub { kill "KILL", $pid; };
		alarm $limit;
		waitpid($pid, 0);
		my $status = $?;
		alarm 0;
		exit($status & 127 ? 124 : $status >> 8);
	' "$timeout_seconds" "$@"
}

failed=0

# 終了時の資源の後始末は、エンジン側の解放順に左右されて時々こぼれる。
# 音声の再生ノードを木ごとたどって切る対処を入れてもなお、4回に1回ほど
# `N resources still in use at exit` が出る。テスト自体は通っているのに
# 落ちるため、この1行だけが理由のときに限って一度やり直す。
# 他のエラーが混じっていれば、やり直さずそのまま落とす。
only_exit_leak() {
	local text="$1"
	local errors
	errors=$(printf '%s\n' "$text" | grep -E "SCRIPT ERROR|ERROR:|Failed to load")
	[ -n "$errors" ] || return 1
	printf '%s\n' "$errors" | grep -qvE "resources still in use at exit" && return 1
	return 0
}

report() {
	local name="$1" status="$2" output="$3" elapsed="${4:-}"
	local suffix=""
	[ -n "$elapsed" ] && suffix=" (${elapsed}s)"
	# 実行時エラーはテストの成否と独立に出る。PASSしていても失敗として扱う。
	# 単発SEが1つも鳴っていない不具合は、まさにこの形で長期間見逃されていた。
	local runtime_errors
	runtime_errors=$(printf '%s\n' "$output" | grep -E "SCRIPT ERROR|ERROR:|Failed to load" | head -6)
	if [ "$status" -eq 0 ] && [ -z "$runtime_errors" ] && printf '%s' "$output" | grep -q "$pass_marker"; then
		printf '  %-28s OK%s\n' "$name" "$suffix"
		return
	fi
	if [ "$status" -eq 0 ] && [ -n "$runtime_errors" ]; then
		failed=$((failed + 1))
		printf '  %-28s 実行時エラー\n' "$name"
		printf '%s\n' "$runtime_errors" | sed 's/^/      /'
		return
	fi
	failed=$((failed + 1))
	if [ "$status" -eq 124 ]; then
		printf '  %-28s 時間切れ(%ss)\n' "$name" "$timeout_seconds"
	else
		printf '  %-28s 失敗(exit=%s)\n' "$name" "$status"
	fi
	printf '%s\n' "$output" | grep -E "SCRIPT ERROR|ERROR:|Assertion failed|previously freed|at: " | head -6 | sed 's/^/      /'
}

# 1本回す。落ちた理由が終了時の資源だけなら一度やり直す。
run_one() {
	local name="$1"
	shift
	local script_path="$test_dir/${name}${test_suffix}"
	if [ ! -f "$script_path" ]; then
		failed=$((failed + 1))
		printf '  %-28s 見つからない(%s)\n' "$name" "$script_path"
		return
	fi
	local started=$SECONDS
	local output status
	output=$(run_limited "$godot_bin" "$@" --path . --script "$script_path" 2>&1)
	status=$?
	if [ "$status" -eq 0 ] && only_exit_leak "$output"; then
		echo "  ${name} は終了時の資源で落ちたのでやり直す"
		output=$(run_limited "$godot_bin" "$@" --path . --script "$script_path" 2>&1)
		status=$?
	fi
	report "$name" "$status" "$output" "$((SECONDS - started))"
}

# 検証の間は音を出さないようにできる。何度も走らせるので、そのたびに鳴ると邪魔になる。
if [ -n "${GMORN_TEST_SILENT_ENV:-}" ]; then
	export "${GMORN_TEST_SILENT_ENV}=1"
fi

# 既定は「ヘッドレスのみ」。通常描画のテストは本物の窓を開き、位置を画面の外へ
# 置いてもOSが前面へ出して焦点とマウスを奪う。作業中に何度も走らせるものなので、
# 既定で開いてはいけない。
mode="${1:-headless}"
case "$mode" in
	headless|render|all) ;;
	*) echo "使い方: $0 [headless|render|all]"; exit 1 ;;
esac

echo "起動確認"
output=$(run_limited "$godot_bin" --headless --path . --quit 2>&1)
status=$?
noise=$(printf '%s\n' "$output" | grep -E "SCRIPT ERROR|ERROR:|Failed to load" | head -6)
if [ "$status" -ne 0 ] || [ -n "$noise" ]; then
	failed=$((failed + 1))
	printf '  %-28s 失敗(exit=%s)\n' "boot" "$status"
	printf '%s\n' "$noise" | sed 's/^/      /'
else
	printf '  %-28s OK\n' "boot"
fi

if [ "$mode" = "all" ] || [ "$mode" = "headless" ]; then
	if [ ${#HEADLESS_TESTS[@]} -gt 0 ]; then
		echo "ヘッドレス"
		for name in "${HEADLESS_TESTS[@]}"; do
			run_one "$name" --headless
		done
	fi
fi

if [ "$mode" = "all" ] || [ "$mode" = "render" ]; then
	if [ ${#RENDER_TESTS[@]} -gt 0 ]; then
		echo "通常描画"
		for name in "${RENDER_TESTS[@]}"; do
			# 窓は画面の外へ出す。手元で回すと窓が前に出て焦点とマウスを奪う。
			# 位置を外へ置いても描画はそのまま行われる（キャプチャで確認済み）。
			run_one "$name" --position "$render_position"
		done
	fi
fi

# 後始末の確認は全テストの後に置く。保存を扱うテストが本物の置き場に残骸を
# 作っていないかを見るため、順番を入れ替えてはいけない。
if [ "$mode" = "all" ] || [ "$mode" = "headless" ]; then
	if [ ${#CLEANUP_TESTS[@]} -gt 0 ]; then
		echo "後始末"
		for name in "${CLEANUP_TESTS[@]}"; do
			run_one "$name" --headless
		done
	fi
fi

if [ "$failed" -ne 0 ]; then
	echo "失敗 ${failed}件"
	exit 1
fi
echo "すべて成功"
