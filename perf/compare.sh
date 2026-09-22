#!/usr/bin/env bash
# 2つのリビジョン (または2つのバイナリ) の before/after を測定し、PR に貼れるレポートを作る。
#
#   perf/compare.sh                                  # origin/main と HEAD を比較
#   perf/compare.sh --base origin/main --head HEAD
#   perf/compare.sh --base-bin ./old --head-bin ./new --rounds 3
#   perf/compare.sh --base /path/to/other/clone --head .   # 未コミットの作業ツリーも比較可能
#
# 公平性のため、corpus と config は両者で共通、各ラウンドで base/head を交互に起動し、
# 指標はラウンド中央値を取る (summarize.py)。
set -euo pipefail

PERF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$PERF_DIR/.." && pwd)"
# shellcheck source=lib.sh
. "$PERF_DIR/lib.sh"

usage() {
	cat <<'EOF'
usage: compare.sh [options]

  --base REF|DIR|BIN   base 側 (git ref / ソースツリー / 実行可能バイナリ)  default: origin/main
  --head REF|DIR|BIN   head 側  default: HEAD
  --base-bin PATH      base 側のバイナリ (--base の代わり)
  --head-bin PATH      head 側のバイナリ (--head の代わり)
  --rounds N           交互実行の回数 (default: 3、中央値を採用)
  --concurrency N      同時接続数 (default: 8)
  --duration SEC       1シナリオあたりの計測時間 (default: 15)
  --warmup SEC         ウォームアップ時間 (default: 5)
  --scenario NAME      シナリオ名 (複数指定可 / all)  default: all
  --avif               encode_avif=true で比較
  --threshold PCT      有意とみなす差分 (default: 5)
  --label NAME         結果ディレクトリ名 (default: compare-<timestamp>)
  --keep-worktrees     ビルド用の worktree / target を残す
  -h, --help
EOF
}

BASE_ARG=""
HEAD_ARG=""
CONCURRENCY=8
DURATION=15
WARMUP=5
ROUNDS=3
AVIF=0
SCENARIOS=()
THRESHOLD=5
LABEL=""
KEEP=0

while [ $# -gt 0 ]; do
	case "$1" in
		--base)
			BASE_ARG="$2"
			shift 2
			;;
		--head)
			HEAD_ARG="$2"
			shift 2
			;;
		--base-bin)
			BASE_ARG="$2"
			shift 2
			;;
		--head-bin)
			HEAD_ARG="$2"
			shift 2
			;;
		--rounds)
			ROUNDS="$2"
			shift 2
			;;
		--concurrency)
			CONCURRENCY="$2"
			shift 2
			;;
		--duration)
			DURATION="$2"
			shift 2
			;;
		--warmup)
			WARMUP="$2"
			shift 2
			;;
		--scenario | --scenarios)
			IFS=',' read -r -a _names <<<"$2"
			SCENARIOS+=("${_names[@]}")
			shift 2
			;;
		--avif)
			AVIF=1
			shift
			;;
		--threshold)
			THRESHOLD="$2"
			shift 2
			;;
		--label)
			LABEL="$2"
			shift 2
			;;
		--keep-worktrees)
			KEEP=1
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			echo "error: unknown option: $1" >&2
			usage >&2
			exit 2
			;;
	esac
done

perf_need python3 "(3.8+)"
perf_need git

if [ -z "$BASE_ARG" ]; then
	for candidate in origin/main main master; do
		if git -C "$ROOT_DIR" rev-parse --verify --quiet "$candidate^{commit}" >/dev/null; then
			BASE_ARG="$candidate"
			break
		fi
	done
	[ -n "$BASE_ARG" ] || perf_die "base のデフォルト ref が見つかりません (--base を指定してください)"
fi
[ -n "$HEAD_ARG" ] || HEAD_ARG="HEAD"

declare -A SIDE_KIND SIDE_LABEL SIDE_SRC SIDE_BIN SIDE_REF SIDE_WT

