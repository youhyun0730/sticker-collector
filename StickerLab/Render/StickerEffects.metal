#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

// -----------------------------------------------------------------------------
// 共通の約束
//
// 3種の加工はすべて同一のシグネチャを持つ。
//
//   half4 fx_xxx(float2 pos, SwiftUI::Layer layer,
//                float2 size, float2 tilt, float2 flow, float time, float seed,
//                device const float *p, int pc)
//
// これにより Swift 側は加工ごとの分岐なしに、カタログの関数名を引いて
// 同じ引数列で呼び出せる。`p` は EffectDefinition.paramSchema の
// **配列順**に詰められた実値であり、添字がパラメータに対応する。
//
// tilt は端末の傾きを -1..1 に正規化したもの。x が左右、y が前後。
//      材質ごとのばねを通った後の値が来るため、遅れはここでは作らない。
// flow は tilt の毎秒あたりの変化量。動かした瞬間だけ強くなる表現に使う。
//      箔の一閃と、液面の波立ちがこれを読む。
//
// 画面座標は y が下向き。光源は既定で上から、重力は +y を基準に置く。
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

static inline float2 rotate2(float2 v, float angle) {
    float s = sin(angle), c = cos(angle);
    return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}

/// 彩度・明度を最大にした色相環。
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

/// 0.5 を中心に伸ばす。模様を「明るくする」のではなく「コントラストを変える」ために使う。
///
/// 加算で模様を乗せると淡い被写体の上で白く飛ぶ。倍率で伸ばすと、
/// 白地でも中間調でも同じ強さで模様が読める。ホロ箔の下地づくりの要。
static inline float3 stretchContrast(float3 c, float factor) {
    return clamp((c - 0.5) * factor + 0.5, 0.0, 1.0);
}

// -----------------------------------------------------------------------------
// 輪郭からの距離場とドームの断面
//
// アルファだけを頼りに「縁からどれだけ内側か」を測る。切り抜き形状に依存しないので、
// フェーズ1で Vision の前景マスクへ差し替えても同じコードで成立する。
//
// 半径の違う 4 本のリングを読む。各 8 点、リングごとに角度を 11.25 度ずつずらして
// 合計 32 方向を拾う。1 ピクセルあたり 33 回の読み取りで、ここがこの加工でいちばん重い。
//
// 3 本 x 8 点（25 回）と 4 本 x 6 点（25 回）も試したが、どちらも縁が多角形に割れる。
// 方向の数と半径の段数はどちらも削れず、33 回が見た目を保てる下限だった。
// -----------------------------------------------------------------------------

/// ドームの形状。ぷっくりと水入りの殻で共有する。
struct Dome {
    /// 輪郭からの距離。0 が縁、1 が探索半径より内側。
    float depth;
    /// 盛り上がりの高さ。0 が縁、1 が頂部の平らな面。
    float height;
    /// 面の法線。頂部では真上を向き、縁では外へ倒れる。
    float3 normal;
    /// 輪郭から内側を指す単位ベクトル。縁の光の向き判定に使う。
    float2 inward;
    /// 断面の傾き。縁でだけ大きくなる。
    float slope;
    /// いちばん内側のリングだけで測った縁の近さ。0 が輪郭上、1 が内側。
    ///
    /// depth は探索半径いっぱいまで見るため、耳のような細い部分では中央でも 1 に届かない。
    /// 接地の暗い線のように「輪郭のすぐ内側だけ」を狙う処理は、太さに影響されない
    /// こちらを見る必要がある。
    float rim;
};

