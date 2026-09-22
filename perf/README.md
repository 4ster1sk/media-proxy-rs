# perf/ — media-proxy-rs パフォーマンス測定ハーネス

メディアプロキシの性能を **メインコードを変更せずに** 測定するための外部ハーネス群です。
任意のリビジョン・任意のバイナリ(Docker イメージやリリース成果物を含む)に対して実行できます。

## できること

| 目的 | 使うもの |
|---|---|
| 手元/実機のプロキシ性能を一発で測定 | `run.sh` |
| PR の before/after を比較してレポート化 | `compare.sh` |
| どの関数が CPU を食っているか調べる | `profile.sh` |

計測できる指標:

- クライアント観測レイテンシ (p50 / p90 / p99 / max)、RPS、スループット (MB/s)
- status / `X-Proxy-Error` 内訳、応答 Content-Type
- サーバープロセスの **RSS ピーク** と **CPU 時間**、そこから算出する **CPU ms/req**
- `profile.sh` による flamegraph (CPU 内訳)

計測できないもの: サーバー内のフェーズ別時間 (fetch / queue / decode / resize / encode)。
これはコード内計測が必要になるため、必要なら別途パッチを当ててください(代わりに flamegraph と
CPU ms/req でボトルネックを推定します)。

## 必要要件

- `python3` (3.8+) — 必須
- `curl` — 必須
- ImageMagick (`magick` または `convert`)、無ければ **ffmpeg** — corpus 生成時のみ
- Rust ツールチェーン (`cargo`) — バイナリをその場でビルドする場合のみ (`--binary` 指定なら不要)
- `perf` (+ 任意で `inferno-flamegraph`) — `profile.sh` のみ

## クイックスタート

```sh
# 1) ローカルでビルドして全シナリオ測定 (~3分)
perf/run.sh

# 2) 実機: ビルド済みバイナリで測定 (Rust 不要)
perf/run.sh --binary /usr/local/bin/media-proxy-rs

# 3) 稼働中のプロキシに負荷をかけるだけ (Docker / systemd で動いている場合)
perf/run.sh --target http://127.0.0.1:12766 --no-start --pid "$(pgrep -f media-proxy-rs | head -1)"

# 4) UNIX ドメインソケットで待ち受けている場合
perf/run.sh --uds /run/media-proxy/proxy.sock --no-start

# 5) AVIF エンコード経路 (重い) を測定
perf/run.sh --avif
```

結果は `perf/results/<label>/` に保存され、`report.md` が PR に貼れる形式のサマリです。
`run.sh` は corpus 生成 → origin 起動 → (必要ならビルド・プロキシ起動) → 計測 → 停止 →
レポート作成までを一括で行い、終了時に必ず子プロセスを停止します。

主なオプション: `--scenario NAME` / `--concurrency N` / `--duration SEC` / `--warmup SEC` /
`--rounds N` / `--port` / `--origin-port` / `--pin` (server と client を別コアに固定) /
`--config FILE` (使う設定ファイルを明示)。
`perf/run.sh --help` を参照してください。

## PR 用 before/after 比較

```sh
# git ref 同士 (worktree を作って両方をビルド)
perf/compare.sh --base origin/main --head HEAD

# ビルド済みバイナリ同士 (実機向け)
perf/compare.sh --base-bin ./old/media-proxy-rs --head-bin ./new/media-proxy-rs --rounds 3

# 未コミットの作業ツリーも比較できる (ディレクトリ指定)
perf/compare.sh --base /path/to/clone --head .
```

- corpus と config は両者で共通 (corpus の sha256 を meta に記録)
- 各ラウンドで base/head を交互に起動し、指標は **ラウンド中央値** を採用
- `--base-label` / `--head-label` でレポートの表示名を指定できる(フォーク比較など)
- `--config FILE` で測定用設定を明示できる(相手側だけが知る追加フィールドを入れた設定を使う場合など)
- 出力: `perf/results/compare-<timestamp>/report.md`

```markdown
| scenario     | req/s                  | p50 (ms)          | p99 (ms)          | err % | CPU ms/req        | RSS peak (MB) |
|--------------|------------------------|-------------------|-------------------|-------|-------------------|---------------|
| jpeg_preview | 412.3 → 430.1 (+4.3%)  | 18.1 → 17.2 (-5.0%) | 45.2 → 43.8 (-3.1%) | 0 → 0 | 21.3 → 20.1 (-5.6%) | 118.0 → 115.2 (-2.4%) |
```

太字は `--threshold` (default 5%) 以上の変化、⚠ は悪化方向の変化です。

## CPU プロファイル

```sh
perf/profile.sh --seconds 20 --scenario jpeg_preview
```

`Cargo.toml` を変更せず、環境変数でシンボル付き release ビルドを作ります
(`target/profile/` に出力、初回は時間がかかります)。負荷をかけながら `perf record` し、
`perf/results/<label>/flamegraph.svg` と `top-symbols.txt` を生成します。

