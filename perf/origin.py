#!/usr/bin/env python3
"""perf/corpus/ を配信するローカル origin スタブ。

メディアプロキシに取り込ませる「上流サーバ」の代役。Range には対応しない
(プロキシは画像が 206 で返ると Range 無しで取り直すため、常に 200 + フルボディを返す)。

依存: Python 3.8+ の標準ライブラリのみ。
"""

from __future__ import annotations

import argparse
import http.server
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))

EXT_TYPES = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".webp": "image/webp",
    ".gif": "image/gif",
    ".svg": "image/svg+xml",
    ".avif": "image/avif",
    ".jxl": "image/jxl",
    ".bmp": "image/bmp",
    ".tif": "image/tiff",
    ".tiff": "image/tiff",
    ".ico": "image/x-icon",
    ".qoi": "image/qoi",
    ".mp4": "video/mp4",
    ".webm": "video/webm",
    ".mp3": "audio/mpeg",
    ".ogg": "audio/ogg",
}


class Handler(http.server.SimpleHTTPRequestHandler):
    delay_ms = 0
    verbose = False

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=Handler.corpus_dir, **kwargs)

    def do_GET(self):  # noqa: N802 (http.server の命名に合わせる)
        if Handler.delay_ms:
            time.sleep(Handler.delay_ms / 1000.0)
        if self.path.split("?")[0] == "/healthz":
            body = b"ok"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

    def log_message(self, fmt, *args):
        if Handler.verbose:
            super().log_message(fmt, *args)


def main() -> int:
    parser = argparse.ArgumentParser(description="corpus を配信するローカル origin スタブ")
    parser.add_argument("--corpus", default=os.path.join(HERE, "corpus"), help="配信するディレクトリ")
    parser.add_argument("--host", default="127.0.0.1", help="bind するアドレス (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=18080, help="bind するポート (default: 18080)")
    parser.add_argument(
        "--delay-ms",
        type=int,
        default=0,
        help="応答前に待つミリ秒 (低速な上流の模擬)",
    )
    parser.add_argument("--verbose", action="store_true", help="アクセスログを表示する")
    args = parser.parse_args()

    corpus = os.path.abspath(args.corpus)
    if not os.path.isdir(corpus):
        print(f"error: corpus directory not found: {corpus}", file=sys.stderr)
        print("  perf/gen_corpus.sh を先に実行してください", file=sys.stderr)
        return 1

    Handler.corpus_dir = corpus
    Handler.delay_ms = args.delay_ms
    Handler.verbose = args.verbose
    Handler.extensions_map = {**Handler.extensions_map, **EXT_TYPES}

    server = http.server.ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    print(
        f"origin listening on http://{args.host}:{args.port} (corpus={corpus}, delay={args.delay_ms}ms)",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