static inline Dome buildDome(SwiftUI::Layer layer, float2 pos, float centerAlpha,
                             float radius, float bevelWidth, float domeHeight)
{
    const float ringScale[4] = { 0.30, 0.55, 0.78, 1.00 };

    // 勾配は内側のリングを重く見る。外側のリングは 1 点あたりの弧が長く、
    // 位置がわずかに動くだけで標本が輪郭を跨いでしまい、法線の向きが飛ぶ。
    // 面の向きは内側から、輪郭までの距離は外側から取るのが安定する。
    const float gradWeight[4] = { 1.00, 0.70, 0.40, 0.18 };

    float coverage = centerAlpha;
    float innerCoverage = centerAlpha;
    float2 gradient = float2(0.0);
    float gradientWeight = 0.0;

    for (int ring = 0; ring < 4; ring++) {
        float r = radius * ringScale[ring];
        float phase = 0.1963495 * float(ring);   // 11.25 度ずつずらす
        float sum = 0.0;
        float2 g = float2(0.0);
        for (int i = 0; i < 8; i++) {
            float a = 0.7853982 * float(i) + phase;
            float2 dir = float2(cos(a), sin(a));
            float s = float(layer.sample(pos + r * dir).a);
            sum += s;
            g += dir * s;
        }
        coverage += sum / 8.0;
        if (ring == 0) { innerCoverage = (innerCoverage + sum / 8.0) * 0.5; }
        gradient += (g / 8.0) * gradWeight[ring];
        gradientWeight += gradWeight[ring];
    }
    coverage /= 5.0;

    Dome dome;
    // 直線の縁の上では被覆率が 0.5 になる。そこを距離 0 として伸ばす。
    // 耳の先のような細い突起では被覆率が 1 に届かないため、距離も頂部に届かない。
    // 実物のぷっくりシールでも細い部分は低く仕上がるので、この飽和は都合がよい。
    dome.depth = clamp(coverage * 2.0 - 1.0, 0.0, 1.0);
    dome.rim = clamp(innerCoverage * 2.0 - 1.0, 0.0, 1.0);

    float2 g = gradient / max(gradientWeight, 1e-4);
    float gl = length(g);
    dome.inward = (gl > 1e-4) ? g / gl : float2(0.0);

    // 向きがどれだけ信用できるか。耳のような細い部分では、リングが突起をまたいで
    // 反対側まで読むため、打ち消し合って勾配が小さくなる。そこで斜面を立てると
    // 向きの定まらない法線が暴れ、縁が皺に割れる。実物でも細い部分は低く仕上がるので、
    // 勾配が小さいところは寝かせるのが形としても正しい。
    float confidence = smoothstep(0.015, 0.075, gl);

    // 縁から頂部までの断面。円弧なので、縁で急に立ち上がり頂部で平らになる。
    // 半球にすると裾が広がって饅頭に見えるため、意図して平らな頂部を作る。
    // 参考写真のぷくぷくシールも、頂部は平らで縁だけが急に落ちている。
    //
    // bevelWidth は距離場の単位。距離 0.5 がおおよそ探索半径の 1/4（＝シールの 5%）に
    // あたるため、0.5 前後で「縁から 1 割ほどが斜面」という実物に近い比率になる。
    float t = clamp(dome.depth / max(bevelWidth, 0.08), 0.0, 1.0);
    float inv = 1.0 - t;
    dome.height = sqrt(max(0.0, 1.0 - inv * inv));
    // 断面の傾き。縁で発散するので頭を押さえる。ここが樹脂の縁の立ち方を決める。
    float dhdt = min(inv / max(dome.height, 0.20), 2.6);
    dome.slope = dhdt * (0.35 + 0.95 * domeHeight) * confidence;

    dome.normal = normalize(float3(-dome.inward * dome.slope, 1.0));
    return dome;
}

/// 簡易の環境光。水平に伸びる明るい帯を並べた「窓」を想定する。
///
/// 点光源の丸いハイライトでは、樹脂の縁に出る細長い筋が作れない。
/// 帯を映り込ませると、反射ベクトルが帯を横切る場所が輪郭と平行な曲線になり、
/// 参考写真のような「縁に沿って伸びる白い筋」がそのまま出る。
static inline float envBand(float3 reflectDir, float2 tiltShift, float freq, float rotation) {
    // 反射ベクトルの xy をそのまま帯の座標にする。立体射影で引き伸ばすと、
    // 急な斜面で座標が一気に走って帯が何本も詰まり、縁が皺だらけに見える。
    // xy は -1..1 に収まるため、斜面を横切る間に通る帯は freq 本ぶんで済む。
    float2 e = rotate2(reflectDir.xy, rotation) + tiltShift;

    float s = e.y * freq;
    // 正弦の山を鋭くして帯にする。矩形の帯は法線のわずかな揺れで割れるが、
    // これなら滑らかなまま、中心だけが強く光る。
    float band = pow(sin(s * 6.2831853) * 0.5 + 0.5, 5.0);
    // 帯と帯の間にもわずかに明かりを残す。完全に黒く沈めると樹脂が金属に見える。
    return band * 0.92 + 0.08 * (0.5 + 0.5 * sin(s * 3.1415927));
}

