#!/usr/bin/env python3
"""loadtest.py の結果 JSON から before/after 比較の markdown レポートを作る。

- 複数ファイル(ラウンド)を渡すと、各指標の中央値を取る
- 片側だけ渡すと単独のサマリ表になる
- ±threshold% (default 5%) 未満の差分はノイズとみなし強調しない

依存: Python 3.8+ の標準ライブラリのみ。
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import statistics
import sys
import time

# (key, 見出し, 大きい方が良い指標か)
COLUMNS = [
    ("rps", "req/s", True),
    ("p50", "p50 (ms)", False),
    ("p90", "p90 (ms)", False),
    ("p99", "p99 (ms)", False),
    ("error_rate", "err %", False),
    ("cpu_ms_per_req", "CPU ms/req", False),
    ("rss_peak_mb", "RSS peak (MB)", False),
]


def load_docs(paths):
    docs = []
    for path in paths:
        try:
            with open(path, "r") as fh:
                doc = json.load(fh)
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(doc, dict) and "scenarios" in doc:
            doc["_path"] = path
            docs.append(doc)
    return docs


def dominant(mapping):
    if not mapping:
        return ""
    return max(mapping.items(), key=lambda kv: kv[1])[0]


def scenario_metrics(doc):
    """doc を {scenario: metrics} に展開する。

    CPU/RSS は doc 全体の値なので、doc が単一シナリオのときだけ帰属させる
    (run.sh はシナリオごとに loadtest を実行するため通常は単一)。
    """
    server = doc.get("server") or {}
    single = len(doc.get("scenarios") or {}) == 1
    out = {}
    for name, res in (doc.get("scenarios") or {}).items():
        lat = res.get("latency_ms") or {}
        out[name] = {
            "count": res.get("count"),
            "rps": res.get("rps"),
            "p50": lat.get("p50"),
            "p90": lat.get("p90"),
            "p99": lat.get("p99"),
            "error_rate": (res.get("error_rate") or 0.0) * 100.0,
            "cpu_ms_per_req": server.get("cpu_ms_per_req") if single else None,
            "rss_peak_mb": server.get("rss_peak_mb") if single else None,
            "type": dominant(res.get("content_types") or {}),
        }
    return out


def median_metrics(docs):
    """{scenario: metrics} の中央値を scenario ごとにまとめる。"""
    per_scenario = {}
    for doc in docs:
        for name, metrics in scenario_metrics(doc).items():
            per_scenario.setdefault(name, []).append(metrics)
    out = {}
    for name, rows in per_scenario.items():
        agg = {}
        for key, _label, _higher in COLUMNS:
            values = [r[key] for r in rows if r.get(key) is not None]
            agg[key] = statistics.median(values) if values else None
        types = [r["type"] for r in rows if r.get("type")]
        agg["type"] = max(set(types), key=types.count) if types else ""
        counts = [r["count"] for r in rows if r.get("count") is not None]
        agg["count"] = int(statistics.median(counts)) if counts else None
        out[name] = agg
    return out


def fmt_value(key, value):
    if value is None:
        return "-"
    if key in ("p50", "p90", "p99", "cpu_ms_per_req", "rss_peak_mb"):
        return f"{value:.1f}"
    if key == "error_rate":
        return f"{value:.2f}"
    if key == "rps":
        return f"{value:.1f}"
    return str(value)


def fmt_delta(key, base, head, higher_is_better, threshold):
    if base is None or head is None:
        return "-"
    if base == 0:
        return f"{base:.1f} → {head:.1f}"
    delta = (head - base) / abs(base) * 100.0
    sign = "+" if delta >= 0 else ""
    body = f"{base:.1f} → {head:.1f} ({sign}{delta:.1f}%)"
    if abs(delta) < threshold:
        return body
    worse = (delta < 0) if higher_is_better else (delta > 0)
    return f"**{body}** ⚠" if worse else f"**{body}**"


def describe_side(label, docs):
    if not docs:
        return f"- {label}: (no data)"
    doc = docs[0]
    meta = doc.get("meta") or {}
    run = doc.get("run") or {}
    git = meta.get("git") or {}
    binary = meta.get("binary") or {}
    parts = [f"- **{label}**"]
    if git.get("rev"):
        rev = git["rev"][:12]
        dirty = " (dirty)" if git.get("dirty") else ""
        ref = f" ({git['ref']})" if git.get("ref") else ""
        parts.append(f"rev `{rev}`{dirty}{ref}")
    if meta.get("describe"):
        parts.append(meta["describe"])
    if binary.get("sha256"):
        size_mb = (binary.get("size") or 0) / 1048576.0
        parts.append(f"binary sha256 `{binary['sha256'][:12]}` ({size_mb:.1f} MiB)")
    parts.append(f"samples={len(docs)}")
    if run:
        parts.append(
            f"concurrency={run.get('concurrency')} duration={run.get('duration_s')}s "
            f"warmup={run.get('warmup_s')}s accept_avif={run.get('accept_avif')}"
        )
    return " / ".join(parts)


def host_line(docs):
    if not docs:
        return "-"
    host = docs[0].get("host") or {}
    return (
        f"- host: {host.get('cpu_model', '?')} ({host.get('cpu_count', '?')} cores) / "
        f"{host.get('kernel', '?')} / python {docs[0].get('run', {}).get('client_python', '?')}"
    )


def build_report(title, base_label, head_label, base_docs, head_docs, threshold, notes):
    lines = []
    lines.append(f"## {title}")
    lines.append("")
    lines.append(describe_side(base_label, base_docs))
    if head_docs:
        lines.append(describe_side(head_label, head_docs))
    lines.append(host_line(base_docs or head_docs))
    corpus = ((base_docs or head_docs)[0].get("meta") or {}).get("corpus") if (base_docs or head_docs) else None
    if corpus:
        lines.append(f"- corpus: {corpus.get('files', '?')} files, digest `{corpus.get('digest', '?')}`")
    lines.append(f"- generated: {time.strftime('%Y-%m-%dT%H:%M:%S%z')}")
    for note in notes:
        lines.append(f"- {note}")
    lines.append("")

    scenarios = sorted(set(median_metrics(base_docs)) | set(median_metrics(head_docs)))
    base_agg = median_metrics(base_docs)
    head_agg = median_metrics(head_docs)

    if head_docs:
        header = "| scenario | " + " | ".join(label for _k, label, _h in COLUMNS) + " | type |"
        sep = "|" + "---|" * (len(COLUMNS) + 2)
        lines.append(header)
        lines.append(sep)
        for name in scenarios:
            b = base_agg.get(name, {})
            h = head_agg.get(name, {})
            cells = []
            for key, _label, higher in COLUMNS:
                cells.append(fmt_delta(key, b.get(key), h.get(key), higher, threshold))
            btype = b.get("type") or "-"
            htype = h.get("type") or "-"
            type_cell = btype if btype == htype else f"{btype} → {htype} ⚠"
            lines.append(f"| {name} | " + " | ".join(cells) + f" | {type_cell} |")
    else:
        header = "| scenario | " + " | ".join(label for _k, label, _h in COLUMNS) + " | type |"
        sep = "|" + "---|" * (len(COLUMNS) + 2)
        lines.append(header)
        lines.append(sep)
        for name in scenarios:
            b = base_agg.get(name, {})
            cells = [fmt_value(key, b.get(key)) for key, _label, _h in COLUMNS]
            lines.append(f"| {name} | " + " | ".join(cells) + f" | {b.get('type') or '-'} |")

    lines.append("")
    if head_docs:
        lines.append(
            f"太字は {threshold:g}% 以上の変化、⚠ は悪化方向の変化。"
            "CPU ms/req は最もノイズに強い比較指標。レイテンシは同一マシンでの負荷生成との競合に、"
            "RSS は確保タイミングに左右されやすいため、単発の差分は `--rounds` を増やして確認すること。"
        )
    return "\n".join(lines) + "\n"


def expand_dirs(dirs):
    paths = []
    for d in dirs:
        paths.extend(sorted(glob.glob(os.path.join(d, "**", "*.json"), recursive=True)))
    return paths


def main() -> int:
    parser = argparse.ArgumentParser(description="loadtest 結果の比較レポート生成")
    parser.add_argument("--base", nargs="*", default=[], help="base 側の結果 JSON")
    parser.add_argument("--head", nargs="*", default=[], help="head 側の結果 JSON")
    parser.add_argument("--base-dir", action="append", default=[], help="base 側の結果ディレクトリ")
    parser.add_argument("--head-dir", action="append", default=[], help="head 側の結果ディレクトリ")
    parser.add_argument("--base-label", default="base")
    parser.add_argument("--head-label", default="head")
    parser.add_argument("--title", default="Performance report")
    parser.add_argument("--threshold", type=float, default=5.0, help="有意とみなす差分 [%%]")
    parser.add_argument("--note", action="append", default=[], help="レポートに追記する注記")
    parser.add_argument("--out", help="markdown の出力先")
    parser.add_argument("--quiet", action="store_true", help="stdout に出力しない")
    args = parser.parse_args()

    base_paths = list(args.base) + expand_dirs(args.base_dir)
    head_paths = list(args.head) + expand_dirs(args.head_dir)
    base_docs = load_docs(base_paths)
    head_docs = load_docs(head_paths)

    if not base_docs and not head_docs:
        print("error: 結果 JSON が 1 つも読み込めませんでした", file=sys.stderr)
        return 1
    if not base_docs:
        base_docs, base_label, head_label = head_docs, args.base_label, args.head_label
        head_docs = []
    else:
        base_label, head_label = args.base_label, args.head_label

    notes = list(args.note)
    report = build_report(args.title, base_label, head_label, base_docs, head_docs, args.threshold, notes)

    if args.out:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w") as fh:
            fh.write(report)
        print(f"wrote {args.out}", file=sys.stderr)
    if not args.quiet:
        print(report, end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
