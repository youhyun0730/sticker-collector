// 加工シェーダーをシミュレータ抜きで画像に焼くための入口。
//
// StickerEffects.metal をそのまま取り込み、SwiftUI が渡すのと同じ形の
// SwiftUI::Layer を手で組み立てて呼ぶ。アプリ側と同じコードを見ているため、
// ここで見えたものは実機でもそのまま出る。
// [[stitchable]] は動的リンク用の印で、単体のライブラリからは直接呼べない。
// プレビューでは同じライブラリ内の普通の関数として取り込む。
#define stitchable
#include "../../StickerLab/Render/StickerEffects.metal"
#undef stitchable

struct PreviewUniforms {
    float2 size;      // シールの表示サイズ（padding を含まない）
    float2 tilt;
    float2 flow;
    float  time;
    float  seed;
    float  pad;       // 透明余白の幅（px）。maxSampleOffset に相当する。
    int    paramCount;
    int    functionIndex;
};

kernel void preview_render(texture2d<half, access::sample> src [[texture(0)]],
                           texture2d<half, access::write>  dst [[texture(1)]],
                           constant PreviewUniforms &u        [[buffer(0)]],
                           device const float *p              [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }

    float2 texSize = u.size + 2.0 * u.pad;
    SwiftUI::Layer layer {
        src,
        { float2(1.0 / texSize.x, 0.0),
          float2(0.0, 1.0 / texSize.y),
          float2(u.pad / texSize.x, u.pad / texSize.y),
          float2(0.0),
          float2(1.0) }
    };

    float2 pos = float2(gid) + 0.5;
    half4 c;
    switch (u.functionIndex) {
        case 0:  c = fx_flatFoil(pos, layer, u.size, u.tilt, u.flow, u.time, u.seed, p, u.paramCount); break;
        case 1:  c = fx_puffyGloss(pos, layer, u.size, u.tilt, u.flow, u.time, u.seed, p, u.paramCount); break;
        case 2:  c = fx_waterCapsule(pos, layer, u.size, u.tilt, u.flow, u.time, u.seed, p, u.paramCount); break;
        default: {
            // ドームの形だけを見る。左上=高さ、右上=距離、下=法線の向き。
            // 見た目の調整で迷ったときに、形が壊れているのか陰影が悪いのかを切り分ける。
            float bevelWidth = (u.paramCount > 1) ? p[1] : 0.3;
            float domeHeight = (u.paramCount > 0) ? p[0] : 0.7;
            half4 src = layer.sample(pos);
            if (src.a < 0.004h) { c = half4(0.0h); break; }
            Dome d = buildDome(layer, pos, float(src.a), min(u.size.x, u.size.y) * 0.20,
                               bevelWidth, domeHeight);
            float2 h = pos / u.size;
            float3 v;
            if (h.y < 0.5) {
                v = (h.x < 0.5) ? float3(d.height) : float3(d.depth);
            } else {
                v = float3(d.normal * 0.5 + 0.5);
            }
            c = half4(half3(v), 1.0h);
            break;
        }
    }
    dst.write(c, gid);
}
