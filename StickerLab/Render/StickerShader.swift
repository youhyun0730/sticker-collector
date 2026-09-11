import SwiftUI

/// カタログの定義から SwiftUI の Shader を組み立てる。
///
/// ここに加工ごとの分岐は無い。関数名は定義から、引数はスキーマの配列順から作る。
/// 新しい加工を足すとき、この関数は変更されない。
enum StickerShader {

    /// `p` に渡す float 配列。**paramSchema の順序がそのまま添字になる。**
    /// 個体が値を持たない場合（旧バージョンで作られ、後からパラメータが増えた場合）は
    /// スキーマの下限で埋め、欠損で描画が破綻しないようにする。
    static func packedParams(definition: EffectDefinition, instance: StickerInstance) -> [Float] {
        definition.paramSchema.map { spec in
            instance.renderParams[spec.name] ?? spec.min
        }
    }

    static func make(
        definition: EffectDefinition,
        instance: StickerInstance,
        size: CGSize,
        tilt: SIMD2<Float>,
        time: Double
    ) -> Shader {
        let function = ShaderFunction(library: .default, name: definition.shaderFunction)
        return Shader(function: function, arguments: [
            .float2(size),
            .float2(tilt.x, tilt.y),
            .float(Float(time)),
            .float(instance.renderSeed),
            .floatArray(packedParams(definition: definition, instance: instance))
        ])
    }

    /// シェーダーが pos の外側をどれだけ参照するか。
    /// ぷっくりの法線推定と水入りの屈折がここに収まる必要がある。
    static func maxSampleOffset(for size: CGSize) -> CGSize {
        let minDim = min(size.width, size.height)
        let reach = max(12, minDim * 0.14)
        return CGSize(width: reach, height: reach)
    }
}
