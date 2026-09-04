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
#   GMORN_TEST_JOBS         同時に走らせる本数（既定: 4）
#   GMORN_TEST_TIME_SCALE   ヘッドレスの時間倍率（既定: 指定なし）
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
jobs=${GMORN_TEST_JOBS:-4}
render_position=${GMORN_TEST_RENDER_POSITION:-6000,6000}
time_scale=${GMORN_TEST_TIME_SCALE:-}

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

# 各GodotプロセスはHOMEとXDG_DATA_HOMEを共有しない。user:// とGodot自身の
# 秒単位ログ名が並列実行中に衝突しないためである。成功時は消し、失敗時は
# 原因を追えるよう実行ログを残す。
run_dir=""
worker_pids=()

stop_workers() {
	local pid
	for pid in "${worker_pids[@]}"; do
		kill "$pid" 2>/dev/null || true
	done
	for pid in "${worker_pids[@]}"; do
		wait "$pid" 2>/dev/null || true
	done
}

abort_run() {
	stop_workers
	[ -z "$run_dir" ] || rm -rf -- "$run_dir"
	exit 130
}
trap abort_run HUP INT TERM

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
	local name="$1" status="$2" output="$3" elapsed="${4:-}" log_path="${5:-}"
	local suffix=""
	[ -n "$elapsed" ] && suffix=" (${elapsed}s)"
	if printf '%s\n' "$output" | grep -q '^GMORN_TEST_MISSING:'; then
		failed=$((failed + 1))
		printf '  %-28s 見つからない(%s)\n' "$name" "${output#GMORN_TEST_MISSING:}"
		return
	fi
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
		[ -n "$log_path" ] && printf '      ログ: %s\n' "$log_path"
		return
	fi
	failed=$((failed + 1))
	if [ "$status" -eq 124 ]; then
		printf '  %-28s 時間切れ(%ss)\n' "$name" "$timeout_seconds"
	else
		printf '  %-28s 失敗(exit=%s)\n' "$name" "$status"
	fi
	printf '%s\n' "$output" | grep -E "SCRIPT ERROR|ERROR:|Assertion failed|previously freed|at: " | head -6 | sed 's/^/      /'
	[ -n "$log_path" ] && printf '      ログ: %s\n' "$log_path"
}

# 1本の結果をファイルへ書く。worker同士でシェル変数を共有しない。
run_one() {
	local key="$1" name="$2"
	shift 2
	local script_path="$test_dir/${name}${test_suffix}"
	local result_dir="$run_dir/$key"
	local output_file="$result_dir/output.log"
	local home_dir="$result_dir/home"
	local xdg_dir="$result_dir/xdg"
	mkdir -p "$home_dir" "$xdg_dir"
	if [ ! -f "$script_path" ]; then
		printf 'GMORN_TEST_MISSING:%s\n' "$script_path" > "$output_file"
		printf '127\n' > "$result_dir/status"
		printf '0\n' > "$result_dir/elapsed"
		return
	fi
	local started=$SECONDS
	local output status
	output=$(HOME="$home_dir" XDG_DATA_HOME="$xdg_dir" run_limited \
		"$godot_bin" --log-file "$result_dir/godot.log" "$@" --path . --script "$script_path" 2>&1)
	status=$?
	if [ "$status" -eq 0 ] && only_exit_leak "$output"; then
		printf '1\n' > "$result_dir/retried"
		output=$(HOME="$home_dir" XDG_DATA_HOME="$xdg_dir" run_limited \
			"$godot_bin" --log-file "$result_dir/godot-retry.log" "$@" --path . --script "$script_path" 2>&1)
		status=$?
	fi
	printf '%s\n' "$output" > "$output_file"
	printf '%s\n' "$status" > "$result_dir/status"
	printf '%s\n' "$((SECONDS - started))" > "$result_dir/elapsed"
}

