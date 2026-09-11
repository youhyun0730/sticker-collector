import Foundation

/// 加工定義を読んで個体を生成する。
///
/// ここには加工ごとの分岐が存在しない。グレード抽選もパラメータ決定も
/// `EffectDefinition` の宣言だけを見て行うため、加工の追加は定義データと
/// シェーダー関数の追加に閉じる（SPEC 6.3）。
enum StickerFactory {

    /// 指定の加工で1個体を生成する。
    /// - Parameter rng: 検証時に系列を固定できるよう外から差し替え可能にする。
    static func make(
        effect: EffectDefinition,
        subjectID: String,
        shapeID: String,
        using rng: inout some RandomNumberGenerator
    ) -> StickerInstance {
        let grade = rollGrade(effect.grades, using: &rng)
        let params = rollParams(schema: effect.paramSchema, grade: grade, using: &rng)

        return StickerInstance(
            id: UUID(),
            subjectID: subjectID,
            shapeID: shapeID,
            effectID: effect.id,
            effectVersion: effect.version,
            fallbackEffectID: effect.fallbackEffectID,
            grade: grade?.id ?? "normal",
            renderParams: params,
            schemaVersion: StickerInstance.currentSchemaVersion,
            createdAt: Date()
        )
    }

    /// カタログ全体から加工も抽選して生成する。
    static func makeRandom(
        catalog: [EffectDefinition],
        subjectID: String,
        shapeID: String,
        using rng: inout some RandomNumberGenerator
    ) -> StickerInstance? {
        guard let effect = catalog.randomElement(using: &rng) else { return nil }
        return make(effect: effect, subjectID: subjectID, shapeID: shapeID, using: &rng)
    }

    // MARK: - 抽選

    /// 重み付き抽選。重みの合計が 0 でも破綻しない。
    static func rollGrade(
        _ grades: [GradeDefinition],
        using rng: inout some RandomNumberGenerator
    ) -> GradeDefinition? {
        let positive = grades.filter { $0.weight > 0 }
        guard !positive.isEmpty else { return grades.first }
        let total = positive.reduce(0.0) { $0 + $1.weight }
        var roll = Double.random(in: 0..<total, using: &rng)
        for grade in positive {
            roll -= grade.weight
            if roll < 0 { return grade }
        }
        return positive.last
    }

    /// スキーマを読んでパラメータの実値を決定する。
    ///
    /// グレードの `paramOverrides` があればその範囲を優先する。
    static func rollParams(
        schema: [ParamSpec],
        grade: GradeDefinition?,
        using rng: inout some RandomNumberGenerator
    ) -> [String: Float] {
        var result: [String: Float] = [:]
        for spec in schema {
            var lower = spec.min
            var upper = spec.max
            if let override = grade?.paramOverrides[spec.name], override.count == 2 {
                lower = override[0]
                upper = override[1]
            }
            if lower > upper { swap(&lower, &upper) }
            result[spec.name] = rollValue(spec: spec, lower: lower, upper: upper, using: &rng)
        }
        return result
    }

    private static func rollValue(
        spec: ParamSpec,
        lower: Float,
        upper: Float,
        using rng: inout some RandomNumberGenerator
    ) -> Float {
        guard upper > lower else { return lower }
        switch spec.distribution {
        case .uniform:
            return Float.random(in: lower...upper, using: &rng)
        case .centered:
            // 三角分布。2回の一様乱数の平均で中央に寄せる。
            let a = Float.random(in: 0...1, using: &rng)
            let b = Float.random(in: 0...1, using: &rng)
            return lower + (upper - lower) * (a + b) * 0.5
        case .quantized:
            let steps = max(1, spec.steps ?? 2)
            let index = Int.random(in: 0..<steps, using: &rng)
            guard steps > 1 else { return lower }
            return lower + (upper - lower) * Float(index) / Float(steps - 1)
        }
    }
}

/// 検証用の固定シード乱数。同じシードから同じ個体群を再現するために使う。
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // 0 を避ける。SplitMix64 は状態 0 でも動くが、初期値を散らしておく。
        state = seed &+ 0x9E3779B97F4A7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
