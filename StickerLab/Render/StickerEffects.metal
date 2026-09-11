#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

// -----------------------------------------------------------------------------
// 共通の約束
//
// 3種の加工はすべて同一のシグネチャを持つ。
//
//   half4 fx_xxx(float2 pos, SwiftUI::Layer layer,
//                float2 size, float2 tilt, float time, float seed,
//                device const float *p, int pc)
//
// これにより Swift 側は加工ごとの分岐なしに、カタログの関数名を引いて
// 同じ引数列で呼び出せる。`p` は EffectDefinition.paramSchema の
// **配列順**に詰められた実値であり、添字がパラメータに対応する。
//
// tilt は端末の傾きを -1..1 に正規化したもの。x が左右、y が前後。
// SwiftUI のレイヤーはアルファ乗算済みのため、色計算の前に必ず除算して戻す。
// -----------------------------------------------------------------------------

static inline float paramAt(device const float *p, int count, int index, float fallback) {
    return (index < count) ? p[index] : fallback;
}

static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static inline float2 hash22(float2 p) {
    float n = hash21(p);
    return float2(n, hash21(p + n * 37.13));
}

static inline float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static inline float fbm(float2 p) {
    float v = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 3; i++) {
        v += amp * vnoise(p);
        p *= 2.02;
        amp *= 0.5;
    }
    return v;
}

