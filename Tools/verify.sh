#!/bin/sh
# 加工カタログの健全性をコマンドラインで検査する。
#
# アプリを起動しなくても、抽選確率・パラメータ範囲・個体差・JSON 往復を確かめられる。
# 加工やグレードを足したあとは、まずこれを通す。
set -e
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
swiftc -O -o "$OUT/catalog-check" \
  StickerLab/Catalog/EffectDefinition.swift \
  StickerLab/Model/StickerFactory.swift \
  StickerLab/Model/StickerInstance.swift \
  Tools/CatalogCheck/main.swift
"$OUT/catalog-check"
