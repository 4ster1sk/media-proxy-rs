#!/usr/bin/env bash
# コード無改変で CPU プロファイルを取る (perf + flamegraph)。
#
#   perf/profile.sh --seconds 20 --scenario jpeg_preview
#
# Cargo.toml を変更せず、環境変数でシンボル付き release ビルドを作る
# (CARGO_PROFILE_RELEASE_DEBUG=true / CARGO_PROFILE_RELEASE_STRIP=false)。
set -euo pipefail

PERF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$PERF_DIR/.." && pwd)"
# shellcheck source=lib.sh
. "$PERF_DIR/lib.sh"

usage() {
	cat <<'EOF'
usage: profile.sh [options]

  --binary PATH      シンボル付きのビルド済みバイナリを使う (省略時はビルドする)
  --seconds N        計測時間 (default: 20)
  --concurrency N    同時接続数 (default: 4)
  --scenario NAME    シナリオ (複数指定可 / all)  default: all
  --avif             encode_avif=true で計測
  --freq HZ          perf のサンプリング周波数 (default: 99)
  --port PORT        プロキシのポート (default: 12766、使用中ならずらす)
  --origin-port PORT origin スタブのポート (default: 18080、使用中ならずらす)
  --corpus DIR       corpus ディレクトリ (default: perf/corpus)
  --label NAME       結果ディレクトリ名 (default: profile-<timestamp>)
  -h, --help
EOF
}

BINARY_ARG=""
SECONDS_ARG=20
CONCURRENCY=4
SCENARIOS=()
AVIF=0
FREQ=99
PROXY_PORT=12766
ORIGIN_PORT=18080
CORPUS="$PERF_DIR/corpus"
LABEL=""

while [ $# -gt 0 ]; do
	case "$1" in
		--binary)
			BINARY_ARG="$2"
			shift 2
			;;
		--seconds)
			SECONDS_ARG="$2"
			shift 2
			;;
		--concurrency)
			CONCURRENCY="$2"
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
		--freq)
			FREQ="$2"
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
		--corpus)
			CORPUS="$2"
			shift 2
			;;
		--label)
			LABEL="$2"
			shift 2
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

if ! command -v perf >/dev/null 2>&1; then
	cat >&2 <<'EOF'
error: perf が見つかりません
  Debian/Ubuntu: sudo apt-get install -y linux-perf
  Fedora:        sudo dnf install -y perf
  Arch:          sudo pacman -S perf
  (代替手段: cargo install flamegraph して `cargo flamegraph --release` を使う)
EOF
	exit 1
fi

PARANOID="$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "")"
if [ -n "$PARANOID" ] && [ "$PARANOID" -gt 1 ] 2>/dev/null; then
	perf_warn "kernel.perf_event_paranoid=$PARANOID のため perf record に root 権限が必要かもしれません"
	perf_warn "  sudo sysctl -w kernel.perf_event_paranoid=1 で緩和できます"
fi

[ -n "$LABEL" ] || LABEL="profile-$(date +%Y%m%d-%H%M%S)"
LABEL_DIR="$PERF_DIR/results/$LABEL"
mkdir -p "$LABEL_DIR"

