#!/bin/sh
# 加工シェーダーの見た目を PNG に焼く。シミュレータは要らない。
#
#   ./Tools/ShaderPreview/render.sh                          # 既定の条件で全加工
#   ./Tools/ShaderPreview/render.sh -shape bunny -subject white
#   ./Tools/ShaderPreview/render.sh -effect puffy.gloss.v2 -variants 6
#
# 出力は out/ に落ちる。傾きを横に並べた一覧なので、動きの幅を静止画で判断できる。
set -e
cd "$(dirname "$0")/../.."
BUILD=${SHADER_PREVIEW_BUILD:-.build/shaderpreview}
mkdir -p "$BUILD" out

xcrun -sdk macosx metal -O -ffast-math \
  -o "$BUILD/preview.metallib" Tools/ShaderPreview/Preview.metal

swiftc -O -o "$BUILD/shaderpreview" \
  StickerLab/Catalog/EffectDefinition.swift \
  StickerLab/Model/StickerFactory.swift \
  StickerLab/Model/StickerInstance.swift \
  Tools/ShaderPreview/main.swift

"$BUILD/shaderpreview" -library "$BUILD/preview.metallib" -out out "$@"