/// 彩度・明度を最大にした色相環。虹色の帯に使う。
static inline float3 hueColor(float h) {
    float3 k = abs(fract(h + float3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return clamp(k - 1.0, 0.0, 1.0);
}

static inline float luma(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

/// スクリーン合成。下地を潰さずに光だけを乗せる。
static inline float3 screenBlend(float3 base, float3 light) {
    return 1.0 - (1.0 - base) * (1.0 - light);
}

/// 半径 r の円周 8 点のアルファ平均。輪郭からの距離の近似に使う。
static inline float ringCoverage(SwiftUI::Layer layer, float2 pos, float r) {
    float sum = 0.0;
    for (int i = 0; i < 8; i++) {
        float a = 6.2831853 * (float(i) + 0.5) / 8.0;
        sum += float(layer.sample(pos + r * float2(cos(a), sin(a))).a);
    }
    return sum / 8.0;
}

/// 円周 8 点を 1 周して、アルファの平均（被覆率）と方向加重和（勾配）を同時に得る。
///
/// 戻り値 .x が被覆率、.yz が勾配。勾配は内側（アルファの大きい側）を向くため、
/// 符号を反転すると外向き法線の xy 成分になる。
/// 被覆率と勾配を別々に取ると同じ点を二度読むことになるため、1 周にまとめている。
static inline float3 ringProbe(SwiftUI::Layer layer, float2 pos, float r) {
    float sum = 0.0;
    float2 g = float2(0.0);
    for (int i = 0; i < 8; i++) {
        float a = 6.2831853 * (float(i) + 0.5) / 8.0;
        float2 dir = float2(cos(a), sin(a));
        float s = float(layer.sample(pos + r * dir).a);
        sum += s;
        g += dir * s;
    }
    return float3(sum, g.x, g.y) / 8.0;
}

// -----------------------------------------------------------------------------
// フラットシール：ホログラム箔
//
// 平面。厚みを持たないぶん、傾けたときの反応が最も速く直線的であること。
// 虹の帯が視線方向に走り、微細なキラ粒が明滅する。
// -----------------------------------------------------------------------------
[[ stitchable ]] half4 fx_flatFoil(float2 pos,
                                   SwiftUI::Layer layer,
                                   float2 size,
                                   float2 tilt,
                                   float time,
                                   float seed,
                                   device const float *p,
                                   int pc)
{
    half4 src = layer.sample(pos);
    if (src.a < 0.004h) { return half4(0.0h); }

    float alpha = float(src.a);
    float3 base = float3(src.rgb) / alpha;

    float bandDensity    = paramAt(p, pc, 0, 5.0);
    float hueOffset      = paramAt(p, pc, 1, 0.0);
    float bandAngle      = paramAt(p, pc, 2, 0.7);
    float sparkleDensity = paramAt(p, pc, 3, 16.0);
    float flowSpeed      = paramAt(p, pc, 4, 0.1);
    float intensity      = paramAt(p, pc, 5, 0.5);
    float pattern        = paramAt(p, pc, 6, 0.0);

    float2 uv = pos / size;
    float2 c  = uv - 0.5;

    float2 dir  = float2(cos(bandAngle), sin(bandAngle));
    float2 perp = float2(-dir.y, dir.x);

    // 帯の走る座標。パターン番号で形を切り替える。
    float t;
    if (pattern < 0.5) {
        t = dot(c, dir);
    } else if (pattern < 1.5) {
        t = length(c * float2(1.0, size.y / max(size.x, 1.0)));
    } else {
        t = (abs(dot(c, dir)) + abs(dot(c, perp))) * 0.72;
    }

    // 傾きで帯が走る。ここが「傾けると光が動く」の主成分。
    float tiltShift = dot(tilt, dir) * 1.7;
    float grain     = fbm(uv * 9.0 + seed) * 0.18;
    float h         = fract(t * bandDensity + tiltShift + time * flowSpeed + hueOffset + grain + seed * 0.017);

    float3 foil = hueColor(h);
    foil *= 0.72 + 0.28 * vnoise(uv * 42.0 + seed * 3.0);

    // 帯とは別に、面を横切る白い一閃。速度が最も速い成分。
    float sweepPos  = dot(c, dir) - dot(tilt, dir) * 0.55;
    float sweep     = exp(-sweepPos * sweepPos * 26.0) * 0.55;

    // キラ粒。傾きに応じて明滅の位相がずれる。
    float2 gridPos = uv * sparkleDensity;
    float2 cell    = floor(gridPos);
    float2 f       = fract(gridPos);
    float2 jitter  = hash22(cell + seed);
    float  rnd     = hash21(cell * 1.7 + seed);
    float  d       = length(f - jitter);
    float  phase   = time * 1.9 + rnd * 6.2831853 + dot(tilt, dir) * 3.4;
    float  twinkle = pow(sin(phase) * 0.5 + 0.5, 5.0);
    float  sparkle = smoothstep(0.22, 0.0, d) * twinkle;

    float mask = 0.35 + 0.65 * luma(base);
    float3 col = screenBlend(base, foil * intensity * mask);
    col = screenBlend(col, float3(sweep * intensity));
    col = screenBlend(col, float3(sparkle * (0.55 + 0.45 * intensity)));

    return half4(half3(col * alpha), src.a);
}

// -----------------------------------------------------------------------------
// ぷっくりシール
//
// 輪郭のアルファ勾配から厚みを推定し、ドーム状の法線を組み立てる。
// 切り抜き形状が任意でも成立するため、フェーズ1で Vision のマスクへ差し替えられる。
// フラットとの差は、面が動くのではなく「ハイライトの玉が転がる」点にある。
// -----------------------------------------------------------------------------
[[ stitchable ]] half4 fx_puffyGloss(float2 pos,
                                     SwiftUI::Layer layer,
                                     float2 size,
                                     float2 tilt,
                                     float time,
                                     float seed,
                                     device const float *p,
                                     int pc)
{
    half4 src = layer.sample(pos);
    if (src.a < 0.004h) { return half4(0.0h); }

    float height        = paramAt(p, pc, 0, 0.7);
    float glossSharp    = paramAt(p, pc, 1, 24.0);
    float rimWidth      = paramAt(p, pc, 2, 0.3);
    float specIntensity = paramAt(p, pc, 3, 0.65);
    float tintHue       = paramAt(p, pc, 4, 0.55);
    float refraction    = paramAt(p, pc, 5, 0.01);
    float innerShadow   = paramAt(p, pc, 6, 0.25);

    float minDim = min(size.x, size.y);
    // 裾の広がり。height が大きいほど、輪郭から内側の広い範囲まで盛り上がる。
    float spread = 0.55 + 0.75 * height;

    // 3 段のリングで輪郭からの距離を近似する。
    // 半径を大きく取るほどドームの裾が広がり、「厚み」として読める範囲が増える。
    float3 probe1 = ringProbe(layer, pos, minDim * 0.05 * spread);
    float3 probe2 = ringProbe(layer, pos, minDim * 0.12 * spread);
    float3 probe3 = ringProbe(layer, pos, minDim * 0.22 * spread);

    float cov = (float(src.a) + probe1.x + probe2.x + probe3.x) * 0.25;
    float dome = smoothstep(0.0, 1.0, clamp(cov, 0.0, 1.0));

    // 外側のリングほど広い範囲の傾きを拾うため、重みを大きくする。
    float2 g = probe1.yz * 0.20 + probe2.yz * 0.35 + probe3.yz * 0.45;
    float slope = length(g);
    float3 n = normalize(float3(-g * (7.0 * height), max(0.10, 1.0 - slope * 1.2)));

    // 光源は傾きに追従する。わずかな呼吸を与えて静止時も死なせない。
    float3 L = normalize(float3(tilt.x * 1.25, -tilt.y * 1.25 + 0.16, 0.92 + 0.03 * sin(time * 0.7 + seed)));
    float3 V = float3(0.0, 0.0, 1.0);
    float3 H = normalize(L + V);

    // 厚みぶん、下の像がずれて見える。
    // ずれは面が急な縁ほど大きく、中央ではほぼ生じない。球面越しに見た歪みに近い。
    float2 offset = -n.xy * refraction * minDim * 2.5;
    half4 refracted = layer.sample(pos + offset);
    float3 base = (refracted.a > 0.02h) ? float3(refracted.rgb) / float(refracted.a)
                                        : float3(src.rgb) / float(src.a);

    float ndl  = max(dot(n, L), 0.0);
    float spec = pow(max(dot(n, H), 0.0), glossSharp) * specIntensity;

    // 面の上を転がる大きなハイライト。傾けると玉のように移動する。
    // ぷっくりらしさの大半はこの移動で決まるため、法線由来の鋭い反射とは別に持つ。
    float2 c = pos / size - 0.5;
    float2 highlightCenter = c + tilt * 0.30;
    float sheen = exp(-dot(highlightCenter, highlightCenter) * (14.0 + glossSharp * 0.6))
                * specIntensity * dome;

    float2 nDir = (slope > 1e-4) ? normalize(n.xy) : float2(0.0);
    float2 lDir = (length(L.xy) > 1e-4) ? normalize(L.xy) : float2(0.0);

    // 縁の内側を細く走る光。厚みのある飴に見えるかどうかはこの線の細さで決まるため、
    // 面全体に広がる淡い光ではなく、輪郭から一定の深さに帯として置く。
    float rimBand = exp(-pow((dome - 0.30) / max(rimWidth, 0.06), 2.0) * 2.0);
    // 光源側の縁だけを強く光らせる。全周が均一に光ると板に戻ってしまう。
    float rimSide = 0.30 + 0.70 * max(dot(nDir, lDir), 0.0);
    float3 rimTint = mix(float3(1.0), hueColor(tintHue), 0.55);

    // 光の当たらない側に落ちる内側の影。
    float edge = 1.0 - clamp(dome, 0.0, 1.0);
    float shadow = innerShadow * edge * max(-dot(nDir, lDir), 0.0);

    float3 col = base * (0.72 + 0.42 * ndl);
    col *= (1.0 - shadow);
    col = screenBlend(col, rimTint * rimBand * rimSide * (0.40 + 0.55 * specIntensity));
    col = screenBlend(col, float3(sheen * 0.40));
    col = screenBlend(col, float3(spec));

    return half4(half3(col * float(src.a)), src.a);
}

// -----------------------------------------------------------------------------
// 水入りシール
//
// 内容物（粒・気泡）が傾きに追従して移動する。粒ごとに追従量を変えることで
// 中身が層になって動き、ガラス越しの奥行きとして知覚される。
// Swift 側から遅れを持たせた tilt が渡るため、揺れ戻りはここでは作らない。
// -----------------------------------------------------------------------------
[[ stitchable ]] half4 fx_waterCapsule(float2 pos,
                                       SwiftUI::Layer layer,
                                       float2 size,
                                       float2 tilt,
                                       float time,
                                       float seed,
                                       device const float *p,
                                       int pc)
{
    half4 src = layer.sample(pos);
    if (src.a < 0.004h) { return half4(0.0h); }

    float particleDensity = paramAt(p, pc, 1, 8.0);
    float particleSize    = paramAt(p, pc, 2, 0.6);
    float tintHue         = paramAt(p, pc, 3, 0.55);
    float waveScale       = paramAt(p, pc, 4, 3.5);
    float refraction      = paramAt(p, pc, 5, 0.025);
    float driftSpeed      = paramAt(p, pc, 6, 0.2);
    float glitterMix      = paramAt(p, pc, 7, 0.5);

    float minDim = min(size.x, size.y);
    float2 uv = pos / size;
    float2 c  = uv - 0.5;

    // 水面のうねり。傾きで流れ、時間でゆっくり変形する。
    float2 wavePos = uv * waveScale + tilt * 0.9 + float2(time * 0.06, time * 0.045) + seed;
    float  wave    = fbm(wavePos);
    float2 waveGrad = float2(fbm(wavePos + float2(0.06, 0.0)) - wave,
                             fbm(wavePos + float2(0.0, 0.06)) - wave) * 14.0;

    // 屈折。傾きぶんの一様な流れと、うねりぶんの局所的なずれを合わせる。
    float2 offset = (tilt * 0.8 + waveGrad) * refraction * minDim;
    half4 refracted = layer.sample(pos + offset);
    float3 base = (refracted.a > 0.02h) ? float3(refracted.rgb) / float(refracted.a)
                                        : float3(src.rgb) / float(src.a);

    float3 tint = hueColor(tintHue);
    base = mix(base, base * (0.55 + 0.75 * tint), 0.30);

    // 封入された粒。3x3 の近傍セルを走査する。
    float2 gridPos = uv * particleDensity;
    float2 cellBase = floor(gridPos);
    float particles = 0.0;
    float3 particleTint = float3(0.0);

    for (int oy = -1; oy <= 1; oy++) {
        for (int ox = -1; ox <= 1; ox++) {
            float2 cell = cellBase + float2(float(ox), float(oy));
            float2 rnd  = hash22(cell + seed);
            float  rz   = hash21(cell * 2.3 + seed);

            // 奥行き。手前の粒ほど大きく動き、層として分離して見える。
            float depth = 0.35 + 0.65 * rz;
            float2 gravity = tilt * (0.55 * depth);
            float2 circulation = float2(sin(time * driftSpeed + rnd.x * 6.2831853),
                                        cos(time * driftSpeed * 0.83 + rnd.y * 6.2831853)) * 0.16;

            float2 center = cell + 0.5 + (rnd - 0.5) * 0.85 + gravity + circulation;
            float  d = length(gridPos - center);
            float  radius = (0.10 + 0.16 * particleSize) * depth;

            float dot_ = smoothstep(radius, radius * 0.25, d);
            particles += dot_ * depth;
            particleTint += hueColor(fract(tintHue + rnd.x * 0.25)) * dot_;
        }
    }
    particles = clamp(particles, 0.0, 1.4);
    particleTint = (particles > 0.001) ? particleTint / max(particles, 0.001) : float3(1.0);

    // 大きな気泡。重力と逆に動くため、粒との動きの違いが液体らしさを補強する。
    float2 bubblePos = -tilt * 0.30 + float2(0.0, -0.04) + float2(sin(time * 0.5 + seed) * 0.02, cos(time * 0.37 + seed) * 0.02);
    float  bd = length((c - bubblePos) * float2(1.0, size.y / max(size.x, 1.0)));
    float  bubbleR = 0.085;
    float  bubble = smoothstep(bubbleR, bubbleR * 0.75, bd);
    float  bubbleEdge = bubble * smoothstep(bubbleR * 0.55, bubbleR * 0.95, bd);

    // ラメ。粒より細かく、傾きで一斉に明滅する。
    float2 gPos = uv * (particleDensity * 3.2);
    float2 gCell = floor(gPos);
    float2 gJit = hash22(gCell * 1.3 + seed * 2.0);
    float  gRnd = hash21(gCell + seed);
    float  gd = length(fract(gPos) - gJit);
    float  glitter = smoothstep(0.26, 0.0, gd)
                   * pow(sin(time * 2.2 + gRnd * 6.2831853 + dot(tilt, float2(2.6, 2.2))) * 0.5 + 0.5, 6.0)
                   * glitterMix;

    // カプセル壁。縁の内側だけを細く光らせる。
    float cov = ringCoverage(layer, pos, minDim * 0.05);
    float wall = pow(1.0 - clamp((float(src.a) + cov) * 0.5, 0.0, 1.0), 2.2);

    float3 col = base;
    col = mix(col, screenBlend(col, particleTint * 0.85), particles * 0.75);
    col = screenBlend(col, float3(bubbleEdge * 0.65));
    col = mix(col, col * 1.12, bubble * 0.5);
    col = screenBlend(col, float3(glitter));
    col = screenBlend(col, mix(float3(1.0), tint, 0.4) * wall * 0.75);
    // 水面のハイライト。うねりの峰だけを拾う。
    col = screenBlend(col, float3(smoothstep(0.68, 0.92, wave + dot(tilt, float2(0.25, 0.2))) * 0.35));

    return half4(half3(col * float(src.a)), src.a);
}
