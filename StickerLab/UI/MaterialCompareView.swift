import SwiftUI

/// 検証項目1：3材質が、傾けたときに別の材質として知覚されるか。
///
/// 同じ被写体・同じ形状で 3 種を並べ、差が加工だけに由来する状態で比べる。
struct MaterialCompareView: View {
    @EnvironmentObject private var engine: MotionEngine
    @ObservedObject var store: LabStore
    @State private var focusedIndex: Int = LabLaunchOptions.focusedMaterial

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ControlBar(store: store)

                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(store.materialSamples.enumerated()), id: \.element.id) { index, instance in
                        VStack(spacing: 6) {
                            StickerView(instance: instance)
                                .frame(maxWidth: .infinity)
                                .onTapGesture { focusedIndex = index }
                                .overlay {
                                    if index == focusedIndex {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(Color.accentColor, lineWidth: 2)
                                            .padding(-6)
                                    }
                                }
                            Text(store.effectDisplayName(instance.effectID))
                                .font(.caption2)
                                .lineLimit(1)
                            Text(store.gradeDisplayName(instance: instance))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .tiltDraggable(engine: engine, enabled: engine.source == .drag)

                if store.materialSamples.indices.contains(focusedIndex) {
                    let focused = store.materialSamples[focusedIndex]
                    VStack(spacing: 10) {
                        StickerView(instance: focused)
                            .frame(maxWidth: .infinity)
                            .tiltDraggable(engine: engine, enabled: engine.source == .drag)

                        ParamTable(instance: focused)
                    }
                }

                Button {
                    store.rerollMaterials()
                } label: {
                    Label("引き直す（グレード再抽選）", systemImage: "dice")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Text("同じ被写体・同じ形状で 3 材質を並べています。傾けたときに、フラットは面全体の虹が走り、ぷっくりはハイライトの玉が転がり、水入りは中身が遅れて動きます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
    }
}

/// 個体に固定されたパラメータの一覧。
/// 「乱数で決まった値が、この個体に張り付いている」ことを目で確認するための表。
struct ParamTable: View {
    let instance: StickerInstance

    var body: some View {
        let definition = EffectCatalog.shared.definition(id: instance.effectID)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(EffectCatalog.shared.definition(id: instance.effectID)?.displayName ?? instance.effectID)
                    .font(.caption.bold())
                Spacer()
                Text("seed \(String(format: "%.2f", instance.renderSeed))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let definition {
                ForEach(definition.paramSchema, id: \.name) { spec in
                    HStack(spacing: 6) {
                        Text(spec.name)
                            .font(.caption2.monospaced())
                            .frame(width: 106, alignment: .leading)
                        ParamBar(
                            value: instance.renderParams[spec.name] ?? spec.min,
                            lower: spec.min,
                            upper: spec.max
                        )
                        Text(String(format: "%.3f", instance.renderParams[spec.name] ?? spec.min))
                            .font(.caption2.monospacedDigit())
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            } else {
                Text("この加工の定義をこのアプリは持っていません")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct ParamBar: View {
    let value: Float
    let lower: Float
    let upper: Float

    var body: some View {
        GeometryReader { proxy in
            let ratio = upper > lower ? CGFloat((value - lower) / (upper - lower)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(2, proxy.size.width * min(max(ratio, 0), 1)))
            }
        }
        .frame(height: 5)
    }
}
