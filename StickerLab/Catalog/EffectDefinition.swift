import Foundation

/// 加工パラメータ1件の定義。
///
/// SPEC 6.3 に従い、生成ロジックはこの宣言だけを読んで乱数を振る。
/// 加工ごとの `if` 分岐は一切書かない。
struct ParamSpec: Codable, Hashable {
    enum Distribution: String, Codable {
        /// 範囲内の一様乱数。
        case uniform
        /// 範囲内の一様乱数を段階数で量子化する（パターン番号など離散値向け）。
        case quantized
        /// 中央に寄る分布（三角分布）。極端な値が出にくい。
        case centered
    }

    /// シェーダーへ渡す際の識別子。`renderParams` の辞書キーになる。
    let name: String
    let min: Float
    let max: Float
    var distribution: Distribution = .uniform
    /// `.quantized` のときの段階数。
    var steps: Int?
    /// UI 表示用の説明。検証時にどのパラメータが効いているか判別するために持つ。
    var note: String?

    private enum CodingKeys: String, CodingKey {
        case name, min, max, distribution, steps, note
    }
}

/// 加工グレード（レア度）の定義。
///
/// グレードは選択制ではなく抽選制（SPEC 2.3）。
/// グレードは `paramOverrides` で任意のパラメータの乱数範囲を上書きできるため、
/// 「高グレードほど派手」を加工ごとの分岐なしに表現できる。
struct GradeDefinition: Codable, Hashable {
    let id: String
    let displayName: String
    /// 抽選の重み。定義内の合計に対する比率で決まる。
    let weight: Double
    /// パラメータ名 -> [min, max] の上書き。
    var paramOverrides: [String: [Float]] = [:]

    private enum CodingKeys: String, CodingKey {
        case id, displayName, weight, paramOverrides
    }
}

/// 加工の定義。アプリに同梱される宣言データ（SPEC 6.3）。
///
/// 加工の追加は「この定義1件 + Metal 関数1つ」で完結することを設計目標とする。
struct EffectDefinition: Codable, Hashable, Identifiable {
    /// 一意かつ不変。個体はこの ID で定義を参照する。
    let id: String
    let version: Int
    let displayName: String
    /// 材質の分類。傾けたときの追従挙動（スロッシュ特性）の選択にのみ使う。
    let material: MaterialClass
    /// Metal 側の [[stitchable]] 関数名。
    let shaderFunction: String
    /// パラメータ定義。**この配列の順序が、シェーダーへ渡す float 配列の添字と対応する。**
    let paramSchema: [ParamSpec]
    let grades: [GradeDefinition]
    /// 未対応時の代替加工 ID（SPEC 6.5）。
    var fallbackEffectID: String?

    enum MaterialClass: String, Codable {
        /// 平面。傾きに即座に追従する。
        case flat
        /// 厚みを持つ。わずかに遅れて追従する。
        case puffy
        /// 内部に流体を封じる。大きく遅れて揺れ戻す。
        case liquid
    }

    private enum CodingKeys: String, CodingKey {
        case id, version, displayName, material, shaderFunction, paramSchema, grades, fallbackEffectID
    }
}