PERF_PROXY_PID=""
PERF_ORIGIN_PID=""
LOADTEST_PID=""
cleanup() {
	perf_stop_pid "${LOADTEST_PID:-}"
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

# --- シンボル付きバイナリ -------------------------------------------------
PROFILE_TARGET_DIR="$ROOT_DIR/target/profile"
if [ -n "$BINARY_ARG" ]; then
	BINARY="$BINARY_ARG"
	[ -x "$BINARY" ] || perf_die "実行可能なバイナリではありません: $BINARY"
else
	perf_need cargo
	perf_info "シンボル付き release ビルド (target/profile、初回は時間がかかります)"
	(
		cd "$ROOT_DIR" &&
			CARGO_TARGET_DIR="$PROFILE_TARGET_DIR" \
				CARGO_PROFILE_RELEASE_DEBUG=true \
				CARGO_PROFILE_RELEASE_STRIP=false \
				cargo build --release
	)
	BINARY="$PROFILE_TARGET_DIR/release/media-proxy-rs"
fi

# --- 起動 -----------------------------------------------------------------
PROXY_PORT="$(perf_pick_port "$PROXY_PORT")"
ORIGIN_PORT="$(perf_pick_port "$ORIGIN_PORT")"
TARGET_URL="http://127.0.0.1:$PROXY_PORT"
ORIGIN_URL="http://127.0.0.1:$ORIGIN_PORT"

if [ "$AVIF" -eq 1 ]; then
	CONFIG_SRC="$PERF_DIR/config.perf-avif.json"
else
	CONFIG_SRC="$PERF_DIR/config.perf.json"
fi
CONFIG="$LABEL_DIR/config.json"
perf_patch_config "$CONFIG_SRC" "$CONFIG" "127.0.0.1:$PROXY_PORT"

perf_start_origin "$PERF_DIR" "$CORPUS" "$ORIGIN_PORT" "127.0.0.1" "$LABEL_DIR/origin.log"
perf_wait_http "http://127.0.0.1:$ORIGIN_PORT/healthz" 10 || perf_die "origin が起動しませんでした"

perf_start_proxy "$BINARY" "$CONFIG" "$LABEL_DIR/proxy.log"
perf_wait_http "$TARGET_URL/healthz" 10 || perf_die "プロキシが起動しませんでした ($LABEL_DIR/proxy.log)"
perf_info "proxy pid=$PERF_PROXY_PID target=$TARGET_URL"

# --- 負荷をかけて perf record --------------------------------------------
LOAD_ARGS=(
	--target "$TARGET_URL"
	--origin "$ORIGIN_URL"
	--concurrency "$CONCURRENCY"
	--warmup 2
	--duration $(( SECONDS_ARG + 3 ))
	--sample-pid "$PERF_PROXY_PID"
	--label "$LABEL"
	--out "$LABEL_DIR/load.json"
	--max-error-rate 1.0
)
if [ "${#SCENARIOS[@]}" -gt 0 ]; then
	for sc in "${SCENARIOS[@]}"; do
		LOAD_ARGS+=(--scenario "$sc")
	done
fi
if [ "$AVIF" -eq 1 ]; then
	LOAD_ARGS+=(--accept-avif)
fi
python3 "$PERF_DIR/loadtest.py" "${LOAD_ARGS[@]}" >"$LABEL_DIR/load.log" 2>&1 &
LOADTEST_PID=$!
perf_info "負荷をかけながら perf record を ${SECONDS_ARG}s 実行します"
sleep 2

perf record -F "$FREQ" -g --call-graph dwarf -o "$LABEL_DIR/perf.data" -p "$PERF_PROXY_PID" -- sleep "$SECONDS_ARG"
# loadtest は +3s 長く回しているので、計測結果を残すために少しだけ待つ
for _ in $(seq 1 50); do
	[ -d "/proc/$LOADTEST_PID" ] || break
	sleep 0.1
done
perf_stop_pid "$LOADTEST_PID"
LOADTEST_PID=""

# --- 後処理 ---------------------------------------------------------------
perf_info "perf report の要約を生成"
perf report --stdio -i "$LABEL_DIR/perf.data" --sort=dso,symbol -q 2>/dev/null | head -n 60 \
	>"$LABEL_DIR/top-symbols.txt" || true

if command -v inferno-flamegraph >/dev/null 2>&1; then
	perf script -i "$LABEL_DIR/perf.data" >"$LABEL_DIR/perf.script"
	inferno-flamegraph --title "$LABEL" "$LABEL_DIR/perf.script" >"$LABEL_DIR/flamegraph.svg"
	perf_info "flamegraph: $LABEL_DIR/flamegraph.svg"
elif command -v flamegraph.pl >/dev/null 2>&1; then
	perf script -i "$LABEL_DIR/perf.data" >"$LABEL_DIR/perf.script"
	flamegraph.pl --title "$LABEL" "$LABEL_DIR/perf.script" >"$LABEL_DIR/flamegraph.svg"
	perf_info "flamegraph: $LABEL_DIR/flamegraph.svg"
else
	perf_warn "inferno-flamegraph / flamegraph.pl が無いため SVG は生成しません"
	perf_warn "  cargo install inferno  (# inferno-flamegraph が入ります)"
fi

ARTIFACTS="perf.data / top-symbols.txt"
if [ -f "$LABEL_DIR/load.json" ]; then
	ARTIFACTS="$ARTIFACTS / load.json"
fi
if [ -f "$LABEL_DIR/flamegraph.svg" ]; then
	ARTIFACTS="$ARTIFACTS / flamegraph.svg"
fi
perf_info "結果: $LABEL_DIR ($ARTIFACTS)"
head -n 25 "$LABEL_DIR/top-symbols.txt" 2>/dev/null >&2 || true