resolve_side() { # $1=side(base|head) $2=value
	local side="$1" value="$2" commit
	if [ -f "$value" ] && [ -x "$value" ]; then
		SIDE_KIND[$side]="binary"
		SIDE_BIN[$side]="$(cd "$(dirname "$value")" && pwd)/$(basename "$value")"
		SIDE_LABEL[$side]="bin:$(basename "$value")"
		return 0
	fi
	if [ -d "$value" ]; then
		SIDE_KIND[$side]="dir"
		SIDE_SRC[$side]="$(cd "$value" && pwd)"
		SIDE_LABEL[$side]="dir:$(basename "${SIDE_SRC[$side]}")"
		return 0
	fi
	if commit=$(git -C "$ROOT_DIR" rev-parse --verify --quiet "$value^{commit}"); then
		SIDE_KIND[$side]="ref"
		SIDE_REF[$side]="$value"
		SIDE_LABEL[$side]="$value @ ${commit:0:12}"
		return 0
	fi
	perf_die "$side を解決できません ($value): 実行可能ファイル / ディレクトリ / git ref のいずれでもありません"
}

resolve_side base "$BASE_ARG"
resolve_side head "$HEAD_ARG"

BUILD_ROOT="${TMPDIR:-/tmp}/media-proxy-perf-build-$$"
mkdir -p "$BUILD_ROOT"

WT_CREATED=()
cleanup() {
	local wt
	perf_stop_pid "${PERF_PROXY_PID:-}"
	perf_stop_pid "${PERF_ORIGIN_PID:-}"
	if [ "$KEEP" -eq 0 ]; then
		for wt in "${WT_CREATED[@]}"; do
			git -C "$ROOT_DIR" worktree remove --force "$wt" >/dev/null 2>&1 || true
		done
		rm -rf "$BUILD_ROOT"
	else
		perf_info "worktree / ビルド成果物を残しました: $BUILD_ROOT"
	fi
}
perf_install_traps cleanup

build_side() { # $1=side -> SIDE_BIN
	local side="$1" srcdir
	case "${SIDE_KIND[$side]}" in
		binary)
			return 0
			;;
		dir)
			srcdir="${SIDE_SRC[$side]}"
			;;
		ref)
			srcdir="$BUILD_ROOT/wt-$side"
			perf_info "worktree: $srcdir (${SIDE_REF[$side]})"
			git -C "$ROOT_DIR" worktree add --detach "$srcdir" "${SIDE_REF[$side]}" >/dev/null
			SIDE_WT[$side]="$srcdir"
			WT_CREATED+=("$srcdir")
			;;
	esac
	perf_need cargo "(Rust ツールチェーン、または --base-bin/--head-bin を指定)"
	perf_info "cargo build --release ($side)"
	(cd "$srcdir" && CARGO_TARGET_DIR="$BUILD_ROOT/target-$side" cargo build --release)
	SIDE_BIN[$side]="$BUILD_ROOT/target-$side/release/media-proxy-rs"
	[ -x "${SIDE_BIN[$side]}" ] || perf_die "ビルドに失敗しました ($side): ${SIDE_BIN[$side]}"
}

if [ "${SIDE_KIND[base]}" != "binary" ] || [ "${SIDE_KIND[head]}" != "binary" ]; then
	if ! command -v cargo >/dev/null 2>&1; then
		perf_die "cargo が必要です (バイナリ同士の比較は --base-bin/--head-bin で行えます)"
	fi
fi
for side in base head; do
	if [ "${SIDE_KIND[$side]}" = "binary" ]; then
		[ -x "${SIDE_BIN[$side]}" ] || perf_die "実行可能ではありません: ${SIDE_BIN[$side]}"
	else
		build_side "$side"
	fi
done

perf_info "base: ${SIDE_LABEL[base]} (${SIDE_BIN[base]})"
perf_info "head: ${SIDE_LABEL[head]} (${SIDE_BIN[head]})"

