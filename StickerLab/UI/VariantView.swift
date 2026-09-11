import SwiftUI

/// 検証項目2：乱数パラメータによる個体差が、目で見て分かるか。
///
/// 同じ加工・同じ被写体・同じ形状で複数枚を並べる。
/// ここで差が知覚できない場合、パラメータの範囲設計が足りていない。
struct VariantView: View {
    @EnvironmentObject private var engine: MotionEngine
    @ObservedObject var store: LabStore
    @State private var inspected: StickerInstance?

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ControlBar(store: store)

                Picker("加工", selection: $store.variantEffectID) {
                    ForEach(store.catalog) { effect in
                        Text(effect.displayName).tag(effect.id)
                    }
                }
                .pickerStyle(.segmented)

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.variantSamples) { instance in
                        VStack(spacing: 4) {
                            StickerView(instance: instance)
                            Text(store.gradeDisplayName(instance: instance))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .onTapGesture { inspected = instance }
                    }
                }
                .tiltDraggable(engine: engine, enabled: engine.source == .drag)

                Button {
                    store.rerollVariants()
                } label: {
                    Label("6枚とも引き直す", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Text("同じ加工・同じ写真から作った 6 個体です。光り方が一枚ずつ違うこと、そしてその違いが下のパラメータの値と対応していることを確認します。タップで詳細。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .sheet(item: $inspected) { instance in
            InstanceDetailSheet(instance: instance)
        }
    }
}

struct InstanceDetailSheet: View {
    let instance: StickerInstance
    @EnvironmentObject private var engine: MotionEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    StickerView(instance: instance)
                        .frame(maxWidth: .infinity)
                        .tiltDraggable(engine: engine, enabled: engine.source == .drag)
                    ParamTable(instance: instance)
                    InstanceJSONView(instance: instance)
                }
                .padding(16)
            }
            .navigationTitle("個体")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

struct InstanceJSONView: View {
    let instance: StickerInstance

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("転送されるデータ")
                .font(.caption.bold())
            Text("シェーダーのコードは送らず、ID とパラメータだけを送る（SPEC 6.5）。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                Text(json)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(instance), let text = String(data: data, encoding: .utf8) else {
            return "エンコードに失敗"
        }
        return text
    }
}
