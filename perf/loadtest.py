#!/usr/bin/env python3
"""media-proxy-rs 向け負荷生成器 / 計測ハーネス。

scenarios.json に従って `/?url=<origin>/<file>&<query>` を GET し、
レイテンシ百分位・RPS・エラー内訳・応答バイト数を集計する。

--sample-pid を指定すると対象プロセスの RSS と CPU 時間を /proc からサンプリングし、
CPU ms/req を算出する(レイテンシよりノイズに強く、before/after 比較の主指標になる)。

依存: Python 3.8+ の標準ライブラリのみ(UDS 対応のため http.client を直接使う)。
"""

from __future__ import annotations

import argparse
import http.client
import itertools
import json
import math
import os
import platform
import socket
import sys
import threading
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SCENARIOS = os.path.join(HERE, "scenarios.json")
CLK_TCK = os.sysconf("SC_CLK_TCK")


# --------------------------------------------------------------- /proc サンプリング
def read_rss_mb(pid: int):
    try:
        with open(f"/proc/{pid}/status", "r") as fh:
            for line in fh:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1]) / 1024.0
    except OSError:
        return None
    return None


def read_cpu_seconds(pid: int):
    try:
        with open(f"/proc/{pid}/stat", "r") as fh:
            data = fh.read()
    except OSError:
        return None
    # comm は括弧を含み得るため、最後の ')' 以降をフィールドとして扱う
    cut = data.rfind(")")
    if cut < 0:
        return None
    fields = data[cut + 2 :].split()
    if len(fields) < 14:
        return None
    # 先頭は state (field 3)。utime=field14 -> index 11, stime=field15 -> index 12
    return (int(fields[11]) + int(fields[12])) / CLK_TCK


class ProcessSampler(threading.Thread):
    """対象プロセスの RSS / CPU 時間を一定間隔でサンプリングする。"""

    def __init__(self, pid: int, interval: float = 0.2):
        super().__init__(daemon=True)
        self.pid = pid
        self.interval = interval
        self._stop = threading.Event()
        self.rss_samples = []
        self.cpu_start = None
        self.cpu_end = None
        self.t_start = None
        self.t_end = None

    def run(self):
        self.cpu_start = read_cpu_seconds(self.pid)
        self.t_start = time.perf_counter()
        while not self._stop.is_set():
            rss = read_rss_mb(self.pid)
            if rss is not None:
                self.rss_samples.append(rss)
            self._stop.wait(self.interval)
        rss = read_rss_mb(self.pid)
        if rss is not None:
            self.rss_samples.append(rss)
        self.cpu_end = read_cpu_seconds(self.pid)
        self.t_end = time.perf_counter()

    def stop(self):
        self._stop.set()
        self.join(timeout=5)

    def summary(self, request_count: int):
        if self.cpu_start is None and not self.rss_samples:
            return None
        out = {"pid": self.pid}
        if self.rss_samples:
            out["rss_peak_mb"] = round(max(self.rss_samples), 1)
            out["rss_end_mb"] = round(self.rss_samples[-1], 1)
        if self.cpu_start is not None and self.cpu_end is not None:
            cpu_s = max(0.0, self.cpu_end - self.cpu_start)
            out["cpu_s"] = round(cpu_s, 2)
            if self.t_start is not None and self.t_end is not None:
                out["window_s"] = round(self.t_end - self.t_start, 2)
            if request_count:
                out["cpu_ms_per_req"] = round(cpu_s * 1000.0 / request_count, 2)
        return out


# ------------------------------------------------------------------ HTTP クライアント
class UnixHTTPConnection(http.client.HTTPConnection):
    """UNIX ドメインソケットへ接続する HTTPConnection (bind_addr=unix:// 用)。"""

    def __init__(self, uds_path: str, timeout: float):
        super().__init__("localhost", timeout=timeout)
        self._uds_path = uds_path

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self._uds_path)
        self.sock = sock