// -----------------------------------------------------------------------------
// フラットシール：ホログラム箔
//
// 平面。厚みを持たないぶん、傾けたときの反応が最も速く直線的であること。
//
// 加算で虹を乗せる作りは、淡い被写体の上で白く飛んで消える。ここでは
// 「箔の地色へ寄せてから、模様でコントラストを伸ばす」順で組む。トレーディング
// カードの箔押しと同じ手順で、白地でも暗部でも同じ強さで模様が残る。
//
// 個体差は 2 系統ある。**模様**（種類・大きさ・深さ）と、**角度に対する色の動き**
// （どの向きに傾けると色が回るか、どれだけ回るか）。後者があるため、同じ角度に
// 傾けても個体ごとに違う色が出る。
// -----------------------------------------------------------------------------
[[ stitchable ]] half4 fx_flatFoil(float2 pos,
                                   SwiftUI::Layer layer,
                                   float2 size,
                                   float2 tilt,
                                   float2 flow,
                                   float time,
                                   float seed,
                                   device const float *p,
                                   int pc)
{
    half4 src = layer.sample(pos);
    if (src.a < 0.004h) { return half4(0.0h); }

    float alpha = float(src.a);
    float3 base = float3(src.rgb) / alpha;

    float patternType  = paramAt(p, pc,  0, 0.0);
    float patternScale = paramAt(p, pc,  1, 14.0);
    float patternDepth = paramAt(p, pc,  2, 0.35);
    float grainScale   = paramAt(p, pc,  3, 70.0);
    float grainDepth   = paramAt(p, pc,  4, 0.18);
    float hueBase      = paramAt(p, pc,  5, 0.0);
    float hueSpread    = paramAt(p, pc,  6, 1.6);
    float tiltChroma   = paramAt(p, pc,  7, 1.4);
    float tiltAxis     = paramAt(p, pc,  8, 0.6);
    float colorAmount  = paramAt(p, pc,  9, 0.62);
    float baseline     = paramAt(p, pc, 10, 0.26);
    float glareSize    = paramAt(p, pc, 11, 0.55);
    float glareAmount  = paramAt(p, pc, 12, 0.5);
    float cellSparkle  = paramAt(p, pc, 13, 0.5);

    float aspect = size.x / max(size.y, 1.0);
    float2 uv = pos / size;
    float2 c  = (uv - 0.5) * float2(aspect, 1.0);

    // ---- 角度に対する色の動き -------------------------------------------------
    // 傾きを、箔の色空間の中の平行移動に変換する。個体ごとに軸と感度が違うので、
    // 「どちらへ傾けると何色になるか」が一枚ずつ変わる。ここが個体差の主成分。
    float2 axis = float2(cos(tiltAxis), sin(tiltAxis));
    float2 perp = float2(-axis.y, axis.x);
    float2 shift = axis * (dot(tilt, axis) * tiltChroma)
                 + perp * (dot(tilt, perp) * tiltChroma * 0.55);

    // ---- 模様 ---------------------------------------------------------------
    // 模様は色より先に決める。小片ごとに箔の位相をずらすので、
    // 模様の目が「別々の色で光る小片」になり、ただの網目にならない。
    float2 pp = rotate2(c, tiltAxis) * patternScale;
    float cell;
    float2 cellID;
    if (patternType < 0.5) {                       // ダイヤ
        float2 d = rotate2(pp, 0.7853982);
        cellID = floor(d);
        cell = fmod(abs(cellID.x + cellID.y), 2.0) < 0.5 ? 0.0 : 1.0;
    } else if (patternType < 1.5) {                // 格子
        cellID = floor(pp);
        cell = fmod(abs(cellID.x + cellID.y), 2.0) < 0.5 ? 0.0 : 1.0;
    } else if (patternType < 2.5) {                // 線状
        cellID = float2(floor(pp.x * 0.5), 0.0);
        cell = fract(pp.x * 0.5) < 0.5 ? 0.0 : 1.0;
    } else {                                       // 六角の近似
        float2 q = float2(pp.x, pp.y * 0.8660254);
        q.x += fmod(abs(floor(q.y)), 2.0) * 0.5;
        cellID = floor(q);
        cell = fract(q.x) < 0.5 ? 0.0 : 1.0;
    }
    float cellPhase = hash21(cellID * 1.13 + seed);

    // ---- 箔の地色 -------------------------------------------------------------
    // 3 チャンネルがそれぞれ別の向きに揺れる。1 本の虹の帯にすると印刷物に見えるが、
    // 向きの違う 3 枚を重ねると、油膜のように場所によって色の並びが入れ替わる。
    float2 q = rotate2(c, hueBase * 6.2831853) * hueSpread + shift;
    q += (cellPhase - 0.5) * patternDepth * 0.55;   // 小片ごとに色をずらす
    float3 foil = float3(sin(q.x * 6.2831853 + hueBase * 6.2831853),
                         cos(q.y * 6.2831853 + hueBase * 4.1887902),
                         sin((q.x + q.y) * 4.4 - hueBase * 2.0943951));
    foil = clamp(0.60 + 0.36 * foil, 0.0, 1.0);

    // ---- 下地へ寄せる ---------------------------------------------------------
    // 明るいところほど強く箔になる。暗部にも baseline ぶんは必ず乗せる。
    // 加算ではなく mix なので、白地でも色が残る。
    //
    // さらに、もともと色が付いている場所では寄せる量を減らす。実物の箔押しでも
    // 白場や淡い場所でいちばん派手に光り、濃い色の上では下の色が勝つ。
    // これが無いと、彩度の高い写真が一様な牛乳色に潰れる。
    float3 b = base;
    float saturation = max(max(b.r, b.g), b.b) - min(min(b.r, b.g), b.b);
    float amount = max(smoothstep(0.18, 1.0, luma(base)) * colorAmount * (1.0 - 0.60 * saturation),
                       baseline * (1.0 - 0.40 * saturation));
    float3 col = mix(base, foil, amount);

    // ---- 模様と粒子でコントラストを伸ばす -------------------------------------
    float grain = vnoise(uv * grainScale + seed * 7.0);
    col = stretchContrast(col, 1.0 + patternDepth * cell);
    col = stretchContrast(col, 1.0 + grainDepth * grain);

    // 小片が角度で一斉に瞬く。箔押しの目がちらつく挙動。
    float twinkle = pow(sin(cellPhase * 6.2831853 + dot(tilt, axis) * 7.0 + time * 0.8) * 0.5 + 0.5, 7.0);
    col = screenBlend(col, float3(twinkle * cell * cellSparkle * 0.55));

    // ---- 面を横切る光 ---------------------------------------------------------
    // 傾きに追従する広い照り返し。箔の色を動かすのが上の shift、明るさを動かすのがこれ。
    float2 glareCenter = -tilt * 0.52;
    float gd = length(c - glareCenter) / max(glareSize, 0.12);
    col = screenBlend(col, float3(smoothstep(1.0, 0.0, gd) * glareAmount * 0.55));

    // 動かした瞬間だけ走る細い一閃。静止画には出ないので、動きの手応えになる。
    float speed = clamp(length(flow) * 0.55, 0.0, 1.0);
    float2 sweepDir = (length(flow) > 1e-3) ? normalize(flow) : axis;
    float sweepPos = dot(c, sweepDir) + dot(tilt, sweepDir) * 0.5;
    col = screenBlend(col, float3(exp(-sweepPos * sweepPos * 34.0) * speed * 0.5));

    return half4(half3(col * alpha), src.a);
}

