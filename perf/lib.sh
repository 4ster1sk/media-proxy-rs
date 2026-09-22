#!/usr/bin/env bash
# perf 配下のスクリプト共通ユーティリティ (source して使う)。
# 呼び出し側で `set -euo pipefail` を設定しておくこと。

perf_info() { printf '[perf] %s\n' "$*" >&2; }
perf_warn() { printf '[perf] warning: %s\n' "$*" >&2; }
perf_die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

perf_need() { # $1=command $2=補足
	command -v "$1" >/dev/null 2>&1 || perf_die "$1 が見つかりません ${2:-}"
}

perf_port_free() { # $1=port -> 0 なら空き
	python3 - "$1" <<'PY'
import socket, sys
s = socket.socket()
s.settimeout(0.3)
sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) != 0 else 1)
PY
}

perf_pick_port() { # $1=base -> 空きポートを stdout に返す
	local p
	for p in $(seq "$1" $(( $1 + 50 ))); do
		if perf_port_free "$p"; then
			echo "$p"
			return 0
		fi
	done
	perf_die "空きポートが見つかりません (base=$1)"
}

perf_wait_http() { # $1=url $2=timeout_sec
	local url="$1" timeout="${2:-10}" i=0 n
	n=$(( timeout * 10 ))
	while [ "$i" -lt "$n" ]; do
		if curl -fsS --max-time 1 -o /dev/null "$url" 2>/dev/null; then
			return 0
		fi
		sleep 0.1
		i=$(( i + 1 ))
	done
	return 1
}

perf_sha256() {
	sha256sum "$1" 2>/dev/null | cut -d' ' -f1
}

perf_cpu_model() {
	local m
	m=$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
	echo "${m:-unknown}"
}

perf_proc_state() { # $1=pid -> 状態1文字 (無ければ空)
	[ -r "/proc/$1/stat" ] || {
		echo ""
		return 0
	}
	# 終了直後のプロセスは stat が消えていることがあるため失敗を握りつぶす
	sed -e 's/^[^)]*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1 || true
}

perf_stop_pid() { # $1=pid
	local pid="${1:-}" i state
	[ -n "$pid" ] || return 0
	kill "$pid" 2>/dev/null || true
	for i in $(seq 1 50); do
		state=$(perf_proc_state "$pid" || true)
		case "$state" in
			"" | Z)
				wait "$pid" 2>/dev/null || true
				return 0
				;;
		esac
		sleep 0.1
	done
	kill -9 "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	return 0
}

perf_patch_config() { # $1=src $2=dst $3=bind_addr
	python3 - "$1" "$2" "$3" <<'PY'
import json, sys
src, dst, bind = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as fh:
    cfg = json.load(fh)
cfg["bind_addr"] = bind
with open(dst, "w") as fh:
    json.dump(cfg, fh, indent=2, ensure_ascii=False)
PY
}

perf_start_origin() { # $1=perf_dir $2=corpus $3=port $4=host $5=logfile -> PERF_ORIGIN_PID
	python3 "$1/origin.py" --corpus "$2" --port "$3" --host "$4" >"$5" 2>&1 &
	PERF_ORIGIN_PID=$!
}

perf_start_proxy() { # $1=binary $2=config $3=logfile [$4=cpus] -> PERF_PROXY_PID
	local bin="$1" cfg="$2" log="$3" cpus="${4:-}"
	if [ -n "$cpus" ]; then
		MEDIA_PROXY_CONFIG_PATH="$cfg" taskset -c "$cpus" "$bin" >"$log" 2>&1 &
	else
		MEDIA_PROXY_CONFIG_PATH="$cfg" "$bin" >"$log" 2>&1 &
	fi
	PERF_PROXY_PID=$!
}

perf_meta_set() { # $1=key $2=value
	export "PERF_META_$1=$2"
}

perf_install_traps() { # $1=cleanup 関数名
	# 出力を `| head` 等で閉じられた場合も、子プロセスを残さず終了する
	trap "$1" EXIT INT TERM
	trap "$1; trap - EXIT INT TERM PIPE; exit 141" PIPE
}

perf_collect_git_meta() { # $1=repo dir
	local repo="$1" rev dirty branch
	rev=$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)
	branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
	if [ -n "$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null || true)" ]; then
		dirty=1
	else
		dirty=0
	fi
	perf_meta_set GIT_REV "$rev"
	perf_meta_set GIT_BRANCH "$branch"
	perf_meta_set GIT_DIRTY "$dirty"
}

perf_write_meta() { # $1=outfile ; PERF_META_* 環境変数から meta.json を作る
	PERF_META_OUT="$1" python3 - <<'PY'
import datetime
import hashlib
import json
import os
import platform


def env(name, default=""):
    return os.environ.get("PERF_META_" + name, default)


def cpu_model():
    try:
        with open("/proc/cpuinfo") as fh:
            for line in fh:
                if line.startswith("model name"):
                    return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor() or "unknown"


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


corpus_dir = env("CORPUS_DIR")
corpus = {"dir": corpus_dir}
try:
    with open(os.path.join(corpus_dir, "corpus.sha256"), "rb") as fh:
        data = fh.read()
    corpus["files"] = len([line for line in data.decode().splitlines() if line.strip()])
    corpus["digest"] = hashlib.sha256(data).hexdigest()
except OSError:
    pass

binary_path = env("BINARY")
binary = {"path": binary_path} if binary_path else {}
if binary_path:
    try:
        binary["sha256"] = sha256_file(binary_path)
        binary["size"] = os.path.getsize(binary_path)
    except OSError:
        pass

config_path = env("CONFIG")
config_values = None
if config_path:
    try:
        with open(config_path) as fh:
            config_values = json.load(fh)
    except (OSError, json.JSONDecodeError):
        config_values = None

meta = {
    "label": env("LABEL"),
    "created_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "git": {
        "rev": env("GIT_REV"),
        "branch": env("GIT_BRANCH"),
        "dirty": env("GIT_DIRTY") == "1",
        "ref": env("GIT_REF"),
    },
    "describe": env("DESCRIBE"),
    "binary": binary,
    "rustc": env("RUSTC", "unknown") or "unknown",
    "host": {
        "cpu_model": cpu_model(),
        "cpu_count": os.cpu_count(),
        "kernel": platform.release(),
    },
    "corpus": corpus,
    "config": config_path,
    "config_values": config_values,
    "target": {"url": env("TARGET"), "uds": env("UDS"), "pid": env("PID")},
    "origin": env("ORIGIN"),
}
with open(os.environ["PERF_META_OUT"], "w") as fh:
    json.dump(meta, fh, indent=2, ensure_ascii=False)
PY
}