class Sample:
    __slots__ = (
        "scenario",
        "latency_ms",
        "status",
        "bytes",
        "error",
        "proxy_error",
        "content_type",
    )

    def __init__(self, scenario, latency_ms, status, nbytes, error, proxy_error, content_type):
        self.scenario = scenario
        self.latency_ms = latency_ms
        self.status = status
        self.bytes = nbytes
        self.error = error
        self.proxy_error = proxy_error
        self.content_type = content_type


def worker(thread_index, scenarios, make_conn, headers, samples, stop_event, measure_start):
    names = list(scenarios.keys())
    rot = thread_index % len(names)
    cycle = itertools.cycle(names[rot:] + names[:rot])
    conn = None
    while not stop_event.is_set():
        name = next(cycle)
        path = scenarios[name]["_path"]
        t0 = time.perf_counter()
        status = 0
        nbytes = 0
        error = None
        proxy_error = None
        content_type = ""
        try:
            if conn is None:
                conn = make_conn()
            conn.request("GET", path, headers=headers)
            resp = conn.getresponse()
            status = resp.status
            proxy_error = resp.getheader("X-Proxy-Error")
            content_type = (resp.getheader("Content-Type") or "").split(";")[0].strip()
            nbytes = len(resp.read())
        except Exception as exc:  # noqa: BLE001 - ネットワーク例外はすべて記録する
            error = type(exc).__name__
            if conn is not None:
                try:
                    conn.close()
                except Exception:
                    pass
                conn = None
        t1 = time.perf_counter()
        if t1 >= measure_start:
            samples.append(
                Sample(name, (t1 - t0) * 1000.0, status, nbytes, error, proxy_error, content_type)
            )
    if conn is not None:
        try:
            conn.close()
        except Exception:
            pass


# ---------------------------------------------------------------------- 集計
def percentile(sorted_values, q):
    if not sorted_values:
        return None
    idx = max(0, math.ceil(q * len(sorted_values)) - 1)
    return sorted_values[min(idx, len(sorted_values) - 1)]


def summarize_scenario(name, s_list, duration):
    latencies = sorted(s.latency_ms for s in s_list)
    status_counts = {}
    error_counts = {}
    proxy_errors = {}
    content_types = {}
    total_bytes = 0
    error_requests = 0
    for s in s_list:
        status_counts[str(s.status)] = status_counts.get(str(s.status), 0) + 1
        if s.error:
            error_counts[s.error] = error_counts.get(s.error, 0) + 1
        if s.proxy_error:
            proxy_errors[s.proxy_error] = proxy_errors.get(s.proxy_error, 0) + 1
        if s.content_type:
            content_types[s.content_type] = content_types.get(s.content_type, 0) + 1
        total_bytes += s.bytes
        if s.error or s.status >= 400:
            error_requests += 1
    count = len(s_list)
    return {
        "scenario": name,
        "count": count,
        "rps": round(count / duration, 2) if duration > 0 else 0.0,
        "latency_ms": {
            "min": round(latencies[0], 2) if latencies else None,
            "p50": round(percentile(latencies, 0.50), 2) if latencies else None,
            "p90": round(percentile(latencies, 0.90), 2) if latencies else None,
            "p99": round(percentile(latencies, 0.99), 2) if latencies else None,
            "max": round(latencies[-1], 2) if latencies else None,
            "mean": round(sum(latencies) / count, 2) if count else None,
        },
        "status": status_counts,
        "errors": error_counts,
        "error_rate": round(error_requests / count, 5) if count else 0.0,
        "proxy_errors": dict(sorted(proxy_errors.items(), key=lambda kv: -kv[1])[:10]),
        "content_types": content_types,
        "bytes": {
            "total": total_bytes,
            "mean": round(total_bytes / count, 1) if count else 0,
            "mb_per_s": round(total_bytes / 1e6 / duration, 3) if duration > 0 else 0.0,
        },
    }


def dominant(mapping):
    if not mapping:
        return ""
    return max(mapping.items(), key=lambda kv: kv[1])[0]


