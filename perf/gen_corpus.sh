#!/usr/bin/env bash
# perf/corpus/ にベンチ用画像コーパスを生成し、corpus.sha256 を記録する。
#
# corpus/ は .gitignore 済み。生成は一度だけで良い(compare.sh は同一 corpus を
# 両リビジョンで使い回すため、実行中に再生成しないこと)。
#
# バックエンドは ImageMagick (magick/convert) を優先し、無ければ ffmpeg を使う。
set -euo pipefail

PERF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$PERF_DIR/corpus"
FORCE=0
BACKEND=""

usage() {
	cat <<'EOF'
usage: gen_corpus.sh [--out DIR] [--force]

  --out DIR   出力先 (default: perf/corpus)
  --force     既存 corpus を再生成する

生成には ImageMagick (magick/convert) または ffmpeg が必要です。
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--out)
			OUT="$2"
			shift 2
			;;
		--force)
			FORCE=1
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

if [ -f "$OUT/corpus.sha256" ] && [ "$FORCE" -ne 1 ]; then
	echo "corpus already exists: $OUT (use --force to regenerate)"
	exit 0
fi

if command -v magick >/dev/null 2>&1; then
	BACKEND=im
	IM=magick
elif command -v convert >/dev/null 2>&1; then
	BACKEND=im
	IM=convert
elif command -v ffmpeg >/dev/null 2>&1; then
	BACKEND=ffmpeg
else
	echo "error: ImageMagick (magick/convert) も ffmpeg も見つかりません" >&2
	echo "  Debian/Ubuntu: apt-get install -y imagemagick  (または ffmpeg)" >&2
	exit 1
fi

mkdir -p "$OUT"
echo "generating corpus into $OUT (backend: $BACKEND) ..."

FFMPEG=(ffmpeg -y -hide_banner -loglevel error)

# 写真相当のエントロピーを持つ JPEG (デコード+リサイズ+WebPエンコードの主対象)
gen_jpeg() { # $1=WxH $2=品質(IM) $3=品質(ffmpeg -q:v) $4=出力
	case "$BACKEND" in
		im) "$IM" -size "$1" plasma:fractal -quality "$2" "$4" ;;
		ffmpeg) "${FFMPEG[@]}" -f lavfi -i "testsrc2=s=$1,noise=alls=12:allf=u" -frames:v 1 -q:v "$3" "$4" ;;
	esac
}

# 透過 PNG (badge 経路: グレースケール化+センタリング+PNG出力)
gen_alpha_png() { # $1=出力
	case "$BACKEND" in
		im)
			"$IM" -size 1500x1500 xc:none \
				-fill "rgba(255,136,0,0.80)" -draw "circle 750,750 750,200" \
				-fill "rgba(0,136,255,0.55)" -draw "rectangle 200,900 1300,1400" \
				"$1"
			;;
		ffmpeg)
			# 半径420px の外側だけ透明にする (アルファ付き PNG)
			"${FFMPEG[@]}" -f lavfi -i "testsrc2=s=1500x1500" \
				-vf "format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='if(gt(hypot(X-750,Y-750),420),0,255)'" \
				-frames:v 1 "$1"
			;;
	esac
}

# 高エントロピー PNG (WebP/PNG エンコードの上限側ストレス)
gen_noise_png() { # $1=出力
	case "$BACKEND" in
		im) "$IM" -size 1024x1024 xc:gray50 +noise Random "$1" ;;
		ffmpeg) "${FFMPEG[@]}" -f lavfi -i "color=c=gray:s=1024x1024,noise=alls=100:allf=t+u" -frames:v 1 "$1" ;;
	esac
}

# WebP 入力 (WebP デコード→再エンコード)
gen_webp() { # $1=出力
	case "$BACKEND" in
		im)
			if ! "$IM" -size 1600x1200 plasma:fractal -quality 80 "$1" 2>/dev/null; then
				echo "error: ImageMagick に WebP delegate がありません (libwebp を入れてください)" >&2
				exit 1
			fi
			;;
		ffmpeg) "${FFMPEG[@]}" -f lavfi -i "testsrc2=s=1600x1200,noise=alls=15:allf=u" -frames:v 1 -c:v libwebp -quality 80 "$1" ;;
	esac
}

# アニメーション 30フレーム (アニメーション WebP エンコード経路)
gen_gif() { # $1=出力
	local tmp i x y
	case "$BACKEND" in
		im)
			tmp="$(mktemp -d)"
			trap 'rm -rf "$tmp"' RETURN
			for i in $(seq 0 29); do
				x=$(((i * 16) % 480))
				y=$((200 + (i % 10) * 8))
				"$IM" -size 480x480 xc:"#102040" \
					-fill "#ffcc00" -draw "circle ${x},${y} $((x + 40)),${y}" \
					-fill "#2288ff" -draw "circle $((479 - x)),$((479 - y)) $((439 - x)),$((479 - y))" \
					"$tmp/f$(printf '%02d' "$i").png"
			done
			"$IM" -delay 5 -loop 0 "$tmp"/f*.png "$1"
			;;
		ffmpeg) "${FFMPEG[@]}" -f lavfi -i "testsrc2=s=480x480:r=10:d=3" -c:v gif -loop 0 "$1" ;;
	esac
}

# SVG (resvg ラスタライズ経路)。フォント依存を避けるため図形のみで構成する。
gen_svg() { # $1=出力
	cat >"$1" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">
  <defs>
    <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#1e3a8a"/>
      <stop offset="1" stop-color="#f59e0b"/>
    </linearGradient>
  </defs>
  <rect width="512" height="512" rx="64" fill="url(#g)"/>
  <circle cx="176" cy="176" r="72" fill="#ffffff" fill-opacity="0.85"/>
  <circle cx="336" cy="336" r="104" fill="#111827" fill-opacity="0.55"/>
  <path d="M64 448 L192 256 L288 384 L384 288 L448 448 Z" fill="#f8fafc" fill-opacity="0.9"/>
</svg>
SVG
}

gen_jpeg 4000x3000 88 3 "$OUT/photo_4000x3000.jpg"
gen_jpeg 2000x1500 85 4 "$OUT/photo_2000x1500.jpg"
gen_jpeg 320x320 85 4 "$OUT/small_320x320.jpg"
gen_alpha_png "$OUT/alpha_1500x1500.png"
gen_noise_png "$OUT/noise_1024.png"
gen_webp "$OUT/pic_1600x1200.webp"
gen_gif "$OUT/anim_480x480.gif"
gen_svg "$OUT/icon.svg"

# ハッシュを記録 (compare.sh の meta に取り込まれ、両リビジョンで同一 corpus であることを保証する)
(
	cd "$OUT"
	find . -maxdepth 1 -type f ! -name corpus.sha256 -printf '%P\n' | sort | xargs -r sha256sum >corpus.sha256
)

echo "generated:"
(cd "$OUT" && ls -lh | awk 'NR>1 {print "  " $9 "  " $5}')
echo "corpus sha256 file: $OUT/corpus.sha256"
echo "corpus digest: $(sha256sum "$OUT/corpus.sha256" | cut -d' ' -f1)"
