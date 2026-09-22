# media-proxy-rs パフォーマンス比較: main (b681a01) vs jj1guj_develop (80b04b7)

測定日: 2026-09-22 / 測定ハーネス: `perf/compare.sh`(このリポジトリの `perf/`)

## 測定環境と条件

- マシン: Intel Core i5-2500 @ 3.30GHz (3 cores) / Linux 6.12 / 負荷生成とサーバーは同一マシン
- corpus: `perf/gen_corpus.sh` 生成の8ファイル(sha256 `42014138bacc…`)、シナリオ定義 `perf/scenarios.json`
- 設定: 両者に同一の `perf/config.perf.json`(AVIF 比較時は `perf/config.perf-avif-nocache.json` + `Accept: image/avif`)
- 各ラウンドで base/head を交互に起動し、2ラウンドの中央値を採用(`--rounds 2`)
- ビルド: どちらも同じ Rust ツールチェーン/プロファイル(`opt-level=3, lto="thin", strip`)。
  main は通常の `cargo build --release`、jj1guj_develop はブランチの README 記載のネイティブ手順
  (`crossfiles/build-imagemagick.sh` → `crossfiles/build-libvips.sh` → `cargo build --release`)。
  バイナリ sha256: main `e0a8aa8fd709…` / jj1guj `a8a9163a97a2…`

## 結果の要約

| 測定 | 条件 | 結果 |
|---|---|---|
| A. デフォルト設定比較 | jj1guj 側はデフォルト(`enable_cache=true`, `passthrough_max_bytes=1MB`) | **全シナリオで 4,100〜4,800 req/s**(main は 6〜430 req/s)、CPU 0.1 ms/req。ただしほぼ全リクエストがキャッシュヒット(同一URL反復) |
| B. 純処理比較 | 両者 `enable_cache=false`, `passthrough_max_bytes=0` | JPEG 系で **CPU/req 23〜61% 削減**(RPS +33〜138%)。アニメ/SVG/PNG/WebP入力は ±5% 以内 |
| C. 同一出力形式(AVIF) | 同上 + `Accept: image/avif`、並列1 | JPEG 入力で **CPU/req 12〜17% 削減**、その他は同等。並列4の単発確認でも同等(167 vs 173 ms/req) |

---

## A. デフォルト設定での比較(キャッシュ/パススルー有効)

`--config perf/config.perf.json`(jj1guj 側では既定値によりキャッシュとパススルーが有効)

この corpus では**パススルーは一度も発動しなかった**(プロキシログの `passthrough=true` が 0 件、
応答サイズも元ファイルより十分小さい)。したがって A の差は実質キャッシュの効果。

| scenario | req/s | p50 (ms) | CPU ms/req | RSS peak (MB) | 出力形式 |
|---|---|---|---|---|---|
| jpeg_avatar | 12.7 → 4681 (+36,759%) | 329 → 0.7 | 204 → 0.1 | 381 → 25 | webp → **jpeg** |
| jpeg_maxpixels | 6.2 → 3537 (+56,955%) | 731 → 1.0 | 451 → 0.1 | 422 → 28 | webp → **jpeg** |
| jpeg_preview | 12.7 → 4668 (+36,652%) | 329 → 0.7 | 207 → 0.1 | 324 → 19 | webp → **jpeg** |
| jpeg_static | 12.3 → 4592 (+37,233%) | 335 → 0.7 | 214 → 0.1 | 294 → 27 | webp → **jpeg** |
| gif_anim | 11.3 → 4105 (+36,230%) | 372 → 0.8 | 238 → 0.1 | 230 → 48 | webp |
| webp_preview | 28.7 → 4660 (+16,138%) | 136 → 0.7 | 89 → 0.1 | 230 → 47 | webp → **jpeg** |
| png_badge | 126.6 → 4792 (+3,685%) | 30 → 0.7 | 17 → 0.1 | 230 → 44 | png |
| svg_avatar | 162.4 → 4678 (+2,781%) | 23 → 0.7 | 14 → 0.1 | 231 → 49 | webp |
| noise_preview | 77.7 → 4646 (+5,880%) | 51 → 0.7 | 28 → 0.1 | 276 → 52 | webp → **jpeg** |
| small_emoji | 431.8 → 4716 (+992%) | 8.7 → 0.7 | 3.9 → 0.1 | 232 → 49 | webp → **jpeg** |

- この数値は「同一URLを繰り返し叩く」条件での**キャッシュヒット時**の値。初回(ミス)はデコード/エンコードが走る。
- 実際の連合先では URL が多様なのでミス率次第。ここでは上限値と解釈すること。
- ⚠ 出力形式が変わる。不透明画像は WebP ではなく turbojpeg(quality 85)で JPEG になる
  (透過がある画像のみ WebP)。バイト数は B の表を参照。