def print_table(results, target_desc, args, measure_window, server):
    print()
    print(
        f"target={target_desc}  concurrency={args.concurrency}  "
        f"warmup={args.warmup:g}s  measure={measure_window:g}s"
    )
    header = (
        f"{'scenario':<18}{'reqs':>7}{'req/s':>9}{'p50':>8}{'p90':>8}{'p99':>8}"
        f"{'max':>8}{'err%':>7}  {'type':<12}{'KB/req':>8}"
    )
    print(header)
    print("-" * len(header))
    for name, r in results.items():
        lat = r["latency_ms"]
        type_str = dominant(r["content_types"]) or "-"
        kb = (r["bytes"]["mean"] / 1024.0) if r["count"] else 0
        print(
            f"{name:<18}{r['count']:>7}{r['rps']:>9.1f}"
            f"{fmt(lat['p50']):>8}{fmt(lat['p90']):>8}{fmt(lat['p99']):>8}{fmt(lat['max']):>8}"
            f"{r['error_rate'] * 100:>7.2f}  {type_str:<12}{kb:>8.1f}"
        )
    if server:
        extras = []
        if "rss_peak_mb" in server:
            extras.append(f"rss_peak={server['rss_peak_mb']}MB")
        if "cpu_s" in server:
            extras.append(f"cpu={server['cpu_s']}s")
        if "cpu_ms_per_req" in server:
            extras.append(f"cpu/req={server['cpu_ms_per_req']}ms")
        if extras:
            print("server: " + " ".join(extras))
    print()


def fmt(v):
    return "-" if v is None else f"{v:.1f}"