// -----------------------------------------------------------------------------
// ぷっくりシール
//
// 狙いは「厚い透明樹脂が、絵の輪郭に沿って盛り上がっている」状態。
// 参考写真から読み取った特徴は 4 つで、この順に効く。
//
//   1. 頂部は平らで、縁だけが急に落ちる。半球ではない。
//   2. 縁は無色に近く白っぽい。樹脂そのものの色が抜けて見える。
//   3. ハイライトは丸い玉ではなく、輪郭に沿って伸びる白い筋。
//   4. 絵は頂部では歪まず、縁でだけ圧縮される。
//
// 1 は距離場に円弧の断面を当てて作る。3 は点光源ではなく帯状の環境光を
// 映り込ませて作る。玉のハイライトでは、写真のような筋の形にならない。
// -----------------------------------------------------------------------------
[[ stitchable ]] half4 fx_puffyGloss(float2 pos,
                                     SwiftUI::Layer layer,
                                     float2 size,
                                     float2 tilt,
                                     float2 flow,
                                     float time,
                                     float seed,
                                     device const float *p,
                                     int pc)
{
    half4 src = layer.sample(pos);
    if (src.a < 0.004h) { return half4(0.0h); }

    float domeHeight  = paramAt(p, pc,  0, 0.70);
    float bevelWidth  = paramAt(p, pc,  1, 0.30);
    float glossSharp  = paramAt(p, pc,  2, 90.0);
    float specAmount  = paramAt(p, pc,  3, 0.75);
    float envFreq     = paramAt(p, pc,  4, 1.5);
    float envRotation = paramAt(p, pc,  5, 0.0);
    float refraction  = paramAt(p, pc,  6, 0.05);
    float rimLight    = paramAt(p, pc,  7, 0.70);
    float innerShadow = paramAt(p, pc,  8, 0.30);
    float tintHue     = paramAt(p, pc,  9, 0.55);
    float tintAmount  = paramAt(p, pc, 10, 0.15);
    float fresnelPow  = paramAt(p, pc, 11, 3.0);

    float minDim = min(size.x, size.y);
    float alpha  = float(src.a);

    Dome dome = buildDome(layer, pos, alpha, minDim * 0.20, bevelWidth, domeHeight);
    float3 n = dome.normal;

    // 光源は上から。傾けると回り込む。静止時も死なないようわずかに呼吸させる。
    float3 L = normalize(float3(tilt.x * 1.15,
                                -0.34 - tilt.y * 1.15,
                                0.95 + 0.03 * sin(time * 0.6 + seed)));
    float3 V = float3(0.0, 0.0, 1.0);
    float3 H = normalize(L + V);
    float3 R = reflect(-V, n);

    // ---- 屈折 ---------------------------------------------------------------
    // 厚みのぶん、下の絵がずれて見える。ずれは縁でだけ大きく、頂部ではほぼ生じない。
    // レンズの縁で像が詰まるのと同じで、内側へ寄せると圧縮に見える。
    float2 offset = -n.xy * refraction * minDim * (0.35 + 0.65 * dome.slope);
    half4 refracted = layer.sample(pos + offset);
    float3 col = (refracted.a > 0.02h) ? float3(refracted.rgb) / float(refracted.a)
                                       : float3(src.rgb) / alpha;

    // ---- 樹脂そのものの色 -----------------------------------------------------
    // 光が斜めに長く通る縁ほど色が濃く出る。無色の個体では効かない。
    float3 resin = mix(float3(1.0), hueColor(tintHue), 0.75);
    col *= mix(float3(1.0), resin, tintAmount * (0.30 + 0.70 * (1.0 - dome.height)));

    // ---- 陰影 ---------------------------------------------------------------
    // 透明なコート層は、下の絵から光を奪う。白い被写体でもハイライトが白へ抜けられるよう、
    // ここで地の明るさを一段落としておく。これを省くと全体が白く飛んで厚みが消える。
    float ndl = max(dot(n, L), 0.0);
    col *= 0.72 + 0.24 * ndl;

    // 斜面はどの向きでも暗くなる。写真のぷくぷくシールで縁がくっきり見えるのは、
    // 光より先にこの陰があるから。光の当たらない側だけをさらに落とす。
    float2 lightDir = normalize(L.xy + float2(1e-5, 1e-5));
    float awayFromLight = max(dot(dome.inward, lightDir), 0.0);
    float bevel = 1.0 - dome.height;
    col *= 1.0 - 0.52 * bevel * bevel;
    col *= 1.0 - innerShadow * bevel * awayFromLight;

    // 平らな頂部が斜面へ落ち始めるところに、細い稜線を 1 本置く。
    // 参考写真で「厚みのある板の角」に見えているのはこの線で、
    // 頂部と斜面を分ける境目がはっきりすると、饅頭ではなく成形品に見える。
    float ridge = exp(-pow((dome.height - 0.88) / 0.09, 2.0));

    // ---- 縁に沿って伸びる白い筋 ------------------------------------------------
    // 参考写真のハイライトの正体。帯状の環境光の映り込みなので、
    // 傾けると筋が輪郭をなぞって移動する。玉のハイライトとは動き方が違う。
    float env = envBand(R, -tilt * 0.45, envFreq, envRotation + seed * 0.01);
    // 縁の斜面だけが強く映り込む。平らな頂部には薄くしか乗らない。
    float envMask = 0.10 + 0.90 * smoothstep(0.0, 0.55, dome.slope);
    col = screenBlend(col, float3(env * envMask * specAmount));
    col = screenBlend(col, float3(ridge * (0.25 + 0.45 * env) * specAmount));

    // ---- 鋭い反射 ------------------------------------------------------------
    // 樹脂は表面が硬いので、指数を大きく取って小さく強い点にする。
    float spec = pow(max(dot(n, H), 0.0), glossSharp) * specAmount * 1.8;
    col = screenBlend(col, float3(spec));

    // ---- フレネル：無色の縁 ---------------------------------------------------
    // 縁を見込む角度が浅いほど、下の絵ではなく空が映る。実物の「縁だけ無色に見える」の正体。
    // 加算では白い被写体の上で消えるため、下地の彩度を抜きながら明度を寄せる。
    float fresnel = pow(1.0 - clamp(n.z, 0.0, 1.0), fresnelPow) * rimLight;
    col = mix(col, float3(0.72 + 0.28 * env), clamp(fresnel, 0.0, 0.85));

    // ---- 接地の暗い線 ---------------------------------------------------------
    // いちばん外側だけを締める。これが無いと背景と溶けて、厚みが消える。
    float contact = smoothstep(0.40, 0.0, dome.rim);
    col *= 1.0 - contact * 0.40;

    // ---- 頂部を転がる広い照り返し ----------------------------------------------
    // 厚みのある塊が動いている感じは、この大きな面の移動が担う。
    float2 cc = pos / size - 0.5;
    float2 sheenAt = cc + tilt * 0.34;
    float sheen = exp(-dot(sheenAt, sheenAt) * 11.0) * dome.height * specAmount;
    col = screenBlend(col, float3(sheen * 0.30));

    return half4(half3(col * alpha), src.a);
}