## B. 純処理比較(キャッシュ/パススルー無効)

`--config perf/config.perf-nocache.json`(main は未対応フィールドを無視)

| scenario | req/s | p50 (ms) | p99 (ms) | CPU ms/req | RSS peak | 出力形式 |
|---|---|---|---|---|---|---|
| jpeg_maxpixels | 6.0 → 14.2 (+137.8%) | 714 → 282 | 1029 → 411 | **465 → 181 (-61.1%)** | 474 → 414 | webp → jpeg |
| small_emoji | 429.5 → 684.0 (+59.3%) | 8.8 → 5.4 | 19.6 → 13.3 | **3.9 → 1.8 (-53.5%)** | 234 → 222 | webp → jpeg |
| jpeg_avatar | 12.1 → 17.2 (+42.1%) | 333 → 232 | 520 → 352 | **212 → 149 (-29.5%)** | 368 → 310 | webp → jpeg |
| jpeg_preview | 12.0 → 16.0 (+33.3%) | 337 → 242 | 520 → 414 | **210 → 162 (-23.0%)** | 341 → 315 | webp → jpeg |
| noise_preview | 78.8 → 89.7 (+13.8%) | 48.9 → 43.1 | 91 → 81 | 28.3 → 23.6 (-16.4%) | 277 → 266 | webp → jpeg |
| jpeg_static | 12.3 → 13.1 (+6.1%) | 329 → 303 | 467 → 535 | 211 → 197 (-6.7%) | 366 → 333 | webp → jpeg |
| webp_preview | 28.9 → 29.8 (+3.1%) | 137 → 131 | 234 → 226 | 89.7 → 86.9 (-3.2%) | 232 → 219 | webp → jpeg |
| png_badge | 126.8 → 128.4 (+1.3%) | 30.2 → 30.2 | 59 → 58 | 17.3 → 16.9 (-1.9%) | 232 → 219 | png |
| gif_anim | 10.9 → 10.9 (+0.0%) | 369 → 364 | 560 → 575 | 245 → 245 (+0.2%) | 232 → 220 | webp |
| svg_avatar | 167.2 → 161.7 (-3.3%) | 22.6 → 23.2 | 44.6 → 50.4 | 13.7 → 13.8 (+0.8%) | 233 → 221 | webp |

### 応答サイズ(同じく B の条件、中央値)

| scenario | main KB/req (webp) | jj KB/req (jpeg) | 差 |
|---|---|---|---|
| jpeg_maxpixels | 59.1 | 192.4 | +225.7% |
| jpeg_avatar | 3.5 | 11.5 | +224.6% |
| jpeg_static | 4.2 | 14.5 | +245.5% |
| jpeg_preview | 1.0 | 4.3 | +311.6% |
| small_emoji | 1.6 | 4.1 | +156.8% |
| noise_preview | 3.2 | 7.2 | +128.6% |
| webp_preview | 1.6 | 4.9 | +205.6% |
| gif_anim / png_badge / svg_avatar | 97.4 / 1.5 / 3.4 | 同左 | 0% |

**解釈**: B の速度向上の主因は「不透明画像を WebP(quality 75)ではなく turbojpeg(quality 85)で出す」方針変更。
エンコードが大幅に安い代わりに、**ペイロードが 2〜4 倍**になる。デコード(turbojpeg/vips)、リサイズ、
アニメーション WebP、SVG(resvg)、PNG 経路はほぼ従来同等(±5% 以内)。

## C. 同一出力形式での比較(AVIF 出力・キャッシュ無効・並列1)

| scenario | req/s | p50 (ms) | CPU ms/req | 出力形式 |
|---|---|---|---|---|
| jpeg_avatar | 1.5 → 1.8 (+21.0%) | 686 → 606 | **1113 → 927 (-16.7%)** | avif |
| jpeg_preview | 2.1 → 2.4 (+12.3%) | 487 → 445 | **486 → 428 (-11.9%)** | avif |
| small_emoji | 6.1 → 5.9 (-3.9%) | 164 → 171 | 164 → 170 (+3.6%) | avif |
| webp_preview | 2.9 → 2.9 (0.0%) | 355 → 357 | 350 → 350 (+0.1%) | avif |

出力形式を揃えても JPEG 入力で 12〜17% の CPU 削減(AVIF エンコードは両者同じ `image`/ravif なので、
差はデコードとリサイズ側)。並列4での単発再確認では両者同等(small_emoji: 167.8 vs 173.2 ms/req)。

### 補足: 並列4で大きな AVIF を混ぜたときの挙動

