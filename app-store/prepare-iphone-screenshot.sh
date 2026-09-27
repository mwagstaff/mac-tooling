#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s INPUT... | FOLDER... | -o OUTPUT.jpg INPUT\n' "$0"
  printf 'Accepts multiple files or folders (PNG/JPEG, non-recursive).\n'
  printf 'Example: %s ~/Downloads/*.png\n' "$0"
  printf 'Outputs are saved beside each source; generated screenshots are skipped in folders.\n'
  printf 'Legacy INPUT OUTPUT.jpg is supported when OUTPUT does not exist; use -o to overwrite.\n'
}

if (( $# == 0 )); then
  usage >&2
  exit 2
fi
if [[ "$1" == '-h' || "$1" == '--help' ]]; then
  usage
  exit 0
fi

explicit_output=''
if [[ "$1" == '-o' || "$1" == '--output' ]]; then
  if (( $# != 3 )); then
    usage >&2
    exit 2
  fi
  explicit_output=$2
  shift 2
  if [[ -z "$explicit_output" || ! -f "$1" ]]; then
    printf 'Explicit output requires one input file and a non-empty output path.\n' >&2
    exit 2
  fi
elif (( $# == 2 )) && [[ -f "$1" && ! -e "$2" && ( "$2" == *.jpg || "$2" == *.jpeg ) ]]; then
  explicit_output=$2
  set -- "$1"
fi

if [[ -n "$explicit_output" && "$explicit_output" != *.jpg && "$explicit_output" != *.jpeg ]]; then
  printf 'Output file must have a .jpg or .jpeg extension: %s\n' "$explicit_output" >&2
  exit 2
fi

if ! command -v magick >/dev/null 2>&1; then
  printf 'ImageMagick is required (install it with: brew install imagemagick).\n' >&2
  exit 1
fi

inputs=()
shopt -s nullglob nocaseglob
for source in "$@"; do
  if [[ -d "$source" ]]; then
    count=${#inputs[@]}
    for input in "$source"/*.{png,jpg,jpeg}; do
      [[ -f "$input" ]] || continue
      case "$input" in
        *-app-store-1320x2868.*|*-app-store-416x496.*) continue ;;
      esac
      inputs+=("$input")
    done
    if (( ${#inputs[@]} == count )); then
      printf 'No source PNG/JPEG images found in folder: %s\n' "$source" >&2
      exit 1
    fi
  elif [[ -f "$source" ]]; then
    inputs+=("$source")
  else
    printf 'Input file or folder does not exist: %s\n' "$source" >&2
    exit 1
  fi
done

for input in "${inputs[@]}"; do
  output=${explicit_output:-${input%.*}-app-store-1320x2868.jpg}

  if [[ "$input" == "$output" ]]; then
    printf 'Input and output must be different files.\n' >&2
    exit 2
  fi

  # Fit the whole capture without cropping or stretching, then pad the small
  # remaining space to App Store Connect's 1320 x 2868 iPhone canvas.
  magick "$input" -auto-orient -background black -flatten \
    -resize '1320x2868' -gravity center -background black -extent '1320x2868' \
    -colorspace sRGB -depth 8 -strip -quality 94 "$output"

  dimensions=$(magick identify -format '%wx%h' "$output")
  if [[ "$dimensions" != '1320x2868' ]]; then
    printf 'Unexpected output dimensions: %s\n' "$dimensions" >&2
    exit 1
  fi

  printf 'Ready for iPhone 6.9-inch screenshots: %s (%s)\n' "$output" "$dimensions"
done
