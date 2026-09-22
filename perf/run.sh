#!/usr/bin/env bash
# media-proxy-rs パフォーマンス測定ランナー (ワンショット)。
#
#   perf/run.sh                          # ローカルでビルドして測定 (dev)
#   perf/run.sh --binary ./media-proxy-rs # ビルド済みバイナリで測定 (実機)
#   perf/run.sh --target http://127.0.0.1:12766 --no-start   # 稼働中プロキシを測定
#   perf/run.sh --uds /run/media-proxy/proxy.sock --no-start # UDS バインドのプロキシを測定
#
# 結果は perf/results/<label>/ に、PR に貼れる形の report.md を含めて保存される。
set -euo pipefail

PERF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$PERF_DIR/.." && pwd)"
# shellcheck source=lib.sh
. "$PERF_DIR/lib.sh"

usage() {
	cat <<'EOF'
usage: run.sh [options]

  --binary PATH        ビルド済みバイナリを使う (省略時は cargo build --release)
  --target URL         起動済みプロキシを測定する (--no-start を暗黙に有効化)
  --uds PATH           起動済みプロキシ (unix socket) を測定する
  --no-start           プロキシを起動しない
  --pid PID            RSS/CPU をサンプリングする対象 PID (default: 起動したプロキシ)
  --avif               encode_avif=true の設定と Accept: image/avif を使う
  --scenario NAME      シナリオ名 (複数指定可 / all)  default: all
  --concurrency N      同時接続数 (default: 8)
  --duration SEC       計測時間 (default: 15)
  --warmup SEC         ウォームアップ時間 (default: 5)
  --rounds N           繰り返し回数 (default: 1)。中央値は summarize が取る
  --label NAME         結果ディレクトリ名 (default: run-<timestamp>)
  --port PORT          プロキシのポート (default: 12766、使用中なら自動でずらす)
  --origin-port PORT   origin スタブのポート (default: 18080、使用中なら自動でずらす)
  --origin-host HOST   origin の bind アドレス (default: 127.0.0.1)
  --origin-url URL     url= に渡す origin の基底 (default: http://<origin-host>:<port>)
  --corpus DIR         corpus ディレクトリ (default: perf/corpus)
  --pin                server/client を別コアに固定する (taskset, コア4以上)
  -h, --help           このヘルプ
EOF
}

BINARY_ARG=""
TARGET_URL=""
UDS_PATH=""
NO_START=0
AVIF=0
SCENARIOS=()
CONCURRENCY=8
DURATION=15
WARMUP=5
ROUNDS=1
LABEL=""
PROXY_PORT=12766
ORIGIN_PORT=18080
ORIGIN_HOST="127.0.0.1"
ORIGIN_URL=""
CORPUS="$PERF_DIR/corpus"
SAMPLE_PID=""
PIN=0

while [ $# -gt 0 ]; do
	case "$1" in
		--binary)
			BINARY_ARG="$2"
			shift 2
			;;
		--target)
			TARGET_URL="$2"
			NO_START=1
			shift 2
			;;
		--uds)
			UDS_PATH="$2"
			NO_START=1
			shift 2
			;;
		--no-start)
			NO_START=1
			shift
			;;
		--pid)
			SAMPLE_PID="$2"
			shift 2
			;;
		--avif)
			AVIF=1
			shift
			;;
		--scenario | --scenarios)
			IFS=',' read -r -a _names <<<"$2"
			SCENARIOS+=("${_names[@]}")
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
		--rounds)
			ROUNDS="$2"
			shift 2
			;;
		--label)
			LABEL="$2"
			shift 2
			;;
		--port)
			PROXY_PORT="$2"
			shift 2
			;;
		--origin-port)
			ORIGIN_PORT="$2"
			shift 2
			;;
		--origin-host)
			ORIGIN_HOST="$2"
			shift 2
			;;
		--origin-url)
			ORIGIN_URL="$2"
			shift 2
			;;
		--corpus)
			CORPUS="$2"
			shift 2
			;;
		--pin)
			PIN=1
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
perf_need curl

if [ "$NO_START" -eq 1 ] && [ -z "$TARGET_URL" ] && [ -z "$UDS_PATH" ]; then
	perf_die "--no-start を使う場合は --target URL か --uds PATH を指定してください"
fi