シナリオを連続実行する条件では、`jpeg_maxpixels`(2048×1536 の AVIF エンコード)が 10 秒の
`timeout` を超えて両者とも 504(`X-Proxy-Error: ImageEncodeTimeout`)になった。その直後の
シナリオで main は連鎖的にタイムアウトし、jj1guj 側は正常応答を維持した。main は timeout 時に
`abort()` しても実行中の blocking クロージャが止まらない(コード内に既知の制限として明記)ため、
多重度が高いと後続リクエストを巻き込みやすい。この影響を避けるには並列度を下げるか、
`encode_avif` を使う場合は `timeout` を延ばす必要がある。

## 注意事項

- 負荷生成とサーバーが同一マシン(3コア)のため、レイテンシの絶対値は環境依存。
  CPU ms/req(サーバープロセスの CPU 時間 ÷ リクエスト数)が最も安定した指標。
- RSS は確保タイミングの影響を受けやすく、単発では振れる(`--rounds` を増やすと安定)。
- 出力形式が違う比較(A/B)は「速度とペイロードのトレードオフ」を含む。形式を揃えた比較は C。
- 数値の再現は次のコマンドで:

```sh
# 実行に使ったコマンド(要: 両バイナリ)
perf/compare.sh --base-bin <main のバイナリ> --head-bin <jj1guj のバイナリ> \
  --config perf/config.perf-nocache.json --rounds 2 --concurrency 4 --duration 10 --warmup 3
perf/compare.sh --base-bin <main> --head-bin <jj1guj> \
  --config perf/config.perf-avif-nocache.json --avif --rounds 2 --concurrency 1 --duration 8 --warmup 3
```

---

## まとめ

**1. 効くのは「キャッシュ」と「WebP → JPEG 出力」。パススルーは今回未発動**

- デフォルト設定での差(4,100〜4,800 req/s vs 6〜430 req/s)はほぼキャッシュヒットの効果。
  連合先のように URL が多様な環境ではミス率次第で、この上限値は大きく下がる。
- キャッシュを切って純処理を比べても JPEG 系は 23〜61% の CPU 削減。ただしこれは
  **不透明画像を WebP(q75) から turbojpeg(q85) に変えたこと**が主因で、
  トレードオフとして**ペイロードが 2〜4 倍**(jpeg_preview 1.0KB → 4.3KB、
  jpeg_maxpixels 59KB → 192KB)になる。CDN/モバイル回線では無視できない差。
- 出力形式を揃えた AVIF 比較では 12〜17% の CPU 削減。つまり
  **デコード/リサイズ側の改善は 1 割台、残りはエンコード方針の変更**という内訳。

**2. アニメーション・SVG・PNG・WebP 入力は従来同等**

`gif_anim`(アニメーション WebP)、`svg_avatar`(resvg)、`png_badge`、`webp_preview` は
±5% 以内。libvips/ImageMagick の導入はこれらの経路の速度には現れていない
(対応フォーマット拡大やデコード経路の一本化が主目的と推測される)。

**3. メモリは一貫して 5〜15% 程度少ない**

RSS ピークは全シナリオで jj1guj 側が小さい(例: jpeg_avatar 368 → 310MB)。
ただし RSS は確保タイミングに左右されるため、この差は参考値。

**4. 運用面: リクエストログにフェーズ別の所要時間が入る**

jj1guj 側は `tracing` で 1 リクエストごとに `check_ms / wait_ms / dl_wait_ms / cpu_wait_ms /
body_ms / decode_ms / encode_ms / ttfb_ms`、`cache` / `passthrough` / `dns_hit` の状態を出力する
(`slow_log_ms`(既定 50ms)未満の高速リクエストは DEBUG に落ちるため、遅いものだけが INFO に残る)。
実測例(run B の jpeg_avatar 初回): `decode_ms=64 encode_ms=66`。
どのフェーズが重いかを本番ログから特定できるため、性能調査のしやすさは明確に向上する。

**5. 導入検討時のチェックポイント**

- [ ] 出力が JPEG になることの可否(Content-Type を見るクライアント/キャッシュ層があるか)
- [ ] サイズ増(2〜4倍)とその帯域コスト、`jpeg_quality` の再調整余地
- [ ] キャッシュの TTL(既定 3600秒)とメモリ上限(既定 128MB)、多様URL環境でのヒット率
- [ ] パススルー条件(寸法が目標以下 & 1MB 以下)は今回の corpus では発動しなかった。
      小さい画像を扱う構成では、main と挙動が変わる(縮小されず元画像が返る)点を別途確認する
- [ ] AVIF を有効にする場合は並列度と `timeout`。大きな画像のエンコードが 10 秒を超えると
      504 になり、main では後続リクエストまで巻き込む

**6. 回帰検知の使い方**

`perf/compare.sh` で PR ごとに before/after を取り、レポートの `type` 列(出力形式)と
CPU ms/req を確認するのが有効。出力形式が変わった場合は ⚠ が付くため、
「速くなったが形式が変わった」を見逃しにくい。