`--binary` で既存バイナリを使う場合は、シンボル付きでビルドしたものを渡してください:

```sh
CARGO_TARGET_DIR=target/profile CARGO_PROFILE_RELEASE_DEBUG=true \
  CARGO_PROFILE_RELEASE_STRIP=false cargo build --release
```

## シナリオ

`scenarios.json` で定義 (編集すればコード変更なしでケース追加できます):

| 名前 | 入力 | クエリ | 主に測っている経路 |
|---|---|---|---|
| `jpeg_preview` | JPEG 4000×3000 | `preview=1` | 大サイズ JPEG の縮小 + WebP エンコード |
| `jpeg_avatar` | JPEG 4000×3000 | `avatar=1` | 高さ 320 への縮小 |
| `jpeg_static` | JPEG 4000×3000 | `static=1` | 498×422 への縮小 |
| `jpeg_maxpixels` | JPEG 4000×3000 | (なし) | max_pixels(2048) への縮小のみ |
| `png_badge` | 透過 PNG 1500² | `badge=1` | グレースケール化 + 中央クロップ + PNG 出力 |
| `webp_preview` | WebP 1600×1200 | `preview=1` | WebP デコード → 再エンコード |
| `gif_anim` | アニメ GIF 30フレーム | `preview=1` | アニメーション WebP エンコード |
| `svg_avatar` | SVG | `avatar=1` | resvg ラスタライズ |
| `small_emoji` | JPEG 320² | `emoji=1` | 幅クランプ + エンコード |
| `noise_preview` | 高エントロピー PNG 1024² | `preview=1` | エンコード上限側のストレス |

## 結果の読み方

- **CPU ms/req** (サーバープロセスの CPU 時間 ÷ リクエスト数) が最もノイズに強い比較指標。
  レイテンシは負荷生成とサーバーが同一マシンで CPU を奪い合うため、環境の影響を受けやすい。
- **±5% 未満の差分はノイズとみなす**。より確実に見たい場合は `--rounds` を増やす。
- **RSS ピーク** はプロセス全体の値で、同一実行内のシナリオ間で持ち越される
  (直前の大きいシナリオの影響を受ける)。厳密に見たい場合は `--scenario` を1つに絞る。
- Content-Type 列が base と head で変わっている場合は出力形式のリグレッションの可能性があります。

## 構成

| ファイル | 役割 |
|---|---|
| `run.sh` | ワンショット実行 (dev / 実機 / 稼働中プロキシ) |
| `compare.sh` | 2リビジョン・2バイナリの before/after 比較 |
| `profile.sh` | `perf` による CPU プロファイル |
| `loadtest.py` | 負荷生成 + レイテンシ集計 + `/proc` サンプリング |
| `origin.py` | corpus を配信するローカル origin スタブ |
| `gen_corpus.sh` | corpus 生成 + sha256 記録 (ImageMagick、無ければ ffmpeg) |
| `summarize.py` | 結果 JSON → markdown レポート |
| `scenarios.json` | シナリオ定義 |
| `config.perf.json` / `config.perf-avif.json` | 測定用プロキシ設定 |
| `config.perf-nocache.json` / `config.perf-avif-nocache.json` | キャッシュ/パススルーを無効化した設定(ブランチ間で純粋な処理性能を比べるとき用。未対応のバイナリは余分なフィールドを無視する) |
| `lib.sh` | スクリプト共通ユーティリティ |

`perf/corpus/` と `perf/results/` は git 管理外です。

## 注意事項

- `config.perf.json` は `allowed_networks: ["127.0.0.0/8"]` を設定しています。ローカルの
  origin スタブをプロキシに取得させるために必要です(既定ではループバックは拒否されます)。
- 稼働中プロキシを `--target` で測定する場合は、そのプロキシが `--origin-url` に到達できる
  必要があります。本番プロキシがプライベートアドレスを拒否している場合は、corpus を
  どこか到達可能な場所に置くか、`--origin-url` を実際のメディア URL を返すサーバーに
  向けてください。
- 負荷生成とサーバーが同一マシンの場合は `--concurrency` を低〜中 (2〜8) に保つのが安全です。
  スループット上限を見たい場合は別マシンから `run.sh --target ... --no-start` を実行してください。
- Docker で動くプロキシの RSS/CPU を見る場合は、`--pid` にホスト側の PID
  (`docker inspect -f '{{.State.Pid}}' <container>`) を渡してください。
- 本番トラフィックと混在させたくない場合は、メンテナンス時間帯に実行するか、
  `--port` を変えて測定用のプロキシを別途起動してください。

## 参考

RSS / VmPeak のサンプリング方法は `media-proxy-rs-vuln_scan2/poc/harness.py` を参考にしています。