# bash 3.2には wait -n が無いので、FIFOを空き枠のトークンとして使う。
# 読み手は親1つだけにし、1本終わるたび次を起動して同時実行数を固定する。
run_group() {
	local group="$1" kind="$2"
	shift 2
	local names=("$@")
	local count=${#names[@]}
	[ "$count" -gt 0 ] || return
	local worker_count=$jobs
	[ "$worker_count" -gt "$count" ] && worker_count=$count
	local queue="$run_dir/$group.queue" token
	local slot index key pid output status elapsed
	local headless_args=(--headless)
	[ -z "$time_scale" ] || headless_args+=(--time-scale "$time_scale")
	mkfifo "$queue" || exit 1
	exec 3<> "$queue"
	rm -f -- "$queue"
	worker_pids=()
	for ((slot = 0; slot < worker_count; slot++)); do
		printf 'ready\n' >&3
	done
	for ((index = 0; index < count; index++)); do
		IFS= read -r token <&3
		key=$(printf '%s-%05d' "$group" "$index")
		(
			if [ "$kind" = headless ]; then
				run_one "$key" "${names[$index]}" "${headless_args[@]}"
			else
				run_one "$key" "${names[$index]}" --position "$render_position"
			fi
			printf 'ready\n' >&3
		) &
		worker_pids+=("$!")
	done
	for pid in "${worker_pids[@]}"; do
		wait "$pid"
	done
	exec 3>&-
	worker_pids=()
	for ((index = 0; index < count; index++)); do
		key=$(printf '%s-%05d' "$group" "$index")
		output=$(cat "$run_dir/$key/output.log")
		status=$(cat "$run_dir/$key/status")
		elapsed=$(cat "$run_dir/$key/elapsed")
		if [ -f "$run_dir/$key/retried" ]; then
			echo "  ${names[$index]} は終了時の資源で落ちたのでやり直した"
		fi
		report "${names[$index]}" "$status" "$output" "$elapsed" "$run_dir/$key/output.log"
	done
}

# 検証の間は音を出さないようにできる。何度も走らせるので、そのたびに鳴ると邪魔になる。
if [ -n "${GMORN_TEST_SILENT_ENV:-}" ]; then
	export "${GMORN_TEST_SILENT_ENV}=1"
fi

# 既定は「ヘッドレスのみ」。通常描画のテストは本物の窓を開き、位置を画面の外へ
# 置いてもOSが前面へ出して焦点とマウスを奪う。作業中に何度も走らせるものなので、
# 既定で開いてはいけない。
mode=headless
mode_seen=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		--jobs)
			[ "$#" -ge 2 ] || { echo "--jobs には正の整数が必要"; exit 1; }
			jobs=$2
			shift 2
			;;
		--jobs=*) jobs=${1#--jobs=}; shift ;;
		headless|render|all)
			[ "$mode_seen" -eq 0 ] || { echo "実行種別は1つだけ指定する"; exit 1; }
			mode=$1
			mode_seen=1
			shift
			;;
		*) echo "使い方: $0 [--jobs N] [headless|render|all]"; exit 1 ;;
	esac
done
case "$jobs" in
	''|*[!0-9]*) echo "並列数は正の整数にする: $jobs"; exit 1 ;;
esac
[ "$jobs" -gt 0 ] || { echo "並列数は1以上にする: $jobs"; exit 1; }
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/gmorn-test-run.XXXXXX") || exit 1

echo "並列数: $jobs"

echo "起動確認"
mkdir -p "$run_dir/boot/home" "$run_dir/boot/xdg"
output=$(HOME="$run_dir/boot/home" XDG_DATA_HOME="$run_dir/boot/xdg" run_limited \
	"$godot_bin" --log-file "$run_dir/boot/godot.log" --headless --path . --quit 2>&1)
status=$?
printf '%s\n' "$output" > "$run_dir/boot/output.log"
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
		run_group headless headless "${HEADLESS_TESTS[@]}"
	fi
fi

if [ "$mode" = "all" ] || [ "$mode" = "render" ]; then
	if [ ${#RENDER_TESTS[@]} -gt 0 ]; then
		echo "通常描画"
		# 窓は画面の外へ出す。手元で回すと窓が前に出て焦点とマウスを奪う。
		run_group render render "${RENDER_TESTS[@]}"
	fi
fi

# 後始末の確認は全テストの後に置く。保存を扱うテストが本物の置き場に残骸を
# 作っていないかを見るため、順番を入れ替えてはいけない。
if [ "$mode" = "all" ] || [ "$mode" = "headless" ]; then
	if [ ${#CLEANUP_TESTS[@]} -gt 0 ]; then
		echo "後始末"
		run_group cleanup headless "${CLEANUP_TESTS[@]}"
	fi
fi

if [ "$failed" -ne 0 ]; then
	echo "失敗 ${failed}件"
	echo "ログ: $run_dir"
	exit 1
fi
rm -rf -- "$run_dir"
echo "すべて成功"
