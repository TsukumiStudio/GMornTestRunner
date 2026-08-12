# GMornTestRunner

## 概要

Godotのテストを、正しい実行環境で回すシェル台本。

テストは2種類ある。取り違えると、音声の実再生や演出の途中状態を見るテストが常に落ちるか、逆に**検証されないまま通ったことになる**。

| 種類 | 何を見るか |
| --- | --- |
| ヘッドレス | シーン生成、状態遷移、計算、保存変換、入力のルーティング |
| 通常描画 | `AudioStreamPlayer` の実再生、`Tween` の実時間演出、Shader、マウス挙動 |

Godotアドオンではないので `addons/` には置かない。`tools/gmorn_test_runner` あたりへ submodule として入れる。

## 動作環境

- bash 3.2 以上（macOSの既定でも動く）
- perl（macOS・多くのLinuxに元から入っている）
- Godot 4.x（4.7で確認）

`timeout` は使わない。macOSの既定には入っていないため、時間切れは perl で行う。

## 何ができるか

- **通ったように見えるものを落とす**。`SCRIPT ERROR` / `ERROR:` / `Failed to load` が出ていれば、成功の印が出ていても失敗として扱う。単発SEが1つも鳴っていない不具合は、まさにこの形で長期間見逃されていた。
- **Godotを残さない**。時間切れの子プロセスを `kill` まで確実に行う。取り逃がすとGodotが裏で走り続ける。
- **こぼれだけをやり直す**。終了時に `N resources still in use at exit` **だけ**が出たときに限り、一度やり直す。エンジン側の解放順に左右されて4回に1回ほど出るためで、他のエラーが混じっていればやり直さずそのまま落とす。
- **窓を勝手に開かない**。既定はヘッドレスのみ。描画テストは頼まれたときだけ回し、窓は画面の外へ置く。
- **後始末を最後に置く**。保存を扱うテストが本物の置き場に残骸を作っていないかを見る枠を、必ず全テストの後に回す。

## 使い方

### 1. 取り込む

```
git submodule add https://github.com/TsukumiStudio/GMornTestRunner.git tools/gmorn_test_runner
```

台本は自分の居場所の2つ上をプロジェクトの根と見なす。別の場所へ置くときは `GMORN_TEST_PROJECT` を渡す。

### 2. 一覧の書き付けを作る

既定では `tests/tests.conf` を読む。

```
# 窓を開かずに回せるもの
[headless]
smoke
save_round_trip
button_inheritance

# 本物の窓と音が要るもの
[render]
audio_runtime
window_scaling

# 全テストの後に回すもの
[cleanup]
save_isolation
```

`#` から後ろと空行は読み飛ばす。名前は `tests/<名前>_test.gd` に対応する。書いた名前のファイルが無ければ落ちる。黙って読み飛ばすと、消したテストに気付けない。

### 3. テストを書く

`SceneTree` を継いで、最後に印を出す。

```gdscript
extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	assert(1 + 1 == 2)
	print("MY TEST: PASS")
	quit(0)
```

印は既定で `TEST: PASS` を含むかどうかで見る。`_initialize()` で直に始めず `call_deferred` を挟むのは、木が動き出してからでないと自動読み込みを引けないためである。

### 4. 回す

```
tools/gmorn_test_runner/run_tests.sh            ヘッドレスのみ（既定）
tools/gmorn_test_runner/run_tests.sh headless   同上
tools/gmorn_test_runner/run_tests.sh render     通常描画のみ（窓が開く）
tools/gmorn_test_runner/run_tests.sh all        両方（窓が開く）
```

作業中に何度も走らせるものなので、既定で窓を開いてはいけない。描画テストは位置を画面の外へ置いてもOSが前面へ出し、焦点とマウスを奪う。

包み台本を1つ置いておくと短く書ける。

```sh
#!/bin/sh
# tools/run_tests.sh
set -eu
cd "$(dirname "$0")/.."
GMORN_TEST_SILENT_ENV=MYGAME_SILENT exec tools/gmorn_test_runner/run_tests.sh "$@"
```

### 5. 動かし方を変える

| 環境変数 | 何を決めるか | 既定 |
| --- | --- | --- |
| `GODOT_BIN` | Godot実行ファイル | `godot` → `/Applications/Godot.app/...` |
| `GMORN_TEST_PROJECT` | プロジェクトの場所 | 台本の2つ上 |
| `GMORN_TEST_MANIFEST` | 一覧の書き付け | `<置き場>/tests.conf` |
| `GMORN_TEST_DIR` | テストの置き場 | `tests` |
| `GMORN_TEST_SUFFIX` | 名前の後ろ | `_test.gd` |
| `GMORN_TEST_TIMEOUT` | 1本あたりの制限秒 | `240` |
| `GMORN_TEST_MARKER` | 成功の印 | `TEST: PASS` |
| `GMORN_TEST_SILENT_ENV` | 回している間だけ `1` にする環境変数の名前 | 無し |
| `GMORN_TEST_RENDER_POSITION` | 描画テストの窓の位置 | `6000,6000` |

`GMORN_TEST_SILENT_ENV` は、作品側で主バスを消すために使う。`--audio-driver Dummy` と違って再生位置は進むので、音が鳴っているかどうかを見るテストはそのまま通る。

### 手を入れる

`verify.sh` で台本そのものを確かめられる。一時の置き場へ最小のプロジェクトと、わざと通る／落ちるテストを作って回す。見たいのは「落ちるべきものが落ちる」ことである。通るものが通るだけの確認では、判定が甘い側へ壊れたときに気付けない。

```
./verify.sh
```

## ライセンス

Unlicense（パブリックドメイン）。
