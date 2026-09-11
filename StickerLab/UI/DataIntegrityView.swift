import SwiftUI

/// 検証項目4：データモデルの前提が成り立っているか。
///
/// - 未知の加工 ID を受け取ってもクラッシュせず、代替表示に落ちること（SPEC 6.5）
/// - 個体データを JSON で往復させても、パラメータが一致すること
///   （＝交換して他人の端末に渡っても同じ光り方になること）
struct DataIntegrityView: View {
    @EnvironmentObject private var engine: MotionEngine
    @ObservedObject var store: LabStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                fallbackSection
                Divider()
                roundTripSection
                Divider()
                lotterySection
                Divider()
                catalogSection
            }
            .padding(16)
        }
    }

    // MARK: - 未知の加工へのフォールバック

    private var fallbackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("未知の加工のフォールバック")
                .font(.headline)
            Text("右は effectID を \"aurora.ribbon.v4\" に差し替えた同じ個体です。このアプリはその定義を持たないため、fallbackEffectID を辿って代替表示になります。パラメータは欠損させずに保持しているため、アプリを更新すれば本来の表示に戻ります。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 12) {
                if let original = store.fallbackOriginal {
                    VStack(spacing: 6) {
                        StickerView(instance: original)
                        Text("定義を知っている端末")
                            .font(.caption2)
                    }
                }
                if let unknown = store.fallbackSample {
                    VStack(spacing: 6) {
                        StickerView(instance: unknown)
                            .overlay(alignment: .bottom) {
                                Text("アプリを更新すると\n本来の表示になります")
                                    .font(.system(size: 9))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.thinMaterial, in: Capsule())
                                    .padding(.bottom, 4)
                            }
                        Text("定義を知らない端末")
                            .font(.caption2)
                    }
                }
            }
            .tiltDraggable(engine: engine, enabled: engine.source == .drag)

            if let unknown = store.fallbackSample {
                let resolved = EffectCatalog.shared.resolveForRendering(
                    id: unknown.effectID,
                    fallbackHint: unknown.fallbackEffectID
                )
                Label(
                    "解決結果: \(unknown.effectID) → \(resolved.definition.id)（代替表示: \(resolved.isFallback ? "はい" : "いいえ")）",
                    systemImage: resolved.isFallback ? "arrow.turn.down.right" : "checkmark"
                )
                .font(.caption.monospaced())
                .foregroundStyle(.orange)
                Text("保持されているパラメータ: \(unknown.renderParams.count) 件（欠損なし）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 往復一致

    private var roundTripSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("交換後の再現性")
                .font(.headline)
            Text("個体を JSON に書き出して読み直し、パラメータが完全に一致するかを確認します。レンダリングは決定論的なので、一致すれば相手の端末でも同じ見た目になります。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(store.materialSamples) { instance in
                let result = RoundTripCheck.run(instance)
                HStack(spacing: 8) {
                    Image(systemName: result.passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundStyle(result.passed ? .green : .red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.effectDisplayName(instance.effectID))
                            .font(.caption)
                        Text(result.detail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            if let sample = store.materialSamples.first {
                HStack(spacing: 12) {
                    VStack(spacing: 4) {
                        StickerView(instance: sample, fixedTilt: engine.rawTilt)
                        Text("元の個体").font(.caption2)
                    }
                    VStack(spacing: 4) {
                        if let decoded = RoundTripCheck.decoded(sample) {
                            StickerView(instance: decoded, fixedTilt: engine.rawTilt)
                        }
                        Text("JSON 往復後").font(.caption2)
                    }
                }
                .tiltDraggable(engine: engine, enabled: engine.source == .drag)
            }
        }
    }

    // MARK: - 抽選

    private var lotterySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("グレード抽選の実測")
                .font(.headline)
            Text("定義した重みどおりに出ているかを、各加工 20,000 回の試行で確かめます。段階数と確率は未決のため（SPEC 10）、ここを見ながら調整します。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(store.catalog) { effect in
                let measured = GradeLotteryCheck.measure(effect: effect, trials: 20_000)
                VStack(alignment: .leading, spacing: 4) {
                    Text(effect.displayName)
                        .font(.caption.bold())
                    ForEach(effect.grades, id: \.id) { grade in
                        let expected = GradeLotteryCheck.expectedRatio(grade: grade, in: effect)
                        let actual = measured[grade.id] ?? 0
                        HStack(spacing: 6) {
                            Text(grade.displayName)
                                .font(.caption2)
                                .frame(width: 76, alignment: .leading)
                            ParamBar(value: Float(actual), lower: 0, upper: 1)
                            Text(String(format: "実測 %.1f%% / 定義 %.1f%%", actual * 100, expected * 100))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 152, alignment: .trailing)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    // MARK: - カタログ

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("読み込まれた加工カタログ")
                .font(.headline)
            Text("加工の追加は、この定義データ1件と Metal 関数1つの追加で完結します。生成ロジックとビューには加工ごとの分岐がありません。")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(store.catalog) { effect in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(effect.displayName)  (\(effect.id) v\(effect.version))")
                        .font(.caption.bold())
                    Text("関数 \(effect.shaderFunction) ／ パラメータ \(effect.paramSchema.count) 件 ／ グレード \(effect.grades.map(\.displayName).joined(separator: "・"))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("代替: \(effect.fallbackEffectID ?? "なし")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

/// 個体の JSON 往復が値を保つかの検査。
enum RoundTripCheck {
    struct Result {
        let passed: Bool
        let detail: String
    }

    static func decoded(_ instance: StickerInstance) -> StickerInstance? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? encoder.encode(instance) else { return nil }
        return try? decoder.decode(StickerInstance.self, from: data)
    }

    static func run(_ instance: StickerInstance) -> Result {
        guard let decoded = decoded(instance) else {
            return Result(passed: false, detail: "エンコードまたはデコードに失敗")
        }
        guard decoded.id == instance.id else {
            return Result(passed: false, detail: "id が一致しない")
        }
        guard decoded.renderParams == instance.renderParams else {
            return Result(passed: false, detail: "renderParams が一致しない")
        }
        guard decoded.renderSeed == instance.renderSeed else {
            return Result(passed: false, detail: "renderSeed が一致しない")
        }
        // 実際にシェーダーへ渡る配列まで一致を見る。
        let definition = EffectCatalog.shared.resolveForRendering(
            id: instance.effectID, fallbackHint: instance.fallbackEffectID
        ).definition
        let a = StickerShader.packedParams(definition: definition, instance: instance)
        let b = StickerShader.packedParams(definition: definition, instance: decoded)
        guard a == b else {
            return Result(passed: false, detail: "シェーダー引数が一致しない")
        }
        return Result(passed: true, detail: "\(a.count) 個のパラメータと seed が完全一致")
    }
}

/// グレード抽選が定義した重みどおりに出ているかを実測する。
enum GradeLotteryCheck {
    static func expectedRatio(grade: GradeDefinition, in effect: EffectDefinition) -> Double {
        let total = effect.grades.reduce(0.0) { $0 + max(0, $1.weight) }
        guard total > 0 else { return 0 }
        return max(0, grade.weight) / total
    }

    /// 固定シードで試行するため、表示のたびに数値が揺れない。
    static func measure(effect: EffectDefinition, trials: Int) -> [String: Double] {
        var rng: SeededGenerator = SeededGenerator(seed: 0x5EED)
        var counts: [String: Int] = [:]
        for _ in 0..<trials {
            if let grade = StickerFactory.rollGrade(effect.grades, using: &rng) {
                counts[grade.id, default: 0] += 1
            }
        }
        return counts.mapValues { Double($0) / Double(trials) }
    }
}