PERF_PROXY_PID=""
PERF_ORIGIN_PID=""
cleanup() {
	perf_stop_pid "${PERF_PROXY_PID:-}"
	perf_stop_pid "${PERF_ORIGIN_PID:-}"
}
perf_install_traps cleanup

# --- corpus ---------------------------------------------------------------
if [ ! -f "$CORPUS/corpus.sha256" ]; then
	perf_info "corpus が無いため生成します: $CORPUS"
	"$PERF_DIR/gen_corpus.sh" --out "$CORPUS"
fi
CORPUS="$(cd "$CORPUS" && pwd)"

# --- シナリオ一覧 ---------------------------------------------------------
if [ ${#SCENARIOS[@]} -eq 0 ]; then
	SCENARIOS=(all)
fi
for s in "${SCENARIOS[@]}"; do
	if [ "$s" = "all" ]; then
		mapfile -t SCENARIOS < <(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))))' "$PERF_DIR/scenarios.json")
		break
	fi
done

# --- バイナリ -------------------------------------------------------------
if [ -n "$BINARY_ARG" ]; then
	BINARY="$BINARY_ARG"
	[ -x "$BINARY" ] || perf_die "実行可能なバイナリではありません: $BINARY"
elif [ "$NO_START" -eq 1 ]; then
	BINARY=""
else
	perf_need cargo "(Rust ツールチェーン、または --binary を指定)"
	perf_info "cargo build --release"
	(cd "$ROOT_DIR" && cargo build --release)
	BINARY="$ROOT_DIR/target/release/media-proxy-rs"
fi

# --- 結果ディレクトリ -----------------------------------------------------
[ -n "$LABEL" ] || LABEL="run-$(date +%Y%m%d-%H%M%S)"
LABEL_DIR="$PERF_DIR/results/$LABEL"
mkdir -p "$LABEL_DIR"

# --- ポート ---------------------------------------------------------------
if [ "$NO_START" -eq 0 ]; then
	PROXY_PORT="$(perf_pick_port "$PROXY_PORT")"
	TARGET_URL="http://127.0.0.1:$PROXY_PORT"
fi
ORIGIN_PORT="$(perf_pick_port "$ORIGIN_PORT")"
[ -n "$ORIGIN_URL" ] || ORIGIN_URL="http://$ORIGIN_HOST:$ORIGIN_PORT"

# --- CPU pinning ---------------------------------------------------------
SERVER_CPUS=""
CLIENT_CPUS=""
if [ "$PIN" -eq 1 ]; then
	if command -v taskset >/dev/null 2>&1; then
		NC="$(nproc)"
		if [ "$NC" -ge 4 ]; then
			SERVER_CPUS="0-$(( NC / 2 - 1 ))"
			CLIENT_CPUS="$(( NC / 2 ))-$(( NC - 1 ))"
			perf_info "CPU pinning: server=$SERVER_CPUS client=$CLIENT_CPUS"
		else
			perf_warn "コア数が少ないため --pin を無視します (nproc=$NC)"
		fi
	else
		perf_warn "taskset が無いため --pin を無視します"
	fi
fi

# --- origin 起動 ----------------------------------------------------------
perf_start_origin "$PERF_DIR" "$CORPUS" "$ORIGIN_PORT" "$ORIGIN_HOST" "$LABEL_DIR/origin.log"
if ! perf_wait_http "http://127.0.0.1:$ORIGIN_PORT/healthz" 10; then
	perf_die "origin が起動しませんでした ($LABEL_DIR/origin.log)"
fi
perf_info "origin: $ORIGIN_URL (pid $PERF_ORIGIN_PID)"

# --- プロキシ起動 ---------------------------------------------------------
if [ "$AVIF" -eq 1 ]; then
	CONFIG_SRC="$PERF_DIR/config.perf-avif.json"
else
	CONFIG_SRC="$PERF_DIR/config.perf.json"
fi
CONFIG="$LABEL_DIR/config.json"
if [ "$NO_START" -eq 0 ]; then
	perf_patch_config "$CONFIG_SRC" "$CONFIG" "127.0.0.1:$PROXY_PORT"
	perf_start_proxy "$BINARY" "$CONFIG" "$LABEL_DIR/proxy.log" "$SERVER_CPUS"
	if ! perf_wait_http "http://127.0.0.1:$PROXY_PORT/healthz" 10; then
		perf_die "プロキシが起動しませんでした ($LABEL_DIR/proxy.log)"
	fi
	perf_info "proxy: $TARGET_URL (pid $PERF_PROXY_PID)"
