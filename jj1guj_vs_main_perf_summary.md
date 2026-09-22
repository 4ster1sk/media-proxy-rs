# パフォーマンス比較サマリ: main (b681a01) vs jj1guj_develop (80b04b7)

測定: 2026-09-22 / `perf/compare.sh`(2ラウンド中央値) / i5-2500 3コア・負荷とサーバー同一マシン / 同一 corpus・同一 config
ビルド: 両者とも同一ツールチェーン・同一リリースプロファイル。jj1guj 側はブランチ README のネイティブ手順(ImageMagick/libvips をソースからビルド)

## 結論

1. **デフォルト設定では桁違いに速い**(4,100〜4,800 req/s vs 6〜430 req/s、CPU 0.1 ms/req)。
   ただし同一URL反復条件でのキャッシュヒット値であり、上限値。
2. **キャッシュ/パススルーを切った純処理でも JPEG 系は 23〜61% の CPU 削減**。
   ただし主因は出力を WebP(q75) → turbojpeg(q85) に変えたことで、**応答サイズが 2〜4 倍**になる。
3. **出力形式を揃えた AVIF 比較では 12〜17% の削減**。デコード/リサイズ側の改善は 1 割台。
4. **アニメーション WebP / SVG / PNG / WebP 入力の経路は従来と同等**(±5% 以内)。
   メモリ(RSS ピーク)は全シナリオで 5〜15% 程度少ない。
5. **運用面**: jj1guj 側はリクエストログにフェーズ別所要時間(`decode_ms` / `encode_ms` /
   `dl_wait_ms` / `cpu_wait_ms` など)と `cache` / `passthrough` の状態を出す(`slow_log_ms`
   未満の高速リクエストは DEBUG に落ちる)。ボトルネック特定がしやすい。

## 数値(キャッシュ・パススルー無効での純処理比較)

| scenario | req/s | CPU ms/req | 応答サイズ | 出力形式 |
|---|---|---|---|---|
| jpeg_maxpixels (4000×3000→2048) | 6.0 → 14.2 (+138%) | 465 → 181 (**-61%**) | 59 KB → 192 KB (+226%) | webp → jpeg |
| small_emoji (320²→emoji) | 430 → 684 (+59%) | 3.9 → 1.8 (**-54%**) | 1.6 KB → 4.1 KB (+157%) | webp → jpeg |
| jpeg_avatar (→320h) | 12.1 → 17.2 (+42%) | 212 → 149 (**-30%**) | 3.5 KB → 11.5 KB (+225%) | webp → jpeg |
| jpeg_preview (→200²) | 12.0 → 16.0 (+33%) | 210 → 162 (**-23%**) | 1.0 KB → 4.3 KB (+312%) | webp → jpeg |
| noise_preview | 78.8 → 89.7 (+14%) | 28.3 → 23.6 (-16%) | 3.2 KB → 7.2 KB (+129%) | webp → jpeg |
| jpeg_static (→498×422) | 12.3 → 13.1 (+6%) | 211 → 197 (-7%) | 4.2 KB → 14.5 KB (+246%) | webp → jpeg |
| webp_preview | 28.9 → 29.8 (+3%) | 89.7 → 86.9 (-3%) | 1.6 KB → 4.9 KB (+206%) | webp → jpeg |
| png_badge | 126.8 → 128.4 (+1%) | 17.3 → 16.9 (-2%) | 同じ | png |
| gif_anim (30フレーム) | 10.9 → 10.9 (0%) | 245 → 245 (+0%) | 同じ | webp |
| svg_avatar | 167.2 → 161.7 (-3%) | 13.7 → 13.8 (+1%) | 同じ | webp |

同一出力形式(AVIF, 並列1): jpeg_avatar -16.7% / jpeg_preview -11.9% / small_emoji +3.6% / webp_preview +0.1%(CPU ms/req)

## 注意点

- 同一マシン(3コア)測定のため絶対値は環境依存。相対比較と CPU ms/req を見るのが安全。
- 不透明画像が **JPEG で返る**ようになる(透過画像は従来どおり WebP)。Content-Type を見る
  クライアントやキャッシュ層がある場合は要確認。
- パススルー(寸法が目標以下 & 1MB 以下)は今回の corpus では**一度も発動しなかった**
  (ログの `passthrough=true` は 0 件)。小さい画像を扱う構成では、main と挙動が変わる
  (縮小されず元画像が返る)点を別途確認する価値がある。
- AVIF を並列で回すと大きな画像は 10 秒 timeout に到達する(両者)。main は timeout 後に
  実行中のエンコードを止められず後続リクエストへ影響が波及しやすい。

## 再現

```sh
perf/compare.sh --base-bin <main> --head-bin <jj1guj> \
  --config perf/config.perf-nocache.json --rounds 2 --concurrency 4 --duration 10 --warmup 3
```

詳細(測定条件の全文、AVIF 比較、並列時の挙動、考察)は `jj1guj_vs_main_perf.md` を参照。