N_SCENARIOS="${#SCENARIOS[@]}"
if [ "$N_SCENARIOS" -eq 0 ]; then
	N_SCENARIOS="$(
		python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$PERF_DIR/scenarios.json"
	)"
fi
EST=$(( ROUNDS * 2 * N_SCENARIOS * (DURATION + WARMUP) ))
perf_info "予想所要時間: 約 $(( EST / 60 )) 分 (${ROUNDS}ラウンド × 2側 × ${N_SCENARIOS}シナリオ × $(( DURATION + WARMUP ))秒)"

[ -n "$LABEL" ] || LABEL="compare-$(date +%Y%m%d-%H%M%S)"
CMP_DIR="$PERF_DIR/results/$LABEL"
mkdir -p "$CMP_DIR"

for r in $(seq 1 "$ROUNDS"); do
	if [ $(( r % 2 )) -eq 1 ]; then
		ORDER=(base head)
	else
		ORDER=(head base)
	fi
	for side in "${ORDER[@]}"; do
		perf_info "round $r/$ROUNDS: $side (${SIDE_LABEL[$side]})"
		# 測定対象の来歴を meta に記録させる (run.sh は main checkout の情報しか持たないため)
		unset PERF_META_GIT_REV PERF_META_GIT_REF PERF_META_GIT_DIRTY PERF_META_GIT_BRANCH
		case "${SIDE_KIND[$side]}" in
			ref)
				export PERF_META_GIT_REV
				PERF_META_GIT_REV="$(git -C "$ROOT_DIR" rev-parse "${SIDE_REF[$side]}^{commit}")"
				export PERF_META_GIT_REF="${SIDE_REF[$side]}"
				export PERF_META_GIT_DIRTY="0"
				export PERF_META_GIT_BRANCH=""
				;;
			dir)
				export PERF_META_GIT_REV
				PERF_META_GIT_REV="$(git -C "${SIDE_SRC[$side]}" rev-parse HEAD 2>/dev/null || true)"
				export PERF_META_GIT_REF="dir:${SIDE_SRC[$side]}"
				export PERF_META_GIT_DIRTY="0"
				export PERF_META_GIT_BRANCH=""
				;;
		esac
		RUN_ARGS=(
			--binary "${SIDE_BIN[$side]}"
			--label "$LABEL/$side-r$r"
			--concurrency "$CONCURRENCY"
			--duration "$DURATION"
			--warmup "$WARMUP"
		)
		if [ "$AVIF" -eq 1 ]; then
			RUN_ARGS+=(--avif)
		fi
		if [ "${#SCENARIOS[@]}" -gt 0 ]; then
			for sc in "${SCENARIOS[@]}"; do
				RUN_ARGS+=(--scenario "$sc")
			done
		fi
		"$PERF_DIR/run.sh" "${RUN_ARGS[@]}"
	done
done

shopt -s nullglob
BASE_FILES=("$CMP_DIR"/base-r*/r*-*.json)
HEAD_FILES=("$CMP_DIR"/head-r*/r*-*.json)
shopt -u nullglob
[ ${#BASE_FILES[@]} -gt 0 ] || perf_die "base 側の結果がありません ($CMP_DIR)"
[ ${#HEAD_FILES[@]} -gt 0 ] || perf_die "head 側の結果がありません ($CMP_DIR)"

python3 "$PERF_DIR/summarize.py" \
	--base "${BASE_FILES[@]}" \
	--head "${HEAD_FILES[@]}" \
	--base-label "${SIDE_LABEL[base]}" \
	--head-label "${SIDE_LABEL[head]}" \
	--title "Performance: ${SIDE_LABEL[base]} → ${SIDE_LABEL[head]}" \
	--threshold "$THRESHOLD" \
	--note "実行: perf/compare.sh (rounds=$ROUNDS, concurrency=$CONCURRENCY, duration=${DURATION}s, warmup=${WARMUP}s, avif=$AVIF)" \
	--out "$CMP_DIR/report.md"

perf_info "比較レポート: $CMP_DIR/report.md (この内容を PR に貼れます)"