else
	cp "$CONFIG_SRC" "$CONFIG" 2>/dev/null || true
	perf_info "起動済みのプロキシを測定します: ${UDS_PATH:+unix:}${TARGET_URL}"
fi

# --- meta -----------------------------------------------------------------
if [ -n "$BINARY" ]; then
	perf_meta_set BINARY "$BINARY"
else
	perf_meta_set BINARY ""
fi
perf_meta_set LABEL "$LABEL"
perf_meta_set CONFIG "$CONFIG"
perf_meta_set CORPUS_DIR "$CORPUS"
perf_meta_set TARGET "$TARGET_URL"
perf_meta_set UDS "$UDS_PATH"
perf_meta_set ORIGIN "$ORIGIN_URL"
perf_meta_set RUSTC "$(rustc --version 2>/dev/null || echo unknown)"
# compare.sh は測定対象のリビジョンが main checkout と異なるため、PERF_META_GIT_* を
# 事前に設定してくる。その場合はそちらを優先する。
if [ -z "${PERF_META_GIT_REV+x}" ]; then
	perf_collect_git_meta "$ROOT_DIR"
fi
if [ -z "${PERF_META_GIT_REF:-}" ]; then
	perf_meta_set GIT_REF "$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
fi
if [ -n "$SAMPLE_PID" ]; then
	perf_meta_set PID "$SAMPLE_PID"
else
	perf_meta_set PID "${PERF_PROXY_PID:-}"
fi
perf_write_meta "$LABEL_DIR/meta.json"

# --- 計測 -----------------------------------------------------------------
run_loadtest() { # $1=scenario $2=outfile $3=round
	local sc="$1" out="$2" r="$3"
	local args=(
		--origin "$ORIGIN_URL"
		--scenario "$sc"
		--concurrency "$CONCURRENCY"
		--duration "$DURATION"
		--warmup "$WARMUP"
		--meta "$LABEL_DIR/meta.json"
		--label "r${r}-${sc}"
		--out "$out"
	)
	if [ -n "$UDS_PATH" ]; then
		args+=(--uds "$UDS_PATH")
	else
		args+=(--target "$TARGET_URL")
	fi
	if [ "$AVIF" -eq 1 ]; then
		args+=(--accept-avif)
	fi
	if [ -n "${SAMPLE_PID:-}" ] || [ -n "${PERF_PROXY_PID:-}" ]; then
		args+=(--sample-pid "${SAMPLE_PID:-$PERF_PROXY_PID}")
	fi
	if [ -n "$CLIENT_CPUS" ]; then
		taskset -c "$CLIENT_CPUS" python3 "$PERF_DIR/loadtest.py" "${args[@]}"
	else
		python3 "$PERF_DIR/loadtest.py" "${args[@]}"
	fi
}

for r in $(seq 1 "$ROUNDS"); do
	for sc in "${SCENARIOS[@]}"; do
		perf_info "round $r/$ROUNDS scenario $sc (concurrency=$CONCURRENCY duration=${DURATION}s)"
		if ! run_loadtest "$sc" "$LABEL_DIR/r${r}-${sc}.json" "$r"; then
			perf_warn "scenario $sc がエラー終了しました (詳細: $LABEL_DIR/r${r}-${sc}.json)"
		fi
	done
done

# --- レポート -------------------------------------------------------------
perf_info "プロキシ/origin を停止します"
perf_stop_pid "${PERF_PROXY_PID:-}"
perf_stop_pid "${PERF_ORIGIN_PID:-}"
PERF_PROXY_PID=""
PERF_ORIGIN_PID=""

shopt -s nullglob
RES_FILES=("$LABEL_DIR"/r*-*.json)
shopt -u nullglob
if [ ${#RES_FILES[@]} -eq 0 ]; then
	perf_die "結果が 1 件もありません ($LABEL_DIR)"
fi

python3 "$PERF_DIR/summarize.py" \
	--base "${RES_FILES[@]}" \
	--base-label "$LABEL" \
	--title "media-proxy-rs perf: $LABEL" \
	--note "実行: perf/run.sh (concurrency=$CONCURRENCY, duration=${DURATION}s, warmup=${WARMUP}s, rounds=$ROUNDS)" \
	--out "$LABEL_DIR/report.md"

perf_info "結果ディレクトリ: $LABEL_DIR"
perf_info "レポート: $LABEL_DIR/report.md"
