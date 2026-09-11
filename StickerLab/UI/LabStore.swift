import SwiftUI

extension StickerInstance {
    /// 同じ個体のまま、被写体と形状だけ差し替える。
    ///
    /// 検証用。`id` と `renderParams` を保つため、素材を変えても同じ個体の光り方を追える。
    func replacingSubject(subjectID: String, shapeID: String) -> StickerInstance {
        StickerInstance(
            id: id,
            subjectID: subjectID,
            shapeID: shapeID,
            effectID: effectID,
            effectVersion: effectVersion,
            fallbackEffectID: fallbackEffectID,
            grade: grade,
            renderParams: renderParams,
            schemaVersion: schemaVersion,
            createdAt: createdAt
        )
    }

    /// 未知の加工 ID を持つ個体を作る。旧バージョン端末が受け取った状況の再現に使う。
    func withUnknownEffect(id unknownID: String) -> StickerInstance {
        StickerInstance(
            id: id,
            subjectID: subjectID,
            shapeID: shapeID,
            effectID: unknownID,
            effectVersion: 99,
            fallbackEffectID: fallbackEffectID,
            grade: grade,
            renderParams: renderParams,
            schemaVersion: schemaVersion,
            createdAt: createdAt
        )
    }
}

@MainActor
final class LabStore: ObservableObject {
    @Published var subjectID: String = "sunset" { didSet { reapplySubject() } }
    @Published var shapeID: String = "circle" { didSet { reapplySubject() } }

    /// 材質比較用。加工ごとに1枚ずつ。
    @Published private(set) var materialSamples: [StickerInstance] = []
    /// 個体差検証用。同一加工・同一被写体で複数枚。
    @Published private(set) var variantSamples: [StickerInstance] = []
    @Published var variantEffectID: String = "water.capsule.v1" { didSet { rerollVariants() } }
    /// 描画負荷検証用。
    @Published private(set) var stressSamples: [StickerInstance] = []
    @Published var stressCount: Int = 12 { didSet { rebuildStress() } }
    /// フォールバック検証用。カタログに存在しない ID を持たせた個体。
    @Published private(set) var fallbackSample: StickerInstance?
    @Published private(set) var fallbackOriginal: StickerInstance?

    private var rng: SystemRandomNumberGenerator = SystemRandomNumberGenerator()

    var catalog: [EffectDefinition] { EffectCatalog.shared.effects }

    init() {
        rerollAll()
    }

    func rerollAll() {
        rerollMaterials()
        rerollVariants()
        rebuildStress()
        rerollFallback()
    }

    func rerollMaterials() {
        materialSamples = catalog.map { effect in
            StickerFactory.make(effect: effect, subjectID: subjectID, shapeID: shapeID, using: &rng)
        }
    }

    func rerollVariants() {
        guard let effect = catalog.first(where: { $0.id == variantEffectID }) ?? catalog.first else { return }
        variantSamples = (0..<6).map { _ in
            StickerFactory.make(effect: effect, subjectID: subjectID, shapeID: shapeID, using: &rng)
        }
    }

    func rebuildStress() {
        let shapes = StickerShape.allIDs
        stressSamples = (0..<stressCount).compactMap { index in
            var instance = StickerFactory.makeRandom(
                catalog: catalog,
                subjectID: subjectID,
                shapeID: shapes[index % shapes.count],
                using: &rng
            )
            if instance == nil, let first = catalog.first {
                instance = StickerFactory.make(effect: first, subjectID: subjectID, shapeID: shapeID, using: &rng)
            }
            return instance
        }
    }

    func rerollFallback() {
        guard let effect = catalog.first(where: { $0.id == "water.capsule.v1" }) ?? catalog.first else { return }
        let original = StickerFactory.make(effect: effect, subjectID: subjectID, shapeID: shapeID, using: &rng)
        fallbackOriginal = original
        // 将来のバージョンで追加される加工を想定した、このアプリが知らない ID。
        fallbackSample = original.withUnknownEffect(id: "aurora.ribbon.v4")
    }

    private func reapplySubject() {
        materialSamples = materialSamples.map { $0.replacingSubject(subjectID: subjectID, shapeID: shapeID) }
        variantSamples = variantSamples.map { $0.replacingSubject(subjectID: subjectID, shapeID: shapeID) }
        fallbackSample = fallbackSample?.replacingSubject(subjectID: subjectID, shapeID: shapeID)
        fallbackOriginal = fallbackOriginal?.replacingSubject(subjectID: subjectID, shapeID: shapeID)
        let shapes = StickerShape.allIDs
        stressSamples = stressSamples.enumerated().map { index, instance in
            instance.replacingSubject(subjectID: subjectID, shapeID: shapes[index % shapes.count])
        }
    }

    func effectDisplayName(_ id: String) -> String {
        EffectCatalog.shared.definition(id: id)?.displayName ?? id
    }

    func gradeDisplayName(instance: StickerInstance) -> String {
        guard let definition = EffectCatalog.shared.definition(id: instance.effectID) else { return instance.grade }
        return definition.grades.first { $0.id == instance.grade }?.displayName ?? instance.grade
    }
}
