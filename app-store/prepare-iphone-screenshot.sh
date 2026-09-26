#!/usr/bin/env bash
set -euo pipefail

if (( $# < 1 || $# > 2 )); then
  printf 'Usage: %s INPUT.png [OUTPUT.jpg]\n' "$0" >&2
  exit 2
fi

if ! command -v magick >/dev/null 2>&1; then
  printf 'ImageMagick is required (install it with: brew install imagemagick).\n' >&2
  exit 1
fi

input=$1
output=${2:-${input%.*}-app-store-1320x2868.jpg}

if [[ ! -f "$input" ]]; then
  printf 'Input file does not exist: %s\n' "$input" >&2
  exit 1
fi

if [[ "$output" != *.jpg && "$output" != *.jpeg ]]; then
  printf 'Output file must have a .jpg or .jpeg extension: %s\n' "$output" >&2
  exit 2
fi

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