# ------------------------------------------------------------------------ main
def main() -> int:
    parser = argparse.ArgumentParser(description="media-proxy-rs 負荷生成器")
    parser.add_argument("--target", help="http://host:port (プロキシ)")
    parser.add_argument("--uds", help="プロキシの UNIX ドメインソケットパス")
    parser.add_argument("--origin", default="http://127.0.0.1:18080", help="url= に渡す origin の基底")
    parser.add_argument("--scenario", action="append", help="シナリオ名 (複数指定可 / all)")
    parser.add_argument("--scenarios-file", default=DEFAULT_SCENARIOS)
    parser.add_argument("--concurrency", type=int, default=8)
    parser.add_argument("--duration", type=float, default=15.0, help="計測時間 [s]")
    parser.add_argument("--warmup", type=float, default=5.0, help="ウォームアップ時間 [s] (集計対象外)")
    parser.add_argument("--timeout", type=float, default=30.0, help="1リクエストのタイムアウト [s]")
    parser.add_argument("--sample-pid", type=int, help="RSS/CPU をサンプリングする対象プロセス")
    parser.add_argument("--accept-avif", action="store_true", help="Accept: image/avif を送る")
    parser.add_argument("--max-error-rate", type=float, default=0.01, help="超えたら非0終了 (default 0.01)")
    parser.add_argument("--meta", help="結果に埋め込む meta.json")
    parser.add_argument("--out", help="結果 JSON の出力先")
    parser.add_argument("--label", default="")
    args = parser.parse_args()

    if bool(args.target) == bool(args.uds):
        print("error: --target か --uds のどちらか一方を指定してください", file=sys.stderr)
        return 2
    if args.concurrency < 1 or args.duration <= 0:
        print("error: --concurrency >= 1 かつ --duration > 0 が必要です", file=sys.stderr)
        return 2

    with open(args.scenarios_file, "r") as fh:
        all_scenarios = json.load(fh)
    wanted = args.scenario or ["all"]
    if "all" in wanted:
        selected = dict(all_scenarios)
    else:
        unknown = [n for n in wanted if n not in all_scenarios]
        if unknown:
            print(f"error: 未知のシナリオ: {', '.join(unknown)}", file=sys.stderr)
            print(f"  利用可能: {', '.join(all_scenarios)}", file=sys.stderr)
            return 2
        selected = {n: all_scenarios[n] for n in wanted}

    origin_base = args.origin.rstrip("/")
    for scen in selected.values():
        params = {"url": f"{origin_base}/{scen['file']}"}
        params.update(scen.get("query") or {})
        scen["_path"] = "/?" + urllib.parse.urlencode(params)

    if args.uds:
        make_conn = lambda: UnixHTTPConnection(args.uds, args.timeout)  # noqa: E731
        target_desc = f"unix:{args.uds}"
    else:
        parts = urllib.parse.urlsplit(args.target)
        if parts.scheme != "http":
            print(f"error: --target は http:// で指定してください: {args.target}", file=sys.stderr)
            return 2
        host = parts.hostname or "127.0.0.1"
        port = parts.port or 80
        make_conn = lambda: http.client.HTTPConnection(host, port, timeout=args.timeout)  # noqa: E731
        target_desc = f"http://{host}:{port}"

    headers = {"Accept": "image/avif,*/*"} if args.accept_avif else {"Accept": "*/*"}

    stop_event = threading.Event()
    samples_per_thread = [[] for _ in range(args.concurrency)]
    t0 = time.perf_counter()
    measure_start = t0 + args.warmup
    end_at = measure_start + args.duration

    threads = []
    for i in range(args.concurrency):
        th = threading.Thread(
            target=worker,
            args=(i, selected, make_conn, headers, samples_per_thread[i], stop_event, measure_start),
            daemon=True,
        )
        th.start()
        threads.append(th)

    while time.perf_counter() < measure_start:
        time.sleep(0.02)
    sampler = None
    if args.sample_pid:
        sampler = ProcessSampler(args.sample_pid)
        sampler.start()
    print(f"measuring {args.duration:g}s ...", file=sys.stderr)
    while time.perf_counter() < end_at:
        time.sleep(0.02)
    stop_event.set()
    for th in threads:
        th.join(timeout=max(5.0, args.timeout + 1.0))
    if sampler is not None:
        sampler.stop()

    samples = [s for chunk in samples_per_thread for s in chunk]
    results = {}
    for name in selected:
        results[name] = summarize_scenario(name, [s for s in samples if s.scenario == name], args.duration)

    server = sampler.summary(len(samples)) if sampler is not None else None
    error_requests = sum(1 for s in samples if s.error or s.status >= 400)
    error_rate = (error_requests / len(samples)) if samples else 1.0

    print_table(results, target_desc, args, args.duration, server)

    meta = {}
    if args.meta:
        try:
            with open(args.meta, "r") as fh:
                meta = json.load(fh)
        except (OSError, json.JSONDecodeError) as exc:
            print(f"warning: --meta を読めません ({exc})", file=sys.stderr)

    doc = {
        "label": args.label,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "target": target_desc,
        "origin": origin_base,
        "scenarios": results,
        "totals": {
            "requests": len(samples),
            "errors": error_requests,
            "error_rate": round(error_rate, 5),
            "cpu_ms_per_req": (server or {}).get("cpu_ms_per_req"),
            "rps": round(len(samples) / args.duration, 2) if args.duration > 0 else 0.0,
        },
        "server": server,
        "run": {
            "concurrency": args.concurrency,
            "duration_s": args.duration,
            "warmup_s": args.warmup,
            "accept_avif": args.accept_avif,
            "client_python": platform.python_version(),
        },
        "host": {
            "hostname": socket.gethostname(),
            "cpu_model": cpu_model(),
            "cpu_count": os.cpu_count(),
            "kernel": platform.release(),
        },
        "meta": meta,
    }

    if args.out:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w") as fh:
            json.dump(doc, fh, indent=2, ensure_ascii=False)
        print(f"wrote {args.out}")

    if not samples:
        print("error: 1件もリクエストが完了しませんでした", file=sys.stderr)
        return 1
    if error_rate > args.max_error_rate:
        print(
            f"error: エラー率 {error_rate * 100:.2f}% がしきい値 {args.max_error_rate * 100:.2f}% を超えました",
            file=sys.stderr,
        )
        return 1
    return 0


def cpu_model():
    try:
        with open("/proc/cpuinfo", "r") as fh:
            for line in fh:
                if line.startswith("model name"):
                    return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor() or "unknown"


if __name__ == "__main__":
    sys.exit(main())
