import Foundation

let json = try! Data(contentsOf: URL(fileURLWithPath: "StickerLab/Catalog/Effects.json"))
let effects = try! JSONDecoder().decode([EffectDefinition].self, from: json)

print("読み込んだ加工: \(effects.count)")
var rng: SeededGenerator = SeededGenerator(seed: 0x5EED)
let trials = 200_000
var failures = 0

for effect in effects {
    print("\n== \(effect.displayName) [\(effect.id)] 関数 \(effect.shaderFunction) ==")

    // グレード抽選の実測
    var counts: [String: Int] = [:]
    for _ in 0..<trials {
        if let g = StickerFactory.rollGrade(effect.grades, using: &rng) { counts[g.id, default: 0] += 1 }
    }
    let total = effect.grades.reduce(0.0) { $0 + $1.weight }
    for grade in effect.grades {
        let expected = grade.weight / total
        let actual = Double(counts[grade.id] ?? 0) / Double(trials)
        let delta = abs(actual - expected)
        let ok = delta < 0.01
        if !ok { failures += 1 }
        print(String(format: "  %@ %-10@ 定義 %.3f  実測 %.3f  差 %.4f", ok ? "OK" : "NG", grade.displayName as NSString, expected, actual, delta))
    }

    // パラメータが必ずスキーマの範囲に収まるか（グレード上書きを含む）
    for _ in 0..<20_000 {
        let grade = StickerFactory.rollGrade(effect.grades, using: &rng)
        let params = StickerFactory.rollParams(schema: effect.paramSchema, grade: grade, using: &rng)
        if params.count != effect.paramSchema.count { failures += 1; print("  NG パラメータ数が一致しない"); break }
        for spec in effect.paramSchema {
            guard let v = params[spec.name] else { failures += 1; print("  NG \(spec.name) が欠落"); break }
            let override = grade?.paramOverrides[spec.name]
            let lo = override.map { min($0[0], $0[1]) } ?? spec.min
            let hi = override.map { max($0[0], $0[1]) } ?? spec.max
            if v < lo - 1e-5 || v > hi + 1e-5 {
                failures += 1
                print("  NG \(spec.name) = \(v) が範囲 [\(lo), \(hi)] の外")
                break
            }
        }
    }
    print("  OK パラメータ 20,000 回すべて範囲内（\(effect.paramSchema.count) 項目）")

    // 個体差：同じ加工から作った個体のパラメータが重複しないか
    var seen = Set<String>()
    var duplicates = 0
    for _ in 0..<5_000 {
        let instance = StickerFactory.make(effect: effect, subjectID: "s", shapeID: "circle", using: &rng)
        let key = effect.paramSchema.map { String(format: "%.6f", instance.renderParams[$0.name] ?? 0) }.joined(separator: ",")
        if !seen.insert(key).inserted { duplicates += 1 }
    }
    if duplicates > 0 { failures += 1 }
    print("  \(duplicates == 0 ? "OK" : "NG") 5,000 個体でパラメータの完全一致は \(duplicates) 件")
}

// JSON 往復
var rt = 0
for effect in effects {
    for _ in 0..<1_000 {
        let a = StickerFactory.make(effect: effect, subjectID: "s", shapeID: "circle", using: &rng)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let b = try! dec.decode(StickerInstance.self, from: try! enc.encode(a))
        if b.renderParams != a.renderParams || b.renderSeed != a.renderSeed || b.id != a.id { rt += 1 }
    }
}
if rt > 0 { failures += 1 }
print("\n\(rt == 0 ? "OK" : "NG") JSON 往復 3,000 件でパラメータと seed が完全一致（不一致 \(rt) 件）")

print(failures == 0 ? "\n=== すべて合格 ===" : "\n=== 失敗 \(failures) 件 ===")
exit(failures == 0 ? 0 : 1)
