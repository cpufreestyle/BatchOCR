#!/bin/bash
# 安装/补齐 OCR 引擎依赖：ocrmypdf（含 tesseract）+ 中文语言包
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v ocrmypdf >/dev/null 2>&1; then
  echo "安装 ocrmypdf（Homebrew）..."
  brew install ocrmypdf
fi

TESSDATA="$(brew --prefix)/share/tessdata"
if ! tesseract --list-langs 2>/dev/null | grep -q '^chi_sim$'; then
  echo "下载中文简体语言包 chi_sim（tessdata_fast）..."
  mkdir -p "$TESSDATA"
  curl -fsSL -o "$TESSDATA/chi_sim.traineddata" \
    "https://github.com/tesseract-ocr/tessdata_fast/raw/main/chi_sim.traineddata"
fi

echo "已安装语言包："
tesseract --list-langs
