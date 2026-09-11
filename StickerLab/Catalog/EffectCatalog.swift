import Foundation

/// 同梱の定義データを読み込み、ID から加工定義を引くカタログ。
///
/// 未知の ID に対しては `fallbackEffectID` を辿り、最終的に汎用のフラット表示へ落とす（SPEC 6.5）。
/// このフォールバックは「旧バージョン端末が新しい加工のシールを受け取る」状況の予行であり、
/// フェーズ0で経路を通しておく。
final class EffectCatalog {
    static let shared = EffectCatalog()

    /// フォールバックの最終到達先。この ID は将来にわたって削除しない。
    static let universalFallbackID = "flat.foil.v1"

    private(set) var effects: [EffectDefinition] = []
    private var index: [String: EffectDefinition] = [:]

    private init() {
        load()
    }

    private func load() {
        guard let url = Bundle.main.url(forResource: "Effects", withExtension: "json") else {
            assertionFailure("Effects.json がバンドルに含まれていない")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            effects = try JSONDecoder().decode([EffectDefinition].self, from: data)
            index = Dictionary(uniqueKeysWithValues: effects.map { ($0.id, $0) })
        } catch {
            assertionFailure("Effects.json の解析に失敗: \(error)")
        }
    }

    /// 定義をそのまま引く。未知なら nil。
    func definition(id: String) -> EffectDefinition? {
        index[id]
    }

    /// 描画に使う定義を解決する。
    ///
    /// 戻り値の `isFallback` が true のとき、個体は本来の見た目で描かれていない。
    /// 個体データ自体は欠損させないため、アプリ更新後に本来の表示へ戻る。
    func resolveForRendering(id: String, fallbackHint: String? = nil) -> (definition: EffectDefinition, isFallback: Bool) {
        if let exact = index[id] {
            return (exact, false)
        }
        // 個体が持ち込んだ代替 ID を先に試す。
        var candidate = fallbackHint
        var hops = 0
        while let next = candidate, hops < 8 {
            if let def = index[next] {
                return (def, true)
            }
            candidate = nil
            hops += 1
        }
        if let universal = index[Self.universalFallbackID] {
            return (universal, true)
        }
        // 定義データが壊れている場合の最終防衛線。ここへ来ても落とさない。
        return (Self.emergencyDefinition, true)
    }

    /// カタログが空でも描画経路を維持するための最小定義。
    static let emergencyDefinition = EffectDefinition(
        id: "builtin.emergency",
        version: 1,
        displayName: "未対応の加工",
        material: .flat,
        shaderFunction: "fx_flatFoil",
        paramSchema: [],
        grades: [GradeDefinition(id: "normal", displayName: "ノーマル", weight: 1)],
        fallbackEffectID: nil
    )
}