// -----------------------------------------------------------------------------
// 水入りシール
//
// ぷっくりの殻の中に液体を入れる。完全な流体計算はせず、次の 4 点だけを守る。
//
//   1. 液面は常に重力と直交する一本の線で、傾けると位置が変わる。
//   2. 液量は変わらない。傾けても液面より下の量がほぼ保たれる。
//   3. 動かした瞬間だけ液面が波立ち、粘度が低い個体ほど細かく速く揺れる。
//   4. 気泡は重力と逆に昇り、ラメは重力に沿って落ちて底に溜まる。
//
// 1 と 2 だけで液体に見える。物理的な正しさより、液面が 1 本の直線であることと、
// 中身が殻とは別の時定数で動くことのほうが効く。
// -----------------------------------------------------------------------------
[[ stitchable ]] half4 fx_waterCapsule(float2 pos,
                                       SwiftUI::Layer layer,
                                       float2 size,
                                       float2 tilt,
                                       float2 flow,
                                       float time,
                                       float seed,
                                       device const float *p,
                                       int pc)
{
    half4 src = layer.sample(pos);
    if (src.a < 0.004h) { return half4(0.0h); }

    float viscosity   = paramAt(p, pc,  0, 0.60);
    float fillRatio   = paramAt(p, pc,  1, 0.62);
    float tintHue     = paramAt(p, pc,  2, 0.55);
    float tintDensity = paramAt(p, pc,  3, 0.60);
    float refraction  = paramAt(p, pc,  4, 0.035);
    float waveScale   = paramAt(p, pc,  5, 3.0);
    float bubbleCount = paramAt(p, pc,  6, 3.0);
    float bubbleSize  = paramAt(p, pc,  7, 0.50);
    float glitterMix  = paramAt(p, pc,  8, 0.50);
    float glitterFall = paramAt(p, pc,  9, 0.20);
    float domeHeight  = paramAt(p, pc, 10, 0.75);
    float bevelWidth  = paramAt(p, pc, 11, 0.26);
    float specAmount  = paramAt(p, pc, 12, 0.80);

    float minDim = min(size.x, size.y);
    float alpha  = float(src.a);
    float aspect = size.x / max(size.y, 1.0);
    float2 c = (pos / size - 0.5) * float2(aspect, 1.0);

    Dome dome = buildDome(layer, pos, alpha, minDim * 0.20, bevelWidth, domeHeight);
    float3 n = dome.normal;

    // ---- 重力 ---------------------------------------------------------------
    // 左右の傾きは重力を面内で回す。前後の傾きは面内では回しようがないので、
    // 液面の高さに割り当てる。端末の上端を奥へ倒すと液体が奥へ寄り、画面では液面が下がる。
    // 奥行き方向のスロッシュを、2次元の液面の上下に読み替えている。
    float2 gDir = normalize(float2(tilt.x * 1.9, 1.0));
    float2 gPerp = float2(-gDir.y, gDir.x);

    // 液量を保つための液面の高さ。形状の外接矩形を重力方向へ射影して求める。
    // 正確な体積計算ではないが、左右に傾けたときに液面が「上がりも下がりもしない」ことのほうが、
    // 面積の厳密さより液体らしさに効く。
    float extent = 0.5 * (abs(gDir.x) * aspect + abs(gDir.y));
    float level = extent * (1.0 - 2.0 * fillRatio) + tilt.y * 0.20;

    // 液面の波。動かした瞬間だけ大きく、粘度が低いほど細かく速い。
    float speed = clamp(length(flow) * 0.6, 0.0, 1.2);
    float agility = 1.0 - clamp(viscosity, 0.0, 1.0);
    float amp = (0.004 + 0.030 * speed) * (0.45 + 0.55 * agility);
    float u = dot(c, gPerp);
    float wobble = sin(u * waveScale * 3.4 + time * (1.6 + 2.0 * agility) + seed)
                 + 0.45 * sin(u * waveScale * 5.7 - time * (1.1 + 1.4 * agility) + seed * 2.3);
    level += wobble * amp;

    // 壁際でわずかに這い上がる。液体が殻に触れている感じはこの一点で決まる。
    float climb = 0.022 * (1.0 - dome.depth) * (1.0 - dome.depth);

    // 重力方向の座標。液面より下が液体。
    float along = dot(c, gDir) + climb;
    float s = along - level;
    float liquid = smoothstep(-0.012, 0.012, s);

    // ---- 屈折 ---------------------------------------------------------------
    // 殻の厚みによるずれに、液体を通る量を足す。液面のすぐ下だけ強く曲げると、
    // 水面越しに見たときの「境目で像が飛ぶ」感じになる。
    // 液面での曲がりを強くしすぎると、像がちぎれて水面ではなく破れ目に見える。
    float meniscus = exp(-pow(s / 0.030, 2.0));
    float2 offset = -n.xy * refraction * minDim * (0.30 + 0.70 * dome.slope);
    offset += gDir * refraction * minDim * (0.9 * liquid * clamp(s * 3.0, 0.0, 1.0) - 0.8 * meniscus);

    half4 refracted = layer.sample(pos + offset);
    float3 col = (refracted.a > 0.02h) ? float3(refracted.rgb) / float(refracted.a)
                                       : float3(src.rgb) / alpha;

    // ---- 液体の色 -------------------------------------------------------------
    // 深いところほど濃い。透過率を指数で落とすと、薄い縁から濃い底へ自然に繋がる。
    float3 tint = mix(float3(1.0), hueColor(tintHue), 0.85);
    float depthInLiquid = clamp(s * 2.6, 0.0, 1.4);
    float3 absorb = exp(-(1.0 - tint) * tintDensity * (0.5 + 1.9 * depthInLiquid));
    col *= mix(float3(1.0), absorb, liquid);
    // 液面より上は空の樹脂、下は液体。液体側を一段沈めて、境目を明度でも作る。
    // 色の吸収だけに頼ると、彩度の高い写真の上で液面が見えなくなる。
    col *= mix(1.12, 0.82 + 0.10 * (1.0 - tintDensity), liquid);

    // ---- 液面 ---------------------------------------------------------------
    // 明るい線のすぐ下に暗い線を置く。1 本だけだと発光して見え、水面にならない。
    float surfaceLine = exp(-pow(s / 0.016, 2.0));
    float underLine   = exp(-pow((s - 0.030) / 0.026, 2.0));
    col *= 1.0 - underLine * 0.22;
    col = screenBlend(col, mix(float3(1.0), tint, 0.35) * surfaceLine * 0.42);

    // ---- 沈むラメ -------------------------------------------------------------
    // 落下は「粒を動かす」のではなく「座標を重力方向へ流す」ことで作る。
    // 粒自体を遠くへ動かすと、近傍 3x3 セルの走査範囲から外れて描かれなくなる。
    // 流すかたちなら、どの時刻でも必ず近傍セルの中に粒がある。
    float2 flowUV = c + gDir * (time * glitterFall * 0.45);
    float2 gp = flowUV * 11.0;
    float2 cellBase = floor(gp);
    float glitter = 0.0;
    for (int oy = -1; oy <= 1; oy++) {
        for (int ox = -1; ox <= 1; ox++) {
            float2 cell = cellBase + float2(float(ox), float(oy));
            float2 jitter = hash22(cell + seed);
            float  rnd = hash21(cell * 3.1 + seed);
            float  d = length(gp - (cell + 0.15 + jitter * 0.7));
            float  twinkle = pow(sin(time * 2.4 + rnd * 6.2831853 + dot(tilt, float2(3.0, 2.4))) * 0.5 + 0.5, 5.0);
            glitter += smoothstep(0.20 + 0.10 * rnd, 0.0, d) * (0.30 + 0.70 * twinkle);
        }
    }
    // 底に積もったぶん。落ちてきた粒がここへ吸い込まれていくように見える。
    // 一粒ずつ着地させるより安く、振ったときの「溜まりが崩れて舞う」も作りやすい。
    float sediment = smoothstep(extent * 0.45, extent * 0.92, along)
                   * (0.55 + 0.45 * sin(u * 26.0 + seed * 3.0))
                   * (1.0 - clamp(speed, 0.0, 0.8));
    float3 glitterColor = mix(float3(1.0), tint, 0.3);
    col = screenBlend(col, glitterColor * clamp(glitter, 0.0, 1.0) * glitterMix * liquid * 0.75);
    col = screenBlend(col, glitterColor * clamp(sediment, 0.0, 1.0) * glitterMix * liquid * 0.35);

    // ---- 昇る気泡 -------------------------------------------------------------
    // 重力と逆に動く。ラメと逆向きに動くものが同居すると、中身が液体だと分かる。
    float bubbles = 0.0;
    float bubbleRim = 0.0;
    int count = int(clamp(bubbleCount, 1.0, 5.0));
    for (int i = 0; i < 5; i++) {
        if (i >= count) { break; }
        float2 rnd = hash22(float2(float(i) * 7.7 + seed, seed * 0.31));
        float phase = fract(rnd.x + time * (0.10 + 0.22 * rnd.y) * (0.4 + 0.9 * agility));
        float2 home = (rnd - 0.5) * float2(aspect, 1.0) * 0.62;
        float2 at = home - gDir * (phase * 0.55 - 0.25);
        float r = (0.018 + 0.045 * bubbleSize) * (0.6 + 0.5 * rnd.y);
        float d = length(c - at);

        float alive = smoothstep(0.0, 0.12, phase) * smoothstep(1.0, 0.82, phase);
        // 液面より上には出ない。
        alive *= smoothstep(-0.02, 0.06, dot(at, gDir) - level);
        bubbles   += smoothstep(r, r * 0.60, d) * alive;
        bubbleRim += smoothstep(r, r * 0.82, d) * (1.0 - smoothstep(r * 0.86, r * 0.62, d)) * alive;
    }
    bubbles = clamp(bubbles, 0.0, 1.0) * liquid;
    bubbleRim = clamp(bubbleRim, 0.0, 1.0) * liquid;
    col = mix(col, col * 1.10, bubbles * 0.6);
    col = screenBlend(col, float3(bubbleRim * 0.55));

    // ---- 底に落ちる光 ---------------------------------------------------------
    // 液面を通った光が底に集まる。液体に厚みがあることの手がかりになる。
    float caustic = exp(-pow((along - extent * 0.78) / 0.13, 2.0)) * liquid;
    col = screenBlend(col, mix(float3(1.0), tint, 0.5) * caustic * 0.22);

    // ---- 殻 -----------------------------------------------------------------
    // ぷっくりと同じ樹脂の殻を被せる。中身の動きと殻の光り方が別の時定数で動くため、
    // 「固い殻の中で液体が遅れて動く」という読み取りになる。
    float3 L = normalize(float3(tilt.x * 1.15, -0.34 - tilt.y * 1.15, 0.95));
    float3 V = float3(0.0, 0.0, 1.0);
    float3 R = reflect(-V, n);
    float env = envBand(R, -tilt * 0.45, 1.7, seed * 0.013);
    float envMask = 0.10 + 0.90 * smoothstep(0.0, 0.55, dome.slope);
    col = screenBlend(col, float3(env * envMask * specAmount * 0.75));

    float spec = pow(max(dot(n, normalize(L + V)), 0.0), 110.0) * specAmount * 1.4;
    col = screenBlend(col, float3(spec));

    float fresnel = pow(1.0 - clamp(n.z, 0.0, 1.0), 3.0);
    col = screenBlend(col, float3(fresnel * 0.75));

    float contact = smoothstep(0.40, 0.0, dome.rim);
    col *= 1.0 - contact * 0.34;

    return half4(half3(col * alpha), src.a);
}
